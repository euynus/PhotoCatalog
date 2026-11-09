import XCTest
@testable import PhotoCatalog

/// A rating key in a list sorted by rating moves photos in it, but when no filter or collection
/// reads review fields (or the photo stays in one that does) the same photos are listed: the next
/// read sorts the photos the last pass found again, without testing every photo, and lists what
/// working the list out afresh lists.
final class RatingSortReviewKeyTests: CatalogTestCase {
    private let shot = Date(timeIntervalSince1970: 1_791_800_000)

    /// Photos with ties in rating, RAW+JPEG pairs (each JPEG with its RAW's rating) and a removed photo.
    private func library() -> [Asset] {
        (0..<80).flatMap { index -> [Asset] in
            func photo(_ id: String, _ name: String, raw: Bool) -> Asset {
                Asset(id: id, pid: 0, ori: "l", thumb: "", preview: "", filename: name, type: raw ? "CR3" : "JPEG",
                      isRaw: raw, folderId: "day", folderName: "Day", date: shot.addingTimeInterval(Double(index) * 60),
                      width: 6000, height: 4000, orientation: 1, camera: "Canon EOS R5", lens: "", focal: 50,
                      aperture: 4, shutter: "1/100", iso: 100, colorSpace: "sRGB", fileMB: 1, rating: index % 6,
                      flag: index % 4 == 0 ? .pick : .none, keywords: index % 3 == 0 ? ["trip"] : [], title: "",
                      caption: "", location: "", gps: (0, 0), status: .ready, importedAt: shot,
                      localPath: scratch.appendingPathComponent(name).path)
            }
            var single = photo("p\(index)", "IMG_\(index).JPG", raw: false)
            single.deleted = index == 41
            guard index % 8 == 0 else { return [single] }
            return [single, photo("r\(index)", "PAIR_\(index).CR3", raw: true), photo("r\(index)j", "PAIR_\(index).JPG", raw: false)]
        }
    }

    @MainActor
    private func makeApp(_ photos: [Asset], pairs: Bool = true) -> AppState {
        let app = AppState.selfCheckFixture()
        app.pairRawAndJpeg = pairs
        app.assets = photos
        app.listChunk = 7
        app.duplicateGroupsCache = []
        return app
    }

    /// The list a new AppState works out for the same photos, collection, filters, search and sort.
    @MainActor
    private func fresh(like app: AppState) -> [String] {
        let other = makeApp(app.assets, pairs: app.pairRawAndJpeg)
        other.duplicateGroupsCache = app.duplicateGroupsCache
        other.smartAlbums = app.smartAlbums
        other.select(app.selection)
        other.setFilters(app.filters)
        other.setSearch(app.search)
        other.setSort(app.sort)
        other.collapsedStackIds = app.collapsedStackIds
        return other.list.map { "\($0.id) \($0.rating)" }
    }

    @MainActor
    private func listed(_ app: AppState) -> [String] { app.list.map { "\($0.id) \($0.rating)" } }

    /// Keys in an unfiltered list, a keyword's and a searched one, sorted by rating either way,
    /// with pairs and without, stacks folded and not: each lists the photos afresh in their new
    /// order, from the last pass.
    @MainActor
    func testARatingKeyInAListSortedByRatingSortsTheLastPassAgain() {
        let all = Selection(type: .lib, id: "all", name: "All")
        let cases: [(String, Selection, String)] = [
            ("All Photographs", all, ""), ("a keyword", Selection(type: .keyword, id: "trip", name: "trip"), ""),
            ("a search", all, "img_1"),
        ]
        var moved = 0
        for pairs in [true, false] {
            for collapsed in [false, true] {
                for descending in [true, false] {
                    for (name, selection, search) in cases {
                        let context = "\(name), pairs \(pairs), folded \(collapsed), descending \(descending)"
                        let app = makeApp(library(), pairs: pairs)
                        app.select(selection)
                        app.setSearch(search)
                        app.setSort(Sort(field: .rating, descending: descending))
                        if collapsed {
                            let live = app.list
                            app.duplicateGroupsCache = [DuplicateGroup(id: "dg", method: "contentHash", score: 1,
                                                                       items: Array(live[1..<4]))]
                            app.setAllStacksCollapsed(true)
                            XCTAssertFalse(app.collapsedStackIds.isEmpty, context)
                        }
                        let before = app.list
                        XCTAssertGreaterThan(before.count, 4, context)
                        let passes = app.listFilterPasses
                        for (number, key) in ["5", "0", "3", "1"].enumerated() {
                            let list = app.list
                            let target = list[[0, list.count - 1, list.count / 2, 1][number]].id
                            app.selectedIds = []
                            app.setPrimary(target)
                            XCTAssertTrue(app.handleKey(key, hasCommand: false), context)
                            XCTAssertEqual(listed(app), fresh(like: app), "\(context), key \(key)")
                            XCTAssertEqual(app.assets.first { $0.id == target }?.rating, Int(key), "\(context): as rated")
                            if app.list.map(\.id) != list.map(\.id) { moved += 1 }
                            XCTAssertEqual(app.listFilterPasses, passes, "\(context), key \(key): no pass over every photo")
                        }
                        if !collapsed {
                            XCTAssertEqual(Set(app.list.map(\.id)), Set(before.map(\.id)), "\(context): the same photos")
                        }
                        // a batch keyed without a read in between, then another sort
                        XCTAssertTrue(app.setRating(4, on: Set(before.prefix(5).map(\.id))), context)
                        XCTAssertTrue(app.setRating(2, on: Set(before.suffix(3).map(\.id))), context)
                        XCTAssertEqual(listed(app), fresh(like: app), "\(context): a batch")
                        app.setSort(Sort(field: .name, descending: false))
                        XCTAssertEqual(listed(app), fresh(like: app), "\(context): sorted by name after")
                        XCTAssertEqual(app.listFilterPasses, passes, "\(context): still the one pass")
                    }
                }
            }
        }
        XCTAssertGreaterThan(moved, 20, "keys moved their photos in the order")
    }

    /// A filter or collection a rating key moves photos out of or into: a photo staying in keeps
    /// the pass; one leaving or coming in takes a new one, as does Recently Imported, whose cutoff
    /// moves with the clock.
    @MainActor
    func testARatingKeyThatMovesPhotosInOrOutTakesANewPass() {
        var rated = Filters()
        rated.minRating = 3
        let app = makeApp(library())
        app.setFilters(rated)
        app.setSort(Sort(field: .rating, descending: true))
        let staying = app.list.first { $0.rating == 4 }!.id
        var passes = app.listFilterPasses
        XCTAssertTrue(app.setRating(5, on: [staying]))
        XCTAssertEqual(listed(app), fresh(like: app), "a photo staying in")
        XCTAssertEqual(app.listFilterPasses, passes, "a photo staying in keeps the pass")

        let leaving = app.list.last!.id
        XCTAssertTrue(app.setRating(1, on: [leaving]))
        XCTAssertFalse(app.list.contains { $0.id == leaving })
        XCTAssertEqual(listed(app), fresh(like: app), "a photo leaving")
        XCTAssertEqual(app.listFilterPasses, passes + 1, "a photo leaving takes a pass")

        passes = app.listFilterPasses
        XCTAssertTrue(app.setRating(5, on: [leaving]))
        XCTAssertTrue(app.list.contains { $0.id == leaving })
        XCTAssertEqual(listed(app), fresh(like: app), "a photo coming in")
        XCTAssertEqual(app.listFilterPasses, passes + 1, "a photo coming in takes a pass")

        app.setFilters(Filters())
        app.select(Selection(type: .smart, id: "rated", name: "Rated"))
        app.smartAlbums = [SmartAlbum(id: "rated", name: "Rated", rule: SmartRule(conditions: [
            SmartCondition(field: "rating", op: ">=", value: "2"),
        ]), count: 0)]
        _ = app.list
        passes = app.listFilterPasses
        XCTAssertTrue(app.setRating(5, on: [app.list.last!.id]))
        XCTAssertEqual(listed(app), fresh(like: app), "staying in a smart album")
        XCTAssertEqual(app.listFilterPasses, passes, "staying in a smart album keeps the pass")

        app.recentImportDays = 36_500   // every photo imported recently
        app.select(Selection(type: .lib, id: "recent", name: "Recent"))
        _ = app.list
        passes = app.listFilterPasses
        XCTAssertTrue(app.setRating(3, on: [app.list[2].id]))
        XCTAssertEqual(listed(app), fresh(like: app), "Recently Imported")
        XCTAssertEqual(app.listFilterPasses, passes + 1, "Recently Imported tests its photos again")
    }
}
