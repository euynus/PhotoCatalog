import XCTest
@testable import PhotoCatalog

/// Smart albums' text tests answer as `localizedStandardContains` does, whichever way they search:
/// keywords, cameras and lenses through a memo's `LocalizedSearch`, with and without a memo.
final class HaystackSearchTests: XCTestCase {
    /// Case, diacritics (precomposed and combining), widths, ligatures, Turkish dotted and dotless
    /// i, Chinese, emoji, NULs and blanks.
    static let texts = ["Café", "cafe", "CAFÉ au lait", "Cafe\u{301} decomposed", "ｃａｆｅ ｆｕｌｌ", "ﬁsh ligature",
                        "fish", "旅行/主题12", "人像", "İstanbul ıi", "Straße STRASSE", "", "   ", "Canon EOS R5",
                        "ＣＡＮＯＮ", "RF50mm F1.2 L USM", "emoji 📷 camera", "a\u{0}b", "IJssel ĳ", "Ω ω Ὠ"]

    static let needles = ["", "cafe", "CAFE", "café", "CAFÉ", "é", "e\u{301}", "ｃａｆｅ", "cafe full", "fi", "ﬁ",
                          "fish", "旅行", "主题1", "人", "istanbul", "İ", "ı", "i", "strasse", "ß", "canon", "Canon",
                          "eos r5", "rf", " ", "📷", "zzz", "\u{0}", "b", "ij", "ĳ", "ω"]

    static func photo(_ index: Int, filename: String = "IMG.JPG", camera: String = "", lens: String = "",
                      keywords: [String] = [], title: String = "", caption: String = "", location: String = "",
                      project: String = "", client: String = "") -> Asset {
        var asset = Asset(id: "h\(index)", pid: index, ori: "l", thumb: "", preview: "", filename: filename,
                          type: "JPG", isRaw: false, folderId: "f", folderName: "F",
                          date: Date(timeIntervalSince1970: 1_700_000_000), width: 6000, height: 4000,
                          orientation: 1, camera: camera, lens: lens, focal: 50, aperture: 2, shutter: "1/100",
                          iso: 100, colorSpace: "sRGB", fileMB: 1, rating: 0, flag: .none, keywords: keywords,
                          title: title, caption: caption, location: location, gps: (0, 0), status: .ready,
                          importedAt: Date(timeIntervalSince1970: 1_700_000_000))
        asset.project = project
        asset.client = client
        return asset
    }

    /// Every text as a camera, a lens and among keywords, each in several photos, so a memo
    /// carried across them answers some from what it found before.
    static func textPhotos() -> [Asset] {
        let texts = Self.texts
        return (0..<(texts.count * 3)).map { index in
            photo(index, camera: texts[index % texts.count], lens: texts[(index * 7 + 3) % texts.count],
                  keywords: index % 5 == 4 ? [] : (0..<(1 + index % 3)).map { texts[(index + $0 * 11) % texts.count] })
        }
    }

    func testKeywordCameraAndLensTestsAnswerAsLocalizedStandardContains() {
        let photos = Self.textPhotos()
        for needle in Self.needles {
            let conditions = [SmartCondition(field: "keywords", op: "包含", value: needle),
                              SmartCondition(field: "keywords", op: "不包含", value: needle),
                              SmartCondition(field: "camera", op: "包含", value: needle),
                              SmartCondition(field: "lens", op: "包含", value: needle)]
            for condition in conditions {
                let prepared = SmartMatcher.Prepared(SmartRule(match: "all", conditions: [condition]))
                var memo = SmartMatcher.Memo(for: prepared)
                // twice over, so the second pass answers every photo from the memo
                for photo in photos + photos {
                    let expected: Bool
                    switch condition.field {
                    case "keywords":
                        let has = photo.keywords.contains { $0.localizedStandardContains(needle) }
                        expected = condition.op == "包含" ? has : !has
                    case "camera": expected = photo.camera.localizedStandardContains(needle)
                    default: expected = photo.lens.localizedStandardContains(needle)
                    }
                    let label = "\(condition.field) \(condition.op) “\(needle)” on \(photo.id)"
                    XCTAssertEqual(SmartMatcher.eval(photo, condition), expected, "no memo: " + label)
                    XCTAssertEqual(prepared.matches(photo, memo: &memo), expected, "memo: " + label)
                }
            }
        }
    }

    /// Several text tests in one rule each keep their own answers in the memo they share.
    func testTextTestsInOneRuleKeepTheirAnswersApart() {
        let photos = Self.textPhotos()
        let pairs = [("cafe", "ﬁ"), ("旅行", "canon"), ("", "ｃａｆｅ"), ("İ", "ß"), ("CAFÉ", "")]
        for (first, second) in pairs {
            for match in ["all", "any"] {
                let rule = SmartRule(match: match, conditions: [
                    SmartCondition(field: "keywords", op: "包含", value: first),
                    SmartCondition(field: "camera", op: "包含", value: second),
                    SmartCondition(field: "lens", op: "包含", value: first),
                ])
                let prepared = SmartMatcher.Prepared(rule)
                var memo = SmartMatcher.Memo(for: prepared)
                for photo in photos + photos {
                    let tests = [photo.keywords.contains { $0.localizedStandardContains(first) },
                                 photo.camera.localizedStandardContains(second),
                                 photo.lens.localizedStandardContains(first)]
                    let expected = match == "all" ? !tests.contains(false) : tests.contains(true)
                    XCTAssertEqual(prepared.matches(photo, memo: &memo), expected,
                                   "\(match) “\(first)” “\(second)” on \(photo.id)")
                }
            }
        }
    }
}
