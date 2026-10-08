// ============================================================
//  PeopleMasks — Lightroom's Select People: whole people and parts of them
// ============================================================
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Vision

/// Finds the people in a photo and the parts of them a mask can select, as weights in the
/// source photo's frame (`SemanticMasks.Result`). Each photo is looked at once, as shot at
/// 2048 px: Vision's person segmentation and person instances for whole people, its face
/// landmarks for the features, and each face's own skin color for skin.
enum PeopleMasks {
    static let workingPixel = 2048

    /// One face's landmarks, in pixels of the analyzed image (top-left origin).
    struct Face: Sendable {
        /// The jaw line, from one temple round the chin to the other.
        var contour: [CGPoint]
        var eyes: [[CGPoint]]
        var brows: [[CGPoint]]
        var outerLips: [CGPoint]
        var innerLips: [CGPoint]
        var pupils: [CGPoint]

        /// Temple to temple.
        var width: Double {
            guard let a = contour.first, let b = contour.last else { return 0 }
            return hypot(Double(b.x - a.x), Double(b.y - a.y))
        }

        var center: CGPoint {
            let points = contour + eyes.flatMap { $0 } + outerLips
            guard !points.isEmpty else { return .zero }
            return CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
                           y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
        }
    }

    /// What a photo shows of its people.
    struct Analysis: Sendable {
        let width: Int, height: Int
        /// The analyzed image, RGBA.
        let pixels: [UInt8]
        /// Faces, left to right.
        let faces: [Face]
        /// Everyone, 0…255; nil when Vision found no one.
        let matte: [UInt8]?
        /// Each face's person, when Vision tells people apart.
        let people: [[UInt8]?]

        /// How many people a mask can pick between: one per face, or everyone as one.
        var count: Int { faces.isEmpty ? (matte == nil ? 0 : 1) : faces.count }
    }

    private final class AnalysisBox { let analysis: Analysis; init(_ analysis: Analysis) { self.analysis = analysis } }
    private static let analyses: NSCache<NSString, AnalysisBox> = {
        let cache = NSCache<NSString, AnalysisBox>()
        cache.countLimit = 2
        return cache
    }()
    private static let results = SemanticMasks.ResultCache()
    /// One analysis at a time: a 2048 px decode and three Vision requests.
    private static let lock = NSLock()

    /// The photo's people, looked at once per version of the file; nil when it can't be read.
    static func analysis(url: URL, isRaw: Bool) -> Analysis? {
        let key = SemanticMasks.fileKey(url) as NSString
        if let box = analyses.object(forKey: key) { return box.analysis }
        return lock.withLock {
            if let box = analyses.object(forKey: key) { return box.analysis }
            guard let image = SemanticMasks.canonicalImage(url: url, isRaw: isRaw, pixel: workingPixel),
                  let analysis = analyze(image) else { return nil }
            analyses.setObject(AnalysisBox(analysis), forKey: key)
            return analysis
        }
    }

    /// Takes `analysis` as the photo at `url`'s, for checks that can't show Vision a real face.
    static func remember(_ analysis: Analysis, for url: URL) {
        analyses.setObject(AnalysisBox(analysis), forKey: SemanticMasks.fileKey(url) as NSString)
    }

    /// The mask for `part` of `person` (an index into the faces, left to right; nil for
    /// everyone), none when the photo doesn't show it, or unreadable.
    static func lookup(_ part: PersonPart, person: Int?, url: URL, isRaw: Bool) -> SemanticMasks.Lookup {
        let key = "\(part.rawValue)|\(person ?? -1)|\(SemanticMasks.fileKey(url))"
        if let hit = results.lookup(key) { return hit }
        guard let analysis = analysis(url: url, isRaw: isRaw) else { return .unreadable }
        let result = weights(part, person: person, in: analysis).flatMap {
            SemanticMasks.result($0, width: analysis.width, height: analysis.height, minimumCoverage: 0.00001)
        }
        return results.store(result, for: key)
    }

    // ---- looking at the photo ----
    static func analyze(_ image: CGImage) -> Analysis? {
        guard let pixels = SemanticMasks.rgba(image) else { return nil }
        let width = image.width, height = image.height, size = CGSize(width: width, height: height)
        let handler = VNImageRequestHandler(cgImage: image)
        let landmarks = VNDetectFaceLandmarksRequest()
        let segmentation = VNGeneratePersonSegmentationRequest()
        segmentation.qualityLevel = .accurate
        segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let instances = VNGeneratePersonInstanceMaskRequest()
        // each request can fail on its own; what the others found still counts
        try? handler.perform([landmarks, segmentation, instances])
        let faces = (landmarks.results ?? []).compactMap { face(from: $0, size: size) }.sorted { $0.center.x < $1.center.x }
        let matte = segmentation.results?.first.flatMap { plane($0.pixelBuffer, width: width, height: height) }
        var people: [[UInt8]?] = faces.map { _ in nil }
        if let observation = instances.results?.first {
            let masks = observation.allInstances.compactMap { index in
                (try? observation.generateScaledMaskForImage(forInstances: [index], from: handler))
                    .flatMap { plane($0, width: width, height: height) }
            }
            // each face's person is the instance covering its middle
            for (i, face) in faces.enumerated() {
                let x = min(width - 1, max(0, Int(face.center.x))), y = min(height - 1, max(0, Int(face.center.y)))
                people[i] = masks.max { $0[y * width + x] < $1[y * width + x] }.flatMap { $0[y * width + x] > 127 ? $0 : nil }
            }
        }
        return Analysis(width: width, height: height, pixels: pixels, faces: faces, matte: matte, people: people)
    }

    private static func face(from observation: VNFaceObservation, size: CGSize) -> Face? {
        guard let marks = observation.landmarks else { return nil }
        func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            (region?.pointsInImage(imageSize: size) ?? []).map { CGPoint(x: $0.x, y: size.height - $0.y) }
        }
        let face = Face(contour: points(marks.faceContour),
                        eyes: [points(marks.leftEye), points(marks.rightEye)].filter { $0.count >= 3 },
                        brows: [points(marks.leftEyebrow), points(marks.rightEyebrow)].filter { $0.count >= 2 },
                        outerLips: points(marks.outerLips), innerLips: points(marks.innerLips),
                        pupils: [points(marks.leftPupil).first, points(marks.rightPupil).first].compactMap { $0 })
        // too small for its features to be told apart
        guard face.contour.count >= 3, face.width >= 24 else { return nil }
        return face
    }

    /// A one-channel Vision result at `width` × `height`, 0…255.
    private static func plane(_ buffer: CVPixelBuffer, width: Int, height: Int) -> [UInt8]? {
        let image = CIImage(cvPixelBuffer: buffer)
        guard image.extent.width > 0, image.extent.height > 0 else { return nil }
        let scaled = image.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / image.extent.width,
                                                            y: CGFloat(height) / image.extent.height))
        var bytes = [UInt8](repeating: 0, count: width * height)
        DevelopRenderer.context.render(scaled, toBitmap: &bytes, rowBytes: width,
                                       bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .R8, colorSpace: nil)
        return bytes
    }

    // ---- the parts ----
    /// `part`'s weight, 0…1 over the analyzed image; nil when the photo doesn't show it.
    static func weights(_ part: PersonPart, person: Int?, in a: Analysis) -> [Float]? {
        if let person, !(0..<a.count).contains(person) { return nil }
        let faces = person.map { a.faces.indices.contains($0) ? [a.faces[$0]] : [] } ?? a.faces
        /// The person's region: their own instance, or everyone when there's no one else.
        func region() -> [UInt8]? {
            guard let person else { return a.matte }
            return (a.people.indices.contains(person) ? a.people[person] : nil) ?? (a.count == 1 ? a.matte : nil)
        }
        switch part {
        case .person:
            return region().map { $0.map { Float($0) / 255 } }
        case .bodySkin:
            guard let region = region(), let skin = skinModel(faces, in: a) else { return nil }
            // everywhere on the person that has the face's skin color, the faces themselves left out
            let heads = raster(a) { context in
                for face in faces {
                    fill(context, facePolygon(face))
                    stroke(context, facePolygon(face), width: face.width * 0.1, closed: true)
                }
            }
            // skin is smooth where hair of a similar color is all strands
            let smooth = smoothness(a)
            let weights = (0..<(a.width * a.height)).map { i in
                Float(region[i]) / 255 * (1 - heads[i]) * skin.likeness(a.pixels, i) * smooth[i]
            }
            return feather(weights, a, radius: 1)
        case .faceSkin, .eyebrows, .sclera, .iris, .lips, .teeth:
            guard !faces.isEmpty else { return nil }
            var union = [Float](repeating: 0, count: a.width * a.height)
            for face in faces {
                guard let weights = faceWeights(part, face, in: a) else { continue }
                for i in union.indices { union[i] = max(union[i], weights[i]) }
            }
            return union
        }
    }

    private static func faceWeights(_ part: PersonPart, _ face: Face, in a: Analysis) -> [Float]? {
        let width = face.width
        let browThickness = width * 0.065
        switch part {
        case .faceSkin:
            let skin = skinArea(face, in: a)
            guard let model = skinModel([face], in: a) else { return nil }
            let weights = (0..<skin.count).map { i in skin[i] * model.likeness(a.pixels, i) }
            return feather(weights, a, radius: max(1, Int((width * 0.012).rounded())))
        case .eyebrows:
            guard !face.brows.isEmpty else { return nil }
            let brows = raster(a) { context in
                for brow in face.brows { stroke(context, brow, width: browThickness, closed: false) }
            }
            return feather(brows, a, radius: max(1, Int((width * 0.01).rounded())))
        case .sclera, .iris:
            guard !face.eyes.isEmpty else { return nil }
            let eyes = raster(a) { context in face.eyes.forEach { fill(context, $0) } }
            let irises = raster(a) { context in
                for eye in face.eyes {
                    // the pupil Vision found in this eye, or its middle; an iris is about two
                    // fifths of the eye's width across
                    let middle = CGPoint(x: eye.map(\.x).reduce(0, +) / CGFloat(eye.count),
                                         y: eye.map(\.y).reduce(0, +) / CGFloat(eye.count))
                    let span = spread(eye)
                    let pupil = face.pupils.min { distance($0, middle) < distance($1, middle) }
                        .flatMap { distance($0, middle) < span / 2 ? $0 : nil } ?? middle
                    let r = CGFloat(span * 0.21)
                    context.fillEllipse(in: CGRect(x: pupil.x - r, y: pupil.y - r, width: 2 * r, height: 2 * r))
                }
            }
            let weights = zip(eyes, irises).map { part == .iris ? $0 * $1 : $0 * (1 - $1) }
            return feather(weights, a, radius: max(1, Int((width * 0.005).rounded())))
        case .lips:
            guard face.outerLips.count >= 3 else { return nil }
            let outer = raster(a) { fill($0, face.outerLips) }
            let inner = face.innerLips.count >= 3 ? raster(a) { fill($0, face.innerLips) } : outer.map { _ in 0 }
            return feather(zip(outer, inner).map { max(0, $0 - $1) }, a, radius: max(1, Int((width * 0.006).rounded())))
        case .teeth:
            guard face.innerLips.count >= 3 else { return nil }
            let mouth = raster(a) { fill($0, face.innerLips) }
            // inside the mouth, what's light and nearly colorless
            let weights = (0..<mouth.count).map { i -> Float in
                guard mouth[i] > 0 else { return 0 }
                let r = Float(a.pixels[i * 4]) / 255, g = Float(a.pixels[i * 4 + 1]) / 255, b = Float(a.pixels[i * 4 + 2]) / 255
                let luma = 0.299 * r + 0.587 * g + 0.114 * b, top = max(r, g, b)
                let saturation = top > 0 ? (top - min(r, g, b)) / top : 0
                return mouth[i] * smoothstep(0.3, 0.5, luma) * (1 - smoothstep(0.3, 0.5, saturation))
            }
            return feather(weights, a, radius: 1)
        case .person, .bodySkin:
            return nil
        }
    }

    /// The face less its eyes, brows and mouth: where its skin is, before its color is checked.
    /// `lower` keeps to below the temples — cheeks, mouth and chin — where hair rarely falls.
    private static func skinArea(_ face: Face, in a: Analysis, lower: Bool = false) -> [Float] {
        let width = face.width
        let area = raster(a) { fill($0, lower ? face.contour : facePolygon(face)) }
        let features = raster(a) { context in
            for eye in face.eyes {
                fill(context, eye)
                stroke(context, eye, width: spread(eye) * 0.35, closed: true)
            }
            for brow in face.brows { stroke(context, brow, width: width * 0.12, closed: false) }
            if face.outerLips.count >= 3 {
                fill(context, face.outerLips)
                stroke(context, face.outerLips, width: width * 0.05, closed: true)
            }
        }
        return zip(area, features).map { max(0, $0 - $1) }
    }

    /// The face's outline: its jaw line, closed over the forehead by half an ellipse reaching as
    /// far above the brows as half the brows' height above the chin.
    static func facePolygon(_ face: Face) -> [CGPoint] {
        guard face.contour.count >= 3, let a = face.contour.first, let b = face.contour.last else { return face.contour }
        let across = (x: Double(b.x - a.x) / face.width, y: Double(b.y - a.y) / face.width)
        let middle = (x: Double(a.x + b.x) / 2, y: Double(a.y + b.y) / 2)
        // the chin is the jaw point furthest from the line between the temples
        func offLine(_ p: CGPoint) -> Double { abs((Double(p.x) - middle.x) * across.y - (Double(p.y) - middle.y) * across.x) }
        guard let chin = face.contour.max(by: { offLine($0) < offLine($1) }) else { return face.contour }
        let height = hypot(middle.x - Double(chin.x), middle.y - Double(chin.y))
        guard height > 0 else { return face.contour }
        let up = (x: (middle.x - Double(chin.x)) / height, y: (middle.y - Double(chin.y)) / height)
        func above(_ p: CGPoint) -> Double { (Double(p.x) - middle.x) * up.x + (Double(p.y) - middle.y) * up.y }
        let browsAbove = max(0, face.brows.flatMap { $0 }.map(above).max() ?? 0)
        let top = browsAbove + 0.5 * (height + browsAbove)
        let halfWidth = face.width / 2
        let arc = (0...16).map { k -> CGPoint in
            let t = Double(k) / 16 * .pi
            let sideways = halfWidth * cos(t), upward = top * sin(t)
            return CGPoint(x: middle.x + across.x * sideways + up.x * upward, y: middle.y + across.y * sideways + up.y * upward)
        }
        return face.contour + arc
    }

    // ---- skin color ----
    /// A face's skin color as chromaticity (brightness drops out, so shading stays in), from
    /// its cheeks and chin.
    private struct SkinModel {
        var r: Float, g: Float, spreadR: Float, spreadG: Float, luma: Float

        func likeness(_ pixels: [UInt8], _ i: Int) -> Float {
            let (cr, cg, y) = PeopleMasks.chromaticity(pixels, i)
            guard y > 0.01 else { return 0 }
            let dr = (cr - r) / spreadR, dg = (cg - g) / spreadG
            let tone = PeopleMasks.smoothstep(luma * 0.3, luma * 0.5, y) * (1 - PeopleMasks.smoothstep(min(0.97, luma * 1.8 + 0.1), 1.01, y))
            return exp(-0.5 * (dr * dr + dg * dg)) * tone
        }
    }

    private static func skinModel(_ faces: [Face], in a: Analysis) -> SkinModel? {
        var rs: [Float] = [], gs: [Float] = [], ys: [Float] = []
        for face in faces {
            let area = skinArea(face, in: a, lower: true)
            let step = max(1, area.lazy.filter { $0 > 0.99 }.count / 4000)
            var seen = 0
            for i in area.indices where area[i] > 0.99 {
                seen += 1
                guard seen % step == 0 else { continue }
                let (r, g, y) = chromaticity(a.pixels, i)
                guard y > 0.03, y < 0.97 else { continue }
                rs.append(r); gs.append(g); ys.append(y)
            }
        }
        guard rs.count >= 30 else { return nil }
        func median(_ values: [Float]) -> Float { values.sorted()[values.count / 2] }
        let r = median(rs), g = median(gs)
        let madR = median(rs.map { abs($0 - r) }), madG = median(gs.map { abs($0 - g) })
        return SkinModel(r: r, g: g, spreadR: max(0.012, madR * 1.4826 * 2.5), spreadG: max(0.012, madG * 1.4826 * 2.5),
                         luma: median(ys))
    }

    /// Red and green shares of the pixel's color, and its luma.
    fileprivate static func chromaticity(_ pixels: [UInt8], _ i: Int) -> (Float, Float, Float) {
        let r = Float(pixels[i * 4]) / 255, g = Float(pixels[i * 4 + 1]) / 255, b = Float(pixels[i * 4 + 2]) / 255
        let sum = max(r + g + b, 1e-4)
        return (r / sum, g / sum, 0.299 * r + 0.587 * g + 0.114 * b)
    }

    /// 1 where the image is smooth, falling to 0 where its luma varies by more than a few
    /// percent over 5 × 5 pixels.
    private static func smoothness(_ a: Analysis) -> [Float] {
        let luma = (0..<(a.width * a.height)).map { (i: Int) -> Float in
            let r = Float(a.pixels[i * 4]), g = Float(a.pixels[i * 4 + 1]), b = Float(a.pixels[i * 4 + 2])
            return (0.299 * r + 0.587 * g + 0.114 * b) / 255
        }
        let mean = SemanticMasks.boxBlur(luma, width: a.width, height: a.height, radius: 2)
        let meanSquare = SemanticMasks.boxBlur(luma.map { $0 * $0 }, width: a.width, height: a.height, radius: 2)
        return zip(mean, meanSquare).map { m, m2 in 1 - smoothstep(0.035, 0.07, max(0, m2 - m * m).squareRoot()) }
    }

    // ---- drawing ----
    /// Shapes drawn white on black over the analyzed image, 0…1, antialiased.
    private static func raster(_ a: Analysis, _ draw: (CGContext) -> Void) -> [Float] {
        var bytes = [UInt8](repeating: 0, count: a.width * a.height)
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: a.width, height: a.height, bitsPerComponent: 8,
                                          bytesPerRow: a.width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            // top-left origin, as the landmarks are
            context.translateBy(x: 0, y: CGFloat(a.height))
            context.scaleBy(x: 1, y: -1)
            context.setFillColor(gray: 1, alpha: 1)
            context.setStrokeColor(gray: 1, alpha: 1)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            draw(context)
        }
        return bytes.map { Float($0) / 255 }
    }

    private static func fill(_ context: CGContext, _ points: [CGPoint]) {
        guard points.count >= 3 else { return }
        context.addLines(between: points)
        context.closePath()
        context.fillPath()
    }

    private static func stroke(_ context: CGContext, _ points: [CGPoint], width: Double, closed: Bool) {
        guard points.count >= 2 else { return }
        context.setLineWidth(CGFloat(width))
        context.addLines(between: points)
        if closed { context.closePath() }
        context.strokePath()
    }

    /// Softened by about `radius` pixels.
    private static func feather(_ weights: [Float], _ a: Analysis, radius: Int) -> [Float] {
        let once = SemanticMasks.boxBlur(weights, width: a.width, height: a.height, radius: radius)
        return SemanticMasks.boxBlur(once, width: a.width, height: a.height, radius: radius)
    }

    /// The widest distance between two of the points.
    private static func spread(_ points: [CGPoint]) -> Double {
        var widest = 0.0
        for i in points.indices { for j in points.indices where j > i { widest = max(widest, distance(points[i], points[j])) } }
        return widest
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(Double(a.x - b.x), Double(a.y - b.y)) }

    fileprivate static func smoothstep(_ low: Float, _ high: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - low) / max(high - low, 1e-6)))
        return t * t * (3 - 2 * t)
    }
}
