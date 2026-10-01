// ============================================================
//  Depth map — how far each part of a photo is, for lens blur
// ============================================================
import CoreImage
import CoreML
import CryptoKit
import Foundation
import Vision

/// A photo's relative depth from Depth Anything V2 (Small, bundled): 0 is the farthest part of
/// the photo, 1 the nearest, at the model's 518 × 392 over the whole photo as decoded — before
/// turns, perspective and crop, where lens blur works. Made once per file (about 30 ms on Apple
/// silicon) and kept in memory and on disk.
enum DepthMap {
    struct Map: Equatable, Sendable {
        let width: Int
        let height: Int
        /// Rows from the top.
        let values: [Float]

        /// The depth at `point` (fractions of the photo, top-left origin), bilinear.
        func depth(at point: CGPoint) -> Double {
            let x = min(Double(width - 1), max(0, Double(point.x) * Double(width) - 0.5))
            let y = min(Double(height - 1), max(0, Double(point.y) * Double(height) - 0.5))
            let x0 = Int(x), y0 = Int(y), x1 = min(width - 1, x0 + 1), y1 = min(height - 1, y0 + 1)
            let fx = Float(x - Double(x0)), fy = Float(y - Double(y0))
            let top = values[y0 * width + x0] * (1 - fx) + values[y0 * width + x1] * fx
            let bottom = values[y1 * width + x0] * (1 - fx) + values[y1 * width + x1] * fx
            return Double(top * (1 - fy) + bottom * fy)
        }

        /// The depth below which `fraction` of the photo lies.
        func percentile(_ fraction: Double) -> Double {
            let sorted = values.sorted()
            return Double(sorted[min(sorted.count - 1, max(0, Int(Double(sorted.count) * fraction)))])
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var memory: [String: Map] = [:]
    nonisolated(unsafe) private static var order: [String] = []

    /// The map for the original at `url`, from memory, disk, or the model; nil when the model
    /// isn't bundled or the photo can't be decoded.
    static func map(for url: URL, isRaw: Bool) -> Map? {
        let key = key(for: url)
        if let hit = lock.withLock({ memory[key] }) { return hit }
        let stored = load(key)
        guard let map = stored ?? compute(url: url, isRaw: isRaw) else { return nil }
        if stored == nil { save(map, key: key) }
        keep(map, key: key)
        return map
    }

    /// Takes `map` as the photo at `url`'s (in memory only), for checks that need a depth they
    /// know.
    static func remember(_ map: Map, for url: URL) { keep(map, key: key(for: url)) }

    private static func keep(_ map: Map, key: String) {
        lock.withLock {
            if memory[key] == nil { order.append(key) }
            memory[key] = map
            while order.count > 12 { memory[order.removeFirst()] = nil }
        }
    }

    /// The model's depth for the photo at `url`, rescaled to 0…1.
    static func compute(url: URL, isRaw: Bool) -> Map? {
        guard let model = AIModels.model(.depth),
              let input = model.modelDescription.inputDescriptionsByName.first,
              let constraint = input.value.imageConstraint,
              let outputName = model.modelDescription.outputDescriptionsByName.keys.first,
              let photo = DevelopRenderer.Source(url: url, isRaw: isRaw, maxPixel: 1024)?.image(DevelopSettings())
                .flatMap(DevelopRenderer.render),
              let value = try? MLFeatureValue(cgImage: photo, constraint: constraint, options: [
                  .cropAndScale: VNImageCropAndScaleOption.scaleFill.rawValue,
              ]),
              let output = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: [input.key: value])),
              let buffer = output.featureValue(for: outputName)?.imageBufferValue else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let half = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent16Half
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        var values = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes)
            for x in 0..<width {
                values[y * width + x] = half ? Float(row.assumingMemoryBound(to: Float16.self)[x])
                    : row.assumingMemoryBound(to: Float.self)[x]
            }
        }
        guard let low = values.min(), let high = values.max(), high > low else { return nil }
        return Map(width: width, height: height, values: values.map { ($0 - low) / (high - low) })
    }

    /// Where lens blur focuses when it's turned on: the largest face's depth when the photo shows
    /// one, else the middle depth of the subject Vision finds, else the nearest major part of the
    /// photo.
    static func defaultFocus(_ map: Map, url: URL, isRaw: Bool) -> Double {
        var faces: [CGRect] = []
        if let image = SemanticMasks.canonicalImage(url: url, isRaw: isRaw) {
            let request = VNDetectFaceRectanglesRequest()
            try? VNImageRequestHandler(cgImage: image).perform([request])
            // Vision's boxes have their origin at the bottom left
            faces = (request.results ?? []).map {
                CGRect(x: $0.boundingBox.minX, y: 1 - $0.boundingBox.maxY, width: $0.boundingBox.width, height: $0.boundingBox.height)
            }
        }
        let subject = faces.isEmpty ? SemanticMasks.mask(.subject, url: url, isRaw: isRaw)?.mask : nil
        return focus(map, faces: faces, subject: subject)
    }

    /// The focus for `faces` (fractions of the photo, top-left origin) or `subject` (a weight
    /// image over the whole photo), as in `defaultFocus`.
    static func focus(_ map: Map, faces: [CGRect], subject: CGImage?) -> Double {
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        if let face = faces.max(by: { $0.width * $0.height < $1.width * $1.height }) {
            // the face's middle, away from the hair and background at its box's edges
            let inner = face.insetBy(dx: face.width / 4, dy: face.height / 4)
            return median((0..<25).map { i in
                map.depth(at: CGPoint(x: inner.minX + inner.width * Double(i % 5) / 4, y: inner.minY + inner.height * Double(i / 5) / 4))
            })
        }
        if let subject {
            // the weights drawn at the map's size, rows from the top as the map's are
            var weights = [UInt8](repeating: 0, count: map.width * map.height)
            if let context = CGContext(data: &weights, width: map.width, height: map.height, bitsPerComponent: 8,
                                       bytesPerRow: map.width, space: CGColorSpaceCreateDeviceGray(),
                                       bitmapInfo: CGImageAlphaInfo.none.rawValue) {
                context.draw(subject, in: CGRect(x: 0, y: 0, width: map.width, height: map.height))
            }
            let depths = zip(weights, map.values).filter { $0.0 > 127 }.map { Double($0.1) }
            if depths.count >= max(1, map.values.count / 200) { return median(depths) }
        }
        return map.percentile(0.85)
    }

    /// The map as a one-channel image over `extent`, stretched back from the model's frame, its
    /// edges then fitted to `guide`'s (the photo), so blur stops where the subject does.
    static func image(_ map: Map, extent: CGRect, guide: CIImage?) -> CIImage {
        let data = map.values.withUnsafeBufferPointer { Data(buffer: $0) }
        var image = CIImage(bitmapData: data, bytesPerRow: map.width * 4,
                            size: CGSize(width: map.width, height: map.height), format: .Lf, colorSpace: nil)
        // Core Image already takes bitmap rows from the top, so only scale and move
        image = image.transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(map.width),
                                                        y: extent.height / CGFloat(map.height))
            .concatenating(CGAffineTransform(translationX: extent.minX, y: extent.minY)))
            .clampedToExtent().cropped(to: extent)
        guard let guide else { return image }
        let radius = max(2, max(extent.width, extent.height) * 0.004)
        return image.applyingFilter("CIGuidedFilter", parameters: [
            "inputGuideImage": guide.clampedToExtent().cropped(to: extent), "inputRadius": radius, "inputEpsilon": 0.0005,
        ]).cropped(to: extent)
    }

    // ---- disk ----
    private static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoCatalog/Depth", isDirectory: true)
    }

    /// The file, its size and when it last changed: an edited original gets a new map.
    private static func key(for url: URL) -> String {
        let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attributes[.size] as? Int64) ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let digest = Insecure.SHA1.hash(data: Data("\(url.path)|\(size)|\(modified)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func load(_ key: String) -> Map? {
        (try? Data(contentsOf: folder.appendingPathComponent(key + ".depth"))).flatMap(decoded)
    }

    private static func save(_ map: Map, key: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? encoded(map).write(to: folder.appendingPathComponent(key + ".depth"), options: .atomic)
    }

    /// The file's layout: width and height (Int32), then the values row by row (Float).
    static func encoded(_ map: Map) -> Data {
        var data = Data()
        withUnsafeBytes(of: Int32(map.width)) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: Int32(map.height)) { data.append(contentsOf: $0) }
        map.values.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    /// The map in `data`, nil when it isn't a whole one.
    static func decoded(_ data: Data) -> Map? {
        guard data.count > 8 else { return nil }
        let width = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Int32.self) })
        let height = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int32.self) })
        guard width > 0, height > 0, data.count == 8 + width * height * 4 else { return nil }
        let values = data.withUnsafeBytes { raw in
            (0..<(width * height)).map { raw.loadUnaligned(fromByteOffset: 8 + $0 * 4, as: Float.self) }
        }
        return Map(width: width, height: height, values: values)
    }
}
