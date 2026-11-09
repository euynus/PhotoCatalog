import XCTest
@testable import PhotoCatalog

/// A rating, flag or color key in a list that reads those fields — Unrated, Picks, Rejected, a
/// rating, flag or color filter, a smart album — patches the list when it only takes photos out:
/// the photos leave the cached list, which comes out as working it out again would, and the photo
/// that left isn't looked for again.
final class ReviewKeyListPatchTests: CatalogTestCase {
    private let shot = Date(timeIntervalSince1970: 1_791_800_000)

    private func photo(_ id: String, _ name: String, raw: Bool, offset: TimeInterval, rating: Int, flag: Flag,
                       color: ColorLabel?) -> Asset {
        var asset = Asset(id: id, pid: 0, ori: "l", thumb: "", preview: "", filename: name,
                          type: raw ? "CR3" : "JPEG", isRaw: raw, folderId: "day", folderName: "Day",
                          date: shot.addingTimeInterval(offset), width: 6000, height: 4000, orientation: 1,
                          camera: "Canon EOS R5", lens: "", focal: 50, aperture: 4, shutter: "1/100", iso: 100,
                          colorSpace: "sRGB", fileMB: 1, rating: rating, flag: flag, keywords: [],
                          title: "", caption: "", location: "", gps: (0, 0), status: .ready, importedAt: shot,
                          localPath: scratch.appendingPathComponent(name).path)
        asset.colorLabel = color
        return asset
    }

    /// Photos of every rating, flag and color, some taken in the same second (ties), with RAW+JPEG
    /// pairs whose JPEG has the RAW's review fields.
    private func library() -> [Asset] {
        var photos: [Asset] = []
        for index in 0..<90 {
            let rating = (index * 7) % 6
            let flag: Flag = [.none, .pick, .none, .reject, .none][index % 5]
            let color: ColorLabel? = [nil, .red, nil, .yellow][index % 4]
            let offset = Double(index / 2) * 60   // two photos a minute
            photos.append(photo("p\(index)", "IMG_\(index).JPG", raw: false, offset: offset, rating: rating, flag: flag,
                                color: color))
            if index % 6 == 0 {
                photos.append(photo("r\(index)", "PAIR_\(index).CR3", raw: true, offset: offset + 1, rating: rating,
                                    flag: flag, color: color))
                photos.append(photo("r\(index)j", "PAIR_\(index).JPG", raw: false, offset: offset + 1, rating: rating,
                                    flag: flag, color: color))
            }
        }
        return photos
    }

    /// What a list shows of each photo that review keys change, in its order.
    private func shown(_ list: [Asset]) -> [String] {
        list.map { "\($0.id) \($0.rating) \($0.flag.rawValue) \($0.colorLabel?.rawValue ?? "-")" }
    }

    @MainActor
    private func makeApp(chunk: Int, pairs: Bool, collapsed: Bool) -> AppState {
        let app = AppState.selfCheckFixture()
        app.pairRawAndJpeg = pairs
        app.assets = library()
        app.listChunk = chunk
        app.duplicateGroupsCache = []
        app.select(Selection(type: .lib, id: "all", name: "All"))
        if collapsed {
            // stacks of three photos shown, some of them review keys take out of the lists below
            let live = app.assets.filter(app.assetPairing.shows)
            app.duplicateGroupsCache = stride(from: 0, to: 72, by: 8).map { start in
                DuplicateGroup(id: "dg\(start)", method: "contentHash", score: 1, items: Array(live[start..<start + 3]))
            }
            app.setAllStacksCollapsed(true)
            XCTAssertFalse(app.collapsedStackIds.isEmpty)
        }
        return app
    }

    private struct Scenario {
        let name: String
        let selection: Selection
        var filters = Filters()
        let keys: [String]
    }

    private var scenarios: [Scenario] {
        var minRating = Filters(), picks = Filters(), red = Filters()
        minRating.minRating = 3
        picks.flag = Flag.pick.rawValue
        red.color = ColorLabel.red.rawValue
        let all = Selection(type: .lib, id: "all", name: "All")
        return [
            Scenario(name: "Unrated", selection: Selection(type: .lib, id: "unrated", name: "Unrated"),
                     keys: ["3", "p", "x", "6", "0", "2"]),
            Scenario(name: "Picks", selection: Selection(type: .lib, id: "picks", name: "Picks"),
                     keys: ["4", "u", "p", "x", "7"]),
            Scenario(name: "Rejected", selection: Selection(type: .lib, id: "rejected", name: "Rejected"),
                     keys: ["2", "u", "x", "p"]),
            Scenario(name: "≥3★", selection: all, filters: minRating, keys: ["5", "1", "4", "0"]),
            Scenario(name: "picks filter", selection: all, filters: picks, keys: ["3", "u", "p", "x"]),
            Scenario(name: "red filter", selection: all, filters: red, keys: ["3", "6", "7", "p"]),
            Scenario(name: "smart album", selection: Selection(type: .smart, id: "rated", name: "Rated"),
                     keys: ["4", "1", "p", "0", "5"]),
        ]
    }

    /// Each key on a photo of the list: the list is the one working it out again gives, nothing
    /// was worked out from every photo, it's a new list exactly when photos left, and the photo
    /// that left isn't looked for in it.
    @MainActor
    func testReviewKeysThatOnlyTakePhotosOutPatchTheList() {
        var left = 0, stayed = 0
        for chunk in [7, Int.max] {
            for pairs in [true, false] {
                for collapsed in [false, true] {
                    let app = makeApp(chunk: chunk, pairs: pairs, collapsed: collapsed)
                    app.smartAlbums = [SmartAlbum(id: "rated", name: "Rated", rule: SmartRule(conditions: [
                        SmartCondition(field: "rating", op: ">=", value: "2"),
                    ]), count: 0)]
                    for scenario in scenarios {
                        app.select(scenario.selection)
                        app.setFilters(scenario.filters)
                        for (number, key) in scenario.keys.enumerated() {
                            let context = "\(scenario.name), key \(key), chunks of \(chunk), pairs \(pairs), "
                                + "collapsed \(collapsed)"
                            let before = app.list.map(\.id)
                            guard !before.isEmpty else { XCTFail("\(context): photos listed"); break }
                            let target = before[[0, before.count / 2, before.count - 1][number % 3]]
                            app.setPrimary(target)
                            XCTAssertNotNil(app.listPosition(of: target), context)   // the hint names it
                            let (computations, identity) = (app.listComputations, app.listIdentity)
                            let lookups = app.listPositionScannedPhotos

                            XCTAssertTrue(app.handleKey(key, hasCommand: false), context)
                            let patched = shown(app.list)
                            XCTAssertEqual(app.listComputations, computations, "\(context): not worked out again")
                            let membershipChanged = Set(app.list.map(\.id)) != Set(before)
                            XCTAssertEqual(app.listIdentity != identity, membershipChanged,
                                           "\(context): a new list exactly when photos left")
                            XCTAssertEqual(app.listPositionScannedPhotos, lookups,
                                           "\(context): the photo that left isn't looked for")
                            if membershipChanged {
                                left += 1
                                XCTAssertFalse(app.list.contains { $0.id == target }, context)
                                XCTAssertNil(app.listPosition(of: target), context)
                                XCTAssertEqual(app.listPositionScannedPhotos, lookups, context)
                            } else {
                                stayed += 1
                            }

                            // the list as working it out again gives it
                            app.listCache = nil
                            app.uncollapsedListCache = nil
                            XCTAssertEqual(patched, shown(app.list), "\(context): as worked out again")
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(left, 50, "most keys took their photo out")
        XCTAssertGreaterThan(stayed, 30, "and some kept it in")
    }

    /// An edit that brings a photo into the list works it out again, as does a batch that also
    /// changes metadata, and a sort by rating, whose order a rating moves.
    @MainActor
    func testEditsThatBringPhotosInOrReorderWorkTheListOutAgain() {
        let app = makeApp(chunk: 7, pairs: true, collapsed: false)
        var minRating = Filters()
        minRating.minRating = 3
        app.setFilters(minRating)
        let listed = Set(app.list.map(\.id))
        let outside = app.assets.first { app.assetPairing.shows($0) && !listed.contains($0.id) }!
        var computations = app.listComputations
        XCTAssertTrue(app.setRating(5, on: [outside.id]))
        XCTAssertTrue(app.list.contains { $0.id == outside.id })
        XCTAssertEqual(app.listComputations, computations + 1, "a photo coming in")

        app.select(Selection(type: .lib, id: "unrated", name: "Unrated"))
        app.setFilters(Filters())
        let photo = app.list[3].id
        computations = app.listComputations
        XCTAssertTrue(app.mutate([photo]) { $0.rating = 2; $0.keywords = ["mixed"] })
        XCTAssertFalse(app.list.contains { $0.id == photo })
        XCTAssertEqual(app.listComputations, computations + 1, "review and metadata in one batch")

        app.setSort(Sort(field: .rating, descending: true))
        let unrated = app.list[0].id
        computations = app.listComputations
        XCTAssertTrue(app.setRating(1, on: [unrated]))
        XCTAssertFalse(app.list.contains { $0.id == unrated })
        XCTAssertEqual(app.listComputations, computations + 1, "a sort by rating")
    }

    /// A batch of more photos than one pass looks for at once, some leaving and some staying,
    /// with and without the list's index.
    @MainActor
    func testABatchTakesItsPhotosOutAtOnce() {
        for indexed in [false, true] {
            let app = makeApp(chunk: 7, pairs: true, collapsed: false)
            app.select(Selection(type: .lib, id: "unrated", name: "Unrated"))
            let ids = app.list.map(\.id)
            if indexed { _ = app.listPositions }
            let batch = Set(stride(from: 0, to: ids.count, by: 2).map { ids[$0] })
            XCTAssertGreaterThan(batch.count, AppState.listScanLimit)
            app.selectedIds = batch
            app.primaryId = ids[0]
            let computations = app.listComputations
            XCTAssertTrue(app.handleKey("p", hasCommand: false), "picks stay unrated")
            XCTAssertEqual(app.list.map(\.id), ids)
            app.selectedIds = batch
            app.primaryId = ids[0]
            if !indexed { app.listPositionsCache = nil }   // the batch is found by one pass
            XCTAssertTrue(app.handleKey("x", hasCommand: false), "rejects leave")
            XCTAssertEqual(app.list.map(\.id), ids.filter { !batch.contains($0) }, "indexed \(indexed)")
            XCTAssertEqual(app.listComputations, computations, "indexed \(indexed)")
            let patched = shown(app.list)
            app.listCache = nil
            app.uncollapsedListCache = nil
            XCTAssertEqual(patched, shown(app.list), "indexed \(indexed)")
        }
    }
}
