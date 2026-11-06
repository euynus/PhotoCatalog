import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

extension DevelopCheck {
    /// A drawn face with its landmarks where they are, and a second one when `pair`: people
    /// masks are checked on it without Vision, which only knows real faces.
    private static func drawnPeople(pair: Bool) -> (analysis: PeopleMasks.Analysis, image: CGImage) {
        let width = pair ? 800 : 400, height = 400
        func ellipse(_ c: CGPoint, _ rx: Double, _ ry: Double, _ n: Int, from: Double = 0, to: Double = 2 * .pi) -> [CGPoint] {
            (0..<n).map { k in
                let t = from + (to - from) * Double(k) / Double(n - 1)
                return CGPoint(x: Double(c.x) + rx * cos(t), y: Double(c.y) + ry * sin(t))
            }
        }
        func face(_ dx: Double) -> PeopleMasks.Face {
            // y points down: the jaw runs from the left temple (angle π) down round the chin (π/2)
            PeopleMasks.Face(contour: ellipse(CGPoint(x: 200 + dx, y: 190), 90, 120, 17, from: .pi, to: 0),
                             eyes: [ellipse(CGPoint(x: 165 + dx, y: 180), 18, 7, 8, to: 2 * .pi * 7 / 8),
                                    ellipse(CGPoint(x: 235 + dx, y: 180), 18, 7, 8, to: 2 * .pi * 7 / 8)],
                             brows: [[CGPoint(x: 145 + dx, y: 160), CGPoint(x: 165 + dx, y: 155), CGPoint(x: 185 + dx, y: 160)],
                                     [CGPoint(x: 215 + dx, y: 160), CGPoint(x: 235 + dx, y: 155), CGPoint(x: 255 + dx, y: 160)]],
                             outerLips: ellipse(CGPoint(x: 200 + dx, y: 260), 30, 12, 14, to: 2 * .pi * 13 / 14),
                             innerLips: ellipse(CGPoint(x: 200 + dx, y: 260), 22, 4, 6, to: 2 * .pi * 5 / 6),
                             pupils: [CGPoint(x: 165 + dx, y: 180), CGPoint(x: 235 + dx, y: 180)])
        }
        func inside(_ x: Double, _ y: Double, _ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) -> Bool {
            let u = (x - cx) / rx, v = (y - cy) / ry
            return u * u + v * v <= 1
        }
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var matte = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let px = Double(x) + 0.5, py = Double(y) + 0.5
                let dx = pair && px >= 400 ? 400.0 : 0
                let fx = px - dx
                var c = (0.2, 0.2, 0.2)
                var person = false
                if inside(fx, py, 200, 175, 95, 135) && py < 80 { c = (0.3, 0.2, 0.12); person = true }          // hair
                else if fx > 170 && fx < 230 && py > 290 { c = (0.8, 0.6, 0.5); person = true }                 // neck
                if inside(fx, py, 200, 185, 88, 125) && py >= 80 { c = (0.85, 0.65, 0.55); person = true }      // skin
                if inside(fx, py, 165, 180, 18, 7) || inside(fx, py, 235, 180, 18, 7) {
                    c = inside(fx, py, 165, 180, 7, 7) || inside(fx, py, 235, 180, 7, 7) ? (0.3, 0.2, 0.1) : (0.95, 0.95, 0.95)
                }
                let brow = [(145.0, 160.0, 165.0, 155.0), (165, 155, 185, 160), (215, 160, 235, 155), (235, 155, 255, 160)]
                    .contains { x0, y0, x1, y1 in
                        let t = max(0, min(1, ((fx - x0) * (x1 - x0) + (py - y0) * (y1 - y0)) / ((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0))))
                        return hypot(fx - (x0 + t * (x1 - x0)), py - (y0 + t * (y1 - y0))) < 4
                    }
                if brow { c = (0.25, 0.2, 0.15) }
                if inside(fx, py, 200, 260, 30, 12) { c = inside(fx, py, 200, 260, 22, 4) ? (0.95, 0.93, 0.9) : (0.75, 0.3, 0.35) }
                let i = y * width + x
                pixels[i * 4] = UInt8(c.0 * 255); pixels[i * 4 + 1] = UInt8(c.1 * 255); pixels[i * 4 + 2] = UInt8(c.2 * 255)
                matte[i] = person ? 255 : 0
            }
        }
        let faces = pair ? [face(0), face(400)] : [face(0)]
        let people: [[UInt8]?] = pair
            ? [matte.enumerated().map { $0.offset % width < 400 ? $0.element : 0 }, matte.enumerated().map { $0.offset % width >= 400 ? $0.element : 0 }]
            : [matte]
        let analysis = PeopleMasks.Analysis(width: width, height: height, pixels: pixels, faces: faces, matte: matte, people: people)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: DevelopRenderer.outputColorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        return (analysis, context.makeImage()!)
    }

    static func checkPeopleMasks() {
        let (one, drawn) = drawnPeople(pair: false)
        func weight(_ part: PersonPart, _ x: Int, _ y: Int, person: Int? = nil, in a: PeopleMasks.Analysis = one) -> Float {
            PeopleMasks.weights(part, person: person, in: a)?[y * a.width + x] ?? -1
        }
        let cheek = (150, 230), eyeWhite = (152, 180), iris = (165, 180), brow = (165, 156), lip = (200, 268)
        let mouth = (200, 260), neck = (200, 340), hair = (200, 60), background = (20, 20)
        assert(weight(.person, 200, 200) > 0.9 && weight(.person, background.0, background.1) < 0.1,
               "the whole person is Vision's matte")
        assert(weight(.faceSkin, cheek.0, cheek.1) > 0.5 && weight(.faceSkin, iris.0, iris.1) < 0.2
               && weight(.faceSkin, brow.0, brow.1) < 0.2 && weight(.faceSkin, lip.0, lip.1) < 0.2
               && weight(.faceSkin, hair.0, hair.1) < 0.2 && weight(.faceSkin, neck.0, neck.1) < 0.2,
               "face skin leaves out the eyes, brows, lips, hair and neck")
        assert(weight(.bodySkin, neck.0, neck.1) > 0.5 && weight(.bodySkin, cheek.0, cheek.1) < 0.2
               && weight(.bodySkin, hair.0, hair.1) < 0.2 && weight(.bodySkin, background.0, background.1) < 0.1,
               "body skin is the rest of the person's skin")
        assert(weight(.eyebrows, brow.0, brow.1) > 0.5 && weight(.eyebrows, cheek.0, cheek.1) < 0.1, "eyebrows follow the brow lines")
        assert(weight(.sclera, eyeWhite.0, eyeWhite.1) > 0.5 && weight(.sclera, iris.0, iris.1) < 0.3
               && weight(.iris, iris.0, iris.1) > 0.5 && weight(.iris, eyeWhite.0, eyeWhite.1) < 0.3,
               "an eye splits into its white and the iris round the pupil")
        assert(weight(.lips, lip.0, lip.1) > 0.5 && weight(.lips, mouth.0, mouth.1) < 0.3
               && weight(.teeth, mouth.0, mouth.1) > 0.5 && weight(.teeth, lip.0, lip.1) < 0.3,
               "lips ring the mouth; teeth are the light inside it")
        assert(one.count == 1 && PeopleMasks.weights(.lips, person: 1, in: one) == nil
               && weight(.lips, lip.0, lip.1, person: 0) == weight(.lips, lip.0, lip.1),
               "one person: the only index is theirs")

        // two people: numbered left to right, each mask narrowed to one
        let (two, _) = drawnPeople(pair: true)
        assert(two.count == 2 && weight(.faceSkin, cheek.0, cheek.1, person: 1, in: two) < 0.1
               && weight(.faceSkin, cheek.0 + 400, cheek.1, person: 1, in: two) > 0.5
               && weight(.person, 200, 200, person: 0, in: two) > 0.9 && weight(.person, 600, 200, person: 0, in: two) < 0.1
               && weight(.faceSkin, cheek.0, cheek.1, in: two) > 0.5 && weight(.faceSkin, cheek.0 + 400, cheek.1, in: two) > 0.5,
               "each person can be picked alone, or everyone together")

        // rendered: a lips mask brightens the lips and nothing else
        let url = pngFile(drawn)
        defer { try? FileManager.default.removeItem(at: url) }
        PeopleMasks.remember(one, for: url)
        var settings = DevelopSettings()
        var lips = LocalAdjustment(kind: .person)
        lips.part = .lips
        lips.exposure = 1.5
        settings.masks = [lips]
        let source = DevelopRenderer.Source(url: url, isRaw: false, maxPixel: nil)!
        let plain = DevelopRenderer.render(source.image(.neutral)!)!, bright = DevelopRenderer.render(source.image(settings)!)!
        assert(Int(pixel(bright, lip.0, lip.1).g) > Int(pixel(plain, lip.0, lip.1).g) + 20
               && abs(Int(pixel(bright, cheek.0, cheek.1).g) - Int(pixel(plain, cheek.0, cheek.1).g)) <= 2,
               "a people mask adjusts only its part")

        // stored with the photo; a different part or person is a different render
        var eyes = lips
        eyes.part = .iris
        var second = lips
        second.person = 1
        let back = (try? JSONEncoder().encode(eyes)).flatMap { try? JSONDecoder().decode(LocalAdjustment.self, from: $0) }
        assert(back == eyes && lips.fingerprintText != eyes.fingerprintText && lips.fingerprintText != second.fingerprintText
               && eyes.title == PersonPart.iris.title,
               "a people mask keeps its part and person")
    }

    static func checkLocalAdjustments() {
        let gray = image { _, _ in (0.4, 0.4, 0.4) }
        func luma(_ image: CGImage, _ x: Int, _ y: Int) -> Double {
            let p = pixel(image, x, y)
            return 0.3 * Double(p.r) + 0.59 * Double(p.g) + 0.11 * Double(p.b)
        }
        let base = luma(develop(gray, .neutral), 32, 32)

        var s = DevelopSettings()
        var radial = LocalAdjustment(kind: .radial)
        radial.center = CGPoint(x: 0.25, y: 0.25)
        radial.radiusX = 0.15; radial.radiusY = 0.15; radial.feather = 20
        radial.exposure = 1.5
        s.masks = [radial]
        var out = develop(gray, s)
        assert(luma(out, 16, 16) > base + 30 && abs(luma(out, 48, 48) - base) < 2,
               "a radial gradient brightens inside and leaves the rest alone")
        s.masks[0].inverted = true
        out = develop(gray, s)
        assert(abs(luma(out, 16, 16) - base) < 2 && luma(out, 48, 48) > base + 30, "an inverted gradient works outside")

        var linear = LocalAdjustment(kind: .linear)
        linear.start = CGPoint(x: 0.5, y: 0); linear.end = CGPoint(x: 0.5, y: 0.5)
        linear.exposure = -1.5
        s.masks = [linear]
        out = develop(gray, s)
        assert(luma(out, 32, 2) < base - 30 && luma(out, 32, 16) < base - 5 && abs(luma(out, 32, 56) - base) < 2,
               "a linear gradient fades from full effect at its start to none past its end")

        s.masks = [linear.withoutAdjustments]
        assert(!s.masks[0].hasEffect && abs(luma(develop(gray, s), 32, 2) - base) < 2, "a mask without adjustments changes nothing")
        var warm = LocalAdjustment(kind: .radial)
        warm.radiusX = 1; warm.radiusY = 1; warm.temperature = 60; warm.saturation = 20
        s.masks = [warm]
        let warmed = pixel(develop(gray, s), 32, 32)
        assert(Int(warmed.r) > Int(warmed.b) + 10, "local temperature warms")

        // masks live on the source photo: after turning, mirroring, straightening and
        // cropping, the effect lands where the overlay maps the mask's center
        let wide = CGContext(data: nil, width: 96, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                             space: DevelopRenderer.outputColorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        wide.setFillColor(CGColor(colorSpace: DevelopRenderer.outputColorSpace, components: [0.3, 0.3, 0.3, 1])!)
        wide.fill(CGRect(x: 0, y: 0, width: 96, height: 64))
        s = DevelopSettings()
        s.rotation = 1; s.flipped = true; s.straighten = 8
        s.crop = DevelopCrop(x: 0.1, y: 0.15, width: 0.8, height: 0.7)
        var spot = LocalAdjustment(kind: .radial)
        spot.center = CGPoint(x: 0.35, y: 0.6)
        spot.radiusX = 0.08; spot.radiusY = 0.08; spot.feather = 10; spot.exposure = 2.5
        s.masks = [spot]
        let placed = develop(wide.makeImage()!, s)
        var data = [UInt8](repeating: 0, count: placed.width * placed.height * 4)
        CGContext(data: &data, width: placed.width, height: placed.height, bitsPerComponent: 8,
                  bytesPerRow: placed.width * 4, space: DevelopRenderer.outputColorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            .draw(placed, in: CGRect(x: 0, y: 0, width: placed.width, height: placed.height))
        var sumX = 0.0, sumY = 0.0, count = 0.0
        for y in 0..<placed.height {
            for x in 0..<placed.width where data[(y * placed.width + x) * 4 + 1] > 125 {   // ~77 around, ~170 inside
                sumX += Double(x) + 0.5; sumY += Double(y) + 0.5; count += 1
            }
        }
        let expected = DevelopGeometry.finishedPoint(fromSource: spot.center, settings: s,
                                                     sourceSize: CGSize(width: 96, height: 64))
        assert(count > 10 && abs(sumX / count - expected.x * Double(placed.width)) < 2
               && abs(sumY / count - expected.y * Double(placed.height)) < 2,
               "a mask follows the photo through rotation, mirroring, straightening and crop")
        for point in [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.7, y: 0.9)] {
            for rotation in 0..<4 {
                var t = s; t.rotation = rotation; t.flipped = rotation % 2 == 0
                let size = CGSize(width: 96, height: 64)
                let back = DevelopGeometry.sourcePoint(
                    fromFinished: DevelopGeometry.finishedPoint(fromSource: point, settings: t, sourceSize: size),
                    settings: t, sourceSize: size)
                assert(abs(back.x - point.x) < 1e-9 && abs(back.y - point.y) < 1e-9, "source and finished points round-trip")
            }
        }

        // brush: a stroke across the middle, part of it erased again
        var brush = LocalAdjustment(kind: .brush)
        brush.exposure = 1.5
        var stroke = BrushStroke()
        stroke.radius = 0.08; stroke.feather = 20
        stroke.append(CGPoint(x: 0.1, y: 0.5)); stroke.append(CGPoint(x: 0.9, y: 0.5))
        brush.strokes = [stroke]
        s = DevelopSettings(); s.masks = [brush]
        out = develop(gray, s)
        assert(luma(out, 32, 32) > base + 30 && luma(out, 12, 32) > base + 30 && abs(luma(out, 32, 8) - base) < 2,
               "a brush stroke adjusts where it was painted and nowhere else")
        var eraser = BrushStroke()
        eraser.radius = 0.1; eraser.feather = 0; eraser.erase = true
        eraser.append(CGPoint(x: 0.5, y: 0.2)); eraser.append(CGPoint(x: 0.5, y: 0.8))
        s.masks[0].strokes.append(eraser)
        out = develop(gray, s)
        assert(abs(luma(out, 32, 32) - base) < 3 && luma(out, 12, 32) > base + 30, "erasing takes the adjustment back")
        s.masks[0].strokes = [stroke]
        s.masks[0].strokes[0].density = 40
        let light = luma(develop(gray, s), 32, 32)
        assert(light > base + 5 && light < luma(out, 12, 32) - 10, "a lower density paints a weaker effect")
        s.masks[0].strokes[0].density = 100
        let tinted = pixel(develop(gray, s, overlayMask: brush.id), 32, 32)
        let untinted = pixel(develop(gray, s, overlayMask: brush.id), 32, 8)
        assert(Int(tinted.r) > Int(tinted.b) + 40 && abs(Int(untinted.r) - Int(untinted.b)) < 4,
               "the overlay tints the selected mask's coverage red")
        // refining other masks with the brush: erasing cuts into a gradient, painting extends it
        var ring = LocalAdjustment(kind: .radial)
        ring.radiusX = 0.4; ring.radiusY = 0.4; ring.feather = 10; ring.exposure = 1.5
        var cut = BrushStroke()
        cut.radius = 0.08; cut.feather = 0; cut.erase = true
        cut.append(CGPoint(x: 0.5, y: 0.2)); cut.append(CGPoint(x: 0.5, y: 0.8))
        ring.strokes = [cut]
        s = DevelopSettings(); s.masks = [ring]
        out = develop(gray, s)
        assert(abs(luma(out, 32, 32) - base) < 3 && luma(out, 20, 32) > base + 30,
               "an erase stroke takes a stripe out of a radial gradient")
        var extended = linear
        var patch = BrushStroke()
        patch.radius = 0.1; patch.feather = 0
        patch.append(CGPoint(x: 0.3, y: 0.85))
        extended.strokes = [patch]
        s = DevelopSettings(); s.masks = [extended]
        out = develop(gray, s)
        assert(luma(out, 19, 54) < base - 30 && abs(luma(out, 50, 54) - base) < 2,
               "a paint stroke extends a linear gradient where it was painted")
        var bare = DevelopSettings(); bare.masks = [linear]
        assert(s.fingerprint != bare.fingerprint, "refinement strokes change the fingerprint")

        // sky: a blue gradient over grass is found, darkened, and the grass left alone; a plain
        // pale wall is not sky
        let landscape = CGContext(data: nil, width: 240, height: 160, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: DevelopRenderer.outputColorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for y in 0..<160 {
            // CGContext rows count from the bottom: grass below 90, sky above
            let t = Double(y) / 160
            let color: [CGFloat] = y < 90 ? [0.22 + 0.1 * CGFloat((y * 7) % 3) / 3, 0.45, 0.18, 1]
                                          : [0.62 - 0.3 * CGFloat(t), 0.75 - 0.15 * CGFloat(t), 0.97, 1]
            landscape.setFillColor(CGColor(colorSpace: DevelopRenderer.outputColorSpace, components: color)!)
            for x in stride(from: 0, to: 240, by: 3) where y >= 90 || (x + y) % 2 == 0 {
                landscape.fill(CGRect(x: x, y: y, width: y < 90 ? 2 : 3, height: 1))
            }
        }
        let landscapeURL = FileManager.default.temporaryDirectory.appendingPathComponent("pc-sky-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: landscapeURL) }
        let landscapeFile = CGImageDestinationCreateWithURL(landscapeURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(landscapeFile, landscape.makeImage()!, nil)
        CGImageDestinationFinalize(landscapeFile)
        let foundSky = SemanticMasks.mask(.sky, url: landscapeURL, isRaw: false)
        assert(foundSky.map { (0.3...0.5).contains($0.coverage) && $0.centroid.y < 0.3 } == true,
               "the sky is found above the grass")
        var skyEdit = DevelopSettings()
        var skyMask = LocalAdjustment(kind: .sky)
        skyMask.exposure = -1.5
        skyEdit.masks = [skyMask]
        let skyRender = DevelopRenderer.render(DevelopRenderer.Source(url: landscapeURL, isRaw: false, maxPixel: nil)!
            .image(skyEdit)!)!
        let plainRender = DevelopRenderer.render(DevelopRenderer.Source(url: landscapeURL, isRaw: false, maxPixel: nil)!
            .image(.neutral)!)!
        assert(luma(skyRender, 120, 20) < luma(plainRender, 120, 20) - 20
               && abs(luma(skyRender, 120, 140) - luma(plainRender, 120, 140)) < 3,
               "a sky mask darkens the sky and leaves the ground alone")
        let wall = image { x, y in (0.86 + 0.02 * Double((x / 8 + y / 8) % 2), 0.85, 0.83) }
        let wallURL = FileManager.default.temporaryDirectory.appendingPathComponent("pc-wall-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: wallURL) }
        let wallFile = CGImageDestinationCreateWithURL(wallURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(wallFile, wall, nil)
        CGImageDestinationFinalize(wallFile)
        assert(SemanticMasks.mask(.sky, url: wallURL, isRaw: false) == nil, "a pale wall is not sky")
        var noSky = LocalAdjustment(kind: .sky)
        let wallExtent = CGRect(x: 0, y: 0, width: 64, height: 64)
        assert(DevelopRenderer.maskWeight(noSky, skyEdit, extent: wallExtent, photo: (wallURL, false)) == nil,
               "a sky mask on a photo without sky covers nothing")
        noSky.inverted = true
        let everything = DevelopRenderer.maskWeight(noSky, skyEdit, extent: wallExtent, photo: (wallURL, false))
            .flatMap { DevelopRenderer.render($0) }
        assert(everything.map { luma($0, 32, 32) > 250 } == true, "and inverted, it covers the whole photo")
        let missingURL = FileManager.default.temporaryDirectory.appendingPathComponent("pc-missing-\(UUID().uuidString).png")
        guard case .unreadable = SemanticMasks.lookup(.sky, url: missingURL, isRaw: false) else {
            preconditionFailure("a missing photo can't be read")
        }
        assert(DevelopRenderer.maskWeight(noSky, skyEdit, extent: wallExtent, photo: (missingURL, false)) == nil,
               "an unreadable photo's inverted mask covers nothing")
        try? FileManager.default.copyItem(at: wallURL, to: missingURL)
        defer { try? FileManager.default.removeItem(at: missingURL) }
        guard case .notFound = SemanticMasks.lookup(.sky, url: missingURL, isRaw: false) else {
            preconditionFailure("a photo that couldn't be read is looked at again once it's there")
        }
        if let subject = SemanticMasks.mask(.subject, url: landscapeURL, isRaw: false) {
            assert(subject.coverage > 0 && subject.coverage <= 1, "a subject mask covers part of the photo")
        }

        let halfStroke = try! JSONDecoder().decode(BrushStroke.self, from: Data(#"{"points":[0.1,0.2,0.3]}"#.utf8))
        assert(halfStroke.pointCount == 1 && halfStroke.radius == 0.05 && !halfStroke.erase,
               "a stroke with a dangling coordinate loads without it")
        var rounded = BrushStroke()
        rounded.append(CGPoint(x: 0.123456789, y: 0.5))
        assert(rounded.points == [0.1235, 0.5], "stroke points are stored rounded")

        let newer = try! JSONDecoder().decode(DevelopSettings.self, from: Data(
            #"{"exposure":0.5,"masks":[{"kind":"depthRange"},{"kind":"linear"}],"spots":[{"mode":"patch","radius":0.02}]}"#.utf8))
        assert(newer.exposure == 0.5 && newer.masks.map(\.kind) == [.linear]
               && newer.spots.first?.mode == .heal && newer.spots.first?.radius == 0.02,
               "a mask or spot from a newer version is left out or read as it can be, not the whole edit")
        let old = try! JSONDecoder().decode(DevelopSettings.self, from: Data(#"{"exposure":0.5}"#.utf8))
        assert(old.masks.isEmpty && old.fingerprint == { var e = DevelopSettings(); e.exposure = 0.5; return e }().fingerprint,
               "edits saved before masks load without any and keep their cache names")
        let partial = try! JSONDecoder().decode(LocalAdjustment.self, from: Data(#"{"kind":"linear","exposure":1}"#.utf8))
        assert(partial.kind == .linear && partial.exposure == 1 && partial.feather == 50, "a mask missing fields loads with defaults")
        let saved = try! JSONDecoder().decode(DevelopSettings.self, from: JSONEncoder().encode(s))
        assert(saved == s, "masks round-trip through storage")
        let carried = DevelopSettings().applying(s, fields: [.masks])
        assert(carried.masks == s.masks && carried.rotation == 0, "masks travel as one setting")
        assert(!DevelopField.defaultCopy.contains(.masks), "copy leaves masks behind unless asked")
    }

    static func checkSpotRemoval() {
        // a gradient from dark (left) to light (right) with a dark speck in the middle
        let speckled = image { x, y in
            let v = 0.25 + 0.5 * Double(x) / 63
            let speck = hypot(Double(x) - 32, Double(y) - 32) < 3
            return speck ? (0.02, 0.02, 0.02) : (v, v, v)
        }
        func luma(_ image: CGImage, _ x: Int, _ y: Int) -> Double {
            let p = pixel(image, x, y)
            return 0.3 * Double(p.r) + 0.59 * Double(p.g) + 0.11 * Double(p.b)
        }
        let plain = develop(speckled, .neutral)
        let around = (luma(plain, 32, 26) + luma(plain, 32, 38)) / 2   // above and below: the same brightness
        // the source sits to the left, where the gradient is darker
        var spot = SpotRemoval(target: CGPoint(x: 0.5, y: 0.5), source: CGPoint(x: 0.25, y: 0.5), radius: 5.0 / 64)
        spot.feather = 20
        var s = DevelopSettings(); s.spots = [spot]
        let healed = develop(speckled, s)
        assert(abs(luma(healed, 32, 32) - around) < 8 && luma(healed, 32, 32) > luma(plain, 32, 32) + 60,
               "healing removes the speck and matches the surrounding brightness")
        s.spots[0].mode = .clone
        let cloned = develop(speckled, s)
        assert(luma(cloned, 32, 32) < around - 20, "cloning copies the source as it is, darker here")
        assert(abs(luma(healed, 4, 4) - luma(plain, 4, 4)) < 2 && abs(luma(healed, 60, 60) - luma(plain, 60, 60)) < 2,
               "a spot leaves the rest of the photo alone")
        s.spots[0].mode = .heal
        s.spots[0].opacity = 50
        let half = luma(develop(speckled, s), 32, 32)
        assert(half > luma(plain, 32, 32) + 20 && half < luma(healed, 32, 32) - 20, "half opacity heals halfway")

        // a source just beside the speck: the speck is in the source's surroundings, and must not
        // brighten the fix to make up for it
        let flatSpeck = image { x, y in hypot(Double(x) - 32, Double(y) - 32) < 3 ? (0.02, 0.02, 0.02) : (0.5, 0.5, 0.5) }
        var near = SpotRemoval(target: CGPoint(x: 0.5, y: 0.5), source: CGPoint(x: 0.5, y: 23.0 / 64), radius: 5.0 / 64)
        near.feather = 20
        var nearEdit = DevelopSettings(); nearEdit.spots = [near]
        let nearPlain = develop(flatSpeck, .neutral), nearHealed = develop(flatSpeck, nearEdit)
        assert([30, 32, 34, 36].allSatisfy { abs(luma(nearHealed, 32, $0) - luma(nearPlain, 32, 50)) < 3 },
               "healing from beside the speck matches the surroundings, not the speck")

        // the source search avoids another speck and takes a place that matches
        var luma64 = [Double](repeating: 0, count: 64 * 64)
        for y in 0..<64 { for x in 0..<64 { luma64[y * 64 + x] = 0.25 + 0.5 * Double(x) / 63 } }
        for y in 0..<64 { for x in 0..<64 where hypot(Double(x) - 32, Double(y) - 20) < 3 { luma64[y * 64 + x] = 0.02 } }
        let found = SpotFinder.source(for: CGPoint(x: 0.5, y: 0.5), radius: 3.0 / 64, luma: luma64, width: 64, height: 64)
        let foundPixel = CGPoint(x: found.x * 64, y: found.y * 64)
        assert(abs(foundPixel.x - 32) < 4 && hypot(foundPixel.x - 32, foundPixel.y - 20) > 6,
               "the source is found in the same column of the gradient, away from the other speck")

        let old = try! JSONDecoder().decode(DevelopSettings.self, from: Data(#"{"exposure":0.5}"#.utf8))
        assert(old.spots.isEmpty, "edits saved before spot removal load without spots")
        let partial = try! JSONDecoder().decode(SpotRemoval.self, from: Data(#"{"radius":0.02}"#.utf8))
        assert(partial.radius == 0.02 && partial.mode == .heal && partial.opacity == 100, "a spot missing fields loads")
        assert(DevelopSettings().applying(s, fields: [.spots]).spots == s.spots
               && !DevelopField.defaultCopy.contains(.spots), "spots travel as one setting, off by default")
        assert(s.fingerprint != DevelopSettings().fingerprint, "spots change the fingerprint")
        let dust = DevelopRenderer.render(DevelopRenderer.visualizeSpots(CIImage(cgImage: speckled)))!
        assert(luma(dust, 32, 29) > 100 && luma(dust, 8, 8) < 20, "the dust view shows a speck and not smooth areas")
    }

    /// Color and luminance range masks, alone or narrowing another mask.
    static func checkRangeMasks() {
        func luma(_ image: CGImage, _ x: Int, _ y: Int) -> Double {
            let p = pixel(image, x, y)
            return 0.2126 * Double(p.r) + 0.7152 * Double(p.g) + 0.0722 * Double(p.b)
        }
        // a gray ramp, dark at the left: a luminance range brightens only the light end
        let ramp = image { x, _ in let v = 0.05 + 0.9 * Double(x) / 63; return (v, v, v) }
        var bright = LocalAdjustment(kind: .luminanceRange)
        bright.range?.low = 70
        bright.range?.high = 100
        bright.range?.smoothness = 10
        bright.exposure = -2
        var s = DevelopSettings(); s.masks = [bright]
        let plain = develop(ramp, .neutral), ranged = develop(ramp, s)
        assert(luma(ranged, 60, 32) < luma(plain, 60, 32) - 40 && abs(luma(ranged, 4, 32) - luma(plain, 4, 32)) < 2,
               "a luminance range reaches only its tones")
        s.masks[0].inverted = true
        let outside = develop(ramp, s)
        assert(luma(outside, 4, 32) < luma(plain, 4, 32) - 3 && abs(luma(outside, 60, 32) - luma(plain, 60, 32)) < 3,
               "inverted, it reaches everything else")

        // red on the left, blue on the right: a color range sampled on red desaturates only red
        let halves = image { x, _ in x < 32 ? (0.8, 0.15, 0.15) : (0.15, 0.25, 0.85) }
        var red = LocalAdjustment(kind: .colorRange)
        red.range?.samples = [CGPoint(x: 0.2, y: 0.5)]
        red.saturation = -100
        var c = DevelopSettings(); c.masks = [red]
        let colored = develop(halves, c)
        let left = pixel(colored, 10, 32), right = pixel(colored, 54, 32)
        assert(abs(Int(left.r) - Int(left.g)) < 30 && Int(right.b) - Int(right.r) > 100,
               "a color range reaches the sampled color and not the others")
        var nothing = red
        nothing.range?.samples = []
        c.masks = [nothing]
        let unsampled = develop(halves, c), before = develop(halves, .neutral)
        assert(abs(Int(pixel(unsampled, 10, 32).r) - Int(pixel(before, 10, 32).r)) < 3,
               "a color range with nothing sampled covers nothing")
        // not yet a range, so nothing to be outside of: inverted it still covers nothing
        nothing.inverted = true
        c.masks = [nothing]
        let unsampledInverted = develop(halves, c)
        assert([(10, 32), (54, 32)].allSatisfy { x, y in
            let after = pixel(unsampledInverted, x, y), plain = pixel(before, x, y)
            return abs(Int(after.r) - Int(plain.r)) < 3 && abs(Int(after.b) - Int(plain.b)) < 3
        }, "an inverted color range with nothing sampled covers nothing")

        // a radial mask narrowed to the light tones: only where both hold
        var radial = LocalAdjustment(kind: .radial)
        radial.center = CGPoint(x: 0.5, y: 0.5)
        radial.radiusX = 0.6; radial.radiusY = 0.6; radial.feather = 0
        radial.exposure = -2
        radial.range = MaskRange(kind: .luminance)
        radial.range?.low = 70; radial.range?.smoothness = 10
        var r = DevelopSettings(); r.masks = [radial]
        let narrowed = develop(ramp, r)
        assert(luma(narrowed, 60, 32) < luma(plain, 60, 32) - 40 && abs(luma(narrowed, 20, 32) - luma(plain, 20, 32)) < 2,
               "a range narrows another mask to its tones")

        let saved = try! JSONDecoder().decode(DevelopSettings.self, from: JSONEncoder().encode(r))
        assert(saved == r, "ranges round-trip through storage")
        var other = r
        other.masks[0].range?.low = 40
        assert(other.fingerprint != r.fingerprint, "a range changes the fingerprint")
        let old = try! JSONDecoder().decode(LocalAdjustment.self, from: Data(#"{"kind":"radial"}"#.utf8))
        assert(old.range == nil, "masks saved before ranges load without one")
    }
}
