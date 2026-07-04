import XCTest
@testable import PhotoCatalog

final class SQLiteTests: XCTestCase {
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
}
