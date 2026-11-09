import XCTest
@testable import PhotoCatalog

/// A pinned keyword stays in the sidebar's favorites while any photo not removed has it, the JPEG
/// behind a RAW included. It's told from the keyword counts already held, or else from the photos,
/// and never makes the keyword tally only to answer.
final class PinnedKeywordFavoriteTests: CatalogTestCase {
    private let shot = Date(timeIntervalSince1970: 1_791_800_000)
    private static let pins = ["trip", "behind", "nowhere", "removed", "later"]

    private func photo(_ id: String, _ name: String, raw: Bool, keywords: [String], deleted: Bool = false) -> Asset {
        Asset(id: id, pid: 0, ori: "l", thumb: "", preview: "", filename: name, type: raw ? "CR3" : "JPEG", isRaw: raw,
              folderId: "day", folderName: "2026-10-12", date: shot, width: 6000, height: 4000, orientation: 1,
              camera: "Canon EOS R5", lens: "", focal: 50, aperture: 4, shutter: "1/100", iso: 100, colorSpace: "sRGB",
              fileMB: 1, rating: 0, flag: .none, keywords: keywords, title: "", caption: "", location: "", gps: (0, 0),
              status: .ready, importedAt: shot, deleted: deleted, localPath: scratch.appendingPathComponent(name).path)
    }

    /// A RAW and its JPEG (which alone has "behind"), a photo on its own, a removed photo with
    /// "removed", and photos enough that edits are patched into the counts.
    private func photos() -> [Asset] {
        [photo("raw", "IMG_0002.CR3", raw: true, keywords: ["trip"]),
         photo("jpeg", "IMG_0002.JPG", raw: false, keywords: ["trip", "behind"]),
         photo("solo", "IMG_0001.CR3", raw: true, keywords: ["home"]),
         photo("gone", "IMG_0003.JPG", raw: false, keywords: ["removed"], deleted: true)]
            + (0..<8).map { photo("filler-\($0)", "IMG_1\($0).JPG", raw: false, keywords: []) }
    }

    @MainActor
    private func app(_ photos: [Asset]) -> AppState {
        let app = AppState.selfCheckFixture()
        app.pairRawAndJpeg = true
        app.assets = photos
        app.duplicateGroupsCache = []
        app.pinnedSidebarItems = Self.pins.map { PinnedSidebarItem(type: .keyword, selectionId: $0, name: $0) }
        XCTAssertTrue(app.assetPairing.isHiddenCompanion("jpeg"), "the JPEG is behind its RAW")
        return app
    }

    @MainActor
    private func pinned(_ app: AppState) -> [String] {
        app.pinnedSidebarFavoritesCache = nil
        return app.pinnedSidebarFavorites.map(\.selectionId)
    }

    @MainActor
    func testPinnedKeywordsResolveWithTheKeywordTallyHeld() {
        let app = app(photos())
        _ = app.keywordList
        _ = app.sidebarCounts
        XCTAssertNotNil(app.keywordCountsCache)
        XCTAssertEqual(pinned(app), ["trip", "behind"], "a shown photo's, and the hidden JPEG's; not a removed photo's")
    }

    /// An edit can drop the keyword tally and keep the sidebar's counts: those answer then.
    @MainActor
    func testPinnedKeywordsResolveWithOnlyTheSidebarCountsHeld() {
        let app = app(photos())
        _ = app.sidebarCounts
        app.keywordCountsCache = nil
        XCTAssertNotNil(app.sidebarCountIndexCache)
        XCTAssertEqual(pinned(app), ["trip", "behind"])
        XCTAssertNil(app.keywordCountsCache, "the keyword tally isn't made to resolve pins")
    }

    @MainActor
    func testPinnedKeywordsResolveWithNoCountsHeld() {
        let app = app(photos())
        app.keywordCountsCache = nil
        app.sidebarCountIndexCache = nil
        XCTAssertEqual(pinned(app), ["trip", "behind"])
        XCTAssertNil(app.keywordCountsCache, "the keyword tally isn't made to resolve pins")
        XCTAssertNil(app.sidebarCountIndexCache)
    }

    /// A keyword the held tally counts on no photo shown (its patches keep such keywords at 0) is
    /// still found on the JPEG behind its RAW, and isn't found where no photo has it.
    @MainActor
    func testAKeywordCountedOnNoShownPhotoIsLookedForBehindTheRAWs() throws {
        let app = app(photos())
        XCTAssertTrue(app.mutate(["raw"]) { $0.keywords.removeAll { $0 == "trip" } })
        _ = app.keywordList
        XCTAssertNil(app.keywordCountsCache?.counts["trip"], "only the hidden JPEG has it")
        XCTAssertEqual(pinned(app), ["trip", "behind"])
        app.keywordCountsCache?.counts["trip"] = 0
        app.keywordCountsCache?.counts["nowhere"] = 0
        XCTAssertNotNil(app.keywordCountsCache)
        XCTAssertEqual(pinned(app), ["trip", "behind"])
    }

    /// Keyword edits patch the counts the pins are resolved from: after each, the pinned list is a
    /// fresh app's with the same photos.
    @MainActor
    func testPinnedListAfterKeywordEditsIsAFreshAppsList() {
        for held in ["tally", "sidebar", "none"] {
            let app = app(photos())
            func check(_ expected: [String], _ step: String) {
                switch held {
                case "tally": _ = app.keywordList
                case "sidebar":
                    _ = app.sidebarCounts
                    app.keywordCountsCache = nil
                default:
                    app.keywordCountsCache = nil
                    app.sidebarCountIndexCache = nil
                }
                XCTAssertEqual(pinned(app), expected, "\(step), \(held) held")
                XCTAssertEqual(pinned(self.app(app.assets)), expected, "a fresh app, \(step), \(held) held")
            }
            check(["trip", "behind"], "at first")

            XCTAssertTrue(app.mutate(["solo"]) { $0.keywords.append("later") })
            check(["trip", "behind", "later"], "a keyword added")

            // the RAW's "trip" counted down to none: the JPEG behind it still has it
            XCTAssertTrue(app.mutate(["raw"]) { $0.keywords.removeAll { $0 == "trip" } })
            check(["trip", "behind", "later"], "a shown photo's keyword removed")

            XCTAssertTrue(app.mutate(["jpeg"]) { $0.keywords.removeAll { $0 == "trip" || $0 == "behind" } })
            check(["later"], "the hidden JPEG's keywords removed")
        }
    }
}
