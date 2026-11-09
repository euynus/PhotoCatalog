import XCTest
@testable import PhotoCatalog

/// The integrity check reads through a connection of its own only in WAL mode. A catalog SQLite
/// couldn't put in WAL mode (a volume without shared memory) is checked on its own connection,
/// as before: there a second connection's read lock would keep every commit out, and edits would
/// fail as busy once they'd waited out the timeout.
final class IntegrityCheckJournalModeTests: CatalogTestCase {
    /// A value one thread sets and another reads after a semaphore says it's there.
    private final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value?

        var value: Value? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    /// A catalog of one photo whose journal is the rollback journal, not the WAL.
    private func rollbackJournalCatalog() throws -> (store: CatalogStore, id: String) {
        let store = try CatalogStore(packageURL: scratch.appendingPathComponent("Library.photolibrary"))
        var photo = DemoData.assets[0]
        photo.isDemo = false
        try store.upsert([photo])
        try store.db.execChecked("PRAGMA journal_mode=DELETE;")
        XCTAssertEqual(store.db.scalarText("PRAGMA journal_mode;"), "delete")
        return (store, photo.id)
    }

    /// The catalog's connection mid-write and holding its lock, as during an edit: the check waits
    /// for the edit to end, then runs on that connection and finds the catalog whole.
    func testOutsideWALModeTheCheckWaitsForTheCatalogsConnection() throws {
        let (store, id) = try rollbackJournalCatalog()
        let finished = DispatchSemaphore(value: 0)
        let verdict = Box<Bool>()
        try store.db.transaction {
            try store.db.run("UPDATE assets SET rating=5 WHERE id=?;", [.text(id)])
            DispatchQueue.global(qos: .utility).async {
                verdict.value = try? store.db.integrityCheck()
                finished.signal()
            }
            XCTAssertEqual(finished.wait(timeout: .now() + 1), .timedOut,
                           "the check waits for the edit on the catalog's connection")
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 30), .success, "and runs once the edit is saved")
        XCTAssertEqual(verdict.value, true)
        XCTAssertEqual(store.db.scalarInt("SELECT rating FROM assets WHERE id=?;", [.text(id)]), 5)
    }

    /// In WAL mode, the catalog's usual one, the check reads through its own connection.
    func testInWALModeTheCheckDoesNotWait() throws {
        let store = try CatalogStore(packageURL: scratch.appendingPathComponent("Library.photolibrary"))
        XCTAssertEqual(store.db.scalarText("PRAGMA journal_mode;"), "wal")
        let finished = DispatchSemaphore(value: 0)
        let verdict = Box<Bool>()
        try store.db.transaction {
            try store.db.run("UPDATE assets SET rating=5;")
            DispatchQueue.global(qos: .utility).async {
                verdict.value = try? store.db.integrityCheck()
                finished.signal()
            }
            XCTAssertEqual(finished.wait(timeout: .now() + 30), .success, "the check ran while the edit was open")
        }
        XCTAssertEqual(verdict.value, true)
    }
}
