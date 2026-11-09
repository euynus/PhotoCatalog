import XCTest
@testable import PhotoCatalog

/// The background checkpoint's priority, as `--scale` sets it to measure one against another:
/// each still checkpoints in the background, the throttled one gives its thread its I/O policy
/// back, and checkpoints a commit runs itself past the ceiling are told apart.
final class WALCheckpointPriorityTests: XCTestCase {
    private var folder: URL!
    private var savedPriority = Database.WALCheckpointer.Priority.utility

    override func setUpWithError() throws {
        savedPriority = Database.WALCheckpointer.priority
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("pc-walpriority-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        Database.WALCheckpointer.priority = savedPriority
        try? FileManager.default.removeItem(at: folder)
    }

    private func open(_ name: String) throws -> Database {
        let db = try Database(path: folder.appendingPathComponent("\(name).sqlite").path)
        try db.execChecked("CREATE TABLE IF NOT EXISTS blobs(id INTEGER PRIMARY KEY, body BLOB);")
        return db
    }

    /// `megabytes` of rows in one transaction.
    private func write(_ db: Database, megabytes: Int) throws {
        let row = SQLValue.blob(Data(repeating: 0xA5, count: 64 * 1024))
        try db.transaction {
            for index in 0..<(megabytes * 16) {
                try db.run("INSERT OR REPLACE INTO blobs(id, body) VALUES(?, ?);", [.int(index), row])
            }
        }
    }

    func testEveryPriorityCheckpointsInTheBackground() throws {
        for priority in [Database.WALCheckpointer.Priority.utility, .background, .throttled] {
            Database.WALCheckpointer.priority = priority
            let db = try open(priority.rawValue)
            let queue = try XCTUnwrap(db.checkpointQueue)
            XCTAssertEqual(queue.qos.qosClass, priority == .background ? .background : .utility, priority.rawValue)
            let policyBefore = queue.sync { getiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD) }
            try write(db, megabytes: 6)
            XCTAssertFalse(db.isCheckpointing)
            db.drainCheckpoints()
            XCTAssertEqual(db.checkpointCount, 1, priority.rawValue)
            XCTAssertEqual(db.ceilingCheckpointCount, 0, priority.rawValue)
            XCTAssertFalse(db.isCheckpointing)
            XCTAssertEqual(db.lastCheckpointFrames?.moved, db.lastCheckpointFrames?.wal, "all of the WAL moved")
            XCTAssertEqual(queue.sync { getiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD) }, policyBefore,
                           "\(priority.rawValue): the queue's thread kept the checkpoint's I/O policy")
        }
    }

    /// A commit that leaves the WAL past the ceiling checkpoints there and then, and is counted apart.
    func testACheckpointPastTheCeilingIsCountedApart() throws {
        let db = try open("ceiling")
        // 10,000 pages of 4 KB
        try write(db, megabytes: 41)
        XCTAssertEqual(db.ceilingCheckpointCount, 1)
        XCTAssertEqual(db.checkpointCount, 1)
    }
}
