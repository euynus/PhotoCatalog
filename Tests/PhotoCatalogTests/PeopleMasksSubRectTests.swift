import CoreGraphics
import XCTest
@testable import PhotoCatalog

/// Face parts worked out over each face's padded region give the masks the whole-image pass gave,
/// within one level of 255, with the same coverage and centroid; skin color is sampled from the
/// same pixels in the same order, so body skin is unchanged.
final class PeopleMasksSubRectTests: XCTestCase {
    private let faceParts: [PersonPart] = [.faceSkin, .eyebrows, .sclera, .iris, .lips, .teeth]

    /// `analysis` moved by (`dx`, `dy`), landmarks and pixels, the uncovered pixels background.
    private func shifted(_ a: PeopleMasks.Analysis, dx: Int, dy: Int) -> PeopleMasks.Analysis {
        func move(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + CGFloat(dx), y: p.y + CGFloat(dy)) }
        var pixels = [UInt8](repeating: 51, count: a.pixels.count)
        var matte = [UInt8](repeating: 0, count: a.width * a.height)
        for y in 0..<a.height {
            for x in 0..<a.width {
                let sx = x - dx, sy = y - dy
                guard sx >= 0, sx < a.width, sy >= 0, sy < a.height else { continue }
                for c in 0..<4 { pixels[(y * a.width + x) * 4 + c] = a.pixels[(sy * a.width + sx) * 4 + c] }
                matte[y * a.width + x] = a.matte?[sy * a.width + sx] ?? 0
            }
        }
        let faces = a.faces.map { face in
            PeopleMasks.Face(contour: face.contour.map(move), eyes: face.eyes.map { $0.map(move) },
                             brows: face.brows.map { $0.map(move) }, outerLips: face.outerLips.map(move),
                             innerLips: face.innerLips.map(move), pupils: face.pupils.map(move))
        }
        return PeopleMasks.Analysis(width: a.width, height: a.height, pixels: pixels, faces: faces, matte: matte,
                                    people: a.people.map { _ in matte })
    }

    private func quantized(_ weights: [Float]) -> [UInt8] {
        weights.map { UInt8((min(1, max(0, $0)) * 255).rounded()) }
    }

    private func assertMatchesOracle(_ part: PersonPart, person: Int?, in a: PeopleMasks.Analysis, _ label: String,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let expected = Oracle.weights(part, person: person, in: a)
        let actual = PeopleMasks.weights(part, person: person, in: a)
        XCTAssertEqual(actual == nil, expected == nil, "\(label): \(part)", file: file, line: line)
        guard let expected, let actual else { return }
        let e = quantized(expected), q = quantized(actual)
        let worst = zip(e, q).map { abs(Int($0) - Int($1)) }.max() ?? 0
        XCTAssertLessThanOrEqual(worst, 1, "\(label): \(part) differs by \(worst) levels", file: file, line: line)
        let r = SemanticMasks.result(expected, width: a.width, height: a.height, minimumCoverage: 0.00001)
        let s = SemanticMasks.result(actual, width: a.width, height: a.height, minimumCoverage: 0.00001)
        XCTAssertEqual(r == nil, s == nil, "\(label): \(part) found", file: file, line: line)
        guard let r, let s else { return }
        XCTAssertEqual(s.coverage, r.coverage, accuracy: r.coverage * 1e-4 + 1e-9, "\(label): \(part) coverage", file: file, line: line)
        XCTAssertEqual(s.centroid.x, r.centroid.x, accuracy: 1e-4, "\(label): \(part) centroid", file: file, line: line)
        XCTAssertEqual(s.centroid.y, r.centroid.y, accuracy: 1e-4, "\(label): \(part) centroid", file: file, line: line)
        XCTAssertGreaterThan(r.coverage, 0, "\(label): \(part) is drawn at all", file: file, line: line)
    }

    func testOneFaceMatchesTheWholeImage() {
        let one = DevelopCheck.drawnPeople(pair: false).analysis
        for part in faceParts + [.bodySkin] {
            assertMatchesOracle(part, person: nil, in: one, "one face")
            assertMatchesOracle(part, person: 0, in: one, "one face, person 0")
        }
    }

    func testTwoFacesMatchTheWholeImage() {
        let two = DevelopCheck.drawnPeople(pair: true).analysis
        for part in faceParts + [.bodySkin] {
            for person in [nil, 0, 1] as [Int?] {
                assertMatchesOracle(part, person: person, in: two, "two faces, person \(person.map(String.init) ?? "all")")
            }
        }
    }

    /// Faces cut by the image's edges: the regions stop at them, and the feather there is the
    /// whole image's.
    func testFacesAtTheEdgesMatchTheWholeImage() {
        let one = DevelopCheck.drawnPeople(pair: false).analysis
        for (dx, dy) in [(-150, -110), (170, 120), (-200, 0), (0, 150)] {
            let moved = shifted(one, dx: dx, dy: dy)
            for part in faceParts + [.bodySkin] {
                assertMatchesOracle(part, person: nil, in: moved, "face moved by \(dx), \(dy)")
            }
        }
    }
}

/// The face parts as worked out over the whole image before, kept as the oracle.
private enum Oracle {
    static func weights(_ part: PersonPart, person: Int?, in a: PeopleMasks.Analysis) -> [Float]? {
        if let person, !(0..<a.count).contains(person) { return nil }
        let faces = person.map { a.faces.indices.contains($0) ? [a.faces[$0]] : [] } ?? a.faces
        func region() -> [UInt8]? {
            guard let person else { return a.matte }
            return (a.people.indices.contains(person) ? a.people[person] : nil) ?? (a.count == 1 ? a.matte : nil)
        }
        if part == .bodySkin {
            guard let region = region(), let skin = skinModel(faces, in: a) else { return nil }
            let heads = raster(a) { context in
                for face in faces {
                    fill(context, PeopleMasks.facePolygon(face))
                    stroke(context, PeopleMasks.facePolygon(face), width: face.width * 0.1, closed: true)
                }
            }
            let smooth = smoothness(a)
            let weights = (0..<(a.width * a.height)).map { i in
                Float(region[i]) / 255 * (1 - heads[i]) * skin.likeness(a.pixels, i) * smooth[i]
            }
            return feather(weights, a, radius: 1)
        }
        guard !faces.isEmpty else { return nil }
        var union = [Float](repeating: 0, count: a.width * a.height)
        for face in faces {
            guard let weights = faceWeights(part, face, in: a) else { continue }
            for i in union.indices { union[i] = max(union[i], weights[i]) }
        }
        return union
    }

    private static func faceWeights(_ part: PersonPart, _ face: PeopleMasks.Face, in a: PeopleMasks.Analysis) -> [Float]? {
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
    private static func skinArea(_ face: PeopleMasks.Face, in a: PeopleMasks.Analysis, lower: Bool = false) -> [Float] {
        let width = face.width
        let area = raster(a) { fill($0, lower ? face.contour : PeopleMasks.facePolygon(face)) }
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

    // ---- skin color ----
    /// A face's skin color as chromaticity (brightness drops out, so shading stays in), from
    /// its cheeks and chin.
    private struct SkinModel {
        var r: Float, g: Float, spreadR: Float, spreadG: Float, luma: Float

        func likeness(_ pixels: [UInt8], _ i: Int) -> Float {
            let (cr, cg, y) = Oracle.chromaticity(pixels, i)
            guard y > 0.01 else { return 0 }
            let dr = (cr - r) / spreadR, dg = (cg - g) / spreadG
            let tone = Oracle.smoothstep(luma * 0.3, luma * 0.5, y) * (1 - Oracle.smoothstep(min(0.97, luma * 1.8 + 0.1), 1.01, y))
            return exp(-0.5 * (dr * dr + dg * dg)) * tone
        }
    }

    private static func skinModel(_ faces: [PeopleMasks.Face], in a: PeopleMasks.Analysis) -> SkinModel? {
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
    static func chromaticity(_ pixels: [UInt8], _ i: Int) -> (Float, Float, Float) {
        let r = Float(pixels[i * 4]) / 255, g = Float(pixels[i * 4 + 1]) / 255, b = Float(pixels[i * 4 + 2]) / 255
        let sum = max(r + g + b, 1e-4)
        return (r / sum, g / sum, 0.299 * r + 0.587 * g + 0.114 * b)
    }

    // ---- drawing ----
    /// Shapes drawn white on black over the analyzed image, 0…1, antialiased.
    private static func raster(_ a: PeopleMasks.Analysis, _ draw: (CGContext) -> Void) -> [Float] {
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
    private static func feather(_ weights: [Float], _ a: PeopleMasks.Analysis, radius: Int) -> [Float] {
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

    static func smoothstep(_ low: Float, _ high: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - low) / max(high - low, 1e-6)))
        return t * t * (3 - 2 * t)
    }
    /// 1 where the image is smooth, falling to 0 where its luma varies by more than a few
    /// percent over 5 × 5 pixels.
    private static func smoothness(_ a: PeopleMasks.Analysis) -> [Float] {
        let luma = (0..<(a.width * a.height)).map { (i: Int) -> Float in
            let r = Float(a.pixels[i * 4]), g = Float(a.pixels[i * 4 + 1]), b = Float(a.pixels[i * 4 + 2])
            return (0.299 * r + 0.587 * g + 0.114 * b) / 255
        }
        let mean = SemanticMasks.boxBlur(luma, width: a.width, height: a.height, radius: 2)
        let meanSquare = SemanticMasks.boxBlur(luma.map { $0 * $0 }, width: a.width, height: a.height, radius: 2)
        return zip(mean, meanSquare).map { m, m2 in 1 - smoothstep(0.035, 0.07, max(0, m2 - m * m).squareRoot()) }
    }
}
