import XCTest
@testable import PhotoCatalog

/// Ratings, flags and colour labels of any number of photos are saved by one statement per
/// column: what the catalog loads again is what was set, and the connection keeps a bounded
/// number of statements however many batch sizes it has seen.
final class AssetColumnUpdateTests: CatalogTestCase {
    private let rows = 1_500

    func testBatchesOfEverySizeLoadAsSet() throws {
        let package = scratch.appendingPathComponent("Library.photolibrary")
        let store = try makeCatalog(at: package, rows: rows)
        var expected = Dictionary(uniqueKeysWithValues: try store.loadAssets().map {
            ($0.id, (rating: $0.rating, flag: $0.flag, color: $0.colorLabel))
        })
        let all = expected.keys.sorted()
        let colors: [ColorLabel?] = ColorLabel.allCases + [nil]
        for (round, size) in [1, 2, 500, 501, 1_200].enumerated() {
            // a different run of photos each round, so each batch overwrites some of the last
            let ids = Set((0..<size).map { all[($0 * 7 + round * 131) % all.count] })
            let rating = round % 5 + 1
            let flag: Flag = round.isMultiple(of: 2) ? .pick : .reject
            let color = colors[round % colors.count]
            try store.updateRatings(rating, assetIDs: ids)
            try store.updateFlags(flag, assetIDs: ids)
            try store.updateColorLabels(color, assetIDs: ids)
            for id in ids { expected[id] = (rating, flag, color) }
        }

        let reopened = try CatalogStore(packageURL: package)
        let loaded = try reopened.loadAssets()
        XCTAssertEqual(loaded.count, expected.count)
        for asset in loaded {
            let want = try XCTUnwrap(expected[asset.id])
            XCTAssertEqual(asset.rating, want.rating, asset.id)
            XCTAssertEqual(asset.flag, want.flag, asset.id)
            XCTAssertEqual(asset.colorLabel, want.color, asset.id)
        }
    }

    /// 600 batch sizes of each column: a placeholder per photo kept a statement for each size.
    func testManyBatchSizesKeepFewStatements() throws {
        let store = try makeCatalog(at: scratch.appendingPathComponent("Library.photolibrary"), rows: rows)
        let all = try store.loadAssets().map(\.id).sorted()
        try store.updateRatings(1, assetIDs: Set(all.prefix(3)))
        let before = store.db.cachedStatementCount
        for size in 2...601 {
            let ids = Set(all.prefix(size))
            try store.updateRatings(size % 6, assetIDs: ids)
            try store.updateFlags(size.isMultiple(of: 2) ? .pick : .none, assetIDs: ids)
            try store.updateColorLabels(size.isMultiple(of: 3) ? .blue : nil, assetIDs: ids)
        }
        XCTAssertLessThanOrEqual(store.db.cachedStatementCount - before, 3,
                                 "a statement for each batch size and column was kept")
        let saved = Dictionary(uniqueKeysWithValues: try store.loadAssets().map { ($0.id, $0) })
        for id in all.prefix(601) {
            XCTAssertEqual(saved[id]?.rating, 601 % 6, id)
            XCTAssertEqual(saved[id]?.flag, Flag.none, id)
            XCTAssertNil(saved[id]?.colorLabel, id)
        }
    }

    /// The batch looks each photo up by its id, rather than reading every row of the table.
    func testABatchSeeksByID() throws {
        let store = try makeCatalog(at: scratch.appendingPathComponent("Library.photolibrary"), rows: 10)
        let plan = try store.db.query("EXPLAIN QUERY PLAN UPDATE assets SET rating=? WHERE id IN (SELECT value FROM json_each(?));",
                                      [.int(1), .text("[\"bulk-1\"]")]).compactMap { $0.text("detail") }
        XCTAssertTrue(plan.contains { $0.hasPrefix("SEARCH assets") }, plan.joined(separator: "\n"))
        XCTAssertFalse(plan.contains { $0.hasPrefix("SCAN assets") }, plan.joined(separator: "\n"))
    }

    // MARK: - helpers

    /// A scratch catalog of `rows` photos, written by SQLite itself from one saved photo, each
    /// with its own id and a rating, flag and colour of its own.
    private func makeCatalog(at package: URL, rows: Int) throws -> CatalogStore {
        let store = try CatalogStore(packageURL: package)
        var template = DemoData.assets[0]
        template.isDemo = false
        template.deleted = false
        try store.upsert([template])
        let values = CatalogStore.columnNames.map { column -> String in
            switch column {
            case "id": return "'bulk-' || n.i"
            case "filename": return "'IMG_' || n.i || '.jpg'"
            case "capture_date": return "t.capture_date + n.i * 37"
            case "rating": return "n.i % 6"
            case "flag": return "CASE n.i % 3 WHEN 0 THEN 'none' WHEN 1 THEN 'pick' ELSE 'reject' END"
            case "color_label": return "CASE n.i % 4 WHEN 0 THEN NULL WHEN 1 THEN 'red' WHEN 2 THEN 'green' ELSE 'purple' END"
            default: return "t.\(column)"
            }
        }
        try store.db.execChecked("""
        WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < \(rows))
        INSERT INTO assets(\(CatalogStore.columnNames.joined(separator: ",")))
        SELECT \(values.joined(separator: ",")) FROM n, assets AS t WHERE t.id = '\(template.id)';
        """)
        try store.db.run("DELETE FROM assets WHERE id=?;", [.text(template.id)])
        return store
    }
}
