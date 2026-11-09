import XCTest
@testable import PhotoCatalog

/// The integrity check reads through a connection of its own: the catalog's connection, which
/// every edit goes through, doesn't wait for it, and it still finds a damaged file.
final class IntegrityCheckConcurrencyTests: CatalogTestCase {
    /// The catalog's connection mid-write and holding its lock, as during an edit: the check
    /// runs to its end all the same.
    func testTheCheckDoesNotWaitForTheCatalogsConnection() throws {
        let store = try makeCatalog(rows: 5_000)
        let finished = DispatchSemaphore(value: 0)
        let verdict = Box<Bool>()
        try store.db.transaction {
            try store.db.run("UPDATE assets SET rating=5 WHERE id='bulk-1';")
            DispatchQueue.global(qos: .utility).async {
                verdict.value = try? store.db.integrityCheck()
                finished.signal()
            }
            XCTAssertEqual(finished.wait(timeout: .now() + 30), .success,
                           "the check finished while the catalog's connection was held")
        }
        XCTAssertEqual(verdict.value, true)
    }

    /// Edits on the catalog's connection carry on while a health check reads, none of them failing
    /// on the reader, and the check sees a whole database. (How long an edit takes isn't asserted:
    /// on a busy machine one stalls for as long as the check of a small catalog runs.)
    func testEditsCarryOnWhileAHealthCheckRuns() throws {
        let rows = 20_000
        let store = try makeCatalog(rows: rows)
        let finished = DispatchSemaphore(value: 0)
        let result = Box<HealthReport>()
        DispatchQueue.global(qos: .utility).async {
            result.value = CatalogHealth.check(store, assets: [], canRead: { _ in true })
            finished.signal()
        }
        var edits = 0
        while finished.wait(timeout: .now()) == .timedOut {
            try store.updateRatings(edits % 6, assetIDs: ["bulk-\(edits % rows + 1)"])
            edits += 1
        }
        let report = try XCTUnwrap(result.value)
        XCTAssertTrue(report.dbIntegrityOK)
        XCTAssertGreaterThan(edits, 1, "edits went on during the check")
        let last = edits - 1
        let lastId = SQLValue.text("bulk-\(last % rows + 1)")
        XCTAssertEqual(store.db.scalarInt("SELECT rating FROM assets WHERE id=?;", [lastId]), last % 6,
                       "the last edit is saved")
    }

    /// A page of garbage in the middle of an index: the check, and the health report, say so.
    func testADamagedCatalogFailsTheCheck() throws {
        let store = try makeCatalog(rows: 2_000)
        XCTAssertTrue(store.db.walCheckpointTruncate(), "every commit in the file, none only in the WAL")
        let root = store.db.scalarInt("SELECT rootpage FROM sqlite_master WHERE name='idx_assets_capture';")
        let pageSize = store.db.scalarInt("PRAGMA page_size;")
        XCTAssertGreaterThan(root, 1)
        let damaged = scratch.appendingPathComponent("Damaged.photolibrary")
        try FileManager.default.createDirectory(at: damaged, withIntermediateDirectories: true)
        let file = damaged.appendingPathComponent("catalog.sqlite")
        try FileManager.default.copyItem(at: store.packageURL.appendingPathComponent("catalog.sqlite"), to: file)
        let handle = try FileHandle(forUpdating: file)
        try handle.seek(toOffset: UInt64((root - 1) * pageSize))
        try handle.write(contentsOf: Data(repeating: 0x5A, count: pageSize))
        try handle.close()

        let copy = try CatalogStore(packageURL: damaged)
        XCTAssertFalse((try? copy.db.integrityCheck()) ?? false)
        XCTAssertFalse(CatalogHealth.check(copy, assets: [], canRead: { _ in true }).dbIntegrityOK)
        XCTAssertTrue(try store.db.integrityCheck(), "the catalog it was copied from is whole")
    }

    // MARK: - helpers

    /// A scratch catalog of `rows` photos, written by SQLite itself from one saved photo: each
    /// with its own id, name and capture time, so the indexes on them grow as an import's would.
    private func makeCatalog(rows: Int) throws -> CatalogStore {
        let store = try CatalogStore(packageURL: scratch.appendingPathComponent("Library.photolibrary"))
        var template = DemoData.assets[0]
        template.isDemo = false
        try store.upsert([template])
        let columns = CatalogStore.columnNames
        let values = columns.map { column -> String in
            switch column {
            case "id": return "'bulk-' || n.i"
            case "filename": return "'IMG_' || n.i || '.jpg'"
            case "capture_date": return "t.capture_date + n.i * 37"
            case "rating": return "n.i % 6"
            default: return "t.\(column)"
            }
        }
        try store.db.execChecked("""
        WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < \(rows))
        INSERT INTO assets(\(columns.joined(separator: ",")))
        SELECT \(values.joined(separator: ",")) FROM n, assets AS t WHERE t.id = '\(template.id)';
        """)
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
