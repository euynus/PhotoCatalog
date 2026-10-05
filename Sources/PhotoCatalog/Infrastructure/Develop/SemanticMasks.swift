// ============================================================
//  SemanticMasks — automatic subject and sky masks
// ============================================================
import CoreImage
import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Finds a photo's subject (Vision's foreground instances) or its sky, as a grayscale weight
/// in the source photo's frame. Both are computed once per file from the photo as shot at
/// 1024 px, whatever size it's being rendered at, so previews, thumbnails and exports agree.
enum SemanticMasks {
    static let workingPixel = 1024
    private static let skyPixel = 512

    struct Result: @unchecked Sendable {
        /// Weight 0…255, the canonical image's size.
        let mask: CGImage
        /// Share of the photo covered, and the covered area's center (source fractions).
        let coverage: Double
        let centroid: CGPoint
    }

    /// What looking for a mask came to: the mask, none in this photo, or a photo that couldn't
    /// be read (not remembered, so it's tried again once the file is back).
    enum Lookup: Sendable {
        case found(Result)
        case notFound
        case unreadable
    }

    /// The last masks a provider found, or found missing; each provider (subject and sky here,
    /// people, landscape, objects) keeps its own. An unreadable photo isn't remembered.
    final class ResultCache: @unchecked Sendable {
        private final class Box { let result: Result?; init(_ result: Result?) { self.result = result } }
        private let cache: NSCache<NSString, Box> = {
            let cache = NSCache<NSString, Box>()
            cache.countLimit = 24
            return cache
        }()

        func lookup(_ key: String) -> Lookup? {
            cache.object(forKey: key as NSString).map { $0.result.map(Lookup.found) ?? .notFound }
        }

        /// Remembers `result` for `key` and gives it back as a lookup.
        func store(_ result: Result?, for key: String) -> Lookup {
            cache.setObject(Box(result), forKey: key as NSString)
            return result.map(Lookup.found) ?? .notFound
        }
    }

    /// A version of a file, as cache keys name it: its path and when it last changed.
    static func fileKey(_ url: URL) -> String {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return "\(url.path)|\(modified?.timeIntervalSince1970 ?? 0)"
    }

    private static let results = ResultCache()
    private final class ImageBox { let image: CGImage; init(_ image: CGImage) { self.image = image } }
    /// The last few canonical images, so a photo's subject and sky share one decode.
    private static let images: NSCache<NSString, ImageBox> = {
        let cache = NSCache<NSString, ImageBox>()
        cache.countLimit = 3
        return cache
    }()
    /// One lock per mask being computed, so two renders of a photo share one computation while
    /// other photos go ahead.
    private static let locksLock = NSLock()
    nonisolated(unsafe) private static var locks: [String: (lock: NSLock, users: Int)] = [:]

    /// The mask for `kind` (subject or sky), or nil when the photo has none or can't be read.
    static func mask(_ kind: LocalAdjustment.Kind, url: URL, isRaw: Bool) -> Result? {
        if case .found(let result) = lookup(kind, url: url, isRaw: isRaw) { result } else { nil }
    }

    static func lookup(_ kind: LocalAdjustment.Kind, url: URL, isRaw: Bool) -> Lookup {
        let key = "\(kind.rawValue)|" + fileKey(url)
        if let hit = results.lookup(key) { return hit }
        // Vision and the RAW decode are the slow part: done once per mask, not once per render
        let lock = locksLock.withLock {
            let entry = locks[key] ?? (NSLock(), 0)
            locks[key] = (entry.lock, entry.users + 1)
            return entry.lock
        }
        defer {
            locksLock.withLock {
                if let entry = locks[key] { locks[key] = entry.users > 1 ? (entry.lock, entry.users - 1) : nil }
            }
        }
        return lock.withLock {
            if let hit = results.lookup(key) { return hit }
            guard let image = canonical(url: url, isRaw: isRaw) else { return .unreadable }
            let result: Result? = switch kind {
            case .subject: subject(in: image)
            case .sky: sky(in: image)
            default: nil
            }
            return results.store(result, for: key)
        }
    }

    /// The photo as shot at 1024 px, the image automatic masks and spot sources are found in.
    static func canonical(url: URL, isRaw: Bool) -> CGImage? {
        let file = fileKey(url) as NSString
        if let cached = images.object(forKey: file) { return cached.image }
        guard let decoded = canonicalImage(url: url, isRaw: isRaw) else { return nil }
        images.setObject(ImageBox(decoded), forKey: file)
        return decoded
    }

    /// The mask as a weight over `extent` (the source photo at the render's size), bent by the
    /// photo's manual distortion correction as the photo itself is.
    static func weight(_ result: Result, extent: CGRect, inverted: Bool, distortion: Double) -> CIImage {
        var image = CIImage(cgImage: result.mask, options: [.colorSpace: NSNull()])
        image = image.transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(result.mask.width),
                                                       y: extent.height / CGFloat(result.mask.height)))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
        if inverted { image = image.applyingFilter("CIColorInvert") }
        return DevelopKernels.distort(image, k: distortion / 100 * 0.15)
    }

    // ---- the canonical image: as shot, 1024 px ----
    /// The photo as shot, at most `pixel` on the long edge.
    static func canonicalImage(url: URL, isRaw: Bool, pixel: Int = workingPixel) -> CGImage? {
        if isRaw, let raw = CIRAWFilter(imageURL: url) {
            let longEdge = max(raw.nativeSize.width, raw.nativeSize.height)
            if longEdge > CGFloat(pixel) { raw.scaleFactor = Float(CGFloat(pixel) / longEdge) }
            guard let output = raw.outputImage else { return nil }
            return DevelopRenderer.context.createCGImage(output, from: output.extent.integral, format: .RGBA8,
                                                         colorSpace: DevelopRenderer.outputColorSpace)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixel,
        ] as CFDictionary)
    }

    // ---- subject ----
    /// Every foreground instance Vision finds, as one soft mask.
    private static func subject(in image: CGImage) -> Result? {
        guard let weights = subjectWeights(in: image) else { return nil }
        return result(weights, width: image.width, height: image.height, minimumCoverage: 0.005)
    }

    private static func subjectWeights(in image: CGImage) -> [Float]? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        guard (try? handler.perform([request])) != nil, let observation = request.results?.first,
              let buffer = try? observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
        else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard width == image.width, height == image.height,
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent32Float,
              let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var weights = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
            for x in 0..<width { weights[y * width + x] = min(1, max(0, row[x])) }
        }
        return weights
    }

    // ---- sky ----
    /// Smooth, bright or blue pixels outside the subject, grown from the top edge across small
    /// color steps only and not down across a horizon. Kept when it covers at least 2% of the photo and
    /// Vision's scene classifier sees sky or the region is blue (a white ceiling isn't sky).
    private static func sky(in canonical: CGImage) -> Result? {
        // at half size: downscaling averages away the noise that would stop the fill or fake a
        // horizon, and keeps the edges that must stop it
        guard let image = scaled(canonical, longEdge: skyPixel) else { return nil }
        let width = image.width, height = image.height, count = width * height
        guard width > 2, height > 2, let pixels = rgba(image) else { return nil }
        func channel(_ i: Int, _ c: Int) -> Float { Float(pixels[i * 4 + c]) / 255 }
        var luma = [Float](repeating: 0, count: count)
        for i in 0..<count { luma[i] = 0.2126 * channel(i, 0) + 0.7152 * channel(i, 1) + 0.0722 * channel(i, 2) }
        let texture = localTexture(luma, width: width, height: height)
        // a smooth patch of sky: clearly blue, or bright and nearly colorless (overcast)
        var candidate = [Bool](repeating: false, count: count)
        for i in 0..<count {
            let r = channel(i, 0), g = channel(i, 1), b = channel(i, 2)
            let blue = b > r + 0.04 && b >= g - 0.03 && luma[i] > 0.2
            let overcast = luma[i] > 0.6 && max(r, g, b) - min(r, g, b) < 0.12
            candidate[i] = (blue || overcast) && texture[i] < 0.035
        }
        // the subject is never sky: a white building or shirt passes for overcast sky otherwise
        let subject = subjectWeights(in: image)
        if let subject {
            for i in 0..<count where subject[i] > 0.5 { candidate[i] = false }
        }
        let barrier = horizonBarrier(pixels, candidate: candidate, image: image)
        func step(_ i: Int, _ j: Int) -> Int {
            max(abs(Int(pixels[i * 4]) - Int(pixels[j * 4])), abs(Int(pixels[i * 4 + 1]) - Int(pixels[j * 4 + 1])),
                abs(Int(pixels[i * 4 + 2]) - Int(pixels[j * 4 + 2])))
        }
        // above the horizon: a tilted one crosses rows, so a sideways step can cross it too
        func below(_ x: Int, _ y: Int) -> Bool { barrier.map { $0.row(x, y) > $0.index } ?? false }
        var sky = [Bool](repeating: false, count: count)
        var stack: [Int] = []
        for x in 0..<width where candidate[x] && !below(x, 0) { sky[x] = true; stack.append(x) }
        while let i = stack.popLast() {
            let x = i % width, y = i / width
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
            where nx >= 0 && nx < width && ny >= 0 && ny < height {
                let j = ny * width + nx
                guard !sky[j], candidate[j], step(i, j) <= 5, !below(nx, ny) else { continue }
                sky[j] = true
                stack.append(j)
            }
        }
        var weights = sky.map { $0 ? Float(1) : 0 }
        if let subject {
            for i in 0..<count { weights[i] *= 1 - subject[i] }
        }
        // soften the edge by a pixel or two
        weights = boxBlur(boxBlur(weights, width: width, height: height, radius: 1), width: width, height: height, radius: 1)
        var covered = 0.0, blueness = 0.0
        for i in 0..<count where weights[i] > 0.5 {
            covered += 1
            blueness += Double(channel(i, 2) - channel(i, 0))
        }
        guard covered / Double(count) >= 0.02 else { return nil }
        guard skyConfidence(image) >= 0.05 || blueness / covered > 0.03 else { return nil }
        return result(weights, width: width, height: height, minimumCoverage: 0.02)
    }

    /// A horizon the sky can't grow down across: the first row (tilted like the horizon Vision
    /// finds) where, between sky-like pixels across a third of the width or more, the color
    /// steps consistently one way — a sky's gradient and its noise average out to nearly nothing.
    private struct Barrier {
        let index: Int
        let slope: Double
        let width: Int
        func row(_ x: Int, _ y: Int) -> Int { Int((Double(y) + slope * Double(x - width / 2)).rounded()) }
    }

    private static func horizonBarrier(_ pixels: [UInt8], candidate: [Bool], image: CGImage) -> Barrier? {
        let width = image.width, height = image.height
        let request = VNDetectHorizonRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        // Vision's angle is counterclockwise positive: a horizon rising to the right
        let probe = Barrier(index: 0, slope: tan(Double(request.results?.first?.angle ?? 0)), width: width)
        var sums = [SIMD3<Double>](repeating: .zero, count: height * 2), pairs = [Int](repeating: 0, count: height * 2)
        for y in 0..<(height - 1) {
            for x in 0..<width {
                let i = y * width + x, j = i + width
                guard candidate[i], candidate[j] else { continue }
                let r = probe.row(x, y) + height / 2
                guard r >= 0, r < height * 2 else { continue }
                pairs[r] += 1
                sums[r] += SIMD3(Double(pixels[j * 4]) - Double(pixels[i * 4]), Double(pixels[j * 4 + 1]) - Double(pixels[i * 4 + 1]),
                                 Double(pixels[j * 4 + 2]) - Double(pixels[i * 4 + 2]))
            }
        }
        // the jump is spread over a row or two at this size, so look at neighboring rows together
        for r in 0..<(height * 2 - 1) where pairs[r] > width / 3 {
            let mean = (sums[r] + sums[r + 1]) / Double(max(1, pairs[r] + pairs[r + 1]))
            guard max(abs(mean.x), abs(mean.y), abs(mean.z)) > 2.5 else { continue }
            return Barrier(index: r - height / 2, slope: probe.slope, width: width)
        }
        return nil
    }

    private static func skyConfidence(_ image: CGImage) -> Float {
        let request = VNClassifyImageRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).filter { ["sky", "blue_sky", "cloudy", "sunset_sunrise"].contains($0.identifier) }
            .map(\.confidence).max() ?? 0
    }

    // ---- helpers ----
    private static func scaled(_ image: CGImage, longEdge: Int) -> CGImage? {
        let scale = min(1, Double(longEdge) / Double(max(image.width, image.height)))
        guard scale < 1 else { return image }
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: DevelopRenderer.outputColorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    static func rgba(_ image: CGImage) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let context = CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: DevelopRenderer.outputColorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels
    }

    /// Mean luma gradient over a 5 × 5 window: how busy each pixel's neighborhood is.
    private static func localTexture(_ luma: [Float], width: Int, height: Int) -> [Float] {
        var gradient = [Float](repeating: 0, count: width * height)
        for y in 0..<(height - 1) {
            for x in 0..<(width - 1) {
                let i = y * width + x
                gradient[i] = abs(luma[i] - luma[i + 1]) + abs(luma[i] - luma[i + width])
            }
        }
        return boxBlur(gradient, width: width, height: height, radius: 2)
    }

    /// Mean over a (2r+1)² window, clipped at the edges, from a summed-area table.
    static func boxBlur(_ values: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        var table = [Double](repeating: 0, count: (width + 1) * (height + 1))
        for y in 0..<height {
            var row = 0.0
            for x in 0..<width {
                row += Double(values[y * width + x])
                table[(y + 1) * (width + 1) + x + 1] = table[y * (width + 1) + x + 1] + row
            }
        }
        var out = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let y0 = max(0, y - radius), y1 = min(height, y + radius + 1)
            for x in 0..<width {
                let x0 = max(0, x - radius), x1 = min(width, x + radius + 1)
                let sum = table[y1 * (width + 1) + x1] - table[y0 * (width + 1) + x1]
                    - table[y1 * (width + 1) + x0] + table[y0 * (width + 1) + x0]
                out[y * width + x] = Float(sum / Double((y1 - y0) * (x1 - x0)))
            }
        }
        return out
    }

    /// An 8-bit mask image with its coverage and centroid; nil when it covers too little.
    static func result(_ weights: [Float], width: Int, height: Int, minimumCoverage: Double) -> Result? {
        var bytes = [UInt8](repeating: 0, count: width * height)
        var total = 0.0, sumX = 0.0, sumY = 0.0
        for y in 0..<height {
            for x in 0..<width {
                let w = weights[y * width + x]
                bytes[y * width + x] = UInt8((min(1, max(0, w)) * 255).rounded())
                total += Double(w); sumX += Double(w) * (Double(x) + 0.5); sumY += Double(w) * (Double(y) + 0.5)
            }
        }
        let coverage = total / Double(width * height)
        guard coverage >= minimumCoverage,
              let provider = CGDataProvider(data: Data(bytes) as CFData),
              let mask = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                                 space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                                 provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return Result(mask: mask, coverage: coverage,
                      centroid: CGPoint(x: sumX / total / Double(width), y: sumY / total / Double(height)))
    }
}
