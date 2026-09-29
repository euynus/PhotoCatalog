// ============================================================
//  DevelopRenderer — non-destructive rendering with Core Image
// ============================================================
import CoreImage
import ImageIO
import Foundation
import Vision

enum DevelopRenderer {
    /// One GPU context for the app: contexts are expensive to create and safe to share.
    static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!,
        .cacheIntermediates: false,
    ])
    static let outputColorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
    static let linearColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!

    /// A photo decoded once and re-rendered as its settings change. Not thread-safe:
    /// confine each instance to one queue (the RAW filter is mutated per render).
    final class Source: @unchecked Sendable {
        let url: URL
        let isRaw: Bool
        /// White balance the camera recorded (RAW only).
        let asShotTemperature: Double?
        let asShotTint: Double?
        private let raw: CIRAWFilter?
        private let base: CIImage?
        private let cachesRawStage: Bool
        /// The RAW stage (demosaic, white balance, exposure) rendered once into a linear
        /// half-float bitmap. Re-running CIRAWFilter costs ~0.5–2 s per change, so tone and color
        /// render from this cache; white balance and exposure drags apply as deltas on it.
        private var rawStage: (key: RawStageKey, image: CIImage)?
        /// The engine's tone curve for this photo, measured in the background from the first
        /// exposure draft on (guarded by `boostLock`: the measurement finishes on another queue).
        private let boostLock = NSLock()
        private var measuredBoost: BoostCurve?
        private var boostRequested = false
        private lazy var cameraModel: String = {
            ((raw?.properties["{TIFF}"] as? [String: Any])?["Model"] as? String) ?? ""
        }()
        private static let boostQueue = DispatchQueue(label: "PhotoCatalog.boost-curve", qos: .utility)
        /// Size of the decoded photo before rotation and crop, known after the first render.
        private(set) var sourceSize: CGSize?
        /// Long edge of the original at full resolution: detail radii are given at that size and
        /// scale down with the render so a preview shows the same look as the full photo.
        private let fullLongEdge: CGFloat

        private struct RawStageKey: Equatable {
            let temperature: Double
            let tint: Double
            let exposure: Double
        }

        /// `maxPixel` bounds the long edge (nil = full resolution). `interactive` sources keep
        /// the RAW stage for fast slider drags; one-shot renders (export, thumbnails) skip it.
        init?(url: URL, isRaw: Bool, maxPixel: Int?, interactive: Bool = true) {
            self.url = url
            self.isRaw = isRaw
            // a full-resolution half-float stage would be ~190 MB
            cachesRawStage = interactive && maxPixel != nil
            if isRaw, let raw = CIRAWFilter(imageURL: url) {
                let native = raw.nativeSize
                let longEdge = max(native.width, native.height)
                fullLongEdge = longEdge
                if let maxPixel, longEdge > CGFloat(maxPixel) {
                    raw.scaleFactor = Float(CGFloat(maxPixel) / longEdge)
                }
                self.raw = raw
                base = nil
                asShotTemperature = Double(raw.neutralTemperature)
                asShotTint = Double(raw.neutralTint)
            } else {
                guard let decoded = Self.decode(url, maxPixel: maxPixel) else { return nil }
                fullLongEdge = CGFloat(decoded.fullLongEdge)
                raw = nil
                base = CIImage(cgImage: decoded.image)
                asShotTemperature = nil
                asShotTint = nil
            }
        }

        /// The photo with `settings` applied. `wholeFrame` skips the crop and leaves the corners a
        /// straightened photo no longer covers empty, for the crop tool to draw over;
        /// `overlayMask` tints that mask's coverage red, for the masking tool; `visualizeSpots`
        /// shows only fine detail, where dust stands out, for the spot tool.
        func image(_ settings: DevelopSettings, draft: Bool = false, wholeFrame: Bool = false,
                   overlayMask: String? = nil, visualizeSpots: Bool = false) -> CIImage? {
            guard let base = baseImage(settings, draft: draft) else { return nil }
            sourceSize = base.extent.integral.size
            let scale = max(base.extent.width, base.extent.height) / max(fullLongEdge, 1)
            let healed = DevelopRenderer.applySpots(DevelopRenderer.applyLens(base, settings), settings)
            let toned = DevelopRenderer.applyTone(healed, settings)
            let colored = DevelopRenderer.applyMixer(DevelopRenderer.applyCurve(toned, settings), settings)
            let present = DevelopRenderer.applyPresence(colored, settings)
            let photo = (url: url, isRaw: isRaw)
            let local = DevelopRenderer.applyOverlay(DevelopRenderer.applyMasks(present, settings, photo: photo), settings,
                                                     maskId: overlayMask, photo: photo, rangeSource: present)
            let detailed = DevelopRenderer.applyDetail(local, settings, scale: min(1, scale))
            let framed = DevelopRenderer.applyGeometry(detailed, settings, wholeFrame: wholeFrame)
            // effects follow the crop, which the crop tool's whole-frame view doesn't apply yet
            let finished = wholeFrame ? framed : DevelopRenderer.applyEffects(framed, settings, scale: min(1, scale))
            return visualizeSpots ? DevelopRenderer.visualizeSpots(finished) : finished
        }

        /// The decoded photo with white balance and exposure: linear light, before any other edit.
        private func baseImage(_ settings: DevelopSettings, draft: Bool) -> CIImage? {
            if let raw {
                let key = RawStageKey(temperature: settings.temperature ?? asShotTemperature ?? 6500,
                                      tint: settings.tint ?? asShotTint ?? 0,
                                      exposure: settings.exposure)
                guard cachesRawStage else { return rawOutput(raw, key, draft: draft) }
                // Rebuild the stage accurately when missing, or once a white-balance/exposure drag ends.
                if rawStage == nil || (!draft && rawStage?.key != key),
                   let output = rawOutput(raw, key, draft: false),
                   let bitmap = DevelopRenderer.context.createCGImage(
                       output, from: output.extent.integral, format: .RGBAh, colorSpace: DevelopRenderer.linearColorSpace) {
                    rawStage = (key, CIImage(cgImage: bitmap))
                }
                guard let stage = rawStage else { return nil }
                var image = stage.image
                if stage.key.exposure != key.exposure {
                    let delta = key.exposure - stage.key.exposure
                    if let curve = boostCurve() {
                        // exposure acts before the engine's tone curve, as in the settled render
                        image = image.applyingFilter("CIColorCurves", parameters: [
                            "inputCurvesData": curve.exposureTable(delta: delta),
                            "inputCurvesDomain": CIVector(x: 0, y: 1),
                            "inputColorSpace": DevelopRenderer.outputColorSpace,
                        ])
                    } else {
                        image = image.applyingFilter("CIExposureAdjust", parameters: ["inputEV": delta])
                    }
                }
                if stage.key.temperature != key.temperature || stage.key.tint != key.tint {
                    // a higher Kelvin setting treats the light as warmer-neutral, so the photo warms
                    image = image.applyingFilter("CITemperatureAndTint", parameters: [
                        "inputNeutral": CIVector(x: key.temperature, y: key.tint),
                        "inputTargetNeutral": CIVector(x: stage.key.temperature, y: stage.key.tint),
                    ])
                }
                return image
            }
            guard var image = base else { return nil }
            if settings.exposure != 0 {
                image = image.applyingFilter("CIExposureAdjust", parameters: ["inputEV": settings.exposure])
            }
            let warmth = settings.temperature ?? 0
            let tint = settings.tint ?? 0
            if warmth != 0 || tint != 0 {
                // Relative shifts: telling Core Image the scene was lit by a cooler source warms it.
                image = image.applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: 6500 + warmth * 25, y: tint * 0.5),
                    "inputTargetNeutral": CIVector(x: 6500, y: 0),
                ])
            }
            return image
        }

        /// The engine's tone curve for exposure drafts. The first call starts measuring this
        /// photo's in the background — two decodes take seconds, too long to hold up a drag —
        /// and until it's ready the last one measured for the same camera stands in (or none).
        private func boostCurve() -> BoostCurve? {
            let (measured, requested) = boostLock.withLock { (measuredBoost, boostRequested) }
            if let measured { return measured }
            let camera = cameraModel
            if !requested {
                boostLock.withLock { boostRequested = true }
                let url = self.url
                Self.boostQueue.async { [weak self] in
                    guard let curve = BoostCurve.measure(url: url) else { return }
                    BoostCurve.remember(curve, camera: camera)
                    guard let self else { return }
                    self.boostLock.withLock { self.measuredBoost = curve }
                }
            }
            return BoostCurve.remembered(camera: camera)
        }

        private func rawOutput(_ raw: CIRAWFilter, _ key: RawStageKey, draft: Bool) -> CIImage? {
            raw.isDraftModeEnabled = draft
            raw.exposure = Float(key.exposure)
            raw.neutralTemperature = Float(key.temperature)
            raw.neutralTint = Float(key.tint)
            return raw.outputImage
        }

        /// The decoded image and the original's long edge in pixels.
        private static func decode(_ url: URL, maxPixel: Int?) -> (image: CGImage, fullLongEdge: Int)? {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
            else { return nil }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let full = max(properties?[kCGImagePropertyPixelWidth] as? Int ?? 0,
                           properties?[kCGImagePropertyPixelHeight] as? Int ?? 0, 1)
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: min(full, maxPixel ?? full),
            ] as CFDictionary) else { return nil }
            return (image, full)
        }
    }

    /// 64-bin R, G, B histogram of a rendered image (fractions of pixels), computed on the GPU
    /// from the encoded display values — what the eye sees, not linear light.
    static func histogram(of image: CGImage) -> DevelopHistogram? {
        var input = CIImage(cgImage: image, options: [.colorSpace: NSNull()])
        let longEdge = max(input.extent.width, input.extent.height)
        if longEdge > 1024 {   // a downsampled render has the same distribution
            let scale = 1024 / longEdge
            input = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let histogram = input.applyingFilter("CIAreaHistogram", parameters: [
            "inputExtent": CIVector(cgRect: input.extent),
            "inputCount": DevelopHistogram.binCount,
            "inputScale": 1,
        ])
        var bins = [Float](repeating: 0, count: DevelopHistogram.binCount * 4)
        context.render(histogram, toBitmap: &bins, rowBytes: DevelopHistogram.binCount * 16,
                       bounds: CGRect(x: 0, y: 0, width: DevelopHistogram.binCount, height: 1),
                       format: .RGBAf, colorSpace: nil)
        let channel = { (offset: Int) in stride(from: offset, to: bins.count, by: 4).map { Double(bins[$0]) } }
        return DevelopHistogram(red: channel(0), green: channel(1), blue: channel(2))
    }

    static func render(_ image: CIImage) -> CGImage? {
        context.createCGImage(image, from: image.extent.integral, format: .RGBA8, colorSpace: outputColorSpace)
    }

    /// Rotation, mirror, straighten and crop (see `DevelopSettings`). The result's origin is zero.
    static func applyGeometry(_ input: CIImage, _ s: DevelopSettings, wholeFrame: Bool = false) -> CIImage {
        guard s.hasGeometry else { return input }
        let orientations: [CGImagePropertyOrientation] = [.up, .right, .down, .left]   // clockwise turns
        var image = input.oriented(orientations[((s.rotation % 4) + 4) % 4])
        if s.flipped { image = image.oriented(.upMirrored) }
        image = atOrigin(image)
        let frame = CGRect(origin: .zero, size: image.extent.integral.size)
        if let perspective = DevelopGeometry.perspective(s, frame: frame.size) {
            // the frame's corners where the correction puts them (Core Image's y points up);
            // outside the corrected photo stays empty, and the crop leaves it out
            func corner(_ x: CGFloat, _ y: CGFloat) -> CIVector {
                let p = perspective.apply(CGPoint(x: x, y: y)) ?? CGPoint(x: x, y: y)
                return CIVector(x: p.x, y: frame.height - p.y)
            }
            image = image.applyingFilter("CIPerspectiveTransform", parameters: [
                "inputTopLeft": corner(0, 0), "inputTopRight": corner(frame.width, 0),
                "inputBottomRight": corner(frame.width, frame.height), "inputBottomLeft": corner(0, frame.height),
            ]).cropped(to: frame)
        }
        if s.straighten != 0 {
            // Core Image's y axis points up, so a clockwise turn is a negative angle
            let turn = CGAffineTransform(translationX: frame.midX, y: frame.midY)
                .rotated(by: -s.straighten * .pi / 180)
                .translatedBy(x: -frame.midX, y: -frame.midY)
            image = image.clampedToExtent().transformed(by: turn).cropped(to: frame)
            if wholeFrame {
                // outside the turned photo stays empty so the crop tool shows where the photo ends
                let mask = CIImage(color: .white).cropped(to: frame).transformed(by: turn)
                image = image.applyingFilter("CIBlendWithAlphaMask", parameters: [
                    kCIInputBackgroundImageKey: CIImage.empty(),
                    kCIInputMaskImageKey: mask,
                ]).cropped(to: frame)
            }
        }
        guard !wholeFrame else { return image }
        let crop = DevelopGeometry.effectiveCrop(s, frame: frame.size)
        let x = (crop.x * frame.width).rounded(), width = max(1, (crop.width * frame.width).rounded())
        let height = max(1, (crop.height * frame.height).rounded())
        let y = ((1 - crop.y) * frame.height).rounded() - height   // top-left fractions → bottom-left pixels
        return atOrigin(image.cropped(to: CGRect(x: x, y: max(0, y), width: width, height: height)))
    }

    /// The straighten angle (degrees, positive = clockwise) that levels the horizon Vision
    /// finds in the photo as rotated and mirrored by `settings`; nil when it finds none.
    static func horizonAngle(url: URL, isRaw: Bool, settings: DevelopSettings) -> Double? {
        var oriented = DevelopSettings()
        oriented.rotation = settings.rotation
        oriented.flipped = settings.flipped
        guard let image = Source(url: url, isRaw: isRaw, maxPixel: 1024)?.image(oriented).flatMap(render) else {
            return nil
        }
        let request = VNDetectHorizonRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        // Vision reports a horizon rising to the right as a negative angle, which a clockwise
        // (positive) straighten of the same size levels
        return request.results?.first.map { -Double($0.angle) * 180 / .pi }
    }

    /// The Transform and straighten settings that set the photo's verticals upright (see
    /// `Upright`), found in the photo as rotated, mirrored and lens-corrected by `settings`.
    static func uprightCorrection(url: URL, isRaw: Bool, settings: DevelopSettings,
                                  mode: Upright.Mode) -> Upright.Correction? {
        var oriented = DevelopSettings()
        oriented.rotation = settings.rotation
        oriented.flipped = settings.flipped
        oriented.distortion = settings.distortion   // lens distortion bends the lines it looks for
        guard let image = Source(url: url, isRaw: isRaw, maxPixel: 900)?.image(oriented).flatMap(render),
              let pixels = SemanticMasks.rgba(image) else { return nil }
        let count = image.width * image.height
        var luma = [Float](repeating: 0, count: count)
        for i in 0..<count {
            luma[i] = (0.2126 * Float(pixels[i * 4]) + 0.7152 * Float(pixels[i * 4 + 1])
                       + 0.0722 * Float(pixels[i * 4 + 2])) / 255
        }
        return Upright.correction(luma: luma, width: image.width, height: image.height, mode: mode)
    }

    private static func atOrigin(_ image: CIImage) -> CIImage {
        let origin = image.extent.origin
        return origin == .zero ? image : image.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
    }

    /// Manual lens corrections on linear light: vignetting first (it belongs to the lens's own
    /// frame), then distortion.
    static func applyLens(_ input: CIImage, _ s: DevelopSettings) -> CIImage {
        guard s.hasLensCorrection else { return input }
        let start = s.lensVignetteMidpoint / 100 * 0.8
        // +100 lifts the corners 1.3 EV, -100 darkens them as much
        let amount = s.lensVignette >= 0 ? s.lensVignette / 100 * 1.5 : s.lensVignette / 100 * 0.6
        let corrected = DevelopKernels.radialGain(input, amount: amount, start: start, width: 1 - start)
        return DevelopKernels.distort(corrected, k: s.distortion / 100 * 0.15)
    }

    /// The point curves, as one lookup table per channel applied to display-encoded values
    /// (CIColorCurves converts to Display P3 for the table and back).
    static func applyCurve(_ input: CIImage, _ s: DevelopSettings) -> CIImage {
        guard !s.curve.isLinear else { return input }
        return input.applyingFilter("CIColorCurves", parameters: [
            "inputCurvesData": curveTable(s.curve),
            "inputCurvesDomain": CIVector(x: 0, y: 1),
            "inputColorSpace": outputColorSpace,
        ])
    }

    /// The HSL mixer, then color grading, on display-encoded values.
    static func applyMixer(_ input: CIImage, _ s: DevelopSettings) -> CIImage {
        guard !s.mixer.isNeutral || !s.grading.isNeutral else { return input }
        let encoded = input.applyingFilter("CILinearToSRGBToneCurve")
        return DevelopKernels.colorGrading(DevelopKernels.colorMixer(encoded, s.mixer), s.grading)
            .applyingFilter("CISRGBToneCurveToLinear")
    }

    private static let curveTables = NSCache<NSString, NSData>()

    /// 1024 RGB float triples: each channel's curve after the composite.
    static func curveTable(_ curve: ToneCurve) -> Data {
        let key = curve.fingerprintText as NSString
        if let cached = curveTables.object(forKey: key) { return cached as Data }
        let size = 1024
        var values = [Float](repeating: 0, count: size * 3)
        for i in 0..<size {
            let x = Double(i) / Double(size - 1)
            values[i * 3] = Float(curve.value(x, channel: .red))
            values[i * 3 + 1] = Float(curve.value(x, channel: .green))
            values[i * 3 + 2] = Float(curve.value(x, channel: .blue))
        }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        curveTables.setObject(data as NSData, forKey: key)
        return data
    }

    /// Dehaze, clarity and texture, in display-encoded values. Their radii are fractions of the
    /// photo's long edge, so a preview and the full photo look alike.
    static func applyPresence(_ input: CIImage, _ s: DevelopSettings) -> CIImage {
        guard s.hasPresence else { return input }
        let extent = input.extent
        let longEdge = Double(max(extent.width, extent.height))
        var image = input.applyingFilter("CILinearToSRGBToneCurve")
        image = DevelopKernels.dehaze(image, amount: s.dehaze / 100)
        // negative amounts stop at removing the detail at that scale, never inverting it
        func gain(_ value: Double, up: Double) -> Double { value >= 0 ? value / 100 * up : value / 100 }
        image = DevelopKernels.localContrast(image, sigma: longEdge * 0.008, amount: gain(s.clarity, up: 2), bias: 1)
        image = DevelopKernels.localContrast(image, sigma: max(0.7, longEdge * 0.0012), amount: gain(s.texture, up: 1.5),
                                             bias: 0.5)
        return image.applyingFilter("CISRGBToneCurveToLinear").cropped(to: extent)
    }

    /// A mask's weight over `extent`: drawn masks from their shapes and strokes, a subject or
    /// sky from the photo itself (`photo`, the file being rendered), then any brush strokes
    /// that add to or erase from a mask that isn't itself a brush.
    static func maskWeight(_ mask: LocalAdjustment, _ s: DevelopSettings, extent: CGRect,
                           photo: (url: URL, isRaw: Bool)?, rangeSource: CIImage? = nil) -> CIImage? {
        let base: CIImage?
        if mask.kind.isRange {
            // the whole photo, narrowed to its range below
            base = CIImage(color: .white).cropped(to: extent)
        } else if mask.kind.isAutomatic {
            switch photo.map({ SemanticMasks.lookup(mask.kind, url: $0.url, isRaw: $0.isRaw) }) {
            case .found(let result):
                base = SemanticMasks.weight(result, extent: extent, inverted: mask.inverted, distortion: s.distortion)
            case .notFound:
                // no subject (or sky) in the photo: everything else is the whole photo
                base = mask.inverted ? CIImage(color: .white).cropped(to: extent) : nil
            case .unreadable, nil:
                base = nil
            }
        } else {
            base = DevelopKernels.maskWeight(mask, extent: extent)
        }
        guard var weight = base else { return nil }
        if mask.kind != .brush, !mask.kind.isRange, !mask.strokes.isEmpty {
            weight = BrushRaster.refine(weight, strokes: mask.strokes, extent: extent)
        }
        // a range narrows what the mask covers, judged on the photo before its masks
        if let range = mask.range, let source = rangeSource,
           let narrowed = DevelopKernels.rangeWeight(range, image: source.applyingFilter("CILinearToSRGBToneCurve")) {
            weight = weight.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: narrowed])
                .cropped(to: extent)
            // a range mask inverted is everything outside the range
            if mask.kind.isRange, mask.inverted { weight = weight.applyingFilter("CIColorInvert") }
        }
        return weight
    }

    /// Each mask's adjustments, blended in through its weight, in order: exposure and white
    /// balance as on the whole photo, then the shared tone and presence code.
    static func applyMasks(_ input: CIImage, _ s: DevelopSettings, photo: (url: URL, isRaw: Bool)? = nil) -> CIImage {
        guard s.masks.contains(where: \.hasEffect) else { return input }
        let extent = input.extent
        var image = input
        for mask in s.masks where mask.hasEffect {
            guard let weight = maskWeight(mask, s, extent: extent, photo: photo, rangeSource: input) else { continue }
            var adjusted = image
            if mask.exposure != 0 {
                adjusted = adjusted.applyingFilter("CIExposureAdjust", parameters: ["inputEV": mask.exposure])
            }
            if mask.temperature != 0 || mask.tint != 0 {
                // the relative scale of non-RAW white balance: a cooler assumed light warms
                adjusted = adjusted.applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: 6500 + mask.temperature * 25, y: mask.tint * 0.5),
                    "inputTargetNeutral": CIVector(x: 6500, y: 0),
                ])
            }
            let tone = mask.toneSettings
            adjusted = applyPresence(applyTone(adjusted, tone), tone)
            image = adjusted.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: image,
                kCIInputMaskImageKey: weight,
            ]).cropped(to: extent)
        }
        return image
    }

    /// Each spot healed or cloned over, in order, on the lens-corrected photo. Every spot's work
    /// is cropped to its own disc, so Core Image only computes the neighborhood around it.
    static func applySpots(_ input: CIImage, _ s: DevelopSettings) -> CIImage {
        guard !s.spots.isEmpty else { return input }
        let extent = input.extent
        let longEdge = max(extent.width, extent.height)
        let clear = CIImage(color: .clear).cropped(to: extent)
        var image = input
        func pixel(_ p: CGPoint) -> CGPoint {
            CGPoint(x: extent.minX + p.x * extent.width, y: extent.maxY - p.y * extent.height)
        }
        for spot in s.spots where spot.opacity > 0 {
            let radius = max(1, CGFloat(spot.radius) * longEdge)
            let target = pixel(spot.target), source = pixel(spot.source)
            let region = CGRect(x: target.x - radius, y: target.y - radius, width: radius * 2, height: radius * 2)
                .insetBy(dx: -2, dy: -2).intersection(extent)
            guard !region.isNull,
                  let disc = DevelopKernels.disc(center: target, radius: radius, feather: spot.feather / 100, extent: extent)
            else { continue }
            let shifted = image.clampedToExtent()
                .transformed(by: CGAffineTransform(translationX: target.x - source.x, y: target.y - source.y))
            var patch = shifted.cropped(to: extent)
            // where the speck lands in the moved copy: a source close to the spot has the speck
            // in its own surroundings
            let ghost = CGPoint(x: 2 * target.x - source.x, y: 2 * target.y - source.y)
            if spot.mode == .heal,
               let ring = DevelopKernels.disc(center: target, radius: radius * 1.05, feather: 0.05, invert: true,
                                              extent: extent),
               let speck = DevelopKernels.disc(center: ghost, radius: radius * 1.05, feather: 0.05, invert: true,
                                               extent: extent) {
                // each side's surroundings, the speck left out of both (the same window on each
                // side, so they compare alike): blur a copy whose alpha is the ring
                let window = ring.applyingFilter("CIMinimumCompositing", parameters: [kCIInputBackgroundImageKey: speck])
                func surroundings(_ image: CIImage) -> CIImage {
                    image.applyingFilter("CIBlendWithMask", parameters: [
                        kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: window,
                    ]).applyingGaussianBlur(sigma: Double(radius) * 0.6)
                }
                patch = DevelopKernels.heal(patch, sourceRing: surroundings(patch), targetRing: surroundings(image),
                                            extent: extent) ?? patch
            }
            let strength = disc.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: spot.opacity / 100, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: spot.opacity / 100, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: spot.opacity / 100, w: 0),
            ])
            image = patch.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: strength,
            ]).cropped(to: region).composited(over: image)
        }
        return image.cropped(to: extent)
    }

    /// Fine detail only, white on black: dust and specks show up as small rings.
    static func visualizeSpots(_ input: CIImage) -> CIImage {
        let extent = input.extent
        let gray = input.applyingFilter("CILinearToSRGBToneCurve")
            .applyingFilter("CIColorControls", parameters: ["inputSaturation": 0])
        let blurred = gray.clampedToExtent()
            .applyingGaussianBlur(sigma: max(1.5, Double(max(extent.width, extent.height)) * 0.0015)).cropped(to: extent)
        return DevelopKernels.highPass(gray, blurred: blurred, gain: 14).cropped(to: extent)
    }

    /// The photo with a mask's coverage tinted red, as Lightroom's overlay shows it.
    static func applyOverlay(_ input: CIImage, _ s: DevelopSettings, maskId: String?,
                             photo: (url: URL, isRaw: Bool)? = nil, rangeSource: CIImage? = nil) -> CIImage {
        guard let maskId, let mask = s.masks.first(where: { $0.id == maskId }),
              let weight = maskWeight(mask, s, extent: input.extent, photo: photo, rangeSource: rangeSource ?? input)
        else { return input }
        let half = weight.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.55, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0.55, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0.55, w: 0),
        ])
        let red = CIImage(color: CIColor(red: 0.95, green: 0.08, blue: 0.08)).cropped(to: input.extent)
        return red.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: input,
            kCIInputMaskImageKey: half,
        ]).cropped(to: input.extent)
    }

    /// Post-crop vignette (on linear light, so darkening behaves like exposure), then grain.
    static func applyEffects(_ input: CIImage, _ s: DevelopSettings, scale: CGFloat) -> CIImage {
        guard s.hasEffects else { return input }
        var image = input
        if s.vignette != 0 {
            // the transition is centered on the midpoint and as wide as the feather asks
            let middle = 0.3 + s.vignetteMidpoint / 100 * 0.7
            let width = 0.1 + s.vignetteFeather / 100 * 0.8
            let amount = s.vignette >= 0 ? s.vignette / 100 * 1.5 : s.vignette / 100 * 0.85
            image = DevelopKernels.radialGain(image, amount: amount, start: max(0, middle - width / 2), width: width)
        }
        if s.grain > 0 {
            let encoded = image.applyingFilter("CILinearToSRGBToneCurve")
            image = DevelopKernels.grain(encoded, amount: s.grain, size: s.grainSize, roughness: s.grainRoughness,
                                         scale: Double(scale))
                .applyingFilter("CISRGBToneCurveToLinear")
        }
        return image
    }

    /// Noise reduction, then sharpening, in display-encoded values where noise and halos are
    /// judged. `scale` is the render's size relative to the full-resolution photo (≤ 1).
    static func applyDetail(_ input: CIImage, _ s: DevelopSettings, scale: CGFloat) -> CIImage {
        guard s.hasDetail else { return input }
        let extent = input.extent
        var image = input.applyingFilter("CILinearToSRGBToneCurve")
        if s.luminanceNoise > 0 {
            // a 3×3 median first: CINoiseReduction alone leaves isolated specks at high ISO
            let smoothed = image.applyingFilter("CIMedianFilter")
                .applyingFilter("CINoiseReduction", parameters: [
                    "inputNoiseLevel": s.luminanceNoise / 100 * 0.06, "inputSharpness": 0,
                ])
            // luminance only (color noise has its own slider); the fixed-size median eases in
            // over the first third, and less in a reduced preview where noise is averaged away
            let luminance = smoothed.applyingFilter("CILuminosityBlendMode", parameters: [kCIInputBackgroundImageKey: image])
            let strength = min(1, s.luminanceNoise / 30) * min(1, Double(scale) * 1.5)
            image = image.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: luminance, "inputTime": strength,
            ])
        }
        if s.colorNoise > 0 {
            // blur the color and keep the original's luminance
            let sigma = s.colorNoise / 100 * 8 * Double(scale)
            let blurred = image.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
            image = blurred.applyingFilter("CIColorBlendMode", parameters: [kCIInputBackgroundImageKey: image])
        }
        if s.sharpening > 0 {
            let sharpened = image.applyingFilter("CISharpenLuminance", parameters: [
                "inputSharpness": s.sharpening / 100,
                "inputRadius": max(0.5, s.sharpenRadius * Double(scale)),
            ])
            image = s.sharpenMasking > 0
                ? sharpened.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: image,
                    kCIInputMaskImageKey: edgeMask(image, masking: s.sharpenMasking, scale: scale),
                ])
                : sharpened
        }
        return image.applyingFilter("CISRGBToneCurveToLinear").cropped(to: extent)
    }

    /// White on edges, black on smooth areas; higher masking keeps only stronger edges.
    static func edgeMask(_ gamma: CIImage, masking: Double, scale: CGFloat) -> CIImage {
        let extent = gamma.extent
        let edges = gamma.applyingFilter("CIColorControls", parameters: ["inputSaturation": 0])
            .clampedToExtent().applyingGaussianBlur(sigma: max(0.6, 1.2 * Double(scale)))
            .applyingFilter("CIEdges", parameters: ["inputIntensity": 6]).cropped(to: extent)
            // edge strength is heavy-tailed; a square root spreads it so the slider moves evenly
            .applyingFilter("CIGammaAdjust", parameters: ["inputPower": 0.5])
        let threshold = pow(masking / 100, 2) * 0.3, width = 0.02 + threshold * 0.5
        let gain = 1 / width, bias = -threshold / width
        return edges.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0),
        ]).applyingFilter("CIColorClamp")
    }

    /// Tone and color shared by RAW and other formats, in Lightroom's order. The curve and
    /// contrast work perceptually so slider response matches the eye, not linear light.
    static func applyTone(_ input: CIImage, _ s: DevelopSettings) -> CIImage {
        var image = input
        let highlightAmount = s.highlights < 0 ? 1 + s.highlights / 100 : 1
        if highlightAmount != 1 || s.shadows != 0 {
            image = image.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": highlightAmount,
                "inputShadowAmount": s.shadows / 100,
            ])
        }
        if s.whites != 0 || s.blacks != 0 || s.highlights > 0 {
            // CIToneCurve already works in a perceptual (gamma 2) version of the working space.
            var y: [Double] = [0, 0.25, 0.5, 0.75, 1]
            if s.blacks > 0 { y[0] = s.blacks / 100 * 0.12 } else { y[1] += s.blacks / 100 * 0.08 }
            if s.whites < 0 { y[4] = 1 + s.whites / 100 * 0.12 } else { y[3] += s.whites / 100 * 0.08 }
            if s.highlights > 0 { y[3] += s.highlights / 100 * 0.06 }
            for i in 1..<y.count { y[i] = min(1, max(y[i], y[i - 1] + 0.004)) }
            image = image.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: y[0]),
                "inputPoint1": CIVector(x: 0.25, y: y[1]),
                "inputPoint2": CIVector(x: 0.5, y: y[2]),
                "inputPoint3": CIVector(x: 0.75, y: y[3]),
                "inputPoint4": CIVector(x: 1, y: y[4]),
            ])
        }
        if s.contrast != 0 || s.saturation != 0 {
            // contrast pivots on mid-gray, so apply it in gamma space rather than linear light
            image = image.applyingFilter("CILinearToSRGBToneCurve")
                .applyingFilter("CIColorControls", parameters: [
                    "inputContrast": 1 + s.contrast / 200,
                    "inputSaturation": 1 + s.saturation / 100,
                    "inputBrightness": 0,
                ])
                .applyingFilter("CISRGBToneCurveToLinear")
        }
        if s.vibrance != 0 {
            image = image.applyingFilter("CIVibrance", parameters: ["inputAmount": s.vibrance / 100])
        }
        return image
    }
}

/// Renders develop previews on its own serial queue (never the Swift cooperative pool: RAW
/// decoding can deadlock it). Requests coalesce — while a slider drags, only the newest
/// pending one renders — and the decoded source is kept until the photo or size changes.
final class DevelopRenderWorker: @unchecked Sendable {
    struct Request: Sendable {
        let url: URL
        let isRaw: Bool
        let maxPixel: Int?
        let settings: DevelopSettings
        let draft: Bool
        var wholeFrame = false
        var overlayMask: String?
        var visualizeSpots = false
        let token: Int
    }

    struct Result: @unchecked Sendable {
        let request: Request
        let image: CGImage?
        let histogram: DevelopHistogram?
        /// The decoded photo's size before rotation and crop.
        let sourceSize: CGSize?
        let asShotTemperature: Double?
        let asShotTint: Double?
    }

    private let queue = DispatchQueue(label: "PhotoCatalog.develop-render", qos: .userInteractive)
    private let lock = NSLock()
    private var pending: (Request, @Sendable (Result) -> Void)?
    private var source: (key: String, source: DevelopRenderer.Source)?

    func submit(_ request: Request, completion: @escaping @Sendable (Result) -> Void) {
        lock.withLock { pending = (request, completion) }
        queue.async { [self] in drain() }
    }

    private func drain() {
        guard let (request, completion) = lock.withLock({ () -> (Request, @Sendable (Result) -> Void)? in
            defer { pending = nil }
            return pending
        }) else { return }
        let key = "\(request.url.path)|\(request.maxPixel ?? 0)"
        if source?.key != key {
            source = DevelopRenderer.Source(url: request.url, isRaw: request.isRaw, maxPixel: request.maxPixel)
                .map { (key, $0) }
        }
        let image = autoreleasepool {
            source?.source.image(request.settings, draft: request.draft, wholeFrame: request.wholeFrame,
                                 overlayMask: request.overlayMask, visualizeSpots: request.visualizeSpots)
                .flatMap(DevelopRenderer.render)
        }
        // the crop tool's empty corners and the mask overlay's tint would skew the histogram
        let histogram = request.wholeFrame || request.overlayMask != nil || request.visualizeSpots
            ? nil : image.flatMap(DevelopRenderer.histogram)
        completion(Result(request: request, image: image, histogram: histogram, sourceSize: source?.source.sourceSize,
                          asShotTemperature: source?.source.asShotTemperature,
                          asShotTint: source?.source.asShotTint))
    }
}
