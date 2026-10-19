import XCTest
@testable import PhotoCatalog

/// The sidebar's counts follow ratings, flags, keywords and other metadata edits without
/// recounting the library, and come out the same as a recount would.
final class SidebarCountTests: CatalogTestCase {
    private let shot = Date(timeIntervalSince1970: 1_791_800_000)

    private func photo(_ id: String, _ name: String, raw: Bool, offset: TimeInterval = 0, rating: Int = 0,
                       keywords: [String] = [], project: String = "") -> Asset {
        var asset = Asset(id: id, pid: 0, ori: "l", thumb: "", preview: "", filename: name,
                          type: raw ? "CR3" : "JPEG", isRaw: raw, folderId: "day", folderName: "2026-10-12",
                          date: shot.addingTimeInterval(offset), width: 6000, height: 4000, orientation: 1,
                          camera: "Canon EOS R5", lens: "", focal: 50, aperture: 4, shutter: "1/100", iso: 100,
                          colorSpace: "sRGB", fileMB: 1, rating: rating, flag: .none, keywords: keywords,
                          title: "", caption: "", location: "", gps: (0, 0), status: .ready, importedAt: shot,
                          localPath: scratch.appendingPathComponent(name).path)
        asset.project = project
        return asset
    }

    private func smart(_ id: String, _ field: String, _ op: String, _ value: String) -> SmartAlbum {
        SmartAlbum(id: id, name: id, rule: SmartRule(conditions: [SmartCondition(field: field, op: op, value: value)]),
                   count: 0)
    }

    @MainActor
    func testReviewAndMetadataEditsPatchTheSidebarCounts() throws {
        let app = AppState.selfCheckFixture()
        app.pairRawAndJpeg = true
        let raw = photo("raw", "IMG_0002.CR3", raw: true, offset: 10, keywords: ["trip"])
        let jpeg = photo("jpeg", "IMG_0002.JPG", raw: false, offset: 10, keywords: ["trip"])
        let solo = photo("solo", "IMG_0001.CR3", raw: true, rating: 4, project: "Wedding")
        let other = photo("other", "IMG_0003.JPG", raw: false, offset: 20, keywords: ["home"])
        // enough other photos that patching a few edits beats recounting the library
        let others = (0..<8).map { photo("filler-\($0)", "IMG_1\($0).JPG", raw: false, offset: 100 + Double($0)) }
        app.assets = [solo, raw, jpeg, other] + others
        app.duplicateGroupsCache = []
        app.albums = [Album(id: "album", name: "Album", assetIds: [raw.id, jpeg.id, other.id])]
        let rated = smart("rated", "rating", ">=", "3")
        let trip = smart("trip", "keywords", "包含", "trip")
        let picks = smart("picks", "flag", "=", "pick")
        let wedding = smart("wedding", "search", "包含", "Wedding")
        app.smartAlbums = [rated, trip, picks, wedding]
        XCTAssertTrue(app.assetPairing.isHiddenCompanion(jpeg.id), "the JPEG is behind its RAW")

        XCTAssertEqual(app.countForSmartAlbum(rated), 1)
        XCTAssertEqual(app.countForSmartAlbum(trip), 1, "the pair counts once")
        XCTAssertEqual(app.countForAlbum(app.albums[0]), 2)
        let rebuilds = app.sidebarCountIndexRebuilds

        // a rating reaches the RAW's JPEG too, which still counts once
        XCTAssertTrue(app.setRating(4, on: [raw.id]))
        XCTAssertEqual(app.countForSmartAlbum(rated), 2)
        XCTAssertEqual(app.sidebarCounts, app.recountedSidebarCounts())

        XCTAssertTrue(app.setFlag(.pick, on: [other.id]))
        XCTAssertEqual(app.countForSmartAlbum(picks), 1)
        XCTAssertEqual(app.sidebarCounts, app.recountedSidebarCounts())

        XCTAssertTrue(app.mutate(app.withCompanions([raw.id])) { $0.keywords = ["beach"] })
        XCTAssertEqual(app.countForSmartAlbum(trip), 0)
        XCTAssertEqual(app.sidebarCounts.keywords["beach"], 1)
        XCTAssertEqual(app.sidebarCounts, app.recountedSidebarCounts())

        XCTAssertTrue(app.mutate(app.withCompanions([raw.id, other.id])) {
            $0.project = "Wedding"
            $0.client = "Acme"
        })
        XCTAssertEqual(app.countForSmartAlbum(wedding), 3)
        XCTAssertEqual(app.sidebarCounts.projects["Wedding"], 3)
        XCTAssertEqual(app.sidebarCounts.clients["Acme"], 2)
        XCTAssertEqual(app.sidebarCounts, app.recountedSidebarCounts())

        XCTAssertTrue(app.mutate([solo.id]) { $0.project = "" })
        XCTAssertEqual(app.sidebarCounts.projects["Wedding"], 2)
        XCTAssertEqual(app.sidebarCounts, app.recountedSidebarCounts())

        XCTAssertEqual(app.sidebarCountIndexRebuilds, rebuilds,
                       "review and metadata edits patch the counts instead of recounting every photo")

        // a structural change still recounts, and lands on the same numbers
        let patched = app.sidebarCounts
        app.assets = app.assets
        XCTAssertEqual(app.sidebarCounts, patched)
        XCTAssertEqual(app.sidebarCountIndexRebuilds, rebuilds + 1)
    }
}
