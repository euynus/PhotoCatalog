import XCTest
@testable import PhotoCatalog

/// The WAL's pages go into the database file in the background after a commit, as SQLite would
/// at the end of the commit itself, and the WAL stays bounded.
final class WALCheckpointTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("pc-wal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func open() throws -> Database {
        let db = try Database(path: folder.appendingPathComponent("test.sqlite").path)
        try db.execChecked("CREATE TABLE IF NOT EXISTS blobs(id INTEGER PRIMARY KEY, body BLOB);")
        return db
    }

    /// `megabytes` of rows in one transaction.
    private func write(_ db: Database, megabytes: Int, from first: Int = 0) throws {
        let row = SQLValue.blob(Data(repeating: 0xA5, count: 64 * 1024))
        try db.transaction {
            for index in 0..<(megabytes * 16) {
                try db.run("INSERT OR REPLACE INTO blobs(id, body) VALUES(?, ?);", [.int(first + index), row])
            }
        }
    }

    private var walBytes: Int {
        let path = folder.appendingPathComponent("test.sqlite-wal").path
        return (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
    }

    func testABigCommitIsCheckpointedInTheBackground() throws {
        let db = try open()
        try write(db, megabytes: 1)
        db.drainCheckpoints()
        XCTAssertEqual(db.checkpointCount, 0, "a small WAL waits")
        try write(db, megabytes: 6, from: 100)
        db.drainCheckpoints()
        XCTAssertEqual(db.checkpointCount, 1)
    }

    /// Commit after commit, the WAL starts over once checkpointed instead of growing.
    func testSustainedWritesKeepTheWALBounded() throws {
        let db = try open()
        for round in 0..<20 {
            try write(db, megabytes: 2, from: round * 100)
            db.drainCheckpoints()
        }
        XCTAssertGreaterThan(db.checkpointCount, 3)
        XCTAssertLessThan(walBytes, 12 << 20, "the WAL is \(walBytes >> 20) MB after 40 MB of commits")
    }

    /// A database let go right after a big commit, its checkpoint queued or running: it closes
    /// cleanly, and the commit is there when it opens again.
    func testClosingWhileACheckpointIsDueKeepsEveryCommit() throws {
        for round in 0..<5 {
            do {
                let db = try open()
                try write(db, megabytes: 5, from: round * 1000)
            }
            let db = try open()
            XCTAssertEqual(db.scalarText("PRAGMA integrity_check;"), "ok")
            XCTAssertEqual(db.scalarInt("SELECT COUNT(*) FROM blobs WHERE id >= ?;", [.int(round * 1000)]), 80)
        }
    }

    /// With the background queue held up, a WAL past the ceiling is checkpointed at the commit.
    func testAWALPastTheCeilingIsCheckpointedAtOnce() throws {
        let db = try open()
        let queue = try XCTUnwrap(db.checkpointQueue)
        queue.suspend()
        try write(db, megabytes: 6)
        XCTAssertEqual(db.checkpointCount, 0, "queued, not run")
        try write(db, megabytes: 40, from: 1000)
        XCTAssertEqual(db.checkpointCount, 1, "run at the commit")
        queue.resume()
        db.drainCheckpoints()
    }
}
