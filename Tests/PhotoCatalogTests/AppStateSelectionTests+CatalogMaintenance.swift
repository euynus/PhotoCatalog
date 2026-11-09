import XCTest
@testable import PhotoCatalog

extension AppStateSelectionTests {
    @MainActor
    func testMaintenanceActionsDoNotReopenClosedCatalog() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-closed-maintenance-\(UUID().uuidString)")
        let package = root.appendingPathComponent("ClosedMaintenance.photolibrary")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try CatalogStore(packageURL: package)

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))
        XCTAssertTrue(app.canRunCatalogMaintenance)

        app.closeCatalog()

        XCTAssertFalse(app.hasOpenCatalog)
        XCTAssertFalse(app.canRunCatalogMaintenance)

        app.runBackup()
        XCTAssertFalse(app.hasOpenCatalog)
        XCTAssertEqual(app.toastCenter.toasts.last?.message, "无目录库可备份")

        app.runHealthCheck()
        XCTAssertFalse(app.hasOpenCatalog)
        XCTAssertEqual(app.toastCenter.toasts.last?.message, "无目录库")

        app.restoreBackup()
        XCTAssertFalse(app.hasOpenCatalog)
        XCTAssertEqual(app.toastCenter.toasts.last?.message, "无目录库可恢复")
    }

    @MainActor
    func testMaintenanceActionsCleanLocalCatalogState() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-maintenance-\(UUID().uuidString)")
        let package = dir.appendingPathComponent("Library.photolibrary")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try CatalogStore(packageURL: package)
        let logFile = store.logsURL.appendingPathComponent("import.log")
        let cacheFile = store.thumb256URL.appendingPathComponent("stale.jpg")
        try Data("log".utf8).write(to: logFile)
        try Data("cache".utf8).write(to: cacheFile)

        let app = AppState()
        app.onboarded = true
        app.confirmDestructiveAction = { _, _, _ in true }
        XCTAssertTrue(app.openCatalog(at: package))

        XCTAssertTrue(app.recentCatalogs.contains { $0.path == package.path })
        app.confirmClearRecentCatalogs()
        XCTAssertTrue(app.recentCatalogs.isEmpty)

        app.confirmClearLogs()
        XCTAssertFalse(FileManager.default.fileExists(atPath: logFile.path))

        let cacheGeneration = app.thumbnailCacheGeneration
        app.confirmClearCache()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.thumb256URL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.preview2048URL.path))
        XCTAssertGreaterThan(app.thumbnailCacheGeneration, cacheGeneration)

        app.runBackup()
        try await waitUntil("Timed out waiting for backup", timeout: 1) {
            BackupService.listBackups(store).count == 1
        }
        XCTAssertEqual(BackupService.listBackups(store).count, 1)
    }

    @MainActor
    func testClearLogsReportsRemovalFailure() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-log-clear-failure-\(UUID().uuidString)")
        let package = dir.appendingPathComponent("Library.photolibrary")
        defer {
            try? setUserImmutableFlag(package.appendingPathComponent("Logs/import.log"), enabled: false)
            try? FileManager.default.removeItem(at: dir)
        }

        let store = try CatalogStore(packageURL: package)
        let logFile = store.logsURL.appendingPathComponent("import.log")
        try Data("log".utf8).write(to: logFile)
        try setUserImmutableFlag(logFile, enabled: true)

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))

        app.clearLogs()

        XCTAssertTrue(FileManager.default.fileExists(atPath: logFile.path))
        XCTAssertEqual(app.toastCenter.toasts.last?.message, "清除日志失败")
        XCTAssertEqual(app.toastCenter.toasts.last?.icon, "warning")
    }

    @MainActor
    func testClearCacheReportsRemovalFailure() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-cache-clear-failure-\(UUID().uuidString)")
        let package = dir.appendingPathComponent("Library.photolibrary")
        defer {
            try? setUserImmutableFlag(package.appendingPathComponent("Cache"), enabled: false)
            try? FileManager.default.removeItem(at: dir)
        }

        let store = try CatalogStore(packageURL: package)
        let cacheFile = store.thumb256URL.appendingPathComponent("stale.jpg")
        try Data("cache".utf8).write(to: cacheFile)
        try setUserImmutableFlag(store.cacheURL, enabled: true)

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))
        let generation = app.thumbnailCacheGeneration

        app.clearCache()

        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheFile.path))
        XCTAssertEqual(app.thumbnailCacheGeneration, generation)
        XCTAssertEqual(app.toastCenter.toasts.last?.message, "清理缓存失败")
        XCTAssertEqual(app.toastCenter.toasts.last?.icon, "warning")
    }

    @MainActor
    func testDestructiveMaintenanceCancelKeepsLocalState() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-maintenance-cancel-\(UUID().uuidString)")
        let source = dir.appendingPathComponent("Source")
        let package = dir.appendingPathComponent("Library.photolibrary")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try CatalogStore(packageURL: package)
        let bookmark = try XCTUnwrap(FileAccessService.createBookmark(for: source))
        try store.addSourceRoot(id: "source-1", displayName: "Source", path: source.path,
                                bookmark: bookmark, volumeIdentifier: nil)
        let logFile = store.logsURL.appendingPathComponent("import.log")
        let cacheFile = store.thumb256URL.appendingPathComponent("stale.jpg")
        try Data("log".utf8).write(to: logFile)
        try Data("cache".utf8).write(to: cacheFile)

        let app = AppState()
        app.onboarded = true
        app.confirmDestructiveAction = { _, _, _ in false }
        XCTAssertTrue(app.openCatalog(at: package))

        app.confirmClearRecentCatalogs()
        app.confirmClearLogs()
        app.confirmClearCache()
        app.confirmClearSecurityBookmarks()

        XCTAssertTrue(app.recentCatalogs.contains { $0.path == package.path })
        XCTAssertTrue(FileManager.default.fileExists(atPath: logFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheFile.path))
        let root = try XCTUnwrap(try store.loadSourceRoots().first { $0.id == "source-1" })
        XCTAssertNotNil(root.bookmarkData)
        XCTAssertEqual(root.status, "online")
    }

    @MainActor
    func testRunBackupDoesNotRewriteCatalogRows() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-backup-no-rewrite-\(UUID().uuidString)")
        let source = dir.appendingPathComponent("Source")
        let package = dir.appendingPathComponent("Library.photolibrary")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try CatalogStore(packageURL: package)
        var asset = DemoData.assets[0]
        let original = source.appendingPathComponent(asset.filename)
        try Data("image".utf8).write(to: original)
        asset.localPath = original.path
        asset.status = .ready
        asset.isDemo = false
        asset.deleted = false
        try store.upsert([asset])

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))

        let db = try Database(path: package.appendingPathComponent("catalog.sqlite").path)
        try db.failWrites("reject_backup_asset_update", before: "UPDATE", on: "assets",
                          message: "backup must not rewrite asset rows")

        app.runBackup()

        try await waitUntil("Timed out waiting for backup", timeout: 1) {
            BackupService.listBackups(store).count == 1
        }
        XCTAssertEqual(BackupService.listBackups(store).count, 1)
        XCTAssertTrue(app.toastCenter.toasts.last?.message.hasPrefix("已备份目录库") == true)
    }

    @MainActor
    func testStatusBackupTextPadsMinute() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-backup-status-\(UUID().uuidString)")
        let package = dir.appendingPathComponent("Library.photolibrary")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try makeCatalogWithOneAsset(at: package, assetIndex: 0)
        let backupDate = try XCTUnwrap(Calendar.current.date(bySettingHour: 9, minute: 5, second: 0, of: Date()))
        let backup = try BackupService.backup(store, at: backupDate)
        try FileManager.default.setAttributes([.modificationDate: backupDate], ofItemAtPath: backup.path)

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))

        try await waitUntil("Timed out waiting for backup status", timeout: 1) {
            app.statusBackupText != "尚未备份"
        }
        XCTAssertTrue(app.statusBackupText.contains("09:05"), app.statusBackupText)
    }

    @MainActor
    func testBackupRefreshesVisibleHealthReport() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-backup-health-refresh-\(UUID().uuidString)")
        let package = dir.appendingPathComponent("Library.photolibrary")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try makeCatalogWithOneAsset(at: package, assetIndex: 0)

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))
        app.runHealthCheck()

        try await waitUntil("Timed out waiting for initial health report", timeout: 1) {
            app.healthReport?.backupCount == 0
        }

        app.runBackup()

        try await waitUntil("Timed out waiting for health backup count", timeout: 1) {
            app.healthReport?.backupCount == 1
        }
        XCTAssertEqual(app.healthReport?.backupCount, 1)
    }

    @MainActor
    func testAutomaticBackupIsTrackedPerCatalog() async throws {
        let defaults = UserDefaults.app
        defaults.set(true, forKey: "pc_openLast")
        defaults.set("1", forKey: "pc_onboarded")
        defaults.set("daily", forKey: "pc_autoBackupFrequency")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-auto-backup-\(UUID().uuidString)")
        let firstPackage = dir.appendingPathComponent("First.photolibrary")
        let secondPackage = dir.appendingPathComponent("Second.photolibrary")
        defer { try? FileManager.default.removeItem(at: dir) }
        let firstStore = try makeCatalogWithOneAsset(at: firstPackage, assetIndex: 0)
        let secondStore = try makeCatalogWithOneAsset(at: secondPackage, assetIndex: 1)

        defaults.set(firstPackage, forKey: "pc_catalogURL")
        let firstApp = AppState()
        XCTAssertTrue(firstApp.hasOpenCatalog)
        try await waitUntil("Timed out waiting for first automatic backup", timeout: 1) {
            BackupService.listBackups(firstStore).count == 1
        }
        XCTAssertEqual(BackupService.listBackups(firstStore).count, 1)

        defaults.set(secondPackage, forKey: "pc_catalogURL")
        let secondApp = AppState()
        XCTAssertTrue(secondApp.hasOpenCatalog)

        try await waitUntil("Timed out waiting for second automatic backup", timeout: 1) {
            BackupService.listBackups(secondStore).count == 1
        }
        XCTAssertEqual(BackupService.listBackups(secondStore).count, 1)
    }

    private func setUserImmutableFlag(_ url: URL, enabled: Bool) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/chflags")
        process.arguments = [enabled ? "uchg" : "nouchg", url.path]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw NSError(domain: "PhotoCatalogTests.chflags", code: Int(process.terminationStatus))
        }
    }
}
