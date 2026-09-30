// ============================================================
//  PhotoMerge — Lightroom's Photo Merge: HDR and panoramas
// ============================================================
import CoreImage
import Foundation
import ImageIO

/// Merges several photos into one, on the Mac: bracketed exposures into an HDR photo by
/// exposure fusion, overlapping frames into a panorama on a cylinder. The result is a
/// display-referred image, written as a 16-bit TIFF and edited like any other photo.
enum PhotoMerge {
    struct Frame: Sendable {
        let url: URL
        let isRaw: Bool
        /// The light the exposure let in, t·ISO/N² (nil when the metadata doesn't say).
        let brightness: Double?
        /// The lens's focal length as on a 35 mm camera (nil when the metadata doesn't say).
        var focalLength35: Double?
    }

    enum PanoramaFailure: Error, Equatable {
        case unreadable
        /// The frames at this index and the next don't overlap enough to join.
        case noOverlap(Int)
        /// The frames at this index and the next barely moved: a burst, not a panorama.
        case notMoving(Int)
        /// The frames at this index and the next moved another way than the rest, or too far
        /// across the pan: not one sweep of the camera.
        case notPanorama(Int)
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

    // ---- panorama ----
    /// Output panoramas are at most this long on their long edge.
    static let maxPanoramaPixel = 16384

    /// The panorama of `frames`, in order, as they were shot: each projected onto a cylinder
    /// around the camera (its focal length from the metadata), lined up with the one before,
    /// its exposure matched, blended with the frames it overlaps, and cut to the largest
    /// rectangle they all fill. `maxPixel` bounds the frames' size (nil: full size).
    static func panorama(_ frames: [Frame], maxPixel: Int?) -> Result<CIImage, PanoramaFailure> {
        guard frames.count >= 2 else { return .failure(.unreadable) }
        let small = frames.compactMap { decode($0, maxPixel: analysisPixel) }
        guard small.count == frames.count else { return .failure(.unreadable) }
        let size = small[0].extent.size
        let focal35 = frames.compactMap(\.focalLength35).sorted().dropFirst(frames.compactMap(\.focalLength35).count / 2).first ?? 35
        let f = focal35 * Double(hypot(size.width, size.height)) / 43.27

        // lined up on the projected frames: sideways first, upward if that's how they were shot
        var layout = panoramaLayout(small, f: f, vertical: false)
        if case .success(let found) = layout, found.vertical { layout = panoramaLayout(small, f: f, vertical: true) }
        guard case .success(let plan) = layout else {
            if case .failure(let failure) = layout { return .failure(failure) }
            return .failure(.unreadable)
        }

        // full size (or as large as the panorama may be), in the same layout
        let fullLongEdge = decode(frames[0], maxPixel: nil).map { max($0.extent.width, $0.extent.height) }
            ?? max(size.width, size.height)
        let smallLong = max(size.width, size.height)
        var scale = fullLongEdge / smallLong
        let canvasLong = max(plan.canvas.width, plan.canvas.height) * scale
        if canvasLong > CGFloat(maxPanoramaPixel) { scale *= CGFloat(maxPanoramaPixel) / canvasLong }
        if let maxPixel { scale = min(scale, CGFloat(maxPixel) / smallLong) }
        let pixel = Int((smallLong * scale).rounded())
        let full = frames.compactMap { decode($0, maxPixel: pixel) }
        guard full.count == frames.count else { return .failure(.unreadable) }
        let ratio = full[0].extent.width / size.width
        let canvas = CGRect(x: 0, y: 0, width: (plan.canvas.width * ratio).rounded(.up),
                            height: (plan.canvas.height * ratio).rounded(.up))
        let empty = CIImage(color: .clear).cropped(to: canvas)
        var colors = empty, weights = empty
        for index in full.indices {
            let center = CGPoint(x: plan.centers[index].x * ratio, y: plan.centers[index].y * ratio)
            let image = full[index].applyingFilter("CIExposureAdjust", parameters: ["inputEV": log2(plan.gains[index])])
            let warped = DevelopKernels.cylinderWarp(image, f: f * Double(ratio), center: center, vertical: plan.vertical)
            let weight = DevelopKernels.cylinderWarp(DevelopKernels.edgeWeight(size: full[index].extent.size),
                                                     f: f * Double(ratio), center: center, vertical: plan.vertical)
            let placedWeight = weight.composited(over: empty).cropped(to: canvas)
            colors = DevelopKernels.add(colors, DevelopKernels.scale(warped.composited(over: empty).cropped(to: canvas),
                                                                     by: placedWeight))
            weights = DevelopKernels.add(weights, placedWeight)
        }
        let crop = CGRect(x: plan.crop.minX * ratio, y: plan.crop.minY * ratio,
                          width: plan.crop.width * ratio, height: plan.crop.height * ratio).integral
            .intersection(canvas).insetBy(dx: 1, dy: 1)
        return .success(atOrigin(DevelopKernels.divide(colors, by: weights).cropped(to: crop)))
    }

    /// Where each frame goes on the panorama (Core Image pixels of the small frames, the canvas
    /// starting at zero), its exposure gain, and the largest rectangle every part of which a
    /// frame covers.
    struct PanoramaLayout {
        let vertical: Bool
        /// Each frame against the one before: how well they matched, and the shift found.
        var scores: [Double] = []
        var offsets: [CGPoint] = []
        let centers: [CGPoint]
        let gains: [Double]
        let canvas: CGSize
        let crop: CGRect
    }

    static func panoramaLayout(_ frames: [CIImage], f: Double, vertical: Bool)
        -> Result<PanoramaLayout, PanoramaFailure> {
        // each frame projected on its own, its middle at the middle of its render
        let size = frames[0].extent.size
        let along = vertical ? size.height : size.width, across = vertical ? size.width : size.height
        let span = 2 * CGFloat(f) * CGFloat(atan(Double(along) / 2 / f))
        let box = vertical ? CGSize(width: across, height: span) : CGSize(width: span, height: across)
        let local = CGPoint(x: box.width / 2, y: box.height / 2)
        var rendered: [(image: CGImage, rgba: [UInt8], width: Int, height: Int)] = []
        for frame in frames {
            let warped = DevelopKernels.cylinderWarp(frame, f: f, center: local, vertical: vertical)
            let rect = CGRect(origin: .zero, size: box).integral
            guard let image = DevelopRenderer.context.createCGImage(warped, from: rect, format: .RGBA8,
                                                                     colorSpace: DevelopRenderer.outputColorSpace),
                  let rgba = premultipliedRGBA(image) else { return .failure(.unreadable) }
            rendered.append((image, rgba, image.width, image.height))
        }
        // each frame against the one before: the offset of its middle, by correlation over the
        // parts both cover
        let grays = rendered.map { maskedGray($0.rgba, width: $0.width, height: $0.height) }
        var offsets: [CGPoint] = [], scores: [Double] = []
        for index in 1..<rendered.count {
            // the same scene lines up closely; different pictures only resemble each other
            guard let found = correlationShift(of: grays[index], onto: grays[index - 1]), found.score >= 0.7 else {
                return .failure(.noOverlap(index - 1))
            }
            offsets.append(CGPoint(x: found.shift.x, y: -found.shift.y))   // Core Image's y points up
            scores.append(found.score)
        }
        let sideways = offsets.reduce(0) { $0 + abs($1.x) }, upward = offsets.reduce(0) { $0 + abs($1.y) }
        if !vertical, upward > sideways * 1.5 {
            return .success(PanoramaLayout(vertical: true, centers: [], gains: [], canvas: .zero, crop: .zero))
        }
        let alongSize = vertical ? box.height : box.width, acrossSize = vertical ? box.width : box.height
        let direction = (vertical ? offsets[0].y : offsets[0].x).sign
        for (index, t) in offsets.enumerated() {
            let step = vertical ? t.y : t.x, drift = abs(vertical ? t.x : t.y)
            // along the pan a frame has moved a tenth or more and still overlaps its neighbor;
            // it keeps going the same way and doesn't wander far across
            guard abs(step) >= alongSize * 0.1 else { return .failure(.notMoving(index)) }
            guard abs(step) <= alongSize * 0.9 else { return .failure(.noOverlap(index)) }
            guard step.sign == direction, drift <= acrossSize * 0.25 else { return .failure(.notPanorama(index)) }
        }
        var centers = [CGPoint.zero]
        for t in offsets { centers.append(CGPoint(x: centers[centers.count - 1].x + t.x, y: centers[centers.count - 1].y + t.y)) }
        // the canvas: every frame's box, moved so it starts at zero
        let boxes = centers.map { CGRect(x: $0.x, y: $0.y, width: box.width, height: box.height) }
        let union = boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }.integral
        centers = centers.map { CGPoint(x: $0.x - union.minX + local.x, y: $0.y - union.minY + local.y) }

        // exposures matched pair by pair where they overlap, then centered on the average
        var gains = [1.0]
        for (index, t) in offsets.enumerated() {
            let ratio = overlapRatio(rendered[index], rendered[index + 1], offset: t)
            gains.append(gains[index] * min(2, max(0.5, ratio)))
        }
        let mean = exp(gains.map(log).reduce(0, +) / Double(gains.count))
        gains = gains.map { $0 / mean }

        // coverage, top-left pixels, and the largest rectangle fully covered
        let width = Int(union.width), height = Int(union.height)
        var covered = [Bool](repeating: false, count: width * height)
        for (index, frame) in rendered.enumerated() {
            let left = Int((centers[index].x - local.x).rounded())
            let top = height - Int((centers[index].y - local.y).rounded()) - frame.height
            for y in 0..<frame.height {
                let cy = top + y
                guard cy >= 0, cy < height else { continue }
                for x in 0..<frame.width where frame.rgba[(y * frame.width + x) * 4 + 3] >= 250 {
                    let cx = left + x
                    if cx >= 0, cx < width { covered[cy * width + cx] = true }
                }
            }
        }
        guard let best = largestRectangle(covered, width: width, height: height) else { return .failure(.unreadable) }
        let crop = CGRect(x: best.x, y: height - best.y - best.height, width: best.width, height: best.height)
        return .success(PanoramaLayout(vertical: vertical, scores: scores, offsets: offsets, centers: centers, gains: gains,
                                       canvas: CGSize(width: width, height: height), crop: crop))
    }

    /// A render's luma (0…1) and which pixels it covers, top row first.
    struct MaskedGray {
        let pixels: [Float]
        let valid: [Bool]
        let width: Int
        let height: Int
    }

    static func maskedGray(_ rgba: [UInt8], width: Int, height: Int) -> MaskedGray {
        var pixels = [Float](repeating: 0, count: width * height), valid = [Bool](repeating: false, count: width * height)
        for i in 0..<(width * height) {
            let alpha = Float(rgba[i * 4 + 3])
            guard alpha >= 250 else { continue }
            valid[i] = true
            pixels[i] = (0.2126 * Float(rgba[i * 4]) + 0.7152 * Float(rgba[i * 4 + 1]) + 0.0722 * Float(rgba[i * 4 + 2])) / alpha
        }
        return MaskedGray(pixels: pixels, valid: valid, width: width, height: height)
    }

    /// The shift (pixels, top-left origin) that lines `image` up with `reference` — a pixel
    /// (x, y) of the reference is (x − dx, y − dy) of the image — with its normalized
    /// correlation, over the parts both cover. Searched exhaustively on a small copy, where
    /// the two overlap by a tenth or more, then refined level by level.
    static func correlationShift(of image: MaskedGray, onto reference: MaskedGray) -> (shift: CGPoint, score: Double)? {
        func half(_ g: MaskedGray) -> MaskedGray {
            let w = g.width / 2, h = g.height / 2
            var pixels = [Float](repeating: 0, count: w * h), valid = [Bool](repeating: false, count: w * h)
            for y in 0..<h {
                for x in 0..<w {
                    let i = 2 * y * g.width + 2 * x
                    let indices = [i, i + 1, i + g.width, i + g.width + 1]
                    guard indices.allSatisfy({ g.valid[$0] }) else { continue }
                    valid[y * w + x] = true
                    pixels[y * w + x] = indices.reduce(0) { $0 + g.pixels[$1] } / 4
                }
            }
            return MaskedGray(pixels: pixels, valid: valid, width: w, height: h)
        }
        var a = [reference], b = [image]
        while max(a[a.count - 1].width, a[a.count - 1].height) > 96, min(a[a.count - 1].width, a[a.count - 1].height) > 16 {
            a.append(half(a[a.count - 1])); b.append(half(b[b.count - 1]))
        }
        func score(_ a: MaskedGray, _ b: MaskedGray, _ dx: Int, _ dy: Int, minimum: Int) -> Double? {
            var n = 0, sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0
            let x0 = max(0, dx), x1 = min(a.width, b.width + dx), y0 = max(0, dy), y1 = min(a.height, b.height + dy)
            guard x1 > x0, y1 > y0 else { return nil }
            for y in y0..<y1 {
                let row = y * a.width, source = (y - dy) * b.width - dx
                for x in x0..<x1 where a.valid[row + x] && b.valid[source + x] {
                    let p = Double(a.pixels[row + x]), q = Double(b.pixels[source + x])
                    n += 1; sa += p; sb += q; saa += p * p; sbb += q * q; sab += p * q
                }
            }
            guard n >= minimum else { return nil }
            let count = Double(n)
            let cov = sab - sa * sb / count, va = saa - sa * sa / count, vb = sbb - sb * sb / count
            guard va > 1e-9, vb > 1e-9 else { return nil }
            return cov / (va * vb).squareRoot()
        }
        // the whole range on the smallest copies
        let top = a.count - 1
        let (ta, tb) = (a[top], b[top])
        let minimum = max(20, ta.width * ta.height / 10)
        var best: (dx: Int, dy: Int, score: Double)?
        for dy in (-tb.height + 1)..<ta.height {
            for dx in (-tb.width + 1)..<ta.width {
                if let s = score(ta, tb, dx, dy, minimum: minimum), s > (best?.score ?? -2) { best = (dx, dy, s) }
            }
        }
        guard var found = best else { return nil }
        // then finer and finer, a couple of pixels around the last answer
        for level in stride(from: top - 1, through: 0, by: -1) {
            let (la, lb) = (a[level], b[level])
            let centerX = found.dx * 2, centerY = found.dy * 2
            found.score = -2
            let floor = max(20, la.width * la.height / 20)
            for dy in (centerY - 2)...(centerY + 2) {
                for dx in (centerX - 2)...(centerX + 2) {
                    if let s = score(la, lb, dx, dy, minimum: floor), s > found.score { found = (dx, dy, s) }
                }
            }
            guard found.score > -2 else { return nil }
        }
        return (CGPoint(x: found.dx, y: found.dy), found.score)
    }

    /// How much brighter the first frame is than the second where they overlap (linear light).
    private static func overlapRatio(_ a: (image: CGImage, rgba: [UInt8], width: Int, height: Int),
                                     _ b: (image: CGImage, rgba: [UInt8], width: Int, height: Int),
                                     offset: CGPoint) -> Double {
        func linear(_ v: UInt8, _ alpha: UInt8) -> Double {
            let c = Double(v) / max(Double(alpha), 1)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        // `b` moved by the offset lands on `a`: a pixel (x, y) of `a` is (x - dx, y - dy) of `b`
        let dx = Int(offset.x.rounded()), dy = -Int(offset.y.rounded())
        var sumA = 0.0, sumB = 0.0, count = 0
        for y in stride(from: 0, to: a.height, by: 2) {
            for x in stride(from: 0, to: a.width, by: 2) {
                let bx = x - dx, by = y - dy
                guard bx >= 0, by >= 0, bx < b.width, by < b.height else { continue }
                let i = (y * a.width + x) * 4, j = (by * b.width + bx) * 4
                guard a.rgba[i + 3] == 255, b.rgba[j + 3] == 255 else { continue }
                sumA += 0.2126 * linear(a.rgba[i], 255) + 0.7152 * linear(a.rgba[i + 1], 255) + 0.0722 * linear(a.rgba[i + 2], 255)
                sumB += 0.2126 * linear(b.rgba[j], 255) + 0.7152 * linear(b.rgba[j + 1], 255) + 0.0722 * linear(b.rgba[j + 2], 255)
                count += 1
            }
        }
        guard count >= 100, sumB > 0 else { return 1 }
        return sumA / sumB
    }

    /// The largest rectangle of `true` cells (top-left origin), by the histogram method.
    static func largestRectangle(_ cells: [Bool], width: Int, height: Int) -> (x: Int, y: Int, width: Int, height: Int)? {
        var heights = [Int](repeating: 0, count: width)
        var best: (area: Int, x: Int, y: Int, width: Int, height: Int) = (0, 0, 0, 0, 0)
        for y in 0..<height {
            for x in 0..<width { heights[x] = cells[y * width + x] ? heights[x] + 1 : 0 }
            var stack: [Int] = []
            for x in 0...width {
                let current = x < width ? heights[x] : 0
                while let top = stack.last, heights[top] > current {
                    stack.removeLast()
                    let h = heights[top], left = (stack.last ?? -1) + 1, w = x - left
                    if w * h > best.area { best = (w * h, left, y - h + 1, w, h) }
                }
                stack.append(x)
            }
        }
        return best.area > 0 ? (best.x, best.y, best.width, best.height) : nil
    }

    /// An 8-bit render's pixels with their coverage, premultiplied RGBA, top row first.
    static func premultipliedRGBA(_ image: CGImage) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let context = CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: DevelopRenderer.outputColorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels
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

    /// The lens's focal length as on a 35 mm camera, from the photo's metadata: as recorded,
    /// or from the focal length and the sensor's size; nil when neither is there.
    static func focalLength35(url: URL) -> Double? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] else { return nil }
        if let equivalent = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Double, equivalent > 0 { return equivalent }
        guard let focal = exif[kCGImagePropertyExifFocalLength] as? Double, focal > 0,
              let resolution = exif[kCGImagePropertyExifFocalPlaneXResolution] as? Double, resolution > 0,
              let pixels = (exif[kCGImagePropertyExifPixelXDimension] as? Double) ?? (properties[kCGImagePropertyPixelWidth] as? Double)
        else { return nil }
        // pixels per unit on the sensor: inches (2), centimeters (3) or millimeters (4)
        let unit = (exif[kCGImagePropertyExifFocalPlaneResolutionUnit] as? Int) ?? 2
        let millimeters = unit == 3 ? 10.0 : unit == 4 ? 1.0 : 25.4
        let sensorWidth = pixels / resolution * millimeters
        guard sensorWidth > 1 else { return nil }
        return focal * 36 / sensorWidth
    }

    // ---- writing ----
    /// Writes `image` as a 16-bit Display P3 TIFF.
    static func writeTIFF(_ image: CIImage, to url: URL) -> Bool {
        (try? DevelopRenderer.context.writeTIFFRepresentation(of: image, to: url, format: .RGBA16,
                                                               colorSpace: DevelopRenderer.outputColorSpace)) != nil
    }
}
