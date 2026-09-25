// ============================================================
//  VisionService — on-device scene tagging + face detection
//  (PRD §4.3: 人脸检测与人物集合, 自动标签/场景识别)
//  Fully on-device; no photo data leaves the machine (§7.3).
// ============================================================
import Foundation
import Vision
import ImageIO

struct VisionResult {
    var sceneLabels: [String] = []
    var faces: Int = 0
}

enum VisionService {
    /// Run scene classification + face detection on an image file.
    static func analyze(_ url: URL, maxLabels: Int = 3, minConfidence: Float = 0.18) -> VisionResult {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return VisionResult() }
        // honor EXIF orientation so face detection works on rotated portraits (CGImage carries
        // raw pixels with no orientation); without this, orientation 6/8 photos undercount faces.
        let rawOrientation = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])?[kCGImagePropertyOrientation] as? UInt32 ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: rawOrientation) ?? .up
        var result = VisionResult()
        let classify = VNClassifyImageRequest()
        let faces = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cg, orientation: orientation, options: [:])
        try? handler.perform([classify, faces])
        if let obs = classify.results {
            result.sceneLabels = obs
                .filter { $0.confidence >= minConfidence && $0.hasMinimumPrecision(0.1, forRecall: 0.0) }
                .prefix(maxLabels)
                .map { localize($0.identifier) }
        }
        result.faces = faces.results?.count ?? 0
        return result
    }

    /// Map a handful of common Vision scene identifiers to Chinese keywords;
    /// fall back to the raw identifier for everything else.
    private static func localize(_ id: String) -> String {
        let map: [String: String] = [
            "outdoor": L("户外"), "indoor": L("室内"), "sky": L("天空"), "water": L("水景"),
            "landscape": L("风光"), "mountain": L("山脉"), "beach": L("海岸"), "snow": L("雪景"),
            "plant": L("植物"), "tree": L("树木"), "flower": L("花卉"), "animal": L("动物"),
            "people": L("人物"), "food": L("美食"), "building": L("建筑"), "city": L("城市"),
            "night": L("夜景"), "sunset": L("日落"), "vehicle": L("交通工具"), "street": L("街拍"),
        ]
        return map[id] ?? id
    }
}
