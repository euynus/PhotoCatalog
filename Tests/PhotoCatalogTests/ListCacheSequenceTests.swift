import XCTest
@testable import PhotoCatalog

/// Long seeded runs of what changes the photo list — review keys (on one photo or a batch, read
/// or not before the next step), undo and redo, a new collection, filter, search or sort, stacks
/// folded and opened — over RAW+JPEG pairs and a removed photo. After each step the list, the
/// positions it reports and the sidebar's counts are what a new AppState working them out afresh
/// gives: no cache kept through a step may show the wrong photos, or the right ones out of place.
final class ListCacheSequenceTests: CatalogTestCase {
    private let shot = Date(timeIntervalSince1970: 1_791_800_000)

    /// A fixed clock: the oracle counts relative dates at the same time as the app.
    private let now = Date(timeIntervalSince1970: 1_791_900_000)

    /// Photos of every rating, flag and color, ties in each sort key, keywords, RAW+JPEG pairs
    /// (each JPEG with its RAW's review fields) and a removed photo.
    private func library() -> [Asset] {
        var photos: [Asset] = []
        func photo(_ id: String, _ name: String, raw: Bool, index: Int, offset: TimeInterval) -> Asset {
            var asset = Asset(id: id, pid: 0, ori: "l", thumb: "", preview: "", filename: name,
                              type: raw ? "CR3" : "JPEG", isRaw: raw, folderId: "day", folderName: "Day",
                              date: shot.addingTimeInterval(offset), width: 6000, height: 4000, orientation: 1,
                              camera: "Canon EOS R5", lens: "", focal: 50, aperture: 4, shutter: "1/100", iso: 100,
                              colorSpace: "sRGB", fileMB: Double(index % 4), rating: (index * 7) % 6,
                              flag: [.none, .pick, .none, .reject, .none][index % 5],
                              keywords: index % 3 == 0 ? ["trip"] : [], title: "", caption: "", location: "",
                              gps: (0, 0), status: .ready, importedAt: shot.addingTimeInterval(Double(index % 3) * 3600),
                              localPath: scratch.appendingPathComponent(name).path)
            asset.colorLabel = [nil, .red, nil, .yellow][index % 4]
            return asset
        }
        for index in 0..<70 {
            let offset = Double(index / 2) * 60   // two photos a minute
            var single = photo("p\(index)", "IMG_\(index % 30).JPG", raw: false, index: index, offset: offset)
            single.deleted = index == 33
            photos.append(single)
            if index % 5 == 0 {
                photos.append(photo("r\(index)", "PAIR_\(index).CR3", raw: true, index: index, offset: offset + 1))
                photos.append(photo("r\(index)j", "PAIR_\(index).JPG", raw: false, index: index, offset: offset + 1))
            }
        }
        return photos
    }

    private let smart = SmartAlbum(id: "rated", name: "Rated", rule: SmartRule(conditions: [
        SmartCondition(field: "rating", op: ">=", value: "3"),
    ]), count: 0)

    private let album = Album(id: "album", name: "Album", assetIds: ["p1", "p2", "r10", "r10j", "p40", "p41", "p64"])

    @MainActor
    private func makeApp(_ photos: [Asset], pairs: Bool, chunk: Int) -> AppState {
        let app = AppState.selfCheckFixture()
        app.sidebarClock = { [now] in now }
        app.pairRawAndJpeg = pairs
        app.autoStackSeconds = nil
        app.assets = photos
        app.listChunk = chunk
        app.duplicateGroupsCache = []
        app.smartAlbums = [smart]
        app.albums = [album]
        return app
    }

    /// What a list shows of each photo, in its order: a photo kept with a stale rating shows too.
    private func shown(_ list: [Asset]) -> [String] {
        list.map { "\($0.id) \($0.rating) \($0.flag.rawValue) \($0.colorLabel?.rawValue ?? "-")" }
    }

    /// A new AppState with the same photos, stacks, collection, filters, search, sort and folded
    /// stacks, working everything out afresh.
    @MainActor
    private func oracle(of app: AppState) -> AppState {
        let other = makeApp(app.assets, pairs: app.pairRawAndJpeg, chunk: app.listChunk)
        other.duplicateGroupsCache = app.duplicateGroupsCache
        other.select(app.selection)
        other.setFilters(app.filters)
        other.setSearch(app.search)
        other.setSort(app.sort)
        other.collapsedStackIds = app.collapsedStackIds
        return other
    }

    @MainActor
    private func verify(_ app: AppState, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        let fresh = oracle(of: app)
        let list = app.list
        XCTAssertEqual(shown(list), shown(fresh.list), "\(context): the list", file: file, line: line)
        XCTAssertEqual(app.listPositions, AppState.positions(of: fresh.list), "\(context): positions", file: file, line: line)
        for id in ["p1", "p4", "r10", "r10j", "p33", "p69", list.first?.id, list.last?.id].compactMap({ $0 }) {
            XCTAssertEqual(app.listPosition(of: id), fresh.list.firstIndex { $0.id == id },
                           "\(context): \(id)'s position", file: file, line: line)
        }
        XCTAssertEqual(app.sidebarCounts, fresh.sidebarCounts, "\(context): sidebar counts", file: file, line: line)
        XCTAssertEqual(app.sidebarCounts, app.recountedSidebarCounts(), "\(context): as recounted", file: file, line: line)
        XCTAssertEqual(app.libraryCounts, fresh.libraryCounts, "\(context): library counts", file: file, line: line)
        XCTAssertEqual(app.cachesDifferingFromRecount(), [], "\(context): derived caches", file: file, line: line)
    }

    /// A small seeded generator, so a failure names a run that can be replayed.
    private struct Seeded {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    @MainActor
    func testSequencesOfListChangesListWhatAFreshRecomputeLists() {
        let selections = [Selection(type: .lib, id: "all", name: "All"), Selection(type: .lib, id: "unrated", name: "Unrated"),
                          Selection(type: .lib, id: "picks", name: "Picks"), Selection(type: .lib, id: "rejected", name: "Rejected"),
                          Selection(type: .smart, id: "rated", name: "Rated"), Selection(type: .album, id: "album", name: "Album"),
                          Selection(type: .keyword, id: "trip", name: "trip"), Selection(type: .lib, id: "missing", name: "Missing")]
        var minRating = Filters(), picks = Filters(), red = Filters()
        minRating.minRating = 3
        picks.flag = Flag.pick.rawValue
        red.color = ColorLabel.red.rawValue
        let filterChoices = [Filters(), Filters(), minRating, picks, red]
        let searches = ["", "", "", "img_1", "pair"]
        let sorts = [Sort(), Sort(field: .rating, descending: true), Sort(field: .rating, descending: false),
                     Sort(field: .name, descending: false), Sort(field: .size, descending: true),
                     Sort(field: .imported, descending: false)]
        let keys = ["0", "1", "2", "3", "4", "5", "p", "x", "u", "6", "7"]
        var steps = 0
        for seed: UInt64 in [1, 2, 3, 4] {
            for pairs in [true, false] {
                for chunk in [7, Int.max] {
                    var random = Seeded(state: seed)
                    let app = makeApp(library(), pairs: pairs, chunk: chunk)
                    let undo = UndoManager()
                    undo.groupsByEvent = false   // no run loop here to close event groups
                    app.undoManager = undo
                    // stacks of three shown photos, some of which review keys take out of lists
                    let live = app.assets.filter(app.assetPairing.shows)
                    app.duplicateGroupsCache = stride(from: 0, to: live.count - 3, by: 9).map { start in
                        DuplicateGroup(id: "dg\(start)", method: "contentHash", score: 1, items: Array(live[start..<start + 3]))
                    }
                    for step in 0..<120 {
                        let context = "seed \(seed), pairs \(pairs), chunk \(chunk), step \(step)"
                        let photos = app.assets.filter { !$0.deleted }
                        switch random.next(14) {
                        case 0: app.select(selections[random.next(selections.count)])
                        case 1: app.setFilters(filterChoices[random.next(filterChoices.count)])
                        case 2: app.setSearch(searches[random.next(searches.count)])
                        case 3, 4: app.setSort(sorts[random.next(sorts.count)])
                        case 5:
                            app.setAllStacksCollapsed(random.next(2) == 0)
                        case 6:
                            let stack = app.photoStacks[random.next(app.photoStacks.count)]
                            app.toggleStack(containing: stack.assetIds[0])
                        case 7, 8, 9:
                            // a key on a photo of the list, as the grid sends it
                            let listed = app.list
                            guard !listed.isEmpty else { break }
                            app.selectedIds = []
                            app.setPrimary(listed[random.next(listed.count)].id)
                            undo.beginUndoGrouping()
                            _ = app.handleKey(keys[random.next(keys.count)], hasCommand: false)
                            undo.endUndoGrouping()
                        case 10:
                            // a batch, keyed with no list read in between
                            let batch = Set((0..<(1 + random.next(12))).map { _ in photos[random.next(photos.count)].id })
                            undo.beginUndoGrouping()
                            switch random.next(3) {
                            case 0: app.setRating(random.next(6), on: app.withCompanions(batch))
                            case 1: app.setFlag([.none, .pick, .reject][random.next(3)], on: app.withCompanions(batch))
                            default: app.setColor([nil, .red, .yellow][random.next(3)], on: app.withCompanions(batch))
                            }
                            undo.endUndoGrouping()
                        case 11, 12:
                            if undo.canUndo { undo.undo() }
                        default:
                            if undo.canRedo { undo.redo() }
                        }
                        steps += 1
                        // some steps run on without a read of the list in between
                        if random.next(3) != 0 { verify(app, context) }
                    }
                    verify(app, "seed \(seed), pairs \(pairs), chunk \(chunk), at the end")
                }
            }
        }
        XCTAssertEqual(steps, 4 * 2 * 2 * 120)
    }
}
