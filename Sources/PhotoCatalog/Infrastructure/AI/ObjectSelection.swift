// ============================================================
//  Object selection — the object a box or clicks pick out, for Select Object
// ============================================================
import CoreGraphics
import CoreML
import Foundation
import Vision

/// Segments the object an `ObjectPrompt` points at with SAM 2.1 (bundled, its tiny size): the
/// photo as shot at 1024 px is encoded once (about a tenth of a second), and each box or click
/// is then decoded into a mask in a few milliseconds. The model sees the photo stretched to a
/// 1024 × 1024 square, so places are given as fractions of it.
enum ObjectSelection {
    private final class Encoding: @unchecked Sendable { let features: MLFeatureProvider; init(_ f: MLFeatureProvider) { features = f } }
    private static let encodings: NSCache<NSString, Encoding> = {
        let cache = NSCache<NSString, Encoding>()
        cache.countLimit = 2
        return cache
    }()
    private static let results = SemanticMasks.ResultCache()
    private static let lock = NSLock()

    /// The side of the square the model sees.
    private static let side = 1024.0

    /// The object `prompt` picks out in the photo at `url`: found, nothing there, or a photo (or
    /// model) that can't be read, which isn't remembered.
    static func lookup(_ prompt: ObjectPrompt, url: URL, isRaw: Bool) -> SemanticMasks.Lookup {
        guard !prompt.isEmpty else { return .notFound }
        let file = SemanticMasks.fileKey(url)
        let key = "\(file)|\(prompt.fingerprintText)"
        if let hit = results.lookup(key) { return hit }
        return lock.withLock {
            if let hit = results.lookup(key) { return hit }
            guard let canonical = SemanticMasks.canonical(url: url, isRaw: isRaw),
                  let weights = mask(prompt, in: canonical, file: file) else { return .unreadable }
            let result = SemanticMasks.result(weights, width: canonical.width, height: canonical.height, minimumCoverage: 0.0002)
            return results.store(result, for: key)
        }
    }

    /// The object's weight, 0…1, over every pixel of `image` (rows from the top); nil when the
    /// models aren't bundled or won't run.
    static func mask(_ prompt: ObjectPrompt, in image: CGImage, file: String? = nil) -> [Float]? {
        guard let encoding = encoding(image, file: file), let (logits, size) = decode(prompt, encoding) else { return nil }
        return weights(logits, size: size, width: image.width, height: image.height)
    }

    /// The model's encoding of `image`, from memory when `file` was encoded lately.
    private static func encoding(_ image: CGImage, file: String?) -> MLFeatureProvider? {
        if let file, let cached = encodings.object(forKey: file as NSString) { return cached.features }
        guard let model = AIModels.model(.objectEncoder),
              let input = model.modelDescription.inputDescriptionsByName.first,
              let constraint = input.value.imageConstraint,
              let value = try? MLFeatureValue(cgImage: image, constraint: constraint, options: [
                  .cropAndScale: VNImageCropAndScaleOption.scaleFill.rawValue,
              ]),
              let features = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: [input.key: value]))
        else { return nil }
        if let file { encodings.setObject(Encoding(features), forKey: file as NSString) }
        return features
    }

    /// The best of the decoder's masks for `prompt`, as logits over a `size` × `size` square.
    private static func decode(_ prompt: ObjectPrompt, _ encoding: MLFeatureProvider) -> ([Float], Int)? {
        // a box is two places labeled as its corners; clicks are 1 (in) or 0 (out)
        var places: [(CGPoint, Int32)] = []
        if let box = prompt.box?.standardized {
            places.append((CGPoint(x: box.minX, y: box.minY), 2))
            places.append((CGPoint(x: box.maxX, y: box.maxY), 3))
        }
        places += prompt.points.suffix(ObjectPrompt.maxPoints).map { ($0.point, $0.include ? 1 : 0) }
        guard !places.isEmpty, let promptModel = AIModels.model(.objectPrompt), let decoder = AIModels.model(.objectDecoder),
              let points = try? MLMultiArray(shape: [1, NSNumber(value: places.count), 2], dataType: .float32),
              let labels = try? MLMultiArray(shape: [1, NSNumber(value: places.count)], dataType: .int32) else { return nil }
        for (i, (point, label)) in places.enumerated() {
            points[[0, i, 0] as [NSNumber]] = NSNumber(value: Double(min(1, max(0, point.x))) * side)
            points[[0, i, 1] as [NSNumber]] = NSNumber(value: Double(min(1, max(0, point.y))) * side)
            labels[[0, i] as [NSNumber]] = NSNumber(value: label)
        }
        guard let encoded = try? promptModel.prediction(from: MLDictionaryFeatureProvider(dictionary: ["points": points, "labels": labels])),
              let sparse = encoded.featureValue(for: "sparse_embeddings"), let dense = encoded.featureValue(for: "dense_embeddings"),
              let image = encoding.featureValue(for: "image_embedding"),
              let s0 = encoding.featureValue(for: "feats_s0"), let s1 = encoding.featureValue(for: "feats_s1"),
              let output = try? decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                  "image_embedding": image, "feats_s0": s0, "feats_s1": s1,
                  "sparse_embedding": sparse, "dense_embedding": dense,
              ])),
              let masks = output.featureValue(for: "low_res_masks")?.multiArrayValue,
              let scores = output.featureValue(for: "scores")?.multiArrayValue,
              masks.shape.count == 4 else { return nil }
        let count = masks.shape[1].intValue, size = masks.shape[2].intValue
        let best = (0..<count).max { scores[[0, $0] as [NSNumber]].floatValue < scores[[0, $1] as [NSNumber]].floatValue } ?? 0
        let strides = masks.strides.map(\.intValue)
        var logits = [Float](repeating: 0, count: size * size)
        func read<T: BinaryFloatingPoint>(_ type: T.Type) {
            let values = masks.dataPointer.assumingMemoryBound(to: T.self)
            for y in 0..<size {
                for x in 0..<size { logits[y * size + x] = Float(values[best * strides[1] + y * strides[2] + x * strides[3]]) }
            }
        }
        switch masks.dataType {
        case .float16: read(Float16.self)
        case .float32: read(Float.self)
        default: return nil
        }
        return (logits, size)
    }

    /// Logits over the model's square stretched back over `width` × `height`, bilinear (as the
    /// model's own outputs are upsampled), then turned into weights.
    static func weights(_ logits: [Float], size: Int, width: Int, height: Int) -> [Float] {
        var out = [Float](repeating: 0, count: width * height)
        let sx = Float(size) / Float(width), sy = Float(size) / Float(height)
        for y in 0..<height {
            let fy = min(Float(size - 1), max(0, (Float(y) + 0.5) * sy - 0.5))
            let y0 = Int(fy), y1 = min(size - 1, y0 + 1), ty = fy - Float(y0)
            for x in 0..<width {
                let fx = min(Float(size - 1), max(0, (Float(x) + 0.5) * sx - 0.5))
                let x0 = Int(fx), x1 = min(size - 1, x0 + 1), tx = fx - Float(x0)
                let top = logits[y0 * size + x0] * (1 - tx) + logits[y0 * size + x1] * tx
                let bottom = logits[y1 * size + x0] * (1 - tx) + logits[y1 * size + x1] * tx
                out[y * width + x] = 1 / (1 + exp(-(top * (1 - ty) + bottom * ty)))
            }
        }
        return out
    }
}
