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

    /// Photos with every kind of tie a sort meets (capture and import times, ratings, sizes,
    /// names equal but for case or leading zeros, names past the sort key's packed bytes),
    /// RAW+JPEG pairs, removed photos and missing files, in two folders.
    private func variedLibrary(_ count: Int) -> [Asset] {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        var photos: [Asset] = []
        for index in 0..<count {
            let names = ["IMG_\(next(40)).JPG", "img_\(next(40)).jpg", "IMG_00\(next(9)).CR3", "Shot \(next(20)).heic",
                         "a\(next(3))b\(next(3)).JPG", "très \(next(5)).JPG",
                         "IMG_\(next(9))_a_name_longer_than_the_packed_bytes_\(next(3)).JPG"]
            let name = names[next(names.count)]
            var asset = photo("p\(index)", name, raw: name.hasSuffix(".CR3"), offset: Double(next(30)) * 60,
                              rating: next(6))
            asset.importedAt = shot.addingTimeInterval(Double(next(5)) * 3600)
            asset.fileMB = Double(next(8)) / 2
            asset.flag = [.none, .none, .pick, .reject][next(4)]
            asset.colorLabel = next(5) == 0 ? .red : nil
            asset.keywords = next(3) == 0 ? ["trip"] : next(2) == 0 ? ["home", "trip"] : []
            asset.project = next(4) == 0 ? "Wedding" : ""
            asset.folderId = next(3) == 0 ? "other" : "day"
            asset.deleted = next(25) == 0
            asset.status = next(15) == 0 ? .missing : .ready
            photos.append(asset)
            if index % 9 == 0 {
                // a RAW and the JPEG shot with it, both under one name
                let raw = photo("pair\(index)", "PAIR_\(index).CR3", raw: true, offset: Double(next(30)) * 60,
                                rating: next(6))
                var jpeg = photo("pair\(index)j", "PAIR_\(index).JPG", raw: false, rating: raw.rating)
                jpeg.date = raw.date
                jpeg.status = index % 2 == 0 ? .missing : .ready
                photos += [raw, jpeg]
            }
        }
        return photos
    }

    /// The list's sort as it was: indices sorted by precomputed keys, ties in collection order.
    static func referenceSorted(_ assets: [Asset], by sort: Sort) -> [Asset] {
        let descending = sort.descending
        var order = Array(assets.indices)
        if sort.field == .name {
            let keys = assets.map { FileNameSortKey($0.filename) }
            order.sort { i, j in
                if keys[i] == keys[j] { return i < j }
                return descending ? keys[j] < keys[i] : keys[i] < keys[j]
            }
        } else {
            let keys: [Double] = switch sort.field {
            case .capture: assets.map { $0.date.timeIntervalSince1970 }
            case .imported: assets.map { $0.importedAt.timeIntervalSince1970 }
            case .rating: assets.map { Double($0.rating) }
            case .size: assets.map(\.fileMB)
            case .name: []
            }
            order.sort { i, j in
                if keys[i] == keys[j] { return i < j }
                return descending ? keys[i] > keys[j] : keys[i] < keys[j]
            }
        }
        return order.map { assets[$0] }
    }

    /// Every collection, filter and sort lists the photos one pass over the catalog finds,
    /// sorted by their keys with ties in catalog order.
    @MainActor
    func testListIsTheCollectionsPhotosFilteredAndSortedWithTiesInCatalogOrder() throws {
        let app = AppState.selfCheckFixture()
        app.pairRawAndJpeg = true
        let photos = variedLibrary(400)
        app.assets = photos
        app.duplicateGroupsCache = []
        app.folders = [Folder(id: "day", name: "Day"), Folder(id: "other", name: "Other")]
        let members = Set(photos.indices.filter { $0 % 3 == 0 }.map { photos[$0].id })
        app.albums = [Album(id: "album", name: "Album", assetIds: Array(members))]
        let smartRule = SmartRule(match: "all", conditions: [SmartCondition(field: "rating", op: ">=", value: "2"),
                                                             SmartCondition(field: "keywords", op: "包含", value: "TRIP")])
        app.smartAlbums = [SmartAlbum(id: "smart", name: "Smart", rule: smartRule, count: 0)]
        let pairing = app.assetPairing
        XCTAssertGreaterThan(pairing.primaryByCompanion.count, 20, "the library has pairs")

        let collections: [(Selection, (Asset) -> Bool)] = [
            (Selection(type: .lib, id: "all", name: "All"), { _ in true }),
            (Selection(type: .keyword, id: "trip", name: "trip"), { $0.keywords.contains("trip") }),
            (Selection(type: .folder, id: "other", name: "Other"), { $0.folderId == "other" }),
            (Selection(type: .album, id: "album", name: "Album"), { members.contains($0.id) }),
            (Selection(type: .smart, id: "smart", name: "Smart"), { SmartMatcher.matches($0, smartRule) }),
            (Selection(type: .project, id: "Wedding", name: "Wedding"), { $0.project == "Wedding" }),
            (Selection(type: .lib, id: "unrated", name: "Unrated"), { $0.rating == 0 && $0.flag != .reject }),
            (Selection(type: .lib, id: "picks", name: "Picks"), { $0.flag == .pick }),
            (Selection(type: .lib, id: "missing", name: "Missing"), { $0.status == .missing || $0.status == .offline }),
        ]
        var minRating = Filters(), picks = Filters(), raws = Filters()
        minRating.minRating = 2
        picks.flag = Flag.pick.rawValue
        raws.type = "RAW"
        let filters: [(Filters, String, (Asset) -> Bool)] = [
            (Filters(), "", { _ in true }),
            (minRating, "", { $0.rating >= 2 }),
            (picks, "", { $0.flag == .pick }),
            (raws, "", { $0.isRaw }),
            (Filters(), "img_1", { $0.searchHaystack.localizedStandardContains("img_1") }),
            (minRating, "ÉS", { $0.rating >= 2 && $0.searchHaystack.localizedStandardContains("ÉS") }),
        ]
        var checked = 0
        // in chunks and sort runs that split everywhere, and in one pass and one run
        for chunk in [7, 64, .max] {
            app.listChunk = chunk
            app.assets = app.assets
            for (selection, belongs) in collections {
                app.select(selection)
                // Missing / Offline lists every file; elsewhere a RAW's JPEG is behind its tile
                let shows = (selection.id == "missing" ? AssetPairing.empty : pairing).shows
                for (filter, search, passes) in filters {
                    app.setFilters(filter)
                    app.setSearch(search)
                    let matching = photos.filter { shows($0) && belongs($0) && passes($0) }
                    for field in Sort.Field.allCases {
                        for descending in [false, true] {
                            let sort = Sort(field: field, descending: descending)
                            app.setSort(sort)
                            XCTAssertEqual(app.list.map(\.id), Self.referenceSorted(matching, by: sort).map(\.id),
                                           "\(selection.id), \(filter), “\(search)”, \(sort), chunks of \(chunk)")
                            checked += matching.isEmpty ? 0 : 1
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 1_200, "most combinations list some photos")

        // no photos at all, and fewer than one chunk
        app.listChunk = 7
        app.select(Selection(type: .lib, id: "all", name: "All"))
        app.setFilters(Filters())
        app.setSearch("")
        app.setSort(Sort())
        app.assets = []
        XCTAssertEqual(app.list.count, 0)
        app.assets = Array(photos.prefix(5))
        XCTAssertEqual(app.list.map(\.id),
                       Self.referenceSorted(Array(photos.prefix(5)).filter(app.assetPairing.shows), by: Sort()).map(\.id))
    }

    /// The list looks up only non-RAW files in the pairing: it hides JPEG and HEIC files behind
    /// their RAW, never a RAW, whatever files share a name.
    func testPairingNeverHidesARaw() throws {
        let groups = [["A.CR3", "A.JPG"], ["B.CR3", "B.HEIC"], ["C.CR3", "C.JPG", "C.HEIC"], ["D.CR3", "D.DNG", "D.JPG"],
                      ["E.DNG", "e.jpg"], ["F.CR3", "F.ARW"], ["G.JPG", "G.HEIC"], ["H.NEF", "h.jpeg"]]
        let rawExtensions: Set<String> = ["CR3", "DNG", "ARW", "NEF"]
        let photos = groups.flatMap { $0 }.map { name in
            photo(name, name, raw: rawExtensions.contains(String(name.split(separator: ".").last!)))
        }
        let pairing = AssetPairing.rawJpeg(photos)
        XCTAssertEqual(pairing.primaryByCompanion.count, 6, "JPEG and HEIC files with one RAW of their name")
        XCTAssertTrue(Set(photos.filter(\.isRaw).map(\.id)).isDisjoint(with: pairing.primaryByCompanion.keys))
    }

    /// Folding stacks hides all but each stack's first photo in the list, and opening them shows
    /// the list as it was, without working out the photos again.
    @MainActor
    func testFoldingStacksListsEachStacksFirstPhoto() throws {
        let app = AppState.selfCheckFixture()
        app.pairRawAndJpeg = true
        let photos = variedLibrary(120)
        app.assets = photos
        app.listChunk = 7
        let live = photos.filter(app.assetPairing.shows)
        let groups = stride(from: 0, to: 60, by: 6).map { start in
            DuplicateGroup(id: "dg\(start)", method: "contentHash", score: 1, items: Array(live[start..<start + 3]))
        }
        app.duplicateGroupsCache = groups
        app.select(Selection(type: .lib, id: "all", name: "All"))
        app.setSort(Sort(field: .name, descending: false))
        let unfolded = app.list.map(\.id)
        XCTAssertEqual(unfolded, Self.referenceSorted(live, by: Sort(field: .name, descending: false)).map(\.id))

        let computations = app.listComputations
        app.setAllStacksCollapsed(true)
        let hidden = Set(groups.flatMap { group in
            // each stack shows the photo of it the list comes to first
            let ids = Set(group.items.map(\.id))
            return unfolded.filter(ids.contains).dropFirst()
        })
        XCTAssertEqual(hidden.count, 20)
        XCTAssertEqual(app.list.map(\.id), unfolded.filter { !hidden.contains($0) })

        app.toggleStack(containing: groups[0].items[0].id)
        let opened = Set(groups[0].items.map(\.id))
        XCTAssertEqual(app.list.map(\.id), unfolded.filter { !hidden.contains($0) || opened.contains($0) })
        app.setAllStacksCollapsed(false)
        XCTAssertEqual(app.list.map(\.id), unfolded)
        XCTAssertEqual(app.listComputations, computations, "folding and opening stacks reuse the photos before folding")
    }
}
