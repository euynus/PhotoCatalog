import XCTest
@testable import PhotoCatalog

/// FileNameTemplate.render makes a token's value only while the name still holds the token.
/// Every name must come out as the eager render it replaced made it, kept here as the oracle.
final class FileNameTemplateTests: XCTestCase {
    private let shot = Date(timeIntervalSince1970: 1_791_800_000)

    private let templates = [
        "", "   ", "plain", "Trip", "Trip_{seq}", "{original}", "{seq}", "{date}", "{time}", "{camera}", "{title}",
        "{rating}", "{date}_{seq}", "{date}-{time}_{camera}_{title}_{rating}_{original}_{seq}",
        "{rating}{title}{camera}{time}{date}{seq}{original}", "{seq}{seq}", "{rating}_{rating}",
        "{original}/{original}", "{title} {title} {seq}", "{unknown}_{seq}", "{seq", "seq}", "{{seq}}", "{SEQ}",
        "{ seq }", "  {title}  ", "{title}\n{seq}", "a:b/c_{seq}", "{seq}\u{301}", "é{original}", "📷{camera}_{seq}",
    ]

    /// Originals, cameras and titles, among them text holding other tokens, path characters and line breaks.
    private let texts = [
        "", " ", "IMG_0001", "{seq}", "{rating}", "{original}", "{title}", "{camera}", "{date}{time}", "a/b", "a\\b",
        "line\nbreak", "cr\r\nlf", "colon: here", "  padded  ", "/", "\n", "x{seq}y{rating}z", "Café", "e\u{301}",
        "照片 {title}", "100% * ok?", "{se", "q}",
    ]

    func testEveryTokenRendersAsTheEagerRenderDid() {
        for template in templates {
            for text in texts {
                assertSameName(template, original: text, camera: "Canon EOS R5", title: "Sunset", rating: 3)
                assertSameName(template, original: "IMG_1234", camera: text, title: "Sunset", rating: 3)
                assertSameName(template, original: "IMG_1234", camera: "Canon EOS R5", title: text, rating: 3)
            }
        }
    }

    func testRatingsAndSequenceNumbersRenderAsTheEagerRenderDid() {
        for template in templates {
            for rating in 0...5 {
                for sequence in [-3, 0, 1, 7, 42, 9999, 10_000, 123_456] {
                    assertSameName(template, original: "IMG_1234", sequence: sequence, camera: "Canon EOS R5",
                                   title: "{rating}", rating: rating)
                }
            }
        }
    }

    func testValuesHoldingTokens() {
        // a value with a later token's text is filled as well; one with an earlier token's isn't
        XCTAssertEqual(render("{original}", original: "a{seq}b", sequence: 7), "a0007b")
        XCTAssertEqual(render("{title}", sequence: 7, title: "{original}"), "{original}")
        XCTAssertEqual(render("{camera}", camera: "{title}", title: "T"), "T")
        let rating = 0
        XCTAssertEqual(render("{rating}{seq}", sequence: 12, rating: rating), L("\(rating)星") + "0012")
    }

    func testAnEmptyNameFallsBackToTheOriginal() {
        XCTAssertEqual(render("", original: "IMG_7"), "IMG_7")
        XCTAssertEqual(render("   ", original: "IMG_7"), "IMG_7")
        XCTAssertEqual(render("{title}", original: "IMG_7", title: ""), "IMG_7")
        XCTAssertEqual(render(" {camera} ", original: "IMG_7", camera: "  "), "IMG_7")
        XCTAssertEqual(render("{title}", original: "IMG_7", title: "/"), "-")
    }

    func testSanitizedMatchesTheEagerVersion() {
        let names = texts + ["", "   ", "\t", " - ", "a\u{2028}b", "a\u{85}b", "\r\n", "ok", "<a|b>", "x?y*z%\"", "名字"]
        for name in names {
            XCTAssertEqual(FileNameTemplate.sanitized(name), eagerSanitized(name), "\(name.debugDescription)")
        }
    }

    // ---------- the rename preview's plan over 10k photos ----------

    func testPlanSpeedDateAndSequence() { measurePlan("{date}_{seq}") }
    func testPlanSpeedPrefixAndSequence() { measurePlan("Trip_{seq}") }
    func testPlanSpeedOriginal() { measurePlan("{original}") }

    private func measurePlan(_ template: String) {
        let targets = (0..<10_000).map { index in
            Asset(id: "p\(index)", pid: 0, ori: "l", thumb: "", preview: "", filename: "IMG_\(index).CR3", type: "CR3",
                  isRaw: true, folderId: "day", folderName: "2026-10-12", date: shot.addingTimeInterval(Double(index)),
                  width: 6000, height: 4000, orientation: 1, camera: "Canon EOS R5", lens: "", focal: 50, aperture: 4,
                  shutter: "1/100", iso: 100, colorSpace: "sRGB", fileMB: 1, rating: index % 6, flag: .none,
                  keywords: [], title: "", caption: "", location: "", gps: (0, 0), status: .ready, importedAt: shot,
                  localPath: "/Photos/2026/2026-10-12/IMG_\(index).CR3")
        }
        var planned = 0
        measure {
            planned = RenameService.plan(targets, template: template, start: 1).names.count
        }
        XCTAssertEqual(planned, targets.count)
    }

    // ---------- helpers ----------

    private func render(_ template: String, original: String = "IMG_1234", sequence: Int = 1, camera: String = "",
                        title: String = "", rating: Int = 0) -> String {
        FileNameTemplate.render(template, original: original, sequence: sequence, date: shot, camera: camera,
                                title: title, rating: rating)
    }

    private func assertSameName(_ template: String, original: String, sequence: Int = 7, camera: String,
                                title: String, rating: Int, line: UInt = #line) {
        let lazy = FileNameTemplate.render(template, original: original, sequence: sequence, date: shot,
                                           camera: camera, title: title, rating: rating)
        let eager = eagerRender(template, original: original, sequence: sequence, date: shot, camera: camera,
                                title: title, rating: rating)
        XCTAssertEqual(lazy, eager, "template \(template.debugDescription), original \(original.debugDescription), "
                       + "camera \(camera.debugDescription), title \(title.debugDescription), rating \(rating), "
                       + "seq \(sequence)", line: line)
    }

    /// The render before tokens were filled lazily, as it was.
    private func eagerRender(_ template: String, original: String, sequence: Int, date: Date, camera: String = "",
                             title: String = "", rating: Int = 0) -> String {
        let name = template
            .replacingOccurrences(of: "{original}", with: original)
            .replacingOccurrences(of: "{seq}", with: String(format: "%04d", sequence))
            .replacingOccurrences(of: "{date}", with: FileNameTemplate.format(date, "yyyyMMdd"))
            .replacingOccurrences(of: "{time}", with: FileNameTemplate.format(date, "HHmmss"))
            .replacingOccurrences(of: "{camera}", with: camera)
            .replacingOccurrences(of: "{title}", with: title)
            .replacingOccurrences(of: "{rating}", with: L("\(rating)星"))
        let cleaned = eagerSanitized(name)
        return cleaned.isEmpty ? original : cleaned
    }

    private func eagerSanitized(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines)
        return name.components(separatedBy: illegal).joined(separator: "-").trimmingCharacters(in: .whitespaces)
    }
}
