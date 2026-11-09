import XCTest
@testable import PhotoCatalog

/// The WAL's pages go into the database file in the background after a commit, as SQLite would
/// at the end of the commit itself, on a connection of their own, and the WAL stays bounded.
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

    /// The background checkpoint moves every frame of the WAL into the database, each time:
    /// a connection that hasn't read the database yet would report success and move nothing.
    func testABackgroundCheckpointMovesTheWholeWAL() throws {
        let db = try open()
        for round in 0..<3 {
            try write(db, megabytes: 6, from: round * 1000)
            db.drainCheckpoints()
            let frames = try XCTUnwrap(db.lastCheckpointFrames)
            XCTAssertGreaterThan(frames.wal, 0, "round \(round)")
            XCTAssertEqual(frames.moved, frames.wal, "round \(round)")
        }
        XCTAssertEqual(db.checkpointCount, 3)
    }

    /// A checkpoint runs while the catalog's own connection is busy (here, inside a transaction
    /// that has written): an edit or a search never waits for one.
    func testACheckpointDoesNotWaitForTheCatalogsConnection() throws {
        let db = try open()
        let queue = try XCTUnwrap(db.checkpointQueue)
        queue.suspend()
        try write(db, megabytes: 6)
        var finished = false
        try db.transaction {
            try db.run("INSERT OR REPLACE INTO blobs(id, body) VALUES(?, ?);", [.int(9_999), .blob(Data([1]))])
            queue.resume()
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                db.drainCheckpoints()
                done.signal()
            }
            finished = done.wait(timeout: .now() + 10) == .success
        }
        XCTAssertTrue(finished, "the checkpoint waited for the catalog's connection")
        XCTAssertEqual(db.checkpointCount, 1)
        XCTAssertGreaterThan(db.lastCheckpointFrames?.moved ?? 0, 0)
    }

    /// Flushing the WAL for a backup waits for a background checkpoint rather than being refused
    /// as busy by it, and leaves no other connection open, so the journal mode can change.
    func testTruncatingAfterABackgroundCheckpointFlushesTheWAL() throws {
        let db = try open()
        let queue = try XCTUnwrap(db.checkpointQueue)
        queue.suspend()
        try write(db, megabytes: 6)
        queue.resume()
        XCTAssertTrue(db.walCheckpointTruncate())
        XCTAssertEqual(walBytes, 0)
        XCTAssertEqual(try db.query("PRAGMA journal_mode=DELETE;").first?.text("journal_mode"), "delete")
        XCTAssertEqual(db.scalarInt("SELECT COUNT(*) FROM blobs;"), 96)
    }

    /// A run of commits doesn't have a checkpoint beside it: it starts once the catalog has been
    /// quiet a moment, and once is enough for the whole run.
    func testACheckpointWaitsForTheCommitsToStop() throws {
        let db = try open()
        try write(db, megabytes: 6)
        for round in 1...5 {
            try write(db, megabytes: 1, from: round * 100)
            XCTAssertEqual(db.checkpointCount, 0, "still committing")
        }
        let quiet = expectation(description: "checkpointed once the commits stopped")
        DispatchQueue.global().asyncAfter(deadline: .now() + Database.WALCheckpointer.quiet * 4) {
            db.checkpointQueue?.sync {}
            quiet.fulfill()
        }
        wait(for: [quiet], timeout: 10)
        XCTAssertEqual(db.checkpointCount, 1)
        XCTAssertEqual(db.lastCheckpointFrames?.moved, db.lastCheckpointFrames?.wal)
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
