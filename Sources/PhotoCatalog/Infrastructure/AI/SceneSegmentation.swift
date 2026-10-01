// ============================================================
//  Scene segmentation — the landscape masks: water, vegetation, mountains, buildings, ground
// ============================================================
import CoreImage
import CoreML
import Foundation
import Vision

/// Labels every part of a photo with what it shows (DETR, bundled, trained on COCO's things and
/// stuff) and turns a landscape category's labels into a mask. The photo as shot at 1024 px is
/// stretched to the model's 448 × 448, so the labels cover all of it; each mask's edges are then
/// fitted to the photo's own.
enum SceneSegmentation {
    /// Each pixel's label (an index into `labels`), rows from the top.
    struct ClassMap: Sendable {
        let width: Int
        let height: Int
        let classes: [UInt8]
    }

    /// Which of the model's labels make up each category, by name, so a model with its labels
    /// in another order still masks the right things.
    static let categoryLabels: [LandscapeCategory: [String]] = [
        .water: ["sea", "river", "water (other)"],
        .vegetation: ["tree", "grass", "flower", "potted plant"],
        .mountains: ["mountain"],
        .architecture: ["building (other)", "house", "roof", "bridge", "wall (brick)", "wall (stone)", "wall (tile)",
                        "wall (wood)", "wall (other)", "window (blind)", "window (other)", "door", "stairs", "fence"],
        // rock: the model calls stone walls and boulders rock, which aren't mountains
        .naturalGround: ["sand", "dirt", "gravel", "snow", "rock"],
        .artificialGround: ["road", "pavement", "railroad", "platform", "playingfield", "floor (wood)", "floor (other)", "rug"],
    ]

    /// The model's labels, as its metadata lists them.
    static let labels: [String] = {
        guard let model = AIModels.model(.segmentation),
              let metadata = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String],
              let parameters = metadata["com.apple.coreml.model.preview.params"],
              let object = try? JSONSerialization.jsonObject(with: Data(parameters.utf8)) as? [String: Any],
              let labels = object["labels"] as? [String] else { return [] }
        return labels
    }()

    private final class MapBox { let map: ClassMap; init(_ map: ClassMap) { self.map = map } }
    private static let maps: NSCache<NSString, MapBox> = {
        let cache = NSCache<NSString, MapBox>()
        cache.countLimit = 4
        return cache
    }()
    private final class ResultBox { let result: SemanticMasks.Result?; init(_ result: SemanticMasks.Result?) { self.result = result } }
    private static let results: NSCache<NSString, ResultBox> = {
        let cache = NSCache<NSString, ResultBox>()
        cache.countLimit = 24
        return cache
    }()
    private static let lock = NSLock()

    private static func fileKey(_ url: URL) -> String {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return "\(url.path)|\(modified?.timeIntervalSince1970 ?? 0)"
    }

    /// The mask of `category` in the photo at `url`: found, none of it in the photo, or a photo
    /// (or model) that can't be read, which isn't remembered.
    static func lookup(_ category: LandscapeCategory, url: URL, isRaw: Bool) -> SemanticMasks.Lookup {
        let file = fileKey(url)
        let key = "\(category.rawValue)|\(file)" as NSString
        if let box = results.object(forKey: key) { return box.result.map(SemanticMasks.Lookup.found) ?? .notFound }
        return lock.withLock {
            if let box = results.object(forKey: key) { return box.result.map(SemanticMasks.Lookup.found) ?? .notFound }
            guard let canonical = SemanticMasks.canonical(url: url, isRaw: isRaw),
                  let map = classMap(canonical, file: file) else { return .unreadable }
            let result = refined(weights(category, in: map), width: map.width, height: map.height, guide: canonical)
                .flatMap { SemanticMasks.result($0, width: canonical.width, height: canonical.height, minimumCoverage: 0.002) }
            results.setObject(ResultBox(result), forKey: key)
            return result.map(SemanticMasks.Lookup.found) ?? .notFound
        }
    }

    /// Takes `map` as the photo at `url`'s, for checks that need labels they know.
    static func remember(_ map: ClassMap, for url: URL) {
        maps.setObject(MapBox(map), forKey: fileKey(url) as NSString)
    }

    /// The labels of `image` (the photo at `file`), from memory or the model.
    private static func classMap(_ image: CGImage, file: String) -> ClassMap? {
        if let box = maps.object(forKey: file as NSString) { return box.map }
        guard let map = classify(image) else { return nil }
        maps.setObject(MapBox(map), forKey: file as NSString)
        return map
    }

    /// The model's label for every part of `image`, over all of it.
    static func classify(_ image: CGImage) -> ClassMap? {
        guard let model = AIModels.model(.segmentation),
              let input = model.modelDescription.inputDescriptionsByName.first,
              let constraint = input.value.imageConstraint,
              let outputName = model.modelDescription.outputDescriptionsByName.keys.first,
              let value = try? MLFeatureValue(cgImage: image, constraint: constraint, options: [
                  .cropAndScale: VNImageCropAndScaleOption.scaleFill.rawValue,
              ]),
              let output = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: [input.key: value])),
              let array = output.featureValue(for: outputName)?.multiArrayValue,
              array.shape.count == 2, array.dataType == .int32 else { return nil }
        let height = array.shape[0].intValue, width = array.shape[1].intValue
        let rowStride = array.strides[0].intValue, columnStride = array.strides[1].intValue
        let values = array.dataPointer.assumingMemoryBound(to: Int32.self)
        var classes = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width { classes[y * width + x] = UInt8(clamping: values[y * rowStride + x * columnStride]) }
        }
        return ClassMap(width: width, height: height, classes: classes)
    }

    /// 1 where `map` shows one of `category`'s labels, 0 elsewhere.
    static func weights(_ category: LandscapeCategory, in map: ClassMap, labels: [String] = labels) -> [Float] {
        let wanted = Set(categoryLabels[category] ?? [])
        let inCategory = labels.map { wanted.contains($0) }
        return map.classes.map { Int($0) < inCategory.count && inCategory[Int($0)] ? 1 : 0 }
    }

    /// `weights` (`width` × `height`) stretched over `guide` and its edges fitted to the
    /// photo's, at the guide's size.
    static func refined(_ weights: [Float], width: Int, height: Int, guide: CGImage) -> [Float]? {
        let extent = CGRect(x: 0, y: 0, width: guide.width, height: guide.height)
        let data = weights.withUnsafeBufferPointer { Data(buffer: $0) }
        // Core Image takes bitmap rows from the top, as the weights are
        let coarse = CIImage(bitmapData: data, bytesPerRow: width * 4, size: CGSize(width: width, height: height),
                             format: .Lf, colorSpace: nil)
            .clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(width), y: extent.height / CGFloat(height)))
            .cropped(to: extent)
        let fitted = coarse.applyingFilter("CIGuidedFilter", parameters: [
            "inputGuideImage": CIImage(cgImage: guide), "inputRadius": 4, "inputEpsilon": 0.001,
        ]).cropped(to: extent)
        var out = [Float](repeating: 0, count: guide.width * guide.height)
        DevelopRenderer.context.render(fitted, toBitmap: &out, rowBytes: guide.width * 4, bounds: extent,
                                       format: .Lf, colorSpace: nil)
        return out.map { min(1, max(0, $0)) }
    }
}
