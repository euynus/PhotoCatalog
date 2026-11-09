import Foundation
import CoreImage

extension DevelopCheck {
    /// 64 × 32: red left half, blue right half.
    private static func split() -> CGImage {
        let context = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                space: DevelopRenderer.outputColorSpace,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: DevelopRenderer.outputColorSpace, components: [1, 0, 0, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        context.setFillColor(CGColor(colorSpace: DevelopRenderer.outputColorSpace, components: [0, 0, 1, 1])!)
        context.fill(CGRect(x: 32, y: 0, width: 32, height: 32))
        return context.makeImage()!
    }

    private static func isRed(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool { p.r > 200 && p.b < 60 }
    private static func isBlue(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool { p.b > 200 && p.r < 60 }

    static func checkLensCorrections() {
        // a white vertical line right of center on black: straightening barrel distortion
        // stretches the edges outward, so the line lands further right
        // white lines 8 and 24 px right of center on black. Straightening barrel distortion
        // stretches the edges more than the middle, so the outer line moves out proportionally further.
        let lines = image { x, _ in x == 40 || x == 56 ? (1, 1, 1) : (0, 0, 0) }
        func centroid(_ image: CGImage, _ columns: Range<Int>) -> Double {
            let weights = columns.map { Double(pixel(image, $0, 32).g) }
            return zip(columns, weights).map { Double($0) * $1 }.reduce(0, +) / max(weights.reduce(0, +), 1)
        }
        func spreadRatio(_ settings: DevelopSettings) -> Double {
            let rendered = develop(lines, settings)
            return (centroid(rendered, 48..<64) - 31.5) / (centroid(rendered, 34..<48) - 31.5)
        }
        var s = DevelopSettings()
        let neutralRatio = spreadRatio(s)
        s.distortion = 100
        assert(spreadRatio(s) > neutralRatio + 0.05, "positive distortion stretches the edges more than the middle")
        s.distortion = -100
        assert(spreadRatio(s) < neutralRatio - 0.05, "negative distortion compresses them")

        let gray = image { _, _ in (0.4, 0.4, 0.4) }
        s = DevelopSettings(); s.lensVignette = 100
        let lifted = develop(gray, s), plain = develop(gray, .neutral)
        assert(pixel(lifted, 1, 1).g > pixel(plain, 1, 1).g + 20, "lens vignetting correction brightens the corners")
        assert(abs(Int(pixel(lifted, 32, 32).g) - Int(pixel(plain, 32, 32).g)) <= 2, "and leaves the center alone")
        s.lensVignetteMidpoint = 100
        assert(pixel(develop(gray, s), 12, 12).g < pixel(lifted, 12, 12).g, "a higher midpoint confines it to the corners")

        var source = DevelopSettings()
        source.distortion = 30; source.lensVignette = 45; source.lensVignetteMidpoint = 20
        let carried = DevelopSettings().applying(source, fields: [.lensCorrections])
        assert(carried.distortion == 30 && carried.lensVignette == 45 && carried.lensVignetteMidpoint == 20,
               "lens corrections travel together")
        assert(DevelopSettings().fingerprint != carried.fingerprint, "lens corrections change the fingerprint")
    }

    /// A `width`×`height` image in display P3 from a color per pixel.
    private static func picture(_ width: Int, _ height: Int, _ color: (Int, Int) -> (Double, Double, Double)) -> CGImage {
        var data = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let c = color(x, y), i = (y * width + x) * 4
                data[i] = UInt8(max(0, min(255, (c.0 * 255).rounded())))
                data[i + 1] = UInt8(max(0, min(255, (c.1 * 255).rounded())))
                data[i + 2] = UInt8(max(0, min(255, (c.2 * 255).rounded())))
            }
        }
        let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: DevelopRenderer.outputColorSpace,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        return context.makeImage()!
    }

    static func checkChromaticAberration() {
        // a scene of gray, black and white rectangles, with a few colored ones, 480 × 360
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func random(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }
        var boxes: [(x: Int, y: Int, w: Int, h: Int, c: (Double, Double, Double))] = []
        let grays = [0.08, 0.3, 0.7, 0.92]
        for _ in 0..<90 {
            let v = grays[random(4)]
            boxes.append((random(470), random(350), 8 + random(50), 8 + random(50), (v, v, v)))
        }
        for i in 0..<8 {
            let color = i.isMultiple(of: 2) ? (0.8, 0.15, 0.1) : (0.12, 0.25, 0.8)
            boxes.append((random(440), random(320), 20 + random(30), 20 + random(30), color))
        }
        let halfDiagonal = (480.0 * 480 + 360 * 360).squareRoot() / 2
        /// The scene with each channel drawn at its own magnification about the middle, with
        /// exact antialiasing: a lens with lateral chromatic aberration.
        func photographed(red: Double, blue: Double) -> CGImage {
            let planes = [red, 1, blue].enumerated().map { channel, scale -> [UInt8] in
                var plane = [UInt8](repeating: 0, count: 480 * 360)
                let context = CGContext(data: &plane, width: 480, height: 360, bitsPerComponent: 8, bytesPerRow: 480,
                                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
                context.setFillColor(gray: 0.45, alpha: 1)
                context.fill(CGRect(x: 0, y: 0, width: 480, height: 360))
                context.translateBy(x: 240, y: 180)
                context.scaleBy(x: scale, y: scale)
                context.translateBy(x: -240, y: -180)
                for box in boxes {
                    context.setFillColor(gray: [box.c.0, box.c.1, box.c.2][channel], alpha: 1)
                    context.fill(CGRect(x: box.x, y: box.y, width: box.w, height: box.h))
                }
                return plane
            }
            return picture(480, 360) { x, y in
                let i = (359 - y) * 480 + x
                return (Double(planes[0][i]) / 255, Double(planes[1][i]) / 255, Double(planes[2][i]) / 255)
            }
        }
        let scene = photographed(red: 1, blue: 1)

        // a lens that magnifies red 0.4% and shrinks blue 0.3% against green: 1.2 and 0.9 pixels
        // at the corners
        let fringed = photographed(red: 1.004, blue: 0.997)
        let found = ChromaticAberration.measure(CIImage(cgImage: fringed))
        func shift(_ scale: ChromaticAberration.Scale, at rho: Double) -> Double {
            (scale.k1 + scale.k2 * rho * rho) * rho * halfDiagonal
        }
        assert(abs(shift(found.red, at: 1) - 1.2) < 0.15 && abs(shift(found.blue, at: 1) + 0.9) < 0.15
               && abs(shift(found.red, at: 0.5) - 0.6) < 0.1 && abs(shift(found.blue, at: 0.5) + 0.45) < 0.1,
               "lateral chromatic aberration is measured from the edges (\(found))")
        assert(ChromaticAberration.measure(CIImage(cgImage: scene)).red.isNone
               || abs(shift(ChromaticAberration.measure(CIImage(cgImage: scene)).red, at: 1)) < 0.1,
               "a sharp photo measures none")

        var settings = DevelopSettings()
        settings.removeChromaticAberration = true
        let corrected = develop(fringed, settings)
        let left = ChromaticAberration.measure(CIImage(cgImage: corrected))
        assert(abs(shift(left.red, at: 1)) < 0.2 && abs(shift(left.blue, at: 1)) < 0.2,
               "removing chromatic aberration lines the channels back up (\(left))")
        assert(settings.hasLensCorrection && settings.fingerprint != DevelopSettings().fingerprint,
               "the correction is an edit of its own")

        // defringe: a purple and a green fringe along a black-to-white edge, and a purple thing
        // away from any edge
        let fringes = image { x, y in
            if x >= 32 && y < 32 { return (1, 1, 1) }
            if x >= 29 && x < 32 && y < 16 { return (0.55, 0.2, 0.75) }   // purple fringe
            if x >= 29 && x < 32 && y < 32 { return (0.3, 0.6, 0.25) }    // green fringe
            if x >= 2 && x < 24 && y >= 40 && y < 62 { return (0.45, 0.25, 0.6) }
            return (0.05, 0.05, 0.05)
        }
        func chroma(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Int { Int(max(p.r, p.g, p.b)) - Int(min(p.r, p.g, p.b)) }
        let plain = develop(fringes, .neutral)
        var purple = DevelopSettings(); purple.defringePurple = 20
        let noPurple = develop(fringes, purple)
        assert(chroma(pixel(noPurple, 30, 8)) * 10 < chroma(pixel(plain, 30, 8)) * 3,
               "purple defringing takes the color out of a purple fringe")
        assert(chroma(pixel(noPurple, 30, 24)) * 10 > chroma(pixel(plain, 30, 24)) * 9
               && chroma(pixel(noPurple, 13, 51)) * 10 > chroma(pixel(plain, 13, 51)) * 9,
               "and leaves green fringes and purple things away from edges alone")
        var green = DevelopSettings(); green.defringeGreen = 20
        assert(chroma(pixel(develop(fringes, green), 30, 24)) * 10 < chroma(pixel(plain, 30, 24)) * 3,
               "green defringing takes the color out of a green fringe")

        // carried by copy, presets, preset files and blends; stored with the photo
        var source = DevelopSettings()
        source.removeChromaticAberration = true; source.defringePurple = 8; source.defringeGreen = 3
        let carried = DevelopSettings().applying(source, fields: [.lensCorrections])
        assert(carried.removeChromaticAberration && carried.defringePurple == 8 && carried.defringeGreen == 3,
               "chromatic aberration settings travel with the lens corrections")
        let preset = DevelopPreset(id: "ca", name: "CA", transfer: DevelopTransfer(settings: source, fields: [.lensCorrections],
                                                                                  sourceIsRaw: true))
        let text = DevelopPresetFile.xmp(for: preset)
        let crsOnly = text.replacingOccurrences(of: #"\s*pc:Preset="[^"]*""#, with: "", options: .regularExpression)
        let lightroom = DevelopPresetFile.read(Data(crsOnly.utf8), fileName: "ca.xmp")
        assert(text.contains("crs:AutoLateralCA=\"1\"") && text.contains("crs:DefringePurpleAmount=\"8\"")
               && lightroom?.preset.transfer.settings.removeChromaticAberration == true
               && lightroom?.preset.transfer.settings.defringePurple == 8 && lightroom?.preset.transfer.settings.defringeGreen == 3
               && lightroom?.skipped.isEmpty == true,
               "Camera Raw's chromatic aberration settings map both ways")
        let half = DevelopSettings.blend(.neutral, source, amount: 0.5, isRaw: true, whiteBalanceOrigin: nil)
        assert(half.removeChromaticAberration && half.defringePurple == 4, "a preset's amount scales defringing")
        let stored = (try? JSONEncoder().encode(source)).flatMap { try? JSONDecoder().decode(DevelopSettings.self, from: $0) }
        assert(stored == source, "chromatic aberration settings are stored")
    }

    static func checkGeometryMath() {
        let frame = CGSize(width: 600, height: 400)
        assert(DevelopGeometry.inscribed(aspect: 1.5, angle: 0, frame: frame) == .full, "level photos keep the whole frame")
        assert(!DevelopGeometry.fits(.full, angle: 8, frame: frame), "a straightened photo has empty corners")
        let auto = DevelopGeometry.inscribed(aspect: 1.5, angle: 8, frame: frame)
        assert(DevelopGeometry.fits(auto, angle: 8, frame: frame) && auto.width < 1
               && abs(auto.width * 600 / (auto.height * 400) - 1.5) < 0.001, "auto crop keeps the shape and fits")
        let grown = DevelopCrop(x: auto.x - 0.001, y: auto.y, width: auto.width + 0.002, height: auto.height)
        assert(!DevelopGeometry.fits(grown, angle: 8, frame: frame), "auto crop is the largest that fits")

        var s = DevelopSettings()
        s.crop = DevelopCrop(x: 0.1, y: 0.2, width: 0.5, height: 0.3)
        s.straighten = 3
        var turned = s
        for _ in 0..<4 { turned = DevelopGeometry.rotated(turned, clockwise: true) }
        assert(turned.rotation == 0 && abs(turned.crop!.x - 0.1) < 1e-9 && abs(turned.crop!.width - 0.5) < 1e-9,
               "four quarter turns come back around")
        let once = DevelopGeometry.rotated(s, clockwise: true)
        assert(once.rotation == 1 && abs(once.crop!.x - 0.5) < 1e-9 && abs(once.crop!.y - 0.1) < 1e-9
               && abs(once.crop!.width - 0.3) < 1e-9, "a quarter turn carries the crop along")
        assert(same(DevelopGeometry.rotated(once, clockwise: false), s), "turning back undoes a turn")
        let mirrored = DevelopGeometry.mirrored(s)
        assert(mirrored.flipped && mirrored.straighten == -3 && abs(mirrored.crop!.x - 0.4) < 1e-9,
               "mirroring flips the crop and the straighten angle")
        assert(same(DevelopGeometry.mirrored(mirrored), s), "mirroring twice is a no-op")
        assert(DevelopGeometry.rotated(mirrored, clockwise: true).rotation == 3,
               "a mirrored photo's clockwise turn runs the other way before the mirror")

        let resized = DevelopGeometry.resize(.full, left: false, right: true, top: false, bottom: true,
                                             dx: -0.4, dy: -0.1, ratio: 1, angle: 0, frame: frame)
        assert(abs(resized.width * 600 - resized.height * 400) < 0.5 && resized.x == 0 && resized.y == 0,
               "a locked corner drag keeps the shape and the opposite corner")
        let edge = DevelopGeometry.resize(.full, left: true, right: false, top: false, bottom: false,
                                          dx: 0.3, dy: 0, ratio: nil, angle: 0, frame: frame)
        assert(abs(edge.x - 0.3) < 1e-9 && edge.height == 1, "a free edge drag moves only that edge")
        let moved = DevelopGeometry.move(auto, dx: 0.5, dy: 0.5, angle: 8, frame: frame)
        assert(DevelopGeometry.fits(moved, angle: 8, frame: frame), "a moved crop stays inside the straightened photo")

        let level = DevelopGeometry.straightenLevelling(from: .zero, to: CGPoint(x: 100, y: 10), current: 0)!
        assert(abs(level + 5.7) < 0.05, "a line falling to the right turns the photo counterclockwise")
        let plumb = DevelopGeometry.straightenLevelling(from: .zero, to: CGPoint(x: -5, y: 100), current: 1)!
        assert(abs(plumb - (1 - 2.9)) < 0.05, "a near-vertical line is made plumb")

        var geometry = DevelopSettings()
        let before = geometry.fingerprint
        geometry.rotation = 1
        assert(geometry.fingerprint != before && DevelopSettings().fingerprint == before,
               "geometry changes the render fingerprint")
        let legacy = Data(#"{"exposure":0.5,"contrast":0,"highlights":0,"shadows":0,"whites":0,"blacks":0,"vibrance":0,"saturation":0}"#.utf8)
        var expected = DevelopSettings()
        expected.exposure = 0.5
        assert((try? JSONDecoder().decode(DevelopSettings.self, from: legacy)) == expected,
               "settings saved before geometry existed still load")
    }

    /// Equal apart from floating-point noise in the crop.
    private static func same(_ a: DevelopSettings, _ b: DevelopSettings) -> Bool {
        var a2 = a, b2 = b
        a2.crop = nil
        b2.crop = nil
        guard a2 == b2, let ca = a.crop, let cb = b.crop else { return a2 == b2 && a.crop == b.crop }
        return [ca.x - cb.x, ca.y - cb.y, ca.width - cb.width, ca.height - cb.height].allSatisfy { abs($0) < 1e-9 }
    }

    static func checkGeometryRendering() {
        var s = DevelopSettings()
        s.rotation = 1
        let turned = develop(split(), s)
        assert(turned.width == 32 && turned.height == 64, "a quarter turn swaps width and height")
        assert(isRed(pixel(turned, 16, 4)) && isBlue(pixel(turned, 16, 60)), "clockwise brings the left edge to the top")

        s = DevelopSettings(); s.flipped = true
        let mirrored = develop(split(), s)
        assert(isBlue(pixel(mirrored, 4, 16)) && isRed(pixel(mirrored, 60, 16)), "mirroring swaps left and right")

        s = DevelopSettings(); s.crop = DevelopCrop(x: 0.5, y: 0, width: 0.5, height: 1)
        let cropped = develop(split(), s)
        assert(cropped.width == 32 && cropped.height == 32 && isBlue(pixel(cropped, 2, 2))
               && isBlue(pixel(cropped, 29, 29)), "cropping keeps only the chosen part")

        s = DevelopSettings(); s.straighten = 10
        let straight = develop(split(), s)
        assert(straight.width < 64 && straight.height < 32 && abs(Double(straight.width) / Double(straight.height) - 2) < 0.15,
               "straightening crops to the photo's shape")
        let corners = [pixel(straight, 0, 0), pixel(straight, straight.width - 1, straight.height - 1)]
        assert(corners.allSatisfy { $0.a == 255 }, "straightening leaves no empty corners")
        let whole = develop(split(), s, wholeFrame: true)
        assert(whole.width == 64 && whole.height == 32 && pixel(whole, 0, 0).a == 0,
               "the crop tool sees the whole frame with empty corners")

        // sky over sea, the horizon rising 4° to the right: auto straighten turns it clockwise
        let context = CGContext(data: nil, width: 800, height: 500, bitsPerComponent: 8, bytesPerRow: 0,
                                space: DevelopRenderer.outputColorSpace,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: DevelopRenderer.outputColorSpace, components: [0.62, 0.78, 0.95, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 500))
        let rise = tan(4 * Double.pi / 180) * 400
        context.setFillColor(CGColor(colorSpace: DevelopRenderer.outputColorSpace, components: [0.08, 0.2, 0.35, 1])!)
        context.addLines(between: [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 250 - rise),
                                   CGPoint(x: 800, y: 250 + rise), CGPoint(x: 800, y: 0)])
        context.fillPath()
        let url = CheckImages.temporaryPNG(context.makeImage()!, prefix: "pc-horizon-")
        defer { try? FileManager.default.removeItem(at: url) }
        let horizon = DevelopRenderer.horizonAngle(url: url, isRaw: false, settings: DevelopSettings())
        assert(horizon.map { (3...5).contains($0) } == true, "auto straighten levels a horizon rising to the right")
    }

    /// Transform: the perspective correction, the crop kept off its empty corners, points mapped
    /// through it both ways, and Upright setting converging verticals upright.
    static func checkPerspective() {
        let frame = CGSize(width: 600, height: 400)
        var s = DevelopSettings()
        s.perspectiveVertical = -40
        guard let h = DevelopGeometry.perspective(s, frame: frame) else {
            preconditionFailure("a Transform slider makes a correction")
        }
        let tl = h.apply(CGPoint(x: 0, y: 0))!, tr = h.apply(CGPoint(x: 600, y: 0))!
        let bl = h.apply(CGPoint(x: 0, y: 400))!, br = h.apply(CGPoint(x: 600, y: 400))!
        assert(tr.x - tl.x > br.x - bl.x + 20, "negative Vertical widens the top")
        let back = h.inverse.apply(h.apply(CGPoint(x: 123, y: 45))!)!
        assert(abs(back.x - 123) < 1e-6 && abs(back.y - 45) < 1e-6, "the correction undoes exactly")
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 400).insetBy(dx: -1e-6, dy: -1e-6)
        assert([tl, tr, bl, br].allSatisfy { bounds.contains($0) }, "the corrected photo fits the frame, nothing lost")
        let crop = DevelopGeometry.effectiveCrop(s, frame: frame)
        let larger = DevelopCrop(x: crop.x - 0.01, y: crop.y - 0.01, width: crop.width + 0.02, height: crop.height + 0.02)
        assert(crop.width < 1 && DevelopGeometry.fits(crop, angle: 0, perspective: h, frame: frame)
               && !DevelopGeometry.fits(larger, angle: 0, perspective: h, frame: frame)
               && abs(crop.width * 600 / (crop.height * 400) - 1.5) < 0.001,
               "the automatic crop is the largest of the frame's shape without empty corners")
        s.straighten = 3
        s.perspectiveHorizontal = 25
        s.crop = DevelopGeometry.refit(s, frame: frame)
        let source = CGPoint(x: 0.3, y: 0.7)
        let finished = DevelopGeometry.finishedPoint(fromSource: source, settings: s, sourceSize: frame)
        let returned = DevelopGeometry.sourcePoint(fromFinished: finished, settings: s, sourceSize: frame)
        assert(abs(returned.x - 0.3) < 1e-6 && abs(returned.y - 0.7) < 1e-6, "masks and spots map through the correction both ways")
        let turned = DevelopGeometry.rotated(s, clockwise: true)
        assert(turned.perspectiveVertical == 25 && turned.perspectiveHorizontal == 40, "a quarter turn carries the correction along")
        assert(DevelopGeometry.mirrored(s).perspectiveHorizontal == -25, "mirroring flips the horizontal correction")
        var copied = DevelopSettings().applying(s, fields: [.perspective])
        assert(copied.perspectiveVertical == -40 && copied.crop == nil && !DevelopField.defaultCopy.contains(.perspective),
               "the correction travels as its own setting, off by default")
        copied = s
        copied.perspectiveVertical = 0
        assert(copied.fingerprint != s.fingerprint, "the correction changes the fingerprint")

        // rendered: no empty corners in the result
        let gray = image { _, _ in (0.5, 0.5, 0.5) }
        var render = DevelopSettings()
        render.perspectiveVertical = -60
        let corrected = develop(gray, render)
        let corners = [(0, 0), (corrected.width - 1, 0), (0, corrected.height - 1), (corrected.width - 1, corrected.height - 1)]
        assert(corners.allSatisfy { let p = pixel(corrected, $0.0, $0.1); return p.a == 255 && abs(Int(p.r) - 127) < 12 },
               "the corrected render has no empty corners")

        // Upright: lines of a building shot from below meet above the photo
        let (width, height) = (600, 400)
        let meet = CGPoint(x: 330, y: -900)
        var luma = [Float](repeating: 0.8, count: width * height)
        for bottom in stride(from: 60.0, through: 560.0, by: 70.0) {
            for y in 0..<height {
                let t = (Double(y) - Double(meet.y)) / (Double(height) - Double(meet.y))
                let x = Double(meet.x) + (bottom - Double(meet.x)) * t
                for dx in -1...1 {
                    let xi = Int(x.rounded()) + dx
                    if xi >= 0, xi < width { luma[y * width + xi] = 0.1 }
                }
            }
        }
        guard let upright = Upright.correction(luma: luma, width: width, height: height, mode: .vertical) else {
            preconditionFailure("converging verticals are found")
        }
        var fixed = DevelopSettings()
        fixed.perspectiveVertical = upright.vertical
        fixed.perspectiveHorizontal = upright.horizontal
        fixed.straighten = upright.straighten
        let size = CGSize(width: width, height: height)
        let angles = stride(from: 60.0, through: 560.0, by: 70.0).map { bottom -> Double in
            func finished(_ y: Double) -> CGPoint {
                let t = (y - Double(meet.y)) / (Double(height) - Double(meet.y))
                let x = Double(meet.x) + (bottom - Double(meet.x)) * t
                let p = DevelopGeometry.finishedPoint(fromSource: CGPoint(x: x / Double(width), y: y / Double(height)),
                                                      settings: fixed, sourceSize: size)
                return CGPoint(x: p.x * CGFloat(width), y: p.y * CGFloat(height))
            }
            let a = finished(50), b = finished(350)
            return atan2(Double(b.x - a.x), Double(b.y - a.y)) * 180 / .pi
        }
        assert(upright.vertical < -10 && angles.allSatisfy { abs($0) < 0.8 },
               "Upright sets converging verticals upright (\(upright), \(angles.map { String(format: "%.2f", $0) }))")
        assert(Upright.correction(luma: [Float](repeating: 0.5, count: width * height), width: width, height: height,
                                  mode: .auto) == nil, "a photo without lines has nothing to set upright")

        // Auto: a facade seen from the left — verticals upright, its horizontals meet far right
        let side = CGPoint(x: 3000, y: 180)
        var facade = [Float](repeating: 0.8, count: width * height)
        func plot(_ x: Double, _ y: Double) {
            for d in -1...1 {
                let xi = Int(x.rounded()), yi = Int(y.rounded()) + d
                if xi >= 0, xi < width, yi >= 0, yi < height { facade[yi * width + xi] = 0.1 }
            }
        }
        for left in stride(from: 20.0, through: 380.0, by: 40.0) {
            for x in 0..<width {
                let t = Double(x) / Double(side.x)
                plot(Double(x), left + (Double(side.y) - left) * t)
            }
        }
        for x in stride(from: 50, through: 550, by: 100) {
            for y in 0..<height { facade[y * width + x] = 0.1; facade[y * width + x + 1] = 0.1 }
        }
        guard let auto = Upright.correction(luma: facade, width: width, height: height, mode: .auto) else {
            preconditionFailure("a facade's lines are found")
        }
        var turnedFacade = DevelopSettings()
        turnedFacade.perspectiveVertical = auto.vertical
        turnedFacade.perspectiveHorizontal = auto.horizontal
        turnedFacade.straighten = auto.straighten
        let facadeAngles = stride(from: 20.0, through: 380.0, by: 40.0).map { left -> Double in
            func finished(_ x: Double) -> CGPoint {
                let y = left + (Double(side.y) - left) * x / Double(side.x)
                let p = DevelopGeometry.finishedPoint(fromSource: CGPoint(x: x / Double(width), y: y / Double(height)),
                                                      settings: turnedFacade, sourceSize: size)
                return CGPoint(x: p.x * CGFloat(width), y: p.y * CGFloat(height))
            }
            let a = finished(100), b = finished(500)
            return atan2(Double(b.y - a.y), Double(b.x - a.x)) * 180 / .pi
        }
        // before: from about +3° (top) to -4° (bottom); Auto takes most of that away
        let facadeSpread = (facadeAngles.max() ?? 0) - (facadeAngles.min() ?? 0)
        assert(auto.horizontal > 5 && facadeSpread < 2.5,
               "Auto turns a facade's horizontals most of the way to parallel (\(auto), \(facadeAngles.map { String(format: "%.2f", $0) }))")
    }
}
