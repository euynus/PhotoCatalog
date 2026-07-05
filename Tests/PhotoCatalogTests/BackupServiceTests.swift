import XCTest
@testable import PhotoCatalog

final class BackupServiceTests: XCTestCase {
    func testFailedRestoreKeepsLiveSidecars() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pc-restore-failure-\(UUID().uuidString)")
        let package = dir.appendingPathComponent("Library.photolibrary")
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
        defer {
            clearUserImmutableFlag(package.appendingPathComponent("catalog.sqlite"))
            try? fm.removeItem(at: dir)
        }

        let backup = dir.appendingPathComponent("backup.sqlite")
        let live = package.appendingPathComponent("catalog.sqlite")
        let wal = package.appendingPathComponent("catalog.sqlite-wal")
        let shm = package.appendingPathComponent("catalog.sqlite-shm")
        try writeValidBackup(at: backup)
        try Data("live".utf8).write(to: live)
        try Data("wal".utf8).write(to: wal)
        try Data("shm".utf8).write(to: shm)
        try setUserImmutableFlag(live)

        XCTAssertThrowsError(try BackupService.restore(backup, intoPackageAt: package))
        XCTAssertTrue(fm.fileExists(atPath: wal.path))
        XCTAssertTrue(fm.fileExists(atPath: shm.path))
        XCTAssertEqual(try Data(contentsOf: live), Data("live".utf8))
    }

    func testInvalidRestoreBackupDoesNotReplaceLiveDatabase() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pc-invalid-restore-\(UUID().uuidString)")
        let package = dir.appendingPathComponent("Library.photolibrary")
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let backup = dir.appendingPathComponent("backup.sqlite")
        let live = package.appendingPathComponent("catalog.sqlite")
        let wal = package.appendingPathComponent("catalog.sqlite-wal")
        let shm = package.appendingPathComponent("catalog.sqlite-shm")
        try Data("not sqlite".utf8).write(to: backup)
        try Data("live".utf8).write(to: live)
        try Data("wal".utf8).write(to: wal)
        try Data("shm".utf8).write(to: shm)

        XCTAssertThrowsError(try BackupService.restore(backup, intoPackageAt: package)) { error in
            XCTAssertEqual(error as? BackupError, .invalidBackup)
        }
        XCTAssertEqual(try Data(contentsOf: live), Data("live".utf8))
        XCTAssertTrue(fm.fileExists(atPath: wal.path))
        XCTAssertTrue(fm.fileExists(atPath: shm.path))
    }

    private func writeValidBackup(at url: URL) throws {
        let db = try Database(path: url.path)
        try db.execChecked("CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT);")
        try db.execChecked("CREATE TABLE assets (id TEXT PRIMARY KEY);")
    }

    private func setUserImmutableFlag(_ url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/chflags")
        process.arguments = ["uchg", url.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func clearUserImmutableFlag(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/chflags")
        process.arguments = ["nouchg", url.path]
        try? process.run()
        process.waitUntilExit()
    }
}
