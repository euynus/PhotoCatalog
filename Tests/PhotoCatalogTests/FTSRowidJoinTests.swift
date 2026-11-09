import XCTest
@testable import PhotoCatalog

/// Full-text search joins its index to the photos on the rowid they share, and finds exactly the
/// photos, in the same order, that the join on the photo's id did (kept here as the oracle), as
/// the catalog changes: trashed photos, edited words, photos imported again and a rebuilt index.
final class FTSRowidJoinTests: CatalogTestCase {
    /// `search(_:)` as it was: the index's asset_id joined to the photos' id.
    static func oldSearch(_ store: CatalogStore, _ query: String) -> [String]? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 3 else { return nil }
        return try? store.db.query("""
        SELECT asset_search.asset_id
        FROM asset_search
        JOIN assets ON assets.id = asset_search.asset_id
        WHERE assets.deleted=0 AND asset_search MATCH ?;
        """, [.text(match(q))]).compactMap { $0.text("asset_id") }
    }

    /// A page's search as it was: photos whose id is among the index's asset_ids, in name order.
    static func oldPage(_ store: CatalogStore, _ query: String) throws -> [String] {
        try store.db.query("""
        SELECT a.id FROM assets AS a
        WHERE a.deleted=0 AND a.id IN (SELECT asset_id FROM asset_search WHERE asset_search MATCH ?)
        ORDER BY a.filename COLLATE NOCASE ASC, a.id ASC;
        """, [.text(match(query.trimmingCharacters(in: .whitespacesAndNewlines)))]).compactMap { $0.text("id") }
    }

    static func match(_ query: String) -> String {
        "\"\(query.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    static let queries = ["IMG", "img", "Canon", "IMG_01", "IMG_0124", "DSC_0123", "DSC_00", "5\"x7", "旅行主题",
                          "harbour", "Café", "CAFÉ", "ILCE", "zzzz", "  IMG  ", "ab", "", "\"\"\"", "R5 IMG",
                          "sunset harbour"]

    /// Photos whose ids sort in another order than their rows were written, so an order taken from
    /// the ids rather than the index would show.
    static func photos(_ range: Range<Int>) -> [Asset] {
        let cameras = ["Canon EOS R5", "SONY ILCE-7M4", "iPhone 15 Pro", ""]
        let keywords = [["harbour"], ["旅行主题", "家庭"], ["sunset", "harbour"], [], ["Café au lait"]]
        return range.map { index in
            var asset = Asset(id: String(format: "p%05d", (index * 7_919) % 10_007), pid: index, ori: "l",
                              thumb: "", preview: "",
                              filename: index % 3 == 0 ? String(format: "DSC_%04d.ARW", index)
                                                       : String(format: "IMG_%04d.JPG", index),
                              type: "JPG", isRaw: false, folderId: "f", folderName: "F",
                              date: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 60),
                              width: 6000, height: 4000, orientation: 1, camera: cameras[index % cameras.count],
                              lens: "", focal: 50, aperture: 2, shutter: "1/100", iso: 100, colorSpace: "sRGB",
                              fileMB: 1, rating: 0, flag: .none, keywords: keywords[index % keywords.count],
                              title: index % 10 == 0 ? "5\"x7 print" : "", caption: "", location: "",
                              gps: (0, 0), status: .ready, importedAt: Date(timeIntervalSince1970: 1_700_000_000),
                              isDemo: false)
            asset.project = index % 4 == 0 ? "Harbour project" : ""
            return asset
        }
    }

    func assertSearchesAsBefore(_ store: CatalogStore, _ stage: String,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        var sort = Sort()
        sort.field = .name
        sort.descending = false
        for query in Self.queries {
            let found = store.search(query)
            XCTAssertEqual(found, Self.oldSearch(store, query), "\(stage): “\(query)”", file: file, line: line)
            guard query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 else { continue }
            let expected = try Self.oldPage(store, query)
            XCTAssertEqual(Set(found ?? []), Set(expected), "\(stage): “\(query)” as a page", file: file, line: line)
            for scope in [AssetQueryScope.all, .smart(rule: SmartRule(conditions: [
                SmartCondition(field: "search", op: "包含", value: query)]))] {
                let page = try store.loadAssetPage(matching: AssetQuery(scope: scope, search: scope == .all ? query : "",
                                                                        sort: sort), limit: 10_000)
                XCTAssertEqual(page.assets.map(\.id), expected, "\(stage): “\(query)” page, \(scope)",
                               file: file, line: line)
                XCTAssertEqual(page.totalCount, expected.count, "\(stage): “\(query)” count", file: file, line: line)
            }
        }
    }

    func testSearchFindsWhatTheIdJoinFoundAsTheCatalogChanges() throws {
        let store = try CatalogStore(packageURL: scratch.appendingPathComponent("Library.photolibrary"))
        var photos = Self.photos(0..<400)
        try store.upsert(photos)
        XCTAssertGreaterThan(store.search("IMG")?.count ?? 0, 200, "a broad term finds most photos")
        XCTAssertEqual(store.search("IMG_0124"), [photos[124].id], "a narrow one finds one")
        XCTAssertNotEqual(store.search("IMG"), store.search("IMG")?.sorted(), "rows aren't in id order")
        try assertSearchesAsBefore(store, "imported")

        // trashed photos are left out, and found again when put back
        for index in stride(from: 0, to: photos.count, by: 3) { photos[index].deleted = true }
        try store.upsert(photos)
        try assertSearchesAsBefore(store, "trashed")
        XCTAssertFalse(store.search("IMG")?.contains(photos[3].id) ?? true)

        // edited words, written whole and as an edit's own columns
        for index in stride(from: 1, to: photos.count, by: 5) {
            photos[index].keywords = ["harbour", "edited\(index)"]
            photos[index].title = "IMG renamed"
        }
        try store.upsert(photos)
        var edited = Array(photos[200..<260])
        for index in edited.indices { edited[index].caption = "sunset harbour CAFÉ" }
        try store.updateEditableColumns(edited, review: false, metadata: true)
        try assertSearchesAsBefore(store, "edited")

        // imported again: the same photos keep their rows, new ones are added after them
        for index in stride(from: 0, to: photos.count, by: 6) { photos[index].deleted = false }
        try store.upsert(photos.reversed())
        let more = Self.photos(400..<520)
        try store.db.transaction { try store.upsertRows(more, updatingExisting: false) }
        try assertSearchesAsBefore(store, "imported again")

        // the index rebuilt in place, and dropped and written again as the v20 migration writes it
        try store.db.run("INSERT INTO asset_search(asset_search) VALUES('rebuild');")
        try assertSearchesAsBefore(store, "rebuilt")
        try store.db.execChecked("DROP TABLE asset_search;")
        try store.db.execChecked("""
        CREATE VIRTUAL TABLE asset_search USING fts5(asset_id UNINDEXED, content, tokenize='trigram');
        """)
        try store.db.execChecked("""
        INSERT INTO asset_search(rowid, asset_id, content)
        SELECT rowid, id,
               COALESCE(filename, '') || ' ' || COALESCE(title, '') || ' '
               || COALESCE(caption, '') || ' ' || COALESCE(keywords, '') || ' '
               || COALESCE(camera, '') || ' ' || COALESCE(lens, '') || ' '
               || COALESCE(location, '') || ' ' || COALESCE(project, '') || ' '
               || COALESCE(client, '')
        FROM assets;
        """)
        try assertSearchesAsBefore(store, "migrated")
        XCTAssertNoThrow(try store.db.run("INSERT INTO asset_search(asset_search) VALUES('integrity-check');"))
    }

    /// Each match is one lookup of the photo by rowid, the index read first: SQLite takes the
    /// MATCH as the table's (an alias's MATCH is no column), and doesn't scan the photos instead.
    func testSearchLooksUpEachMatchByRowid() throws {
        let store = try CatalogStore(packageURL: scratch.appendingPathComponent("Library.photolibrary"))
        try store.upsert(Self.photos(0..<50))
        let plan = try store.db.query("""
        EXPLAIN QUERY PLAN
        SELECT a.id
        FROM asset_search
        JOIN assets AS a ON a.rowid = asset_search.rowid
        WHERE a.deleted=0 AND asset_search MATCH ?;
        """, [.text(Self.match("IMG"))]).compactMap { $0.text("detail") }
        XCTAssertEqual(plan.count, 2, "\(plan)")
        XCTAssertTrue(plan.first?.hasPrefix("SCAN asset_search VIRTUAL TABLE") ?? false, "\(plan)")
        XCTAssertEqual(plan.last, "SEARCH a USING INTEGER PRIMARY KEY (rowid=?)", "\(plan)")
        XCTAssertThrowsError(try store.db.query("""
        SELECT a.id FROM asset_search AS s JOIN assets AS a ON a.rowid = s.rowid WHERE s MATCH ?;
        """, [.text(Self.match("IMG"))]), "MATCH has to name the table")
    }
}
