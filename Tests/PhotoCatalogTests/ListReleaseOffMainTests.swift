import XCTest
@testable import PhotoCatalog

/// A list worked out again hands the lists it replaces to another thread to be freed, never one
/// still in use: not the photos' own array, nor the photos before folding that the new list
/// keeps. A queue held shut keeps what it was handed alive, so handing over a list still in use
/// would make the next in-place edit copy it.
final class ListReleaseOffMainTests: CatalogTestCase {
    private let shot = Date(timeIntervalSince1970: 1_791_800_000)

    private func library(pairs: Bool) -> [Asset] {
        (0..<60).flatMap { index -> [Asset] in
            func photo(_ id: String, _ name: String, raw: Bool) -> Asset {
                Asset(id: id, pid: 0, ori: "l", thumb: "", preview: "", filename: name, type: raw ? "CR3" : "JPEG",
                      isRaw: raw, folderId: "day", folderName: "Day", date: shot.addingTimeInterval(Double(index) * 60),
                      width: 6000, height: 4000, orientation: 1, camera: "Canon EOS R5", lens: "", focal: 50,
                      aperture: 4, shutter: "1/100", iso: 100, colorSpace: "sRGB", fileMB: Double(index % 3),
                      rating: index % 6, flag: .none, keywords: [], title: "", caption: "", location: "", gps: (0, 0),
                      status: .ready, importedAt: shot, localPath: scratch.appendingPathComponent(name).path)
            }
            let single = photo("p\(index)", "IMG_\(index).JPG", raw: false)
            guard pairs, index % 6 == 0 else { return [single] }
            return [single, photo("r\(index)", "PAIR_\(index).CR3", raw: true), photo("r\(index)j", "PAIR_\(index).JPG", raw: false)]
        }
    }

    @MainActor
    private func makeApp(pairs: Bool, held: DispatchQueue) -> AppState {
        let app = AppState.selfCheckFixture()
        app.pairRawAndJpeg = pairs
        app.assets = library(pairs: pairs)
        app.listChunk = 7
        app.duplicateGroupsCache = []
        app.listReleaseQueue = held
        return app
    }

    private func address(_ list: [Asset]?) -> UnsafePointer<Asset>? {
        list?.withUnsafeBufferPointer { $0.baseAddress }
    }

    /// A queue that runs nothing until the test ends.
    private func heldQueue() -> DispatchQueue {
        let queue = DispatchQueue(label: "held list releases")
        queue.suspend()
        addTeardownBlock { queue.resume() }
        return queue
    }

    @MainActor
    func testReplacedListsAreFreedOffTheMainThread() {
        let app = makeApp(pairs: true, held: heldQueue())
        _ = app.list
        var handed = app.listsReleasedOffMain
        app.setSort(Sort(field: .name, descending: false))
        _ = app.list
        XCTAssertEqual(app.listsReleasedOffMain, handed + 1, "the list sorted before: one array before folding and after")
        handed = app.listsReleasedOffMain
        var rated = Filters()
        rated.minRating = 2
        app.setFilters(rated)
        _ = app.list
        XCTAssertEqual(app.listsReleasedOffMain, handed + 1, "the unfiltered list")
    }

    /// Folding and opening stacks keeps the photos before folding: never handed over, so a
    /// rating key after it patches the list in place.
    @MainActor
    func testTheListKeptThroughFoldingIsNeverHandedOver() {
        let app = makeApp(pairs: true, held: heldQueue())
        // (the test keeps no list of its own: holding one would make the patch below copy it)
        app.duplicateGroupsCache = [DuplicateGroup(id: "dg", method: "contentHash", score: 1, items: Array(app.list[2..<5]))]
        let count = app.list.count
        let photosBeforeFolding = address(app.uncollapsedListCache?.value)
        XCTAssertEqual(address(app.list), photosBeforeFolding, "nothing folded: one array")
        let handed = app.listsReleasedOffMain
        app.setAllStacksCollapsed(true)
        XCTAssertEqual(app.list.count, count - 2)
        XCTAssertEqual(address(app.uncollapsedListCache?.value), photosBeforeFolding, "folded from the photos kept")
        XCTAssertEqual(app.listsReleasedOffMain, handed, "the photos before folding are kept, not handed over")
        app.setAllStacksCollapsed(false)
        XCTAssertEqual(app.list.count, count)
        XCTAssertEqual(address(app.list), photosBeforeFolding, "opened: the photos kept again")
        XCTAssertEqual(app.listsReleasedOffMain, handed + 1, "the folded list handed over")

        // a rating key in an unsorted list patches the one array in place: nothing else holds it
        let target = app.list[7].id
        XCTAssertTrue(app.setRating(5, on: [target]))
        XCTAssertEqual(app.list.first { $0.id == target }?.rating, 5)
        XCTAssertEqual(address(app.list), photosBeforeFolding, "patched in place, not copied")
    }

    /// A list that is the photos' own array (as All Photographs is primed when a catalog opens) is
    /// never handed over: an edit of the photos after a new sort writes into them in place.
    @MainActor
    func testThePhotosOwnArrayIsNeverHandedOver() {
        let app = makeApp(pairs: false, held: heldQueue())
        app.primeDefaultListCache(with: app.assets)
        let photos = address(app.assets)
        XCTAssertEqual(address(app.listCache?.value), photos, "primed with the photos' own array")
        let handed = app.listsReleasedOffMain
        app.setSort(Sort(field: .size, descending: true))
        _ = app.list
        XCTAssertEqual(app.listsReleasedOffMain, handed, "the photos' own array kept")
        XCTAssertTrue(app.setRating(4, on: [app.assets[3].id]))
        XCTAssertEqual(address(app.assets), photos, "rated in place, not copied")
        XCTAssertEqual(app.list.first { $0.id == app.assets[3].id }?.rating, 4)
    }
}
