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

        let matches = Set(store.search("needlefts"))
        XCTAssertTrue(matches.contains(live.id))
        XCTAssertFalse(matches.contains(deleted.id))
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
