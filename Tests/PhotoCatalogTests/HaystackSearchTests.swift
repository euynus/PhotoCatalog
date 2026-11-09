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

    /// Photos whose searched fields differ in every way the bytes could: empty fields (consecutive
    /// spaces), no keywords (no trailing space), a byte order mark starting the text and inside it,
    /// NULs, combining marks, ligatures, widths, Turkish i, Chinese and emoji.
    static func haystackPhotos() -> [Asset] {
        [
            photo(0, filename: "IMG_1234.CR3", camera: "Canon EOS R5", lens: "RF50mm F1.2 L USM",
                  keywords: ["旅行/主题12", "人像", "Café", "ｃａｆｅ ｆｕｌｌ"], title: "Wedding at the Café",
                  caption: "Cafe\u{301} decomposed, résumé naïve", location: "30.500, 114.300", project: "İstanbul ıi",
                  client: "Straße STRASSE"),
            photo(1, filename: "", camera: "", lens: "", keywords: []),
            photo(2, filename: "\u{FEFF}IMG_1.JPG", camera: "Canon"),
            photo(3, filename: "\u{FEFF}", keywords: ["\u{FEFF}"]),
            photo(4, filename: "", camera: "\u{FEFF}Canon", keywords: ["a\u{FEFF}b"]),
            photo(5, filename: "ﬁsh.HEIC", lens: "ＦＥ 35mm", keywords: ["emoji 📷 camera", "IJssel ĳ", "Ω ω Ὠ"]),
            photo(6, filename: "a\u{0}b.JPG", keywords: ["", "", "x"], title: "\u{0}"),
            photo(7, filename: "short", keywords: ["   "]),
            photo(8, filename: "DSC_0001.ARW", camera: "SONY ILCE-7M4", lens: "FE 35mm F1.4 GM",
                  keywords: (0..<40).map { "keyword\($0)" }, title: "harbour dawn"),
            photo(9, filename: "x"),
        ]
    }

    static let haystackNeedles = needles + [
        "img_12", "IMG_10", "R5 RF50", "wedding", "114.3", "  ", "       ", "\u{FEFF}", "\u{FEFF}IMG", "IMG",
        "\u{FEFF}Canon", "a\u{FEFF}b", "ab", "keyword39", "dawn keyword0", "Canon RF", "ｆｅ 35", "R5 RF50mm F1.2",
        "旅行/主题12 人像", "x\u{0}", "\u{0} ", "short    ", "ﬁsh.heic", "naive", "e decomposed",
    ]

    /// The bytes written for a photo and searched as one string answer as its joined Swift string
    /// does, through one search carried photo to photo.
    func testHaystackAnswersAsSearchHaystackLocalizedStandardContains() {
        let photos = Self.haystackPhotos() + Self.textPhotos()
        for needle in Self.haystackNeedles {
            var search = LocalizedSearch()
            for photo in photos {
                XCTAssertEqual(search.haystack(of: photo, contains: needle),
                               photo.searchHaystack.localizedStandardContains(needle),
                               "“\(needle)” in “\(photo.searchHaystack)”")
            }
        }
    }

    /// The storage one search reuses holds only the photo it is searching: after a long text, a
    /// short one isn't searched with the end of the long one still behind it.
    func testReusedStorageHoldsOnlyThePhotoSearched() {
        var search = LocalizedSearch()
        let long = Self.photo(0, filename: "IMG_0001.JPG", camera: "Canon EOS R5", lens: "RF24-70mm F2.8",
                              keywords: (0..<60).map { "tailword\($0)" })
        let short = Self.photo(1, filename: "x")
        for _ in 0..<3 {
            XCTAssertTrue(search.haystack(of: long, contains: "tailword59"))
            XCTAssertFalse(search.haystack(of: short, contains: "tailword"))
            XCTAssertFalse(search.haystack(of: short, contains: "IMG"))
            XCTAssertFalse(search.haystack(of: short, contains: "x I"))
            XCTAssertTrue(search.haystack(of: short, contains: "x  "))
        }
    }

    /// Core Foundation drops a byte order mark that starts the bytes; a filename starting with one
    /// is searched as its joined text, mark included.
    func testAFilenameStartingWithAByteOrderMarkIsSearchedWithIt() {
        var search = LocalizedSearch()
        let marked = Self.photo(0, filename: "\u{FEFF}IMG_1.JPG", camera: "Canon")
        XCTAssertTrue(marked.searchHaystack.localizedStandardContains("\u{FEFF}"), "the oracle finds the mark")
        XCTAssertTrue(search.haystack(of: marked, contains: "\u{FEFF}"))
        XCTAssertTrue(search.haystack(of: marked, contains: "\u{FEFF}IMG"))
        XCTAssertTrue(search.haystack(of: marked, contains: "img_1"))
        XCTAssertFalse(search.haystack(of: Self.photo(1, filename: "IMG_1.JPG"), contains: "\u{FEFF}"))
    }

    /// A smart album's 全文搜索 answers as the joined text does, with a memo carried photo to photo
    /// and without one, alone and beside other text tests.
    func testFullTextConditionsMatchAsSearchHaystackDoes() {
        let photos = Self.haystackPhotos() + Self.textPhotos()
        for needle in Self.haystackNeedles {
            let condition = SmartCondition(field: "search", op: "包含", value: needle)
            let alone = SmartMatcher.Prepared(SmartRule(match: "all", conditions: [condition]))
            let beside = SmartMatcher.Prepared(SmartRule(match: "any", conditions: [
                SmartCondition(field: "keywords", op: "包含", value: "zzz-none"), condition,
                SmartCondition(field: "camera", op: "包含", value: "zzz-none"),
            ]))
            var aloneMemo = SmartMatcher.Memo(for: alone)
            var besideMemo = SmartMatcher.Memo(for: beside)
            for photo in photos + photos.reversed() {
                let expected = photo.searchHaystack.localizedStandardContains(needle)
                let label = "“\(needle)” in “\(photo.searchHaystack)”"
                XCTAssertEqual(SmartMatcher.eval(photo, condition), expected, "no memo: " + label)
                XCTAssertEqual(alone.matches(photo, memo: &aloneMemo), expected, "memo: " + label)
                XCTAssertEqual(beside.matches(photo, memo: &besideMemo), expected, "beside: " + label)
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
