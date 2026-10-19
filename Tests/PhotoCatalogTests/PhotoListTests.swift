import XCTest
@testable import PhotoCatalog

/// The photo list as the grid shows it: edits patch it in place, and it always comes out as
/// working it out again would.
final class PhotoListTests: CatalogTestCase {
    private let shot = Date(timeIntervalSince1970: 1_791_800_000)

    private func photo(_ id: String, _ name: String, raw: Bool, offset: TimeInterval = 0, rating: Int = 0) -> Asset {
        Asset(id: id, pid: 0, ori: "l", thumb: "", preview: "", filename: name,
              type: raw ? "CR3" : "JPEG", isRaw: raw, folderId: "day", folderName: "2026-10-12",
              date: shot.addingTimeInterval(offset), width: 6000, height: 4000, orientation: 1,
              camera: "Canon EOS R5", lens: "", focal: 50, aperture: 4, shutter: "1/100", iso: 100,
              colorSpace: "sRGB", fileMB: 1, rating: rating, flag: .none, keywords: [],
              title: "", caption: "", location: "", gps: (0, 0), status: .ready, importedAt: shot,
              localPath: scratch.appendingPathComponent(name).path)
    }

    /// What a list shows of each photo that edits can change, in its order (`Asset` equality
    /// compares ids only).
    private func shown(_ list: [Asset]) -> [String] {
        list.map { "\($0.id) \($0.rating) \($0.flag.rawValue) \($0.colorLabel?.rawValue ?? "-")" }
    }

    /// Rating a RAW+JPEG pair edits the JPEG behind the tile too. The JPEG isn't in the list, so
    /// the patch has nothing to look for: it used to walk the whole list for it (~23 ms at 500k).
    @MainActor
    func testRatingARawJpegPairPatchesTheListWithoutWalkingIt() throws {
        let app = AppState.selfCheckFixture()
        app.pairRawAndJpeg = true
        let raw = photo("raw", "IMG_0002.CR3", raw: true, offset: 10)
        let jpeg = photo("jpeg", "IMG_0002.JPG", raw: false, offset: 10)
        let others = (0..<200).map { photo("p\($0)", "IMG_1\($0).JPG", raw: false, offset: 100 + Double($0)) }
        app.assets = [raw, jpeg] + others
        app.duplicateGroupsCache = []
        app.select(Selection(type: .lib, id: "all", name: "All"))
        XCTAssertTrue(app.assetPairing.isHiddenCompanion(jpeg.id), "the JPEG is behind its RAW")
        let before = app.photoList
        XCTAssertEqual(before.count, 201)
        app.setPrimary(raw.id)
        XCTAssertEqual(app.listPosition(of: raw.id), 200)

        let walked = app.listPatchScannedPhotos
        XCTAssertTrue(app.setRating(4, on: [raw.id]))
        XCTAssertEqual(app.asset(id: jpeg.id)?.rating, 4, "the rating reaches the JPEG")
        XCTAssertEqual(app.listPatchScannedPhotos - walked, 0,
                       "the patch finds the RAW where it last was and doesn't look for its JPEG")
        XCTAssertEqual(app.photoList, before, "patched in place")
        let patched = shown(app.list)
        XCTAssertEqual(patched.last, "raw 4 none -")
        app.assets = app.assets   // a structural change: the list is worked out again
        XCTAssertEqual(shown(app.list), patched, "the patched list is the list worked out again")

        // Missing / Offline lists every file, the JPEG too: there a rating patches both
        app.assets = app.assets.map {
            var asset = $0
            if asset.id == raw.id || asset.id == jpeg.id { asset.status = .missing }
            return asset
        }
        app.select(Selection(type: .lib, id: "missing", name: "Missing"))
        XCTAssertEqual(Set(app.list.map(\.id)), [raw.id, jpeg.id])
        XCTAssertTrue(app.setRating(2, on: [raw.id]))
        let missing = shown(app.list)
        XCTAssertEqual(Set(missing), ["raw 2 none -", "jpeg 2 none -"])
        app.assets = app.assets
        XCTAssertEqual(shown(app.list), missing, "the patched list is the list worked out again")
    }
}
