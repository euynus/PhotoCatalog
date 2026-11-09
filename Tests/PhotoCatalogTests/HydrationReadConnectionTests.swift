import XCTest
@testable import PhotoCatalog

/// The whole-catalog read behind a catalog's open reads through a read-only connection of its
/// own: the catalog's connection, which every edit goes through, doesn't wait for it, and it reads
/// what the catalog's connection would.
final class HydrationReadConnectionTests: CatalogTestCase {
    /// The catalog's connection mid-write and holding its lock, as during an edit: the read runs
    /// to its end all the same, and sees the catalog as it was before that write.
    func testTheReadDoesNotWaitForTheCatalogsConnection() throws {
        let rows = 20_000
        let store = try makeCatalog(rows: rows)
        let finished = DispatchSemaphore(value: 0)
        let loaded = Box<[Asset]>()
        try store.db.transaction {
            try store.db.run("UPDATE assets SET rating=5 WHERE id='bulk-1';")
            DispatchQueue.global(qos: .userInitiated).async {
                loaded.value = try? store.loadAssets()
                finished.signal()
            }
            XCTAssertEqual(finished.wait(timeout: .now() + 60), .success,
                           "the read waited for the catalog's connection")
        }
        let assets = try XCTUnwrap(loaded.value)
        XCTAssertEqual(assets.count, rows)
        XCTAssertEqual(assets.first { $0.id == "bulk-1" }?.rating, 1, "a write not yet committed was read")
    }

    /// What the read gives, in the same order, is what the catalog's connection reads.
    func testTheReadEqualsTheCatalogsConnection() throws {
        let store = try makeCatalog(rows: 3_000)
        var edited = try XCTUnwrap(try store.loadAssets().first)
        edited.keywords = ["harbour", "dawn"]
        edited.title = "Quay"
        try store.upsert([edited])
        try store.updateRatings(4, assetIDs: ["bulk-7", "bulk-8"])

        XCTAssertNotNil(store.db.readOnlyConnection(), "a catalog in WAL mode reads aside")
        let aside = try store.loadAssets()
        let oracle = try store.loadAssets(through: store.db)
        XCTAssertEqual(aside.count, oracle.count)
        XCTAssertEqual(aside.map(\.id), oracle.map(\.id))
        for (a, b) in zip(aside, oracle) {
            XCTAssertEqual(CatalogStore.params(a).map(String.init(describing:)),
                           CatalogStore.params(b).map(String.init(describing:)), a.id)
        }
        XCTAssertEqual(aside.first { $0.id == edited.id }?.keywords, ["harbour", "dawn"])
        XCTAssertEqual(aside.first { $0.id == "bulk-8" }?.rating, 4)
    }

    /// Out of WAL mode a reader of its own would keep every commit out while it read: the read
    /// goes through the catalog's connection, as before. And no connection is left open after a
    /// read, so the journal mode can change (as a full backup's flush needs).
    func testOutOfWALModeTheCatalogsConnectionReads() throws {
        let store = try makeCatalog(rows: 500)
        _ = try store.loadAssets()
        XCTAssertTrue(store.db.walCheckpointTruncate())
        XCTAssertEqual(try store.db.query("PRAGMA journal_mode=DELETE;").first?.text("journal_mode"), "delete",
                       "a connection the read opened is still open")
        XCTAssertNil(store.db.readOnlyConnection())
        XCTAssertEqual(try store.loadAssets().count, 500)
        XCTAssertEqual(try store.db.query("PRAGMA journal_mode=WAL;").first?.text("journal_mode"), "wal")
    }

    /// A read aside that fails (here the reader finds no photos table; in use, busy past its
    /// timeout) is made again through the catalog's connection: the catalog still opens. A read
    /// the catalog's connection can't make fails as before.
    func testAFailedReadAsideIsMadeAgainThroughTheCatalogsConnection() throws {
        let store = try makeCatalog(rows: 300)
        let other = scratch.appendingPathComponent("Other.sqlite").path
        try Database(path: other).execChecked("CREATE TABLE unrelated(id INTEGER);")
        let reader = try Database(path: other, readOnly: true)
        XCTAssertThrowsError(try store.loadAssets(through: reader), "the probe: the reader can't read the photos")

        let loaded = try store.loadAssets(aside: reader)
        XCTAssertEqual(loaded.map(\.id), try store.loadAssets(through: store.db).map(\.id))
        XCTAssertEqual(loaded.count, 300, "a failed read aside failed the open")

        try store.db.execChecked("ALTER TABLE assets RENAME TO assets_gone;")
        XCTAssertThrowsError(try store.loadAssets(aside: reader), "a read the catalog can't make came back empty")
        XCTAssertThrowsError(try store.loadAssets())
    }

    // MARK: - helpers

    /// A scratch catalog of `rows` photos, written by SQLite itself from one saved photo, each with
    /// its own id, name, capture time and rating.
    private func makeCatalog(rows: Int) throws -> CatalogStore {
        let store = try CatalogStore(packageURL: scratch.appendingPathComponent("Library.photolibrary"))
        var template = DemoData.assets[0]
        template.isDemo = false
        template.deleted = false
        try store.upsert([template])
        let values = CatalogStore.columnNames.map { column -> String in
            switch column {
            case "id": return "'bulk-' || n.i"
            case "filename": return "'IMG_' || n.i || '.jpg'"
            case "capture_date": return "t.capture_date + (n.i % 977) * 37"
            case "rating": return "n.i % 6"
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

/// A value one thread sets and another reads after a semaphore says it's there.
private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    var value: Value? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
