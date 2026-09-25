import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Develop adjustments render in the right direction, persist, and undo.
enum DevelopCheck {
    static func run() {
        checkRendering()
        checkHistogram()
        checkGeometryMath()
        checkGeometryRendering()
        checkPersistence()
        MainActor.assumeIsolated { checkEditsAndUndo() }
        print("--- develop assertions passed ---")
    }

    /// A 64×64 solid-color image in display P3.
    private static func solid(_ color: (Double, Double, Double)) -> CGImage {
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                space: DevelopRenderer.outputColorSpace,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: DevelopRenderer.outputColorSpace,
                                     components: [color.0, color.1, color.2, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        return context.makeImage()!
    }

    /// Renders `settings` on `image` through a PNG file, as the app renders a photo.
    private static func develop(_ image: CGImage, _ settings: DevelopSettings, wholeFrame: Bool = false) -> CGImage {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pc-develop-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        let source = DevelopRenderer.Source(url: url, isRaw: false, maxPixel: nil)!
        return DevelopRenderer.render(source.image(settings, wholeFrame: wholeFrame)!)!
    }

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

    /// RGBA at (x, y), top-left origin.
    private static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: DevelopRenderer.outputColorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let i = (y * image.width + x) * 4
        return (data[i], data[i + 1], data[i + 2], data[i + 3])
    }

    private static func isRed(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool { p.r > 200 && p.b < 60 }
    private static func isBlue(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool { p.b > 200 && p.r < 60 }

    /// Mean RGB (0…1, display P3) of a rendered adjustment of a solid-color image.
    private static func mean(_ color: (Double, Double, Double), _ settings: DevelopSettings) -> (r: Double, g: Double, b: Double) {
        let rendered = develop(solid(color), settings)
        var pixel = [UInt8](repeating: 0, count: 4)
        let sample = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                               space: DevelopRenderer.outputColorSpace,
                               bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        sample.interpolationQuality = .medium
        sample.draw(rendered, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
    }

    private static func luma(_ c: (r: Double, g: Double, b: Double)) -> Double { 0.3 * c.r + 0.59 * c.g + 0.11 * c.b }

    private static func checkRendering() {
        let gray = (0.5, 0.5, 0.5)
        let neutral = mean(gray, .neutral)
        assert(abs(neutral.r - 0.5) < 0.02 && abs(neutral.b - 0.5) < 0.02, "neutral settings leave the photo unchanged")

        var s = DevelopSettings()
        s.exposure = 1
        assert(luma(mean(gray, s)) > luma(neutral) + 0.1, "positive exposure brightens")

        s = DevelopSettings(); s.temperature = 60
        let warm = mean(gray, s)
        s.temperature = -60
        let cool = mean(gray, s)
        assert(warm.r > warm.b + 0.03 && cool.b > cool.r + 0.03, "temperature warms and cools")

        s = DevelopSettings(); s.shadows = 100
        assert(luma(mean((0.12, 0.12, 0.12), s)) > 0.14, "lifting shadows brightens dark tones")
        s = DevelopSettings(); s.whites = -100
        assert(luma(mean((0.95, 0.95, 0.95), s)) < 0.93, "lowering whites darkens near-white")
        s = DevelopSettings(); s.blacks = 100
        let lifted = luma(mean((0.02, 0.02, 0.02), s))
        assert(lifted > 0.05, "raising blacks lifts the black point")

        s = DevelopSettings(); s.saturation = -100
        let gray2 = mean((0.8, 0.3, 0.2), s)
        assert(abs(gray2.r - gray2.g) < 0.03 && abs(gray2.g - gray2.b) < 0.03, "-100 saturation is monochrome")
        s = DevelopSettings(); s.contrast = 100
        assert(luma(mean((0.8, 0.8, 0.8), s)) > luma(mean((0.8, 0.8, 0.8), .neutral)),
               "contrast pushes light tones lighter")
    }

    private static func checkHistogram() {
        let dark = DevelopRenderer.histogram(of: solid((0.1, 0.1, 0.1)))!
        let total = dark.red.reduce(0, +)
        assert(abs(total - 1) < 0.01, "histogram bins are fractions of all pixels")
        // encoded value 0.1 lands in bin 6 of 64 — display values, not linear light (bin 0)
        assert(dark.green.firstIndex(where: { $0 > 0.5 }) == 6, "histogram counts display values")
        assert(dark.shadowClipping < DevelopHistogram.clippingWarning, "mid-dark tones don't clip")

        let white = DevelopRenderer.histogram(of: solid((1, 1, 1)))!
        assert(white.highlightClipping > 0.99, "pure white reports highlight clipping")
        let warm = DevelopRenderer.histogram(of: solid((0.9, 0.5, 0.1)))!
        let peak = { (bins: [Double]) in bins.firstIndex(of: bins.max()!)! }
        assert(peak(warm.red) > peak(warm.green) && peak(warm.green) > peak(warm.blue), "channels are kept apart")
    }

    private static func checkGeometryMath() {
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

    private static func checkGeometryRendering() {
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
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pc-horizon-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        let horizon = DevelopRenderer.horizonAngle(url: url, isRaw: false, settings: DevelopSettings())
        assert(horizon.map { (3...5).contains($0) } == true, "auto straighten levels a horizon rising to the right")
    }

    private static func checkPersistence() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pc-develop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let store = try CatalogStore(packageURL: directory.appendingPathComponent("Develop.photolibrary"))
            var edit = DevelopSettings()
            edit.exposure = 0.7
            edit.temperature = 4800
            try store.saveDevelopSettings(["a": edit, "b": edit])
            let saved = try store.loadDevelopSettings()
            assert(saved == ["a": edit, "b": edit], "adjustments round-trip")
            try store.saveDevelopSettings(["a": .neutral])
            let cleared = try store.loadDevelopSettings()
            assert(cleared == ["b": edit], "neutral settings delete the stored edit")
        } catch {
            preconditionFailure("develop persistence check failed: \(error)")
        }
    }

    @MainActor
    private static func checkEditsAndUndo() {
        let undo = UndoManager()
        undo.groupsByEvent = false
        let app = AppState.selfCheckFixture()
        app.undoManager = undo
        var edit = DevelopSettings()
        edit.exposure = 1.2

        app.updateDevelopDraft(edit, for: "x")
        assert(app.developSettings(for: "x") == edit && app.developSettings["x"] == nil,
               "a drag previews without saving")
        undo.beginUndoGrouping()
        app.commitDevelop(["x": edit], undoName: "调整曝光度")
        undo.endUndoGrouping()
        assert(app.developSettings["x"] == edit && app.developDraft == nil, "release saves the edit")
        undo.undo()
        assert(app.developSettings["x"] == nil, "undo returns the photo to as shot")
        undo.redo()
        assert(app.developSettings["x"] == edit, "redo reapplies the edit")

        app.view = .grid
        _ = app.handleKey("d", hasCommand: false)
        assert(app.view == .develop, "D opens Develop")
        _ = app.handleKey("\\", hasCommand: false)
        assert(app.developShowsOriginal, "\\ shows the photo before adjustments")

        app.view = .grid
        _ = app.handleKey("r", hasCommand: false)
        assert(app.view == .develop && app.developCropping, "R opens the crop tool from anywhere")
        _ = app.handleKey("escape", hasCommand: false)
        assert(app.view == .develop && !app.developCropping, "Esc closes the crop tool but stays in Develop")
        _ = app.handleKey("r", hasCommand: false)
        app.view = .grid
        assert(!app.developCropping, "leaving Develop closes the crop tool")
    }
}
