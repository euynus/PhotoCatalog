import XCTest
@testable import PhotoCatalog

/// Looking photos up in the list: the last position found answers for the photo it names, a few
/// others are found by one pass that stops at the last of them, and a batch uses the index.
final class ListPositionLookupTests: CatalogTestCase {
    private let shot = Date(timeIntervalSince1970: 1_791_800_000)

    /// The photo the default sort (newest first) lists at `index`.
    private func photo(_ index: Int) -> Asset {
        Asset(id: "p\(index)", pid: 0, ori: "l", thumb: "", preview: "", filename: "IMG_\(index).JPG",
              type: "JPEG", isRaw: false, folderId: "day", folderName: "Day",
              date: shot.addingTimeInterval(-Double(index)), width: 6000, height: 4000, orientation: 1,
              camera: "Canon EOS R5", lens: "", focal: 50, aperture: 4, shutter: "1/100", iso: 100,
              colorSpace: "sRGB", fileMB: 1, rating: 0, flag: .none, keywords: [],
              title: "", caption: "", location: "", gps: (0, 0), status: .ready, importedAt: shot,
              localPath: scratch.appendingPathComponent("IMG_\(index).JPG").path)
    }

    /// All Photographs listing `count` photos, `p0` first, with no index, hint or primary photo.
    @MainActor
    private func listed(_ count: Int) -> AppState {
        let app = AppState.selfCheckFixture()
        app.assets = (0..<count).map(photo)
        app.duplicateGroupsCache = []
        app.select(Selection(type: .lib, id: "all", name: "All"))
        XCTAssertEqual(app.list.map(\.id), (0..<count).map { "p\($0)" })
        app.listPositionsCache = nil
        app.listPositionHint = nil
        app.primaryId = nil
        app.selectedIds = []
        return app
    }

    @MainActor
    func testTheHintAnswersForThePhotoItNamesWithoutAPass() {
        let app = listed(50)
        app.listPositionHint = ("p30", 30)
        var scanned = app.listPositionScannedPhotos
        XCTAssertEqual(app.listPosition(of: "p30"), 30)
        XCTAssertEqual(app.listPositionScannedPhotos - scanned, 0, "the hint names the photo where it is")

        // a hint that no longer names its photo where it was is passed over
        app.listPositionHint = ("p30", 31)
        scanned = app.listPositionScannedPhotos
        XCTAssertEqual(app.listPosition(of: "p30"), 30)
        XCTAssertEqual(app.listPositionScannedPhotos - scanned, 31)

        // and one naming another photo doesn't stop the pass for this one
        app.listPositionHint = ("p2", 2)
        scanned = app.listPositionScannedPhotos
        XCTAssertEqual(app.listPositions(of: ["p2", "p9"]), ["p2": 2, "p9": 9])
        XCTAssertEqual(app.listPositionScannedPhotos - scanned, 10, "the hint's photo found, the pass stops at p9")
    }

    @MainActor
    func testAPassStopsAtTheLastPhotoAskedFor() {
        let app = listed(50)
        var scanned = app.listPositionScannedPhotos
        XCTAssertEqual(app.listPosition(of: "p17"), 17)
        XCTAssertEqual(app.listPositionScannedPhotos - scanned, 18)

        scanned = app.listPositionScannedPhotos
        XCTAssertEqual(app.listPositions(of: ["p3", "p40", "p12"]), ["p3": 3, "p40": 40, "p12": 12])
        XCTAssertEqual(app.listPositionScannedPhotos - scanned, 41)

        // the primary photo found is the next lookup's hint
        app.primaryId = "p40"
        scanned = app.listPositionScannedPhotos
        XCTAssertEqual(app.listPosition(of: "p40"), 40)
        XCTAssertEqual(app.listPositionScannedPhotos - scanned, 41)
        scanned = app.listPositionScannedPhotos
        XCTAssertEqual(app.listPositions(of: ["p40", "p12"]), ["p40": 40, "p12": 12])
        XCTAssertEqual(app.listPositionScannedPhotos - scanned, 13, "p40 from the hint, the pass stops at p12")
    }

    @MainActor
    func testAPhotoNotInTheListWalksTheWholeList() {
        let app = listed(50)
        var filters = Filters()
        filters.minRating = 1
        XCTAssertTrue(app.setRating(2, on: ["p5", "p6"]))
        app.setFilters(filters)
        XCTAssertEqual(app.list.map(\.id), ["p5", "p6"])
        app.listPositionHint = nil
        app.primaryId = nil
        let scanned = app.listPositionScannedPhotos
        XCTAssertNil(app.listPosition(of: "p7"), "filtered out")
        XCTAssertNil(app.listPosition(of: "nowhere"), "no such photo")
        XCTAssertEqual(app.listPositions(of: ["p6", "p8"]), ["p6": 1])
        XCTAssertEqual(app.listPositionScannedPhotos - scanned, 3 * app.list.count)
    }

    @MainActor
    func testABatchLargerThanTheScanLimitUsesTheIndex() {
        let app = listed(50)
        let ids = Set((0..<AppState.listScanLimit + 4).map { "p\($0 * 3)" })
        let scanned = app.listPositionScannedPhotos
        let positions = app.listPositions(of: ids.union(["nowhere"]))
        XCTAssertEqual(positions, Dictionary(uniqueKeysWithValues: ids.map { ($0, Int($0.dropFirst())!) }))
        XCTAssertNotNil(app.listPositionsCache, "the index was built")
        // the index answers a single photo too, once built
        XCTAssertEqual(app.listPosition(of: "p49"), 49)
        XCTAssertEqual(app.listPositionScannedPhotos - scanned, 0, "nothing looked at one by one")
    }

    /// A single edit is found where the hint says, or by a pass that stops at it.
    @MainActor
    func testARatingPatchesTheListFromTheHintOrAPass() {
        let app = listed(50)
        var walked = app.listPatchScannedPhotos
        XCTAssertTrue(app.setRating(3, on: ["p25"]))
        XCTAssertEqual(app.listPatchScannedPhotos - walked, 26, "a pass that stops at the photo")
        XCTAssertEqual(app.list[25].rating, 3)

        app.listPositionHint = ("p25", 25)
        walked = app.listPatchScannedPhotos
        XCTAssertTrue(app.setRating(4, on: ["p25"]))
        XCTAssertEqual(app.listPatchScannedPhotos - walked, 0, "the hint names it")
        XCTAssertEqual(app.list[25].rating, 4)
        XCTAssertEqual(app.list.map(\.id), (0..<50).map { "p\($0)" }, "patched in place")
    }

    /// `locate` on its own: each id found once, at its first place, a few ids compared one by one
    /// and more hashed, the hint taken only for a wanted photo where it still is.
    func testLocateReportsEachIdOnceAtItsFirstPlace() {
        let photos = (0..<40).map(photo) + [photo(3), photo(20)]   // p3 and p20 listed twice
        func locate(_ ids: [String], hint: (id: String, position: Int)? = nil) -> (found: [String: Int], scanned: Int) {
            var found: [String: Int] = [:]
            let scanned = photos.withUnsafeBufferPointer { photos in
                AppState.locate(ids, in: photos, hint: hint) { id, position in
                    XCTAssertNil(found[id], "\(id) reported once")
                    found[id] = position
                }
            }
            return (found, scanned)
        }
        XCTAssertEqual(locate([]).scanned, 0)
        XCTAssertEqual(locate(["p20"]).found, ["p20": 20])
        XCTAssertEqual(locate(["p20"]).scanned, 21)
        XCTAssertEqual(locate(["p20", "p20", "p3"]).found, ["p20": 20, "p3": 3])
        XCTAssertEqual(locate(["p20", "p3"], hint: ("p3", 40)).found, ["p20": 20, "p3": 40], "the hint's own place")
        XCTAssertEqual(locate(["p20", "p3"], hint: ("p3", 40)).scanned, 21)
        XCTAssertEqual(locate(["p20"], hint: ("p3", 3)).found, ["p20": 20], "a hint for a photo not asked for")
        XCTAssertEqual(locate(["p20"], hint: ("p20", 19)).scanned, 21, "a hint that doesn't name its photo there")
        XCTAssertEqual(locate(["p20"], hint: ("p20", 99)).found, ["p20": 20], "a hint past the end")

        let many = (0..<AppState.listScanLimit + 3).map { "p\($0 * 2)" } + ["nowhere"]
        let hashed = locate(many, hint: ("p0", 0))
        XCTAssertEqual(hashed.found, Dictionary(uniqueKeysWithValues: many.dropLast().map { ($0, Int($0.dropFirst())!) }))
        XCTAssertEqual(hashed.scanned, photos.count, "the id not there keeps the pass going to the end")
        let all = locate(Array(many.dropLast()))
        XCTAssertEqual(all.scanned, (AppState.listScanLimit + 2) * 2 + 1, "stops at the last one")
    }
}
