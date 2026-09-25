// ============================================================
//  FaceService — faces and their feature prints, on device
// ============================================================
import Foundation
import Vision
import ImageIO
import CoreGraphics

enum FaceService {
    struct Detected: Sendable {
        /// Normalized, top-left origin, in the upright image.
        let box: CGRect
        let quality: Float
        let vector: [Float]
    }

    /// Faces too small to recognise are skipped (pixels on the image's long edge).
    static let minimumFacePixels: CGFloat = 40
    static let analysisMaxPixel = 2048

    /// Faces in an image file, upright. Nil when the file can't be read. For a RAW original,
    /// `embeddedPreview` reads the camera's JPEG preview instead of developing the RAW (~10×
    /// faster, and plenty of pixels for faces).
    static func faces(in url: URL, embeddedPreview: Bool = false) -> [Detected]? {
        let fromImage = embeddedPreview ? kCGImageSourceCreateThumbnailFromImageIfAbsent : kCGImageSourceCreateThumbnailFromImageAlways
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  fromImage: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: analysisMaxPixel,
              ] as CFDictionary) else { return nil }
        return faces(in: image)
    }

    static func faces(in image: CGImage) -> [Detected] {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let detect = VNDetectFaceRectanglesRequest()
        try? handler.perform([detect])
        guard let found = detect.results, !found.isEmpty else { return [] }
        let quality = VNDetectFaceCaptureQualityRequest()
        quality.inputFaceObservations = found
        try? handler.perform([quality])
        let width = CGFloat(image.width), height = CGFloat(image.height)
        return (quality.results ?? found).compactMap { face -> Detected? in
            let box = face.boundingBox   // normalized, bottom-left origin
            guard box.width * width >= minimumFacePixels else { return nil }
            // a square crop with some hair and chin, which prints more consistently
            let side = max(box.width * width, box.height * height) * 1.4
            var crop = CGRect(x: box.midX * width - side / 2, y: box.midY * height - side / 2, width: side, height: side)
            crop = crop.intersection(CGRect(x: 0, y: 0, width: width, height: height))
            let print = VNGenerateImageFeaturePrintRequest()
            print.regionOfInterest = CGRect(x: crop.minX / width, y: crop.minY / height,
                                            width: crop.width / width, height: crop.height / height)
            print.imageCropAndScaleOption = .scaleFill
            try? handler.perform([print])
            guard let observation = print.results?.first else { return nil }
            return Detected(box: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height),
                            quality: face.faceCaptureQuality ?? 0, vector: vector(of: observation))
        }
    }

    private static func vector(of observation: VNFeaturePrintObservation) -> [Float] {
        let count = observation.elementCount
        return observation.data.withUnsafeBytes { raw in
            switch observation.elementType {
            case .float: Array(raw.bindMemory(to: Float.self).prefix(count))
            case .double: raw.bindMemory(to: Double.self).prefix(count).map(Float.init)
            default: []
            }
        }
    }
}
