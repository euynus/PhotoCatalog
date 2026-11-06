import CoreImage
import ImageIO
import Foundation
import Vision

extension DevelopRenderer {
    /// Lens blur (see `LensBlur`): each part blurred by how far its depth lies outside the band
    /// in focus, up to a radius that's a share of the long edge, so a preview matches the full
    /// photo. `visualize` shows the depth instead, near warm and far cool.
    static func applyLensBlur(_ input: CIImage, _ s: DevelopSettings, photo: (url: URL, isRaw: Bool)?,
                              visualize: Bool = false) -> CIImage {
        guard s.hasLensBlur || visualize, let photo, let map = DepthMap.map(for: photo.url, isRaw: photo.isRaw) else {
            return input
        }
        let extent = input.extent
        let depth = DepthMap.image(map, extent: extent, guide: input, distortion: s.distortion)
        if visualize {
            return depth.applyingFilter("CIFalseColor", parameters: [
                "inputColor0": CIColor(red: 0.08, green: 0.16, blue: 0.45), "inputColor1": CIColor(red: 1, green: 0.62, blue: 0.25),
            ]).cropped(to: extent)
        }
        let blur = s.lensBlur
        let longEdge = Double(max(extent.width, extent.height))
        // Where depth sweeps past the focus between two blurred parts (a near edge before a far
        // background), a thin band would stay sharp as an outline: closing the mask (widest,
        // then narrowest, over a few pixels) fills bands that thin and leaves wider sharp parts.
        let close = max(1, 0.0025 * longEdge)
        let mask = DevelopKernels.lensBlurMask(depth, focus: blur.focus, inner: blur.range / 100 * 0.3, soft: 0.12)
            .clampedToExtent()
            .applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": close])
            .applyingFilter("CIMorphologyMinimum", parameters: ["inputRadius": close])
            .cropped(to: extent)
        let radius = blur.amount / 100 * 0.02 * longEdge
        return input.clampedToExtent()
            .applyingFilter("CIMaskedVariableBlur", parameters: ["inputMask": mask, "inputRadius": radius])
            .cropped(to: extent)
    }

    /// A mask's weight over `extent`: drawn masks from their shapes and strokes, a subject, sky
    /// or people from the photo itself (`photo`, the file being rendered), then any brush strokes
    /// that add to or erase from a mask that isn't itself a brush.
    static func maskWeight(_ mask: LocalAdjustment, _ s: DevelopSettings, extent: CGRect,
                           photo: (url: URL, isRaw: Bool)?, rangeSource: CIImage? = nil) -> CIImage? {
        let base: CIImage?
        if mask.kind.isRange {
            // a color range with nothing sampled yet isn't a range: nothing to be inside or,
            // inverted, outside of
            guard let range = mask.range, range.kind == .luminance || !range.samples.isEmpty else { return nil }
            // the whole photo, narrowed to its range below
            base = CIImage(color: .white).cropped(to: extent)
        } else if mask.kind.isAutomatic {
            let lookup = photo.map { photo in
                switch mask.kind {
                case .person: PeopleMasks.lookup(mask.part, person: mask.person, url: photo.url, isRaw: photo.isRaw)
                case .object: ObjectSelection.lookup(mask.prompt, url: photo.url, isRaw: photo.isRaw)
                case .landscape: SceneSegmentation.lookup(mask.landscape, url: photo.url, isRaw: photo.isRaw)
                default: SemanticMasks.lookup(mask.kind, url: photo.url, isRaw: photo.isRaw)
                }
            }
            switch lookup {
            case .found(let result):
                base = SemanticMasks.weight(result, extent: extent, inverted: mask.inverted, distortion: s.distortion)
            case .notFound:
                // no subject (or sky, or person) in the photo: everything else is the whole photo
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
    static func applySpots(_ input: CIImage, _ s: DevelopSettings, photo: (url: URL, isRaw: Bool)? = nil) -> CIImage {
        guard !s.spots.isEmpty else { return input }
        let extent = input.extent
        let longEdge = max(extent.width, extent.height)
        let clear = CIImage(color: .clear).cropped(to: extent)
        var image = input
        func pixel(_ p: CGPoint) -> CGPoint {
            CGPoint(x: extent.minX + p.x * extent.width, y: extent.maxY - p.y * extent.height)
        }
        for (index, spot) in s.spots.enumerated() where spot.opacity > 0 {
            if spot.mode == .remove {
                // the fill made for this photo (made now if it's gone from the caches)
                guard let photo, let fill = GenerativeFill.fill(for: index, settings: s, url: photo.url, isRaw: photo.isRaw),
                      let mask = BrushRaster.dabs(spot.strokes, extent: extent) else { continue }
                image = GenerativeFill.composite(fill, into: image, mask: mask, opacity: spot.opacity, extent: extent)
                continue
            }
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
}
