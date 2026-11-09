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
                guard let patch = faceWeights(part, face, in: a) else { continue }
                let r = patch.region
                for y in 0..<r.height {
                    for x in 0..<r.width {
                        let i = (r.y + y) * a.width + r.x + x
                        union[i] = max(union[i], patch.values[y * r.width + x])
                    }
                }
            }
            return union
        }
    }

    /// A rectangle of the analyzed image, in whole pixels (top-left origin).
    private struct Region {
        var x: Int, y: Int, width: Int, height: Int

        static func whole(_ a: Analysis) -> Region { Region(x: 0, y: 0, width: a.width, height: a.height) }

        /// Covers what's drawn inside `bounds`, antialiased edges included, and `pad` pixels round
        /// that: room for a feather to fade out in. Never outside the image.
        init(covering bounds: CGRect, pad: Int, in a: Analysis) {
            guard !bounds.isNull, bounds.minX.isFinite, bounds.maxX.isFinite, bounds.minY.isFinite, bounds.maxY.isFinite else {
                self.init(x: 0, y: 0, width: 0, height: 0)
                return
            }
            let x0 = max(0, Int(bounds.minX.rounded(.down)) - 1 - pad)
            let y0 = max(0, Int(bounds.minY.rounded(.down)) - 1 - pad)
            let x1 = min(a.width, Int(bounds.maxX.rounded(.up)) + 1 + pad)
            let y1 = min(a.height, Int(bounds.maxY.rounded(.up)) + 1 + pad)
            self.init(x: min(x0, a.width), y: min(y0, a.height), width: max(0, x1 - x0), height: max(0, y1 - y0))
        }

        init(x: Int, y: Int, width: Int, height: Int) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }

        /// The image's pixel index of the region's `i`th, row by row.
        func index(_ i: Int, in a: Analysis) -> Int { (y + i / width) * a.width + x + i % width }
    }

    /// Weights over a region of the analyzed image, row by row; 0 outside it.
    private struct Patch {
        let region: Region
        let values: [Float]
    }

    /// One face's `part`, worked out over the part of the image it can reach: what's drawn for
    /// it, and room for its feather.
    private static func faceWeights(_ part: PersonPart, _ face: Face, in a: Analysis) -> Patch? {
        let width = face.width
        let browThickness = width * 0.065
        /// Feathered by `radius`: the region round `bounds` the feather can reach.
        func region(_ bounds: CGRect, feather radius: Int) -> Region {
            Region(covering: bounds, pad: 3 * radius + 2, in: a)
        }
        switch part {
        case .faceSkin:
            let radius = max(1, Int((width * 0.012).rounded()))
            let skin = skinArea(face, in: a, pad: 3 * radius + 2)
            guard let model = skinModel([face], in: a) else { return nil }
            let weights = skin.values.indices.map { i in skin.values[i] * model.likeness(a.pixels, skin.region.index(i, in: a)) }
            return Patch(region: skin.region, values: feather(weights, skin.region, radius: radius))
        case .eyebrows:
            guard !face.brows.isEmpty else { return nil }
            let radius = max(1, Int((width * 0.01).rounded()))
            let area = region(bounds(face.brows, outset: browThickness / 2), feather: radius)
            let brows = raster(a, in: area) { context in
                for brow in face.brows { stroke(context, brow, width: browThickness, closed: false) }
            }
            return Patch(region: area, values: feather(brows, area, radius: radius))
        case .sclera, .iris:
            guard !face.eyes.isEmpty else { return nil }
            // the pupil Vision found in each eye, or its middle; an iris is about two fifths of the
            // eye's width across
            let irisCircles = face.eyes.map { eye -> CGRect in
                let middle = CGPoint(x: eye.map(\.x).reduce(0, +) / CGFloat(eye.count),
                                     y: eye.map(\.y).reduce(0, +) / CGFloat(eye.count))
                let span = spread(eye)
                let pupil = face.pupils.min { distance($0, middle) < distance($1, middle) }
                    .flatMap { distance($0, middle) < span / 2 ? $0 : nil } ?? middle
                let r = CGFloat(span * 0.21)
                return CGRect(x: pupil.x - r, y: pupil.y - r, width: 2 * r, height: 2 * r)
            }
            let radius = max(1, Int((width * 0.005).rounded()))
            let area = region(irisCircles.reduce(bounds(face.eyes, outset: 0)) { $0.union($1) }, feather: radius)
            let eyes = raster(a, in: area) { context in face.eyes.forEach { fill(context, $0) } }
            let irises = raster(a, in: area) { context in irisCircles.forEach { context.fillEllipse(in: $0) } }
            let weights = zip(eyes, irises).map { part == .iris ? $0 * $1 : $0 * (1 - $1) }
            return Patch(region: area, values: feather(weights, area, radius: radius))
        case .lips:
            guard face.outerLips.count >= 3 else { return nil }
            let radius = max(1, Int((width * 0.006).rounded()))
            let area = region(bounds([face.outerLips], outset: 0), feather: radius)
            let outer = raster(a, in: area) { fill($0, face.outerLips) }
            let inner = face.innerLips.count >= 3 ? raster(a, in: area) { fill($0, face.innerLips) } : outer.map { _ in 0 }
            return Patch(region: area, values: feather(zip(outer, inner).map { max(0, $0 - $1) }, area, radius: radius))
        case .teeth:
            guard face.innerLips.count >= 3 else { return nil }
            let area = region(bounds([face.innerLips], outset: 0), feather: 1)
            let mouth = raster(a, in: area) { fill($0, face.innerLips) }
            // inside the mouth, what's light and nearly colorless
            let weights = mouth.indices.map { j -> Float in
                guard mouth[j] > 0 else { return 0 }
                let i = area.index(j, in: a)
                let r = Float(a.pixels[i * 4]) / 255, g = Float(a.pixels[i * 4 + 1]) / 255, b = Float(a.pixels[i * 4 + 2]) / 255
                let luma = 0.299 * r + 0.587 * g + 0.114 * b, top = max(r, g, b)
                let saturation = top > 0 ? (top - min(r, g, b)) / top : 0
                return mouth[j] * smoothstep(0.3, 0.5, luma) * (1 - smoothstep(0.3, 0.5, saturation))
            }
            return Patch(region: area, values: feather(weights, area, radius: 1))
        case .person, .bodySkin:
            return nil
        }
    }

    /// The face less its eyes, brows and mouth: where its skin is, before its color is checked,
    /// over the face's outline and `pad` pixels round it. `lower` keeps to below the temples —
    /// cheeks, mouth and chin — where hair rarely falls.
    private static func skinArea(_ face: Face, in a: Analysis, lower: Bool = false, pad: Int = 0) -> Patch {
        let width = face.width
        let outline = lower ? face.contour : facePolygon(face)
        let area = Region(covering: bounds([outline], outset: 0), pad: pad, in: a)
        let inside = raster(a, in: area) { fill($0, outline) }
        let features = raster(a, in: area) { context in
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
        return Patch(region: area, values: zip(inside, features).map { max(0, $0 - $1) })
    }

    /// What `shapes` cover, `outset` wider all round (half a stroke's width).
    private static func bounds(_ shapes: [[CGPoint]], outset: Double) -> CGRect {
        let points = shapes.flatMap { $0 }
        guard let first = points.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).insetBy(dx: -outset, dy: -outset)
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
            // row by row over the outline's region: the image's own order
            let area = skinArea(face, in: a, lower: true)
            let step = max(1, area.values.lazy.filter { $0 > 0.99 }.count / 4000)
            var seen = 0
            for j in area.values.indices where area.values[j] > 0.99 {
                seen += 1
                guard seen % step == 0 else { continue }
                let (r, g, y) = chromaticity(a.pixels, area.region.index(j, in: a))
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
        raster(a, in: .whole(a), draw)
    }

    /// Shapes drawn white on black over `region` of the analyzed image, 0…1, antialiased.
    private static func raster(_ a: Analysis, in region: Region, _ draw: (CGContext) -> Void) -> [Float] {
        guard region.width > 0, region.height > 0 else { return [] }
        var bytes = [UInt8](repeating: 0, count: region.width * region.height)
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: region.width, height: region.height,
                                          bitsPerComponent: 8, bytesPerRow: region.width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            // top-left origin, as the landmarks are, at the region's corner
            context.translateBy(x: 0, y: CGFloat(region.height))
            context.scaleBy(x: 1, y: -1)
            context.translateBy(x: CGFloat(-region.x), y: CGFloat(-region.y))
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
        feather(weights, .whole(a), radius: radius)
    }

    /// Weights over `region` softened by about `radius` pixels: as over the whole image when
    /// they fade to 0 at least 2 × `radius` from its edges inside the image.
    private static func feather(_ weights: [Float], _ region: Region, radius: Int) -> [Float] {
        guard region.width > 0, region.height > 0 else { return weights }
        let once = SemanticMasks.boxBlur(weights, width: region.width, height: region.height, radius: radius)
        return SemanticMasks.boxBlur(once, width: region.width, height: region.height, radius: radius)
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
