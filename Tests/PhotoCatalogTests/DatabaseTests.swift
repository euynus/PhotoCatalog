import Foundation
import XCTest
@testable import PhotoCatalog

final class DatabaseTests: XCTestCase {
    func testCatalogLoadsAssetsInDefaultCaptureOrder() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-capture-order-\(UUID().uuidString)")
        let package = directory.appendingPathComponent("Library.photolibrary")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try CatalogStore(packageURL: package)
        var oldest = DemoData.assets[0]
        oldest.date = Date(timeIntervalSince1970: 1_000)
        oldest.isDemo = false
        var newest = DemoData.assets[1]
        newest.date = Date(timeIntervalSince1970: 3_000)
        newest.isDemo = false
        var middle = DemoData.assets[2]
        middle.date = Date(timeIntervalSince1970: 2_000)
        middle.isDemo = false
        try store.upsert([middle, oldest, newest])

        XCTAssertEqual(try store.loadAssets().map(\.id), [newest.id, middle.id, oldest.id])
    }

    func testCatalogLoadsStableAssetPagesWithoutOverlap() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-asset-pages-\(UUID().uuidString)")
        let package = directory.appendingPathComponent("Library.photolibrary")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try CatalogStore(packageURL: package)
        var assets = Array(DemoData.assets.prefix(6))
        for index in assets.indices {
            assets[index].date = Date(timeIntervalSince1970: Double(index / 2 + 1) * 1_000)
            assets[index].isDemo = false
            assets[index].deleted = false
        }
        try store.upsert(Array(assets.reversed()))

        let first = try store.loadAssetPage(offset: 0, limit: 2)
        let second = try store.loadAssetPage(offset: 2, limit: 2)
        let third = try store.loadAssetPage(offset: 4, limit: 2)
        let expected = assets.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id > $1.id
        }.map(\.id)

        XCTAssertEqual(first.totalCount, 6)
        XCTAssertEqual(first.offset, 0)
        XCTAssertTrue(first.hasMore)
        XCTAssertEqual(first.assets.map(\.id) + second.assets.map(\.id) + third.assets.map(\.id), expected)
        XCTAssertFalse(third.hasMore)
    }

    func testCatalogPageAppliesCollectionFiltersSearchAndSort() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-filtered-pages-\(UUID().uuidString)")
        let package = directory.appendingPathComponent("Library.photolibrary")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try CatalogStore(packageURL: package)
        var assets = Array(DemoData.assets.prefix(4))
        for index in assets.indices {
            assets[index].isDemo = false
            assets[index].deleted = false
            assets[index].rating = [5, 3, 4, 4][index]
            assets[index].flag = index == 2 ? .none : .pick
            assets[index].keywords = index == 2 ? ["城市"] : ["旅行"]
            assets[index].project = index < 2 ? "Editorial" : "Archive"
            assets[index].title = index == 1 ? "Other Frame" : "Golden Needle \(index)"
        }
        try store.upsert(assets)
        try store.saveAlbum(Album(id: "album-page", name: "Page", assetIds: assets.map(\.id)))

        var filters = Filters()
        filters.minRating = 4
        filters.flag = Flag.pick.rawValue
        let filtered = try store.loadAssetPage(
            matching: AssetQuery(scope: .album(id: "album-page"), filters: filters,
                                 search: "Needle", sort: Sort(field: .rating, descending: false)),
            limit: 10
        )
        XCTAssertEqual(filtered.assets.map(\.id), [assets[3].id, assets[0].id])
        XCTAssertEqual(filtered.totalCount, 2)

        let shortSearch = try store.loadAssetPage(
            matching: AssetQuery(search: "dl", sort: Sort(field: .name, descending: false)),
            limit: 10
        )
        XCTAssertEqual(Set(shortSearch.assets.map(\.id)), Set([assets[0].id, assets[2].id, assets[3].id]))

        let smartRule = SmartRule(match: "all", conditions: [
            SmartCondition(field: "keywords", op: "包含", value: "旅行"),
            SmartCondition(field: "rating", op: ">=", value: "4"),
        ])
        let smart = try store.loadAssetPage(
            matching: AssetQuery(scope: .smart(rule: smartRule)),
            limit: 10
        )
        XCTAssertEqual(Set(smart.assets.map(\.id)), Set([assets[0].id, assets[3].id]))

        let keyword = try store.loadAssetPage(
            matching: AssetQuery(scope: .keyword("旅行")),
            limit: 10
        )
        XCTAssertEqual(Set(keyword.assets.map(\.id)), Set([assets[0].id, assets[1].id, assets[3].id]))
    }

    func testQueryMapDecodesRowsInOrderAndDropsNilTransforms() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-query-map-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let database = try Database(path: directory.appendingPathComponent("catalog.sqlite").path)
        try database.execChecked("CREATE TABLE samples (id INTEGER PRIMARY KEY, name TEXT, score REAL, payload BLOB);")
        try database.run(
            "INSERT INTO samples (id, name, score, payload) VALUES (?, ?, ?, ?);",
            [.int(1), .text("first"), .double(1.5), .blob(Data([0x01]))]
        )
        try database.run(
            "INSERT INTO samples (id, name, score, payload) VALUES (?, ?, ?, ?);",
            [.int(2), .text("skip"), .double(2.5), .blob(Data([0x02]))]
        )
        try database.run(
            "INSERT INTO samples (id, name, score, payload) VALUES (?, ?, ?, ?);",
            [.int(3), .text("third"), .double(3.5), .blob(Data([0x03]))]
        )

        let decoded: [(Int, String, Double, Data)] = try database.queryMap(
            "SELECT id, name, score, payload FROM samples ORDER BY id;"
        ) { row in
            guard row.text("name") != "skip",
                  let id = row.int("id"),
                  let name = row.text("name"),
                  let score = row.double("score"),
                  let payload = row.blob("payload") else { return nil }
            return (id, name, score, payload)
        }

        XCTAssertEqual(decoded.map(\.0), [1, 3])
        XCTAssertEqual(decoded.map(\.1), ["first", "third"])
        XCTAssertEqual(decoded.map(\.2), [1.5, 3.5])
        XCTAssertEqual(decoded.map(\.3), [Data([0x01]), Data([0x03])])
    }
}
