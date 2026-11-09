import XCTest
@testable import PhotoCatalog

/// Long seeded runs of what changes the photo list — review keys (on one photo or a batch, read
/// or not before the next step), undo and redo, a new collection (Recently Imported too), filter
/// (relative dates too), search or sort, stacks folded and opened, RAW+JPEG pairing turned on or
/// off, new photos added, photos moved to the Trash and back, renamed or gone offline, and the
/// clock passing midnight — over RAW+JPEG pairs and a removed photo. After each step the list, the
/// positions it reports and the sidebar's counts are what a new AppState working them out afresh
/// gives: no cache kept through a step may show the wrong photos, or the right ones out of place.
final class ListCacheSequenceTests: CatalogTestCase {
    /// Where the sidebar clock starts. It moves on in steps of six hours, past midnight now and
    /// then; the oracle counts relative dates at the same time as the app.
    private let start = Date(timeIntervalSince1970: 1_791_900_000)

    /// When the photos were imported, against the real clock Recently Imported counts from.
    private let imported = Date()

    private func photo(_ id: String, _ name: String, raw: Bool, index: Int, taken: Date) -> Asset {
        var asset = Asset(id: id, pid: 0, ori: "l", thumb: "", preview: "", filename: name,
                          type: raw ? "CR3" : "JPEG", isRaw: raw, folderId: "day", folderName: "Day",
                          date: taken, width: 6000, height: 4000, orientation: 1,
                          camera: "Canon EOS R5", lens: "", focal: 50, aperture: 4, shutter: "1/100", iso: 100,
                          colorSpace: "sRGB", fileMB: Double(index % 4), rating: (index * 7) % 6,
                          flag: [.none, .pick, .none, .reject, .none][index % 5],
                          keywords: index % 3 == 0 ? ["trip"] : [], title: "", caption: "", location: "",
                          gps: (0, 0), status: .ready,
                          // over 30 days: some in Recently Imported's 14, some not
                          importedAt: imported.addingTimeInterval(-Double(index % 30) * 86_400 - 60),
                          localPath: scratch.appendingPathComponent(name).path)
        asset.colorLabel = [nil, .red, nil, .yellow][index % 4]
        return asset
    }

    /// Photos of every rating, flag and color, ties in each sort key, keywords, RAW+JPEG pairs
    /// (each JPEG with its RAW's review fields), capture days around the clock's and a removed photo.
    private func library() -> [Asset] {
        var photos: [Asset] = []
        for index in 0..<70 {
            // two photos a minute, on days half a day apart from three days before the clock's
            // start to five after, the days it passes through
            let taken = start.addingTimeInterval(Double(index / 2) * 60 + Double(index % 17 - 6) * 43_200)
            var single = photo("p\(index)", "IMG_\(index % 30).JPG", raw: false, index: index, taken: taken)
            single.deleted = index == 33
            photos.append(single)
            if index % 5 == 0 {
                photos.append(photo("r\(index)", "PAIR_\(index).CR3", raw: true, index: index, taken: taken + 1))
                photos.append(photo("r\(index)j", "PAIR_\(index).JPG", raw: false, index: index, taken: taken + 1))
            }
        }
        return photos
    }

    private let smart = SmartAlbum(id: "rated", name: "Rated", rule: SmartRule(conditions: [
        SmartCondition(field: "rating", op: ">=", value: "3"),
    ]), count: 0)

    private let album = Album(id: "album", name: "Album", assetIds: ["p1", "p2", "r10", "r10j", "p40", "p41", "p64"])

    @MainActor
    private func makeApp(_ photos: [Asset], pairs: Bool, chunk: Int, clock: Clock) -> AppState {
        let app = AppState.selfCheckFixture()
        app.sidebarClock = { clock.now }
        app.recentImportDays = 14
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
        let other = makeApp(app.assets, pairs: app.pairRawAndJpeg, chunk: app.listChunk, clock: Clock(app.sidebarClock()))
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
                          Selection(type: .keyword, id: "trip", name: "trip"), Selection(type: .lib, id: "missing", name: "Missing"),
                          Selection(type: .lib, id: "recent", name: "Recently Imported")]
        var minRating = Filters(), picks = Filters(), red = Filters(), today = Filters(), yesterday = Filters()
        var lastWeekRated = Filters()
        minRating.minRating = 3
        picks.flag = Flag.pick.rawValue
        red.color = ColorLabel.red.rawValue
        today.date = "today"
        yesterday.date = "yesterday"
        lastWeekRated.date = "last7Days"
        lastWeekRated.minRating = 2
        let filterChoices = [Filters(), Filters(), minRating, picks, red, today, yesterday, lastWeekRated]
        // names that pair with photos there (a RAW hiding JPEGs, a JPEG behind a RAW) or not
        let jpegNames = ["IMG_3.JPG", "IMG_31.JPG", "PAIR_10.JPG", "PAIR_15.JPG", "PAIR_99.JPG", "NEW.JPG"]
        let rawNames = ["IMG_3.CR3", "IMG_7.CR3", "PAIR_15.CR3", "PAIR_99.CR3"]
        let searches = ["", "", "", "img_1", "pair"]
        let sorts = [Sort(), Sort(field: .rating, descending: true), Sort(field: .rating, descending: false),
                     Sort(field: .name, descending: false), Sort(field: .size, descending: true),
                     Sort(field: .imported, descending: false)]
        let keys = ["0", "1", "2", "3", "4", "5", "p", "x", "u", "6", "7"]
        var steps = 0
        var midnights = 0, structural = 0
        for seed: UInt64 in [1, 2, 3, 4] {
            for pairs in [true, false] {
                for chunk in [7, Int.max] {
                    var random = Seeded(state: seed)
                    let clock = Clock(start)
                    let app = makeApp(library(), pairs: pairs, chunk: chunk, clock: clock)
                    var added = 0
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
                        switch random.next(23) {
                        case 0: app.select(selections[random.next(selections.count)])
                        case 1, 19: app.setFilters(filterChoices[random.next(filterChoices.count)])
                        case 2: app.setSearch(searches[random.next(searches.count)])
                        case 3, 4: app.setSort(sorts[random.next(sorts.count)])
                        case 5:
                            app.setAllStacksCollapsed(random.next(2) == 0)
                        case 6:
                            guard !app.photoStacks.isEmpty else { break }
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
                        case 13:
                            if undo.canRedo { undo.redo() }
                        case 14:
                            app.pairRawAndJpeg.toggle()
                        case 15:
                            // new photos, as an import batch or a tethered shot adds them: one may
                            // pair with a RAW already there, or bring a RAW of its own
                            added += 1
                            let raw = random.next(2) == 0
                            let name = raw ? rawNames[random.next(rawNames.count)] : jpegNames[random.next(jpegNames.count)]
                            var new = [photo("n\(added)", name, raw: raw, index: added + Int(seed),
                                             taken: clock.now.addingTimeInterval(-Double(random.next(3)) * 43_200))]
                            if random.next(2) == 0 {
                                new.append(photo("n\(added)r", "NEW_\(added).CR3", raw: true, index: added, taken: new[0].date))
                                new.append(photo("n\(added)j", "NEW_\(added).JPG", raw: false, index: added, taken: new[0].date))
                            }
                            app.appendAssets(new)
                            structural += 1
                        case 16, 17, 18:
                            // a photo moved to the Trash or back, renamed (into or out of a pair), or
                            // gone offline, missing or back
                            let all = app.assets
                            let batch = Set((0..<(1 + random.next(4))).map { _ in all[random.next(all.count)].id })
                            let kind = random.next(3)
                            let edits = app.positions(of: batch).map { offset -> (offset: Int, asset: Asset) in
                                var asset = all[offset]
                                switch kind {
                                case 0: asset.deleted.toggle()
                                case 1:
                                    let names = asset.isRaw ? rawNames : jpegNames
                                    let name = names[random.next(names.count)]
                                    asset.filename = name
                                    asset.localPath = scratch.appendingPathComponent(name).path
                                default: asset.status = [.ready, .offline, .missing][random.next(3)]
                                }
                                return (offset, asset)
                            }
                            app.replaceInPlace(edits)
                            structural += 1
                        default:
                            let day = CaptureDates.startOfToday(now: clock.now)
                            clock.now = clock.now.addingTimeInterval(6 * 3_600)
                            if CaptureDates.startOfToday(now: clock.now) != day { midnights += 1 }
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
        XCTAssertGreaterThan(midnights, 10, "the clock passed midnight")
        XCTAssertGreaterThan(structural, 100, "photos were added, trashed, renamed and taken offline")
    }
}

/// The sidebar clock, which a run moves on.
private final class Clock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}
