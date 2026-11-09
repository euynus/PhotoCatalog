import XCTest
@testable import PhotoCatalog

/// Restoring a backup snapshots the catalog first, without writing its photos again: edits are
/// saved as they're made.
final class RestoreBackupRowsTests: CatalogTestCase {
    @MainActor
    func testRestoreDoesNotRewriteCatalogRows() throws {
        let source = scratch.appendingPathComponent("Source")
        let package = scratch.appendingPathComponent("Library.photolibrary")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let store = try CatalogStore(packageURL: package)
        var asset = DemoData.assets[0]
        let original = source.appendingPathComponent(asset.filename)
        try Data("image".utf8).write(to: original)
        asset.localPath = original.path
        asset.status = .ready
        asset.isDemo = false
        asset.deleted = false
        try store.upsert([asset])
        let backup = try BackupService.backup(store, at: Date(timeIntervalSinceNow: -3_600))

        // no launch checks, so the restore's own writes are the only ones
        let app = AppState()
        app.onboarded = true
        app.runsBackgroundMaintenance = false
        XCTAssertTrue(app.openCatalog(at: package))
        do {
            // closed before the restore, which puts another file in this one's place
            let db = try Database(path: package.appendingPathComponent("catalog.sqlite").path)
            try db.execChecked("""
            CREATE TRIGGER reject_restore_asset_update BEFORE UPDATE ON assets
            BEGIN
              SELECT RAISE(ABORT, 'restore must not rewrite asset rows');
            END;
            """)
        }

        app.restoreBackup(from: backup)

        let toast = try XCTUnwrap(app.toastCenter.toasts.last)
        XCTAssertTrue(toast.message.hasPrefix("已恢复备份"), "not restored: \(toast.message)")
        XCTAssertTrue(app.hasOpenCatalog)
        XCTAssertEqual(app.assets.map(\.id), [asset.id])
        XCTAssertEqual(BackupService.listBackups(try XCTUnwrap(app.store)).count, 2,
                       "no snapshot of the catalog as it was before the restore")
    }
}
