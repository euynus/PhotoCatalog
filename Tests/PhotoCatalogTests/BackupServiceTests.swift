import XCTest
@testable import PhotoCatalog

final class BackupServiceTests: XCTestCase {
    func testListBackupsSortsByModificationDate() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pc-backup-order-\(UUID().uuidString)")
        let package = dir.appendingPathComponent("Library.photolibrary")
        let store = try CatalogStore(packageURL: package)
        defer { try? fm.removeItem(at: dir) }

        let older = store.backupsURL.appendingPathComponent("catalog-pre-migration-v99.sqlite")
        let newer = store.backupsURL.appendingPathComponent("catalog-2026-07-05-121125.sqlite")
        try Data().write(to: older)
        try Data().write(to: newer)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)],
                             ofItemAtPath: older.path)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)],
                             ofItemAtPath: newer.path)

        XCTAssertEqual(BackupService.listBackups(store).map(\.lastPathComponent),
                       [newer.lastPathComponent, older.lastPathComponent])
    }

    /// The status bar's "last backup" is when the newest backup was made, not when the catalog
    /// file last changed (a copy keeps the file's modification date).
    func testLastBackupDateIsWhenTheBackupWasMade() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pc-backup-date-\(UUID().uuidString)")
        let store = try CatalogStore(packageURL: dir.appendingPathComponent("Library.photolibrary"))
        defer { try? fm.removeItem(at: dir) }
        // the catalog last written long ago, its WAL already flushed
        XCTAssertTrue(store.db.walCheckpointTruncate())
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)],
                             ofItemAtPath: store.packageURL.appendingPathComponent("catalog.sqlite").path)

        let madeAt = Date()
        try BackupService.backup(store, at: madeAt)

        let newest = try XCTUnwrap(BackupService.listBackups(store).first)
        let date = try XCTUnwrap(BackupService.date(of: newest))
        XCTAssertEqual(date.timeIntervalSince1970, madeAt.timeIntervalSince1970, accuracy: 2)
    }

    /// Backups are listed newest first by when they were made, whatever their files' dates say.
    func testListBackupsPutsTheNewestBackupFirst() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pc-backup-newest-\(UUID().uuidString)")
        let store = try CatalogStore(packageURL: dir.appendingPathComponent("Library.photolibrary"))
        defer { try? fm.removeItem(at: dir) }
        let older = store.backupsURL.appendingPathComponent("catalog-2026-07-05-121125.sqlite")
        let newer = store.backupsURL.appendingPathComponent("catalog-2026-08-01-090000.sqlite")
        let migration = store.backupsURL.appendingPathComponent("catalog-pre-migration-v24-20260901T000000Z.sqlite")
        for url in [older, newer, migration] { try Data().write(to: url) }
        // copies of a catalog file: the older backup's copy is of a later-written file
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 300)], ofItemAtPath: older.path)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: newer.path)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: migration.path)

        XCTAssertEqual(BackupService.listBackups(store).map(\.lastPathComponent),
                       [migration.lastPathComponent, newer.lastPathComponent, older.lastPathComponent])
        XCTAssertEqual(BackupService.date(of: migration), Date(timeIntervalSince1970: 1_788_220_800))
    }

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

    /// A snapshot is SQLite's own copy of the catalog as of one commit, not a copy of the file
    /// after a checkpoint: it's made while something else reads the catalog (which holds a
    /// checkpoint off), and it holds what's committed only to the WAL so far.
    func testSnapshotIsTakenFromTheDatabaseNotItsFile() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pc-backup-snapshot-\(UUID().uuidString)")
        let store = try CatalogStore(packageURL: dir.appendingPathComponent("Library.photolibrary"))
        defer { try? fm.removeItem(at: dir) }
        var first = DemoData.assets[0], second = DemoData.assets[1]
        first.isDemo = false
        second.isDemo = false
        try store.upsert([first])
        // another reader of the catalog, mid-read
        let reader = try Database(path: store.packageURL.appendingPathComponent("catalog.sqlite").path)
        XCTAssertTrue(reader.exec("BEGIN; SELECT COUNT(*) FROM assets;"))
        defer { reader.exec("ROLLBACK;") }
        try store.upsert([second])

        let backup = try BackupService.backup(store)

        let copy = try Database(path: backup.path)
        XCTAssertEqual(Set(try copy.query("SELECT id FROM assets;").compactMap { $0.text("id") }), [first.id, second.id])
        XCTAssertEqual(try copy.query("PRAGMA integrity_check;").first?.text("integrity_check"), "ok")
    }

    /// A damaged snapshot (one torn while it was copied, say) is refused, even though the tables
    /// a catalog has are all there; the live catalog stays as it is.
    func testRestoreRefusesADamagedBackup() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pc-restore-damaged-\(UUID().uuidString)")
        let package = dir.appendingPathComponent("Library.photolibrary")
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let live = package.appendingPathComponent("catalog.sqlite")
        try Data("live".utf8).write(to: live)

        let backup = dir.appendingPathComponent("backup.sqlite")
        do {
            let db = try Database(path: backup.path)
            try db.execChecked("CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT);")
            try db.execChecked("CREATE TABLE assets (id TEXT PRIMARY KEY, payload BLOB);")
            try db.transaction {
                for index in 0..<200 {
                    try db.run("INSERT INTO assets(id, payload) VALUES(?, randomblob(1000));", [.text("asset-\(index)")])
                }
            }
            XCTAssertEqual(try db.query("PRAGMA journal_mode=DELETE;").first?.text("journal_mode"), "delete")
        }
        // a page in the middle of the assets table, overwritten
        let handle = try FileHandle(forWritingTo: backup)
        try handle.seek(toOffset: 20 * 4096)
        try handle.write(contentsOf: Data(repeating: 0xA5, count: 4096))
        try handle.close()

        XCTAssertThrowsError(try BackupService.restore(backup, intoPackageAt: package)) { error in
            XCTAssertEqual(error as? BackupError, .invalidBackup)
        }
        XCTAssertEqual(try Data(contentsOf: live), Data("live".utf8))
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
