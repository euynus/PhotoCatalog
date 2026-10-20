import XCTest
@testable import PhotoCatalog

final class SQLiteTests: XCTestCase {
    func testSearchSkipsSoftDeletedAssets() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try CatalogStore(packageURL: dir.appendingPathComponent("Library.photolibrary"))
        var live = DemoData.assets[0]
        var deleted = DemoData.assets[1]
        live.title = "needlefts"
        deleted.title = "needlefts"
        deleted.deleted = true
        try store.upsert([live, deleted])

        let matches = Set(store.search("needlefts") ?? [])
        XCTAssertTrue(matches.contains(live.id))
        XCTAssertFalse(matches.contains(deleted.id))
    }

    /// The search index holds a photo's words: an edit that leaves them (a rating, a flag, Move to
    /// Trash and back) doesn't write its row again, and one that changes them does, and finds by them.
    func testSearchIndexIsWrittenOnlyWhenAPhotosWordsChange() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-search-words-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try CatalogStore(packageURL: dir.appendingPathComponent("Library.photolibrary"))
        var photo = DemoData.assets[0]
        photo.title = "harbour dawn"
        try store.upsert([photo])
        let writes = store.searchIndexWrites

        photo.rating = 5
        photo.flag = .pick
        try store.upsert([photo])
        photo.deleted = true
        try store.upsert([photo])
        photo.deleted = false
        try store.upsert([photo])
        XCTAssertEqual(store.searchIndexWrites, writes, "the words are as they were")
        XCTAssertEqual(store.search("harbour"), [photo.id])

        photo.title = "harbour dusk"
        try store.upsert([photo])
        XCTAssertEqual(store.searchIndexWrites, writes + 1, "a new title")
        XCTAssertEqual(store.search("dusk"), [photo.id])
        XCTAssertEqual(store.search("dawn"), [])
    }

    func testTransactionThrowsWhenCommitFails() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-sqlite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let db = try Database(path: dir.appendingPathComponent("test.sqlite").path)
        try db.run("CREATE TABLE parent(id INTEGER PRIMARY KEY);")
        try db.run("""
        CREATE TABLE child(
          parent_id INTEGER REFERENCES parent(id) DEFERRABLE INITIALLY DEFERRED
        );
        """)

        XCTAssertThrowsError(try db.transaction {
            try db.run("INSERT INTO child(parent_id) VALUES (42);")
        })
        XCTAssertEqual(try db.query("SELECT COUNT(*) AS count FROM child;").first?.int("count"), 0)
    }

    /// An empty BLOB is a value, not a missing one: it reads back as empty data, however it was
    /// written (bound from empty `Data`, or as SQL's `X''`).
    func testZeroLengthBlobReadsBackAsEmptyData() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-sqlite-blob-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let db = try Database(path: dir.appendingPathComponent("test.sqlite").path)
        try db.run("CREATE TABLE t(id INTEGER PRIMARY KEY, v BLOB NOT NULL);")
        try db.run("INSERT INTO t(id, v) VALUES(1, ?);", [.blob(Data())])
        try db.run("INSERT INTO t(id, v) VALUES(2, X'');")

        let rows = try db.query("SELECT id, v, typeof(v) AS kind FROM t ORDER BY id;")
        XCTAssertEqual(rows.map { $0.text("kind") }, ["blob", "blob"])
        XCTAssertEqual(rows.map { $0.blob("v") }, [Data(), Data()])
    }

    /// Text is stored and read back whole, a NUL character in it included: written as a
    /// parameter, or read from what SQL wrote.
    func testTextWithAnEmbeddedNulRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-sqlite-nul-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let db = try Database(path: dir.appendingPathComponent("test.sqlite").path)
        try db.run("CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT);")
        try db.run("INSERT INTO t(id, v) VALUES(1, ?);", [.text("a\u{0}b")])
        try db.run("INSERT INTO t(id, v) VALUES(2, CAST(X'610062' AS TEXT));")
        try db.run("INSERT INTO t(id, v) VALUES(3, ?);", [.text("")])

        let rows = try db.query("SELECT id, v, length(CAST(v AS BLOB)) AS bytes FROM t ORDER BY id;")
        XCTAssertEqual(rows.map { $0.int("bytes") }, [3, 3, 0], "the parameter is stored whole")
        XCTAssertEqual(rows.map { $0.text("v") }, ["a\u{0}b", "a\u{0}b", ""], "and read back whole")
    }

    /// A parameter the statement has no place for is an error, not quietly dropped.
    func testParameterWithoutAPlaceholderThrows() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-sqlite-bind-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let db = try Database(path: dir.appendingPathComponent("test.sqlite").path)
        try db.run("CREATE TABLE t(id INTEGER PRIMARY KEY);")
        XCTAssertThrowsError(try db.run("INSERT INTO t(id) VALUES(?);", [.int(1), .text("extra")]))
        XCTAssertEqual(db.scalarInt("SELECT COUNT(*) FROM t;"), 0)
        try db.run("INSERT INTO t(id) VALUES(?);", [.int(1)])
        XCTAssertEqual(db.scalarInt("SELECT COUNT(*) FROM t;"), 1, "the statement still works with its own parameters")
    }

    /// A face named without a vector (none could be made for it) is still there after a relaunch.
    func testNamedFaceWithoutVectorSurvivesReload() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-face-blob-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let package = dir.appendingPathComponent("Library.photolibrary")
        var asset = DemoData.assets[0]
        asset.isDemo = false
        let face = FaceRecord(id: "face-1", assetId: asset.id, box: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
                              quality: 0.5, vector: [], person: "Alice", confirmed: true)
        do {
            let store = try CatalogStore(packageURL: package)
            try store.upsert([asset])
            try store.saveFaceScans([asset.id: [face]])
        }

        let reopened = try CatalogStore(packageURL: package)
        XCTAssertEqual(try reopened.loadFaces(), [face])
    }

    func testManualAlbumRenameAndDeletePreserveAssets() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-album-crud-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try CatalogStore(packageURL: dir.appendingPathComponent("Library.photolibrary"))
        var asset = DemoData.assets[0]
        asset.isDemo = false
        try store.upsert([asset])
        try store.saveAlbum(Album(id: "album-1", name: "Before", assetIds: [asset.id]))

        try store.renameAlbum(id: "album-1", name: "After")
        XCTAssertEqual(try store.loadAlbums(), [Album(id: "album-1", name: "After", assetIds: [asset.id])])

        try store.deleteAlbum(id: "album-1")
        XCTAssertTrue(try store.loadAlbums().isEmpty)
        XCTAssertEqual(store.assetCount(), 1)
    }

    func testSmartAlbumUpdateAndDeletePreserveAssets() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-smart-album-crud-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try CatalogStore(packageURL: dir.appendingPathComponent("Library.photolibrary"))
        var asset = DemoData.assets[0]
        asset.isDemo = false
        try store.upsert([asset])
        let initialRule = SmartRule(match: "all", conditions: [
            SmartCondition(field: "rating", op: ">=", value: "4"),
        ])
        try store.saveSmartAlbum(SmartAlbum(id: "smart-1", name: "Before", rule: initialRule, count: 0))

        let updatedRule = SmartRule(match: "all", conditions: [
            SmartCondition(field: "type", op: "是", value: asset.type),
        ])
        try store.saveSmartAlbum(SmartAlbum(id: "smart-1", name: "After", rule: updatedRule, count: 1))
        let loaded = try XCTUnwrap(store.loadSmartAlbums().first)
        XCTAssertEqual(loaded.name, "After")
        XCTAssertEqual(loaded.rule, updatedRule)

        try store.deleteSmartAlbum(id: "smart-1")
        XCTAssertTrue(try store.loadSmartAlbums().isEmpty)
        XCTAssertEqual(store.assetCount(), 1)
    }
}
