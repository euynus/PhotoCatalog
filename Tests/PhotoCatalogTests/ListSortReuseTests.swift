import XCTest
@testable import PhotoCatalog

/// A change of sort lists the same photos in another order: it sorts again the photos the last
/// pass over the catalog found, without testing every photo again, and lists them as working the
/// list out afresh does.
final class ListSortReuseTests: CatalogTestCase {
    private let shot = Date(timeIntervalSince1970: 1_791_800_000)

    /// Photos with ties in every sort key, keywords, RAW+JPEG pairs and a removed photo.
    private func library() -> [Asset] {
        (0..<160).flatMap { index -> [Asset] in
            let raw = index % 7 == 0
            let name = ["IMG_\(index % 40).\(raw ? "CR3" : "JPG")", "img_\(index).jpg", "Shot \(index % 9).JPG"][index % 3]
            var asset = Asset(id: "p\(index)", pid: 0, ori: "l", thumb: "", preview: "", filename: name,
                              type: raw ? "CR3" : "JPEG", isRaw: raw, folderId: "day", folderName: "Day",
                              date: shot.addingTimeInterval(Double(index % 23) * 60), width: 6000, height: 4000,
                              orientation: 1, camera: "Canon EOS R5", lens: "", focal: 50, aperture: 4,
                              shutter: "1/100", iso: 100, colorSpace: "sRGB", fileMB: Double(index % 5),
                              rating: index % 6, flag: .none, keywords: index % 3 == 0 ? ["trip"] : [],
                              title: "", caption: "", location: "", gps: (0, 0), status: .ready,
                              importedAt: shot.addingTimeInterval(Double(index % 4) * 3600),
                              localPath: scratch.appendingPathComponent(name).path)
            asset.deleted = index == 50
            guard raw else { return [asset] }
            let jpeg = Asset(id: "p\(index)j", pid: 0, ori: "l", thumb: "", preview: "", filename: "IMG_\(index % 40).JPG",
                         type: "JPEG", isRaw: false, folderId: "day", folderName: "Day", date: asset.date,
                         width: 6000, height: 4000, orientation: 1, camera: "Canon EOS R5", lens: "", focal: 50,
                         aperture: 4, shutter: "1/100", iso: 100, colorSpace: "sRGB", fileMB: 1, rating: asset.rating,
                         flag: .none, keywords: asset.keywords, title: "", caption: "", location: "", gps: (0, 0),
                         status: .ready, importedAt: asset.importedAt,
                         localPath: scratch.appendingPathComponent("IMG_\(index % 40).JPG").path)
            return [asset, jpeg]
        }
    }

    private let smart = SmartAlbum(id: "smart", name: "Smart", rule: SmartRule(match: "all", conditions: [
        SmartCondition(field: "keywords", op: "包含", value: "trip"), SmartCondition(field: "rating", op: ">=", value: "1"),
    ]), count: 0)

    @MainActor
    private func makeApp(_ photos: [Asset]) -> AppState {
        let app = AppState.selfCheckFixture()
        app.pairRawAndJpeg = true
        app.assets = photos
        app.listChunk = 7
        app.duplicateGroupsCache = []
        app.smartAlbums = [smart]
        return app
    }

    /// The list a new AppState works out for the same photos, collection, filters, search and sort.
    @MainActor
    private func fresh(like app: AppState) -> [String] {
        let other = makeApp(app.assets)
        other.select(app.selection)
        other.setFilters(app.filters)
        other.setSearch(app.search)
        other.setSort(app.sort)
        return other.list.map(\.id)
    }

    @MainActor
    func testASortChangeSortsThePhotosTheLastPassFound() {
        let app = makeApp(library())
        var rated = Filters()
        rated.minRating = 2
        let all = Selection(type: .lib, id: "all", name: "All")
        let cases: [(String, Selection, Filters, String)] = [
            ("a filter", all, rated, ""),
            ("a search", all, Filters(), "img_1"),
            ("a smart album", Selection(type: .smart, id: "smart", name: "Smart"), Filters(), ""),
            ("a smart album, filtered and searched", Selection(type: .smart, id: "smart", name: "Smart"), rated, "img"),
        ]
        let sorts = [Sort(field: .name, descending: false), Sort(field: .name, descending: true),
                     Sort(field: .rating, descending: true), Sort(field: .rating, descending: false),
                     Sort(field: .size, descending: false), Sort(field: .imported, descending: true),
                     Sort(field: .capture, descending: false), Sort()]
        for (name, selection, filters, search) in cases {
            app.setSort(Sort())
            app.select(selection)
            app.setFilters(filters)
            app.setSearch(search)
            let listed = app.list.map(\.id)
            let passes = app.listFilterPasses
            XCTAssertFalse(listed.isEmpty, name)
            for sort in sorts {
                app.setSort(sort)
                XCTAssertEqual(app.list.map(\.id), fresh(like: app), "\(name), \(sort)")
                XCTAssertEqual(Set(app.list.map(\.id)), Set(listed), "\(name), \(sort): the same photos")
            }
            XCTAssertEqual(app.listFilterPasses, passes, "\(name): no pass for a new order")
        }
    }

    /// Folded stacks and a new order together reuse the pass; any change of the photos, and the
    /// moving cutoff of Recently Imported, take a new one.
    @MainActor
    func testANewPassFollowsAChangeOfThePhotos() {
        let app = makeApp(library())
        app.select(Selection(type: .smart, id: "smart", name: "Smart"))
        let members = app.list
        app.duplicateGroupsCache = [DuplicateGroup(id: "dg", method: "contentHash", score: 1, items: Array(members[2..<5]))]
        _ = app.list
        var passes = app.listFilterPasses
        app.setAllStacksCollapsed(true)
        app.setSort(Sort(field: .name, descending: false))
        let folded = app.list.map(\.id)
        XCTAssertEqual(app.listFilterPasses, passes, "folded and sorted again")
        XCTAssertLessThan(folded.count, fresh(like: app).count, "a stack folded")
        // as worked out afresh
        (app.matchingPositionsCache, app.listCache, app.uncollapsedListCache) = (nil, nil, nil)
        XCTAssertEqual(app.list.map(\.id), folded)
        passes = app.listFilterPasses
        app.setAllStacksCollapsed(false)
        XCTAssertEqual(app.list.map(\.id), fresh(like: app))
        XCTAssertEqual(app.listFilterPasses, passes)

        // a structural change of the photos: their positions may have moved
        app.assets = app.assets.reversed()
        app.setSort(Sort(field: .size, descending: true))
        XCTAssertEqual(app.list.map(\.id), fresh(like: app))
        XCTAssertEqual(app.listFilterPasses, passes + 1, "the photos changed")

        passes = app.listFilterPasses
        app.select(Selection(type: .lib, id: "recent", name: "Recent"))
        _ = app.list
        app.setSort(Sort(field: .name, descending: true))
        XCTAssertEqual(app.list.map(\.id), fresh(like: app))
        XCTAssertEqual(app.listFilterPasses, passes + 2, "Recently Imported tests its photos again")
    }
}
