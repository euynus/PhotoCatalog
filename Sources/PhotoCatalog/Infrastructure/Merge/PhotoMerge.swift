// ============================================================
//  PhotoMerge — Lightroom's Photo Merge: HDR from bracketed exposures
// ============================================================
import CoreImage
import Foundation
import Vision

/// Merges several photos into one, on the Mac: bracketed exposures into an HDR photo by
/// exposure fusion. The result is a display-referred image, written as a 16-bit TIFF and
/// edited like any other photo.
enum PhotoMerge {
    struct Frame: Sendable {
        let url: URL
        let isRaw: Bool
        /// The light the exposure let in, t·ISO/N² (nil when the metadata doesn't say).
        let brightness: Double?
    }

    struct HDROptions: Equatable, Sendable {
        /// Lines the frames up first, for photos taken by hand.
        var align = true
        /// Where something moved between frames, keeps it as the middle exposure shows it.
        var deghost = true
    }

    /// Merges run here, off the Swift cooperative pool (RAW decodes can deadlock it), one at a time.
    static let queue = DispatchQueue(label: "PhotoCatalog.photo-merge", qos: .userInitiated)

    /// Frames are lined up on renders this size, and deghosting measures exposures on them.
    private static let analysisPixel = 1024

    // ---- HDR ----
    /// The HDR merge of `frames` at `maxPixel` (nil: full size), in the working space; nil
    /// when a frame can't be read. Also the index of the reference frame, the middle exposure.
    static func hdr(_ frames: [Frame], options: HDROptions, maxPixel: Int?) -> (image: CIImage, reference: Int)? {
        guard frames.count >= 2 else { return nil }
        let small = frames.map { decode($0, maxPixel: analysisPixel) }
        guard small.allSatisfy({ $0 != nil }) else { return nil }
        let previews = small.compactMap { $0 }.map { DevelopRenderer.render($0) }
        guard previews.allSatisfy({ $0 != nil }) else { return nil }
        let thumbnails = previews.compactMap { $0 }
        let reference = middleExposure(frames, thumbnails)

        // offsets onto the reference, found on the small renders by median threshold bitmaps,
        // which don't care how bright each exposure is
        var offsets = [CGPoint](repeating: .zero, count: frames.count)
        if options.align, let base = grayscale(thumbnails[reference]) {
            for index in frames.indices where index != reference {
                guard let gray = grayscale(thumbnails[index]), gray.width == base.width, gray.height == base.height
                else { continue }
                let shift = medianThresholdShift(of: gray.pixels, onto: base.pixels, width: base.width, height: base.height)
                offsets[index] = CGPoint(x: shift.x, y: -shift.y)   // Core Image's y points up
            }
        }
        let ratios = frames.indices.map { exposureRatio(thumbnails[$0], thumbnails[reference], offset: offsets[$0]) }

        // the full-size frames, moved into line and cut to the part they all cover
        let full = maxPixel == analysisPixel ? small.compactMap { $0 } : frames.compactMap { decode($0, maxPixel: maxPixel) }
        guard full.count == frames.count else { return nil }
        let scale = full[reference].extent.width / max(small[reference]!.extent.width, 1)
        var common = full[reference].extent
        let moved = full.indices.map { index -> CIImage in
            let shift = CGAffineTransform(translationX: (offsets[index].x * scale).rounded(),
                                          y: (offsets[index].y * scale).rounded())
            let image = full[index].transformed(by: shift)
            common = common.intersection(image.extent)
            return image
        }
        let area = common.integral.insetBy(dx: 1, dy: 1)
        guard area.width > 16, area.height > 16 else { return nil }
        let aligned = moved.map { atOrigin($0.cropped(to: area)) }
        return (fuse(aligned, reference: reference, ratios: ratios, deghost: options.deghost), reference)
    }

    /// Exposure fusion (Mertens, Kautz and Van Reeth): each frame weighted by its detail, color
    /// and exposure, blended level by level in Laplacian pyramids so the seams between
    /// frames never show.
    static func fuse(_ images: [CIImage], reference: Int, ratios: [Double], deghost: Bool) -> CIImage {
        let extent = images[0].extent
        let encoded = images.map { $0.applyingFilter("CILinearToSRGBToneCurve") }
        var weights = encoded.indices.map { index -> CIImage in
            let gray = encoded[index].applyingFilter("CIColorControls", parameters: ["inputSaturation": 0])
            let laplacian = gray.clampedToExtent().applyingFilter("CIConvolution3X3", parameters: [
                "inputWeights": CIVector(values: [0, 1, 0, 1, -4, 1, 0, 1, 0], count: 9), "inputBias": 0,
            ]).cropped(to: extent)
            var weight = DevelopKernels.fusionWeight(encoded[index], laplacian: laplacian)
            if deghost, index != reference {
                weight = DevelopKernels.scale(weight, by: DevelopKernels.ghostWeight(images[index], reference: images[reference],
                                                                                       ratio: ratios[index]))
            }
            return weight
        }
        let total = weights.dropFirst().reduce(weights[0]) { DevelopKernels.add($0, $1) }
        weights = weights.map { DevelopKernels.divide($0, by: total) }

        let levels = max(1, Int(log2(Double(min(extent.width, extent.height)))) - 5)
        var blended: [CIImage] = []
        for index in encoded.indices {
            let colors = gaussianPyramid(encoded[index], levels: levels)
            let weight = gaussianPyramid(weights[index], levels: levels)
            for level in 0..<levels {
                let detail = level == levels - 1
                    ? colors[level] : DevelopKernels.subtract(colors[level], up(colors[level + 1], to: colors[level].extent))
                let term = DevelopKernels.scale(detail, by: weight[level])
                if index == 0 { blended.append(term) } else { blended[level] = DevelopKernels.add(blended[level], term) }
            }
        }
        var result = blended[levels - 1]
        for level in stride(from: levels - 2, through: 0, by: -1) {
            result = DevelopKernels.add(up(result, to: blended[level].extent), blended[level])
        }
        return result
            .applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 1), "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
            ])
            .applyingFilter("CISRGBToneCurveToLinear")
            .cropped(to: extent)
    }

    // ---- pyramids ----
    static func gaussianPyramid(_ image: CIImage, levels: Int) -> [CIImage] {
        var pyramid = [image]
        for _ in 1..<max(levels, 1) { pyramid.append(down(pyramid[pyramid.count - 1])) }
        return pyramid
    }

    /// Half the size, blurred first so nothing aliases.
    static func down(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let half = image.clampedToExtent().applyingGaussianBlur(sigma: 1).cropped(to: extent)
            .transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
        return half.clampedToExtent().cropped(to: CGRect(x: 0, y: 0, width: ceil(extent.width / 2),
                                                         height: ceil(extent.height / 2)))
    }

    /// Twice the size, onto `extent`.
    static func up(_ image: CIImage, to extent: CGRect) -> CIImage {
        image.clampedToExtent().transformed(by: CGAffineTransform(scaleX: 2, y: 2)).cropped(to: extent)
    }

    // ---- frames ----
    /// The photo as shot (neutral develop settings), at `maxPixel`, with its origin at zero.
    static func decode(_ frame: Frame, maxPixel: Int?) -> CIImage? {
        DevelopRenderer.Source(url: frame.url, isRaw: frame.isRaw, maxPixel: maxPixel, interactive: false)?
            .image(.neutral).map(atOrigin)
    }

    /// The middle exposure: by the metadata when every frame has it, else by how bright each looks.
    static func middleExposure(_ frames: [Frame], _ thumbnails: [CGImage]) -> Int {
        let brightness: [Double] = frames.allSatisfy({ $0.brightness != nil })
            ? frames.map { $0.brightness! } : thumbnails.map(meanLuma)
        let order = brightness.indices.sorted { brightness[$0] < brightness[$1] }
        return order[order.count / 2]
    }

    /// Luma, 0…255, of an 8-bit render.
    static func grayscale(_ image: CGImage) -> (pixels: [UInt8], width: Int, height: Int)? {
        guard let rgba = SemanticMasks.rgba(image) else { return nil }
        var gray = [UInt8](repeating: 0, count: image.width * image.height)
        for i in gray.indices {
            gray[i] = UInt8((54 * Int(rgba[i * 4]) + 183 * Int(rgba[i * 4 + 1]) + 19 * Int(rgba[i * 4 + 2])) >> 8)
        }
        return (gray, image.width, image.height)
    }

    /// The shift (pixels, top-left origin, y down) that lines `image` up with `reference`, by
    /// Ward's median threshold bitmaps: each image split at its own median, so exposures line
    /// up whatever their brightness; searched coarse to fine, up to 63 pixels either way.
    static func medianThresholdShift(of image: [UInt8], onto reference: [UInt8], width: Int, height: Int) -> CGPoint {
        func pyramid(_ pixels: [UInt8], _ width: Int, _ height: Int, _ levels: Int) -> [(p: [UInt8], w: Int, h: Int)] {
            var result = [(pixels, width, height)]
            for _ in 1..<levels {
                let (prev, w, h) = result[result.count - 1]
                let nw = w / 2, nh = h / 2
                guard nw >= 8, nh >= 8 else { break }
                var next = [UInt8](repeating: 0, count: nw * nh)
                for y in 0..<nh {
                    for x in 0..<nw {
                        let i = 2 * y * w + 2 * x
                        next[y * nw + x] = UInt8((Int(prev[i]) + Int(prev[i + 1]) + Int(prev[i + w]) + Int(prev[i + w + 1])) / 4)
                    }
                }
                result.append((next, nw, nh))
            }
            return result
        }
        func bitmaps(_ pixels: [UInt8]) -> (threshold: [Bool], keep: [Bool]) {
            var histogram = [Int](repeating: 0, count: 256)
            for v in pixels { histogram[Int(v)] += 1 }
            var running = 0, median = 0
            for (value, count) in histogram.enumerated() {
                running += count
                if running >= pixels.count / 2 { median = value; break }
            }
            return (pixels.map { Int($0) > median }, pixels.map { abs(Int($0) - median) > 4 })
        }
        let levels = 6
        let a = pyramid(reference, width, height, levels), b = pyramid(image, width, height, levels)
        var dx = 0, dy = 0
        for level in stride(from: min(a.count, b.count) - 1, through: 0, by: -1) {
            let (pa, w, h) = a[level], pb = b[level].p
            let (ta, ka) = bitmaps(pa), (tb, kb) = bitmaps(pb)
            dx *= 2; dy *= 2
            var best = (errors: Int.max, dx: dx, dy: dy)
            for sy in -1...1 {
                for sx in -1...1 {
                    let cx = dx + sx, cy = dy + sy
                    var errors = 0
                    // reference pixel (x, y) against image pixel (x - cx, y - cy)
                    for y in max(0, cy)..<min(h, h + cy) {
                        let row = y * w, source = (y - cy) * w - cx
                        for x in max(0, cx)..<min(w, w + cx) where ka[row + x] && kb[source + x] && ta[row + x] != tb[source + x] {
                            errors += 1
                        }
                    }
                    if errors < best.errors { best = (errors, cx, cy) }
                }
            }
            dx = best.dx; dy = best.dy
        }
        return CGPoint(x: dx, y: dy)
    }

    /// The translation (Core Image pixels of `reference`) that lines `image` up with it.
    static func translation(of image: CGImage, onto reference: CGImage) -> CGPoint? {
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: image)
        try? VNImageRequestHandler(cgImage: reference).perform([request])
        guard let t = (request.results?.first as? VNImageTranslationAlignmentObservation)?.alignmentTransform
        else { return nil }
        return CGPoint(x: t.tx, y: t.ty)
    }

    /// How much brighter the reference is than `image` in linear light, from the median over
    /// tones both show well; 1 when too few do.
    static func exposureRatio(_ image: CGImage, _ reference: CGImage, offset: CGPoint) -> Double {
        guard image.width == reference.width, image.height == reference.height,
              let a = SemanticMasks.rgba(image), let b = SemanticMasks.rgba(reference) else { return 1 }
        func linear(_ v: UInt8) -> Double {
            let c = Double(v) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let width = image.width, height = image.height
        // the offset moves `image` onto the reference: Core Image's y points up
        let dx = Int(offset.x.rounded()), dy = -Int(offset.y.rounded())
        var ratios: [Double] = []
        for y in stride(from: 0, to: height, by: 4) {
            for x in stride(from: 0, to: width, by: 4) {
                let sx = x - dx, sy = y - dy
                guard sx >= 0, sy >= 0, sx < width, sy < height else { continue }
                let i = (sy * width + sx) * 4, j = (y * width + x) * 4
                let la = 0.2126 * linear(a[i]) + 0.7152 * linear(a[i + 1]) + 0.0722 * linear(a[i + 2])
                let lb = 0.2126 * linear(b[j]) + 0.7152 * linear(b[j + 1]) + 0.0722 * linear(b[j + 2])
                guard la > 0.02, la < 0.8, lb > 0.02, lb < 0.8 else { continue }
                ratios.append(lb / la)
            }
        }
        guard ratios.count >= 50 else { return 1 }
        ratios.sort()
        return ratios[ratios.count / 2]
    }

    static func meanLuma(_ image: CGImage) -> Double {
        guard let pixels = SemanticMasks.rgba(image) else { return 0 }
        var total = 0.0
        for i in stride(from: 0, to: pixels.count, by: 16) {
            total += 0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])
        }
        return total / Double(max(pixels.count / 16, 1))
    }

    static func atOrigin(_ image: CIImage) -> CIImage {
        let origin = image.extent.origin
        return origin == .zero ? image : image.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
    }

    // ---- writing ----
    /// Writes `image` as a 16-bit Display P3 TIFF.
    static func writeTIFF(_ image: CIImage, to url: URL) -> Bool {
        (try? DevelopRenderer.context.writeTIFFRepresentation(of: image, to: url, format: .RGBA16,
                                                               colorSpace: DevelopRenderer.outputColorSpace)) != nil
    }
}
