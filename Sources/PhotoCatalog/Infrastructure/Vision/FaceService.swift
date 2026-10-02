// ============================================================
//  FaceService — faces and what tells people apart, on device
// ============================================================
import Foundation
import Vision
import ImageIO
import CoreGraphics
import CoreML
import Accelerate

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
    /// The recognition model's vectors have this many numbers.
    static let vectorLength = FaceClustering.vectorLength

    /// Faces in an image file, upright. Nil when the file can't be read or the recognition
    /// model won't load. For a RAW original, `embeddedPreview` reads the camera's JPEG preview
    /// instead of developing the RAW (~10× faster, and plenty of pixels for faces).
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

    static func faces(in image: CGImage) -> [Detected]? {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let detect = VNDetectFaceRectanglesRequest()
        try? handler.perform([detect])
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let found = (detect.results ?? []).filter { $0.boundingBox.width * width >= minimumFacePixels }
        guard !found.isEmpty else { return [] }
        guard let model = AIModels.model(.faceRecognition) else { return nil }
        let landmarks = VNDetectFaceLandmarksRequest()
        landmarks.inputFaceObservations = found
        let quality = VNDetectFaceCaptureQualityRequest()
        quality.inputFaceObservations = found
        try? handler.perform([landmarks, quality])
        let marked = landmarks.results ?? []
        let scored = quality.results ?? []
        return found.compactMap { face -> Detected? in
            let box = face.boundingBox   // normalized, bottom-left origin
            // the requests answer per input face; find this one's answers by its box
            let landmarks = marked.first { $0.boundingBox == box }?.landmarks
            let points = landmarks.flatMap { keyPoints($0, box: box, width: width, height: height) }
                ?? estimatedKeyPoints(box, width: width, height: height)
            guard let crop = aligned(image, points: points), let vector = embedding(crop, model: model) else { return nil }
            return Detected(box: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height),
                            quality: scored.first { $0.boundingBox == box }?.faceCaptureQuality ?? 0, vector: vector)
        }
    }

    // ---------- alignment: the face turned and scaled onto the template SFace learned from ----------
    static let side = 112
    /// Where the eye centres, nose tip and mouth corners sit in a 112-pixel aligned face (the
    /// ArcFace template, which SFace was trained with). Top-left origin; image-left eye first.
    static let template: [CGPoint] = [CGPoint(x: 38.2946, y: 51.6963), CGPoint(x: 73.5318, y: 51.5014),
                                      CGPoint(x: 56.0252, y: 71.7366), CGPoint(x: 41.5493, y: 92.3655),
                                      CGPoint(x: 70.7299, y: 92.2041)]

    /// The template's five points found in Vision's landmarks, in pixels from the image's top left.
    static func keyPoints(_ landmarks: VNFaceLandmarks2D, box: CGRect, width: CGFloat, height: CGFloat) -> [CGPoint]? {
        guard let leftEye = landmarks.leftEye, let rightEye = landmarks.rightEye,
              let nose = landmarks.noseCrest, let lips = landmarks.outerLips else { return nil }
        // landmark points are fractions of the face box, bottom-left origin
        func pixels(_ region: VNFaceLandmarkRegion2D) -> [CGPoint] {
            region.normalizedPoints.map { point in
                CGPoint(x: (box.minX + point.x * box.width) * width, y: (1 - box.minY - point.y * box.height) * height)
            }
        }
        func mean(_ points: [CGPoint]) -> CGPoint? {
            points.isEmpty ? nil : CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
                                           y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
        }
        guard let a = mean(pixels(leftEye)), let b = mean(pixels(rightEye)), let tip = pixels(nose).last else { return nil }
        let eyes = a.x <= b.x ? [a, b] : [b, a]
        // the mouth's corners: the outer lip points furthest along the line through the eyes
        let across = CGPoint(x: eyes[1].x - eyes[0].x, y: eyes[1].y - eyes[0].y)
        let mouth = pixels(lips)
        func along(_ point: CGPoint) -> CGFloat { point.x * across.x + point.y * across.y }
        guard let left = mouth.min(by: { along($0) < along($1) }), let right = mouth.max(by: { along($0) < along($1) })
        else { return nil }
        return [eyes[0], eyes[1], tip, left, right]
    }

    /// The five points guessed from the face box alone, for a face Vision gave no landmarks.
    static func estimatedKeyPoints(_ box: CGRect, width: CGFloat, height: CGFloat) -> [CGPoint] {
        let side = CGFloat(Self.side)
        return template.map { point in
            CGPoint(x: (box.minX + point.x / side * box.width) * width,
                    y: (1 - box.maxY + point.y / side * box.height) * height)
        }
    }

    /// The least-squares rotation, scale and shift taking `from` onto `to`.
    static func similarity(from: [CGPoint], to: [CGPoint]) -> CGAffineTransform {
        let n = CGFloat(from.count)
        let fromMean = CGPoint(x: from.map(\.x).reduce(0, +) / n, y: from.map(\.y).reduce(0, +) / n)
        let toMean = CGPoint(x: to.map(\.x).reduce(0, +) / n, y: to.map(\.y).reduce(0, +) / n)
        var dot: CGFloat = 0, cross: CGFloat = 0, norm: CGFloat = 0
        for (p, q) in zip(from, to) {
            let px = p.x - fromMean.x, py = p.y - fromMean.y, qx = q.x - toMean.x, qy = q.y - toMean.y
            dot += px * qx + py * qy
            cross += px * qy - py * qx
            norm += px * px + py * py
        }
        let a = norm > 0 ? dot / norm : 1, b = norm > 0 ? cross / norm : 0
        // q = [a −b; b a] p + t
        return CGAffineTransform(a: a, b: b, c: -b, d: a,
                                 tx: toMean.x - (a * fromMean.x - b * fromMean.y),
                                 ty: toMean.y - (b * fromMean.x + a * fromMean.y))
    }

    /// The face drawn into a 112-pixel square with its key points on the template's; black
    /// where the square reaches past the photo.
    static func aligned(_ image: CGImage, points: [CGPoint]) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.interpolationQuality = .high
        // both point sets count from the top; Core Graphics counts from the bottom
        let fromTop = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(image.height))
        let toBottom = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(side))
        context.concatenate(fromTop.concatenating(similarity(from: points, to: template)).concatenating(toBottom))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// SFace's 128 numbers for an aligned face, scaled to length 1 so faces compare by angle.
    static func embedding(_ face: CGImage, model: MLModel) -> [Float]? {
        guard let input = model.modelDescription.inputDescriptionsByName.first,
              let constraint = input.value.imageConstraint,
              let value = try? MLFeatureValue(cgImage: face, constraint: constraint, options: nil),
              let output = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: [input.key: value])),
              let array = output.featureValue(for: "embedding")?.multiArrayValue,
              array.dataType == .float32, array.count == vectorLength else { return nil }
        let raw = Array(UnsafeBufferPointer(start: array.dataPointer.assumingMemoryBound(to: Float.self), count: vectorLength))
        let length = (raw.reduce(0) { $0 + $1 * $1 }).squareRoot()
        guard length > 0, length.isFinite else { return nil }
        return vDSP.divide(raw, length)
    }
}
