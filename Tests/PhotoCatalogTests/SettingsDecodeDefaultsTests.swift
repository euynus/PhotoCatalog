import XCTest
import CoreGraphics
@testable import PhotoCatalog

/// The nested settings types decode a missing key to its default, write every field under the
/// key it has always had, and read each key back to the same field. DevelopSettings substitutes
/// a whole `LensBlur()`, `ColorGrading()` or `ColorMixer()` when its key is absent, so the "{}"
/// checks of DevelopSettings never reach the defaults written into these types' own decoders.
final class SettingsDecodeDefaultsTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    /// The names `value` is stored under. A renamed property changes its key, and photos edited
    /// before would decode that field to its default: these lists change only on purpose.
    private func assertStoredKeys<T: Encodable>(_ value: T, _ expected: [String],
                                                file: StaticString = #filePath, line: UInt = #line) throws {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any]
        XCTAssertEqual(object?.keys.sorted(), expected.sorted(), "\(T.self)'s stored keys", file: file, line: line)
    }

    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    /// Every stored property of `value` differs from `defaults`', so its round trip covers every
    /// key (a field added later fails here until the test changes it too).
    private func assertEveryFieldChanged<T>(_ value: T, from defaults: T, file: StaticString = #filePath, line: UInt = #line) {
        let fields = Mirror(reflecting: value).children, original = Mirror(reflecting: defaults).children
        XCTAssertFalse(fields.isEmpty, file: file, line: line)
        for (field, base) in zip(fields, original) {
            XCTAssertNotEqual(String(describing: field.value), String(describing: base.value),
                              "\(T.self).\(field.label ?? "?") is changed", file: file, line: line)
        }
    }

    func testLensBlur() throws {
        XCTAssertEqual(try decode(LensBlur.self, "{}"), LensBlur())
        var blur = LensBlur()
        blur.enabled = true
        blur.amount = 70
        blur.focus = 0.3
        blur.range = 45
        assertEveryFieldChanged(blur, from: LensBlur())
        XCTAssertEqual(try roundTrip(blur), blur)
        try assertStoredKeys(blur, ["amount", "enabled", "focus", "range"])
    }

    func testColorGrading() throws {
        XCTAssertEqual(try decode(ColorGrading.self, "{}"), ColorGrading())
        XCTAssertEqual(try decode(ColorGrading.Grade.self, "{}"), ColorGrading.Grade())
        var grading = ColorGrading()
        grading.shadows = ColorGrading.Grade(hue: 210, saturation: 30, luminance: -10)
        grading.midtones = ColorGrading.Grade(hue: 40, saturation: 12, luminance: 5)
        grading.highlights = ColorGrading.Grade(hue: 55, saturation: 25, luminance: 15)
        grading.global = ColorGrading.Grade(hue: 300, saturation: 8, luminance: -3)
        grading.blending = 70
        grading.balance = -20
        assertEveryFieldChanged(grading, from: ColorGrading())
        assertEveryFieldChanged(grading.shadows, from: ColorGrading.Grade())
        XCTAssertEqual(try roundTrip(grading), grading)
        try assertStoredKeys(grading, ["balance", "blending", "global", "highlights", "midtones", "shadows"])
    }

    func testColorMixer() throws {
        XCTAssertEqual(try decode(ColorMixer.self, "{}"), ColorMixer())
        var mixer = ColorMixer()
        mixer.hue = [1, 2, 3, 4, 5, 6, 7, 8]
        mixer.saturation = [-10, -20, -30, -40, -50, -60, -70, -80]
        mixer.luminance = [11, 12, 13, 14, 15, 16, 17, 18]
        assertEveryFieldChanged(mixer, from: ColorMixer())
        XCTAssertEqual(try roundTrip(mixer), mixer)
        try assertStoredKeys(mixer, ["hue", "luminance", "saturation"])
    }

    /// ToneCurve's decoder is the synthesized one, which needs every channel; it is always
    /// written whole, so only the round trip is locked.
    func testToneCurve() throws {
        var curve = ToneCurve()
        curve.rgb = ToneCurve.mediumContrast
        curve.red = [CurvePoint(x: 0, y: 0.05), CurvePoint(x: 1, y: 1)]
        curve.green = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.55), CurvePoint(x: 1, y: 1)]
        curve.blue = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 0.9)]
        assertEveryFieldChanged(curve, from: ToneCurve())
        XCTAssertEqual(try roundTrip(curve), curve)
        try assertStoredKeys(curve, ["blue", "green", "red", "rgb"])
    }

    func testLocalAdjustment() throws {
        // a radial mask without a range; its id is a new one
        let decoded = try decode(LocalAdjustment.self, "{}")
        var expected = LocalAdjustment(kind: .radial)
        expected.id = decoded.id
        XCTAssertEqual(decoded, expected)
        XCTAssertNil(decoded.range)

        var mask = LocalAdjustment(kind: .object)
        mask.id = "mask-1"
        mask.start = CGPoint(x: 0.2, y: 0.3)
        mask.end = CGPoint(x: 0.6, y: 0.7)
        mask.center = CGPoint(x: 0.4, y: 0.35)
        mask.radiusX = 0.31
        mask.radiusY = 0.22
        mask.angle = 15
        mask.feather = 65
        var stroke = BrushStroke()
        stroke.points = [0.1, 0.2, 0.3, 0.4]
        mask.strokes = [stroke]
        mask.inverted = true
        mask.range = MaskRange(kind: .color)
        mask.part = .lips
        mask.person = 2
        mask.prompt = ObjectPrompt(box: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.4),
                                   points: [ObjectPrompt.Point(point: CGPoint(x: 0.3, y: 0.3), include: false)])
        mask.landscape = .mountains
        for (index, adjustment) in LocalAdjustment.adjustments.enumerated() { mask[keyPath: adjustment] = Double(index + 1) * 3 }
        var defaults = LocalAdjustment(kind: .radial)
        defaults.id = ""
        assertEveryFieldChanged(mask, from: defaults)
        XCTAssertEqual(try roundTrip(mask), mask)
        try assertStoredKeys(mask, [
            "angle", "blacks", "center", "clarity", "contrast", "dehaze", "end", "exposure", "feather", "highlights",
            "id", "inverted", "kind", "landscape", "part", "person", "prompt", "radiusX", "radiusY", "range",
            "saturation", "shadows", "start", "strokes", "temperature", "texture", "tint", "whites"
        ])
    }

    func testMaskRange() throws {
        XCTAssertEqual(try decode(MaskRange.self, "{}"), MaskRange(kind: .luminance))
        var range = MaskRange(kind: .color)
        range.low = 20
        range.high = 80
        range.smoothness = 35
        range.samples = [CGPoint(x: 0.25, y: 0.75)]
        range.amount = 60
        assertEveryFieldChanged(range, from: MaskRange(kind: .luminance))
        XCTAssertEqual(try roundTrip(range), range)
        try assertStoredKeys(range, ["amount", "high", "kind", "low", "samples", "smoothness"])
    }

    func testBrushStroke() throws {
        XCTAssertEqual(try decode(BrushStroke.self, "{}"), BrushStroke())
        var stroke = BrushStroke()
        stroke.points = [0.1, 0.2, 0.3, 0.4]
        stroke.radius = 0.08
        stroke.feather = 30
        stroke.density = 60
        stroke.erase = true
        assertEveryFieldChanged(stroke, from: BrushStroke())
        XCTAssertEqual(try roundTrip(stroke), stroke)
        try assertStoredKeys(stroke, ["density", "erase", "feather", "points", "radius"])
    }

    func testSpotRemoval() throws {
        // a heal spot in the middle; its id is a new one
        let decoded = try decode(SpotRemoval.self, "{}")
        var expected = SpotRemoval(target: CGPoint(x: 0.5, y: 0.5), source: CGPoint(x: 0.55, y: 0.5), radius: 0.01)
        expected.id = decoded.id
        XCTAssertEqual(decoded, expected)
        XCTAssertEqual(decoded.mode, .heal)

        var spot = SpotRemoval(target: CGPoint(x: 0.2, y: 0.3), source: CGPoint(x: 0.4, y: 0.6), radius: 0.03)
        spot.id = "spot-1"
        spot.mode = .remove
        spot.feather = 20
        spot.opacity = 80
        var stroke = BrushStroke()
        stroke.points = [0.2, 0.3]
        spot.strokes = [stroke]
        var defaults = expected
        defaults.id = ""
        assertEveryFieldChanged(spot, from: defaults)
        XCTAssertEqual(try roundTrip(spot), spot)
        try assertStoredKeys(spot, ["feather", "id", "mode", "opacity", "radius", "source", "strokes", "target"])
    }

    func testExportSettings() throws {
        XCTAssertEqual(try decode(ExportSettings.self, "{}"), ExportSettings())
        var export = ExportSettings()
        export.format = .tiff
        export.quality = 0.55
        export.sixteenBit = true
        export.colorSpace = .adobeRGB
        export.resize = .fitWithin
        export.edge = 1000
        export.maxWidth = 800
        export.maxHeight = 600
        export.allowEnlarge = true
        export.sharpenFor = .mattePaper
        export.sharpenAmount = .high
        export.fileNameTemplate = "{date}-{seq}"
        export.sequenceStart = 7
        export.subfolder = "Out"
        export.metadata = .copyrightOnly
        export.removeLocation = true
        export.watermarkEnabled = true
        export.watermark = "© Me"
        export.collision = .skip
        export.revealInFinder = false
        assertEveryFieldChanged(export, from: ExportSettings())
        XCTAssertEqual(try roundTrip(export), export)
        try assertStoredKeys(export, [
            "allowEnlarge", "collision", "colorSpace", "edge", "fileNameTemplate", "format", "maxHeight", "maxWidth",
            "metadata", "quality", "removeLocation", "resize", "revealInFinder", "sequenceStart", "sharpenAmount",
            "sharpenFor", "sixteenBit", "subfolder", "watermark", "watermarkEnabled"
        ])
    }

    func testPrintSettings() throws {
        XCTAssertEqual(try decode(PrintSettings.self, "{}"), PrintSettings())
        var settings = PrintSettings()
        settings.paper = .letter
        settings.orientation = .landscape
        settings.rotateToFit = false
        settings.layout = .contactSheet
        settings.fill = true
        settings.rows = 5
        settings.columns = 2
        settings.margin = 18
        settings.spacing = 6
        settings.caption = .title
        settings.sharpenFor = .glossyPaper
        settings.sharpenAmount = .low
        settings.profile = "Printer.icc"
        settings.intent = .relative
        settings.resolution = 240
        assertEveryFieldChanged(settings, from: PrintSettings())
        XCTAssertEqual(try roundTrip(settings), settings)
        try assertStoredKeys(settings, [
            "caption", "columns", "fill", "intent", "layout", "margin", "orientation", "paper", "profile",
            "resolution", "rotateToFit", "rows", "sharpenAmount", "sharpenFor", "spacing"
        ])
    }
}
