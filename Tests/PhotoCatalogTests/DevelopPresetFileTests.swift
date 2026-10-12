import XCTest
@testable import PhotoCatalog

/// Presets as Camera Raw .xmp files, as Lightroom reads and writes them.
final class DevelopPresetFileTests: XCTestCase {
    private func preset(_ settings: DevelopSettings, _ fields: Set<DevelopField>, raw: Bool = true) -> DevelopPreset {
        DevelopPreset(id: "p", name: "P", transfer: DevelopTransfer(settings: settings, fields: fields, sourceIsRaw: raw))
    }

    /// The file as Lightroom sees it: without the app's own copy of the preset.
    private func crsOnly(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s*pc:Preset="[^"]*""#, with: "", options: .regularExpression)
    }

    private func read(_ text: String) -> DevelopTransfer? {
        DevelopPresetFile.read(Data(text.utf8), fileName: "p.xmp")?.preset.transfer
    }

    // ---- color grading (#52) ----
    private var graded: DevelopSettings {
        var settings = DevelopSettings()
        settings.grading.shadows = ColorGrading.Grade(hue: 210, saturation: 15, luminance: -5)
        settings.grading.midtones = ColorGrading.Grade(hue: 100, saturation: 10, luminance: 3)
        settings.grading.highlights = ColorGrading.Grade(hue: 40, saturation: 20, luminance: 5)
        settings.grading.global = ColorGrading.Grade(hue: 300, saturation: 4, luminance: -2)
        settings.grading.balance = 30
        settings.grading.blending = 60
        return settings
    }

    func testColorGradingIsWrittenWithLightroomsKeys() {
        let text = DevelopPresetFile.xmp(for: preset(graded, [.colorGrading]))
        for property in [#"crs:SplitToningShadowHue="210""#, #"crs:SplitToningShadowSaturation="15""#,
                         #"crs:SplitToningHighlightHue="40""#, #"crs:SplitToningHighlightSaturation="20""#,
                         #"crs:SplitToningBalance="+30""#, #"crs:ColorGradeShadowLum="-5""#,
                         #"crs:ColorGradeMidtoneHue="100""#, #"crs:ColorGradeMidtoneSat="10""#, #"crs:ColorGradeMidtoneLum="+3""#,
                         #"crs:ColorGradeHighlightLum="+5""#, #"crs:ColorGradeGlobalHue="300""#, #"crs:ColorGradeGlobalSat="4""#,
                         #"crs:ColorGradeGlobalLum="-2""#, #"crs:ColorGradeBlending="60""#] {
            XCTAssertTrue(text.contains(property), "missing \(property)")
        }
        for key in ["ColorGradeShadowHue", "ColorGradeShadowSat", "ColorGradeHighlightHue", "ColorGradeHighlightSat",
                    "ColorGradeBalance"] {
            XCTAssertFalse(text.contains("crs:\(key)="), "\(key) isn't one Lightroom reads")
        }
        XCTAssertEqual(read(crsOnly(text))?.settings.grading, graded.grading, "and it reads back")
    }

    func testColorGradingReadsTheKeysEarlierVersionsWrote() {
        let text = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
         <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
          crs:ColorGradeShadowHue="210" crs:ColorGradeShadowSat="15" crs:ColorGradeShadowLum="-5"
          crs:ColorGradeHighlightHue="40" crs:ColorGradeHighlightSat="20" crs:ColorGradeBalance="+30" crs:HasSettings="True"/>
        </rdf:RDF></x:xmpmeta>
        """
        let grading = read(text)?.settings.grading
        XCTAssertEqual(grading?.shadows, ColorGrading.Grade(hue: 210, saturation: 15, luminance: -5))
        XCTAssertEqual(grading?.highlights, ColorGrading.Grade(hue: 40, saturation: 20, luminance: 0))
        XCTAssertEqual(grading?.balance, 30)
    }
}
