import CoreImage
import ImageIO
import Foundation

extension DevelopRenderer {
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
                   overlayMask: String? = nil, visualizeSpots: Bool = false, visualizeDepth: Bool = false) -> CIImage? {
            guard let base = baseImage(settings, draft: draft) else { return nil }
            sourceSize = base.extent.integral.size
            let scale = max(base.extent.width, base.extent.height) / max(fullLongEdge, 1)
            // lateral chromatic aberration is measured on the photo itself, once per file
            let lateral = settings.removeChromaticAberration ? ChromaticAberration.correction(url: url, isRaw: isRaw) : nil
            let lensed = DevelopRenderer.applyLens(base, settings, scale: min(1, scale), lateral: lateral)
            let healed = DevelopRenderer.applySpots(lensed, settings, photo: (url: url, isRaw: isRaw))
            let calibrated = DevelopRenderer.applyCalibration(healed, settings)
            let toned = DevelopRenderer.applyTone(DevelopRenderer.applyProfile(calibrated, settings), settings)
            let colored = DevelopRenderer.applyLUT(
                DevelopRenderer.applyMixer(DevelopRenderer.applyCurve(toned, settings), settings), settings, originalURL: url)
            let present = DevelopRenderer.applyPresence(colored, settings)
            let photo = (url: url, isRaw: isRaw)
            let masked = DevelopRenderer.applyMasks(present, settings, photo: photo)
            let blurred = DevelopRenderer.applyLensBlur(masked, settings, photo: photo, visualize: visualizeDepth)
            let local = DevelopRenderer.applyOverlay(blurred, settings, maskId: overlayMask, photo: photo, rangeSource: present)
            let detailed = DevelopRenderer.applyDetail(local, settings, scale: min(1, scale))
            let framed = DevelopRenderer.applyGeometry(detailed, settings, wholeFrame: wholeFrame)
            // effects follow the crop, which the crop tool's whole-frame view doesn't apply yet
            let finished = wholeFrame ? framed : DevelopRenderer.applyEffects(framed, settings, scale: min(1, scale))
            return visualizeSpots ? DevelopRenderer.visualizeSpots(finished) : finished
        }

        /// The photo as the spot at `index` finds it: decoded, lens-corrected, and with the spots
        /// before it applied — what a remove spot's fill is made from.
        func spotStage(_ settings: DevelopSettings, before index: Int) -> CIImage? {
            guard let base = baseImage(settings, draft: false) else { return nil }
            let scale = max(base.extent.width, base.extent.height) / max(fullLongEdge, 1)
            let lateral = settings.removeChromaticAberration ? ChromaticAberration.correction(url: url, isRaw: isRaw) : nil
            var earlier = settings
            earlier.spots = Array(settings.spots.prefix(index))
            let lensed = DevelopRenderer.applyLens(base, earlier, scale: min(1, scale), lateral: lateral)
            return DevelopRenderer.applySpots(lensed, earlier, photo: (url: url, isRaw: isRaw))
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
                        image = DevelopRenderer.applyingCurves(image, curve.exposureTable(delta: delta))
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
            return DevelopRenderer.relativeWhiteBalance(image, temperature: settings.temperature ?? 0, tint: settings.tint ?? 0)
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
}
