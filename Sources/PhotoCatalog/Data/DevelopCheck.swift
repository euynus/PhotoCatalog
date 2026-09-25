import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Develop adjustments render in the right direction, persist, and undo.
enum DevelopCheck {
    static func run() {
        checkRendering()
        checkHistogram()
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

    /// Mean RGB (0…1, display P3) of a rendered adjustment of a solid-color image.
    private static func mean(_ color: (Double, Double, Double), _ settings: DevelopSettings) -> (r: Double, g: Double, b: Double) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pc-develop-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, solid(color), nil)
        CGImageDestinationFinalize(destination)

        let source = DevelopRenderer.Source(url: url, isRaw: false, maxPixel: nil)!
        let rendered = DevelopRenderer.render(source.image(settings)!)!
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
    }
}
