import XCTest
@testable import PhotoCatalog

extension AppStateSelectionTests {
    @MainActor
    func testReplacingWatchedSourceRootStopsScanningOldFolder() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-watch-replace-\(UUID().uuidString)")
        let oldRoot = dir.appendingPathComponent("Old")
        let newRoot = dir.appendingPathComponent("New")
        let package = dir.appendingPathComponent("Library.photolibrary")
        try FileManager.default.createDirectory(at: oldRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let oldOnlyPhoto = oldRoot.appendingPathComponent("old-only.jpg")
        let newOnlyPhoto = newRoot.appendingPathComponent("new-only.jpg")
        try writeTestJPEG(to: oldOnlyPhoto, black: false)
        try writeTestJPEG(to: newOnlyPhoto, black: false)
        _ = try CatalogStore(packageURL: package)

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))
        app.replaceWatchedSourceRoot(oldRootPath: nil, newRoot: oldRoot)
        app.replaceWatchedSourceRoot(oldRootPath: oldRoot.path, newRoot: newRoot)

        app.rescanCurrentSource()
        func imported(_ url: URL) -> Bool {
            let path = url.resolvingSymlinksInPath().path
            return app.assets.contains { asset in
                asset.localPath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == path } ?? false
            }
        }

        for _ in 0..<30 where !imported(newOnlyPhoto) {
            try await Task.sleep(for: .milliseconds(100))
        }

        XCTAssertTrue(imported(newOnlyPhoto))
        XCTAssertFalse(imported(oldOnlyPhoto))
    }

    @MainActor
    func testRecoveredEmptyImportDoesNotWatchSourceRoot() async throws {
        let defaults = UserDefaults.app
        let previousOnboarded = defaults.object(forKey: "pc_onboarded")
        let previousCatalogURL = defaults.object(forKey: "pc_catalogURL")
        let previousRecent = defaults.object(forKey: "pc_recentCatalogs")
        defer {
            if let previousOnboarded {
                defaults.set(previousOnboarded, forKey: "pc_onboarded")
            } else {
                defaults.removeObject(forKey: "pc_onboarded")
            }
            if let previousCatalogURL {
                defaults.set(previousCatalogURL, forKey: "pc_catalogURL")
            } else {
                defaults.removeObject(forKey: "pc_catalogURL")
            }
            if let previousRecent {
                defaults.set(previousRecent, forKey: "pc_recentCatalogs")
            } else {
                defaults.removeObject(forKey: "pc_recentCatalogs")
            }
        }
        defaults.removeObject(forKey: "pc_onboarded")
        defaults.removeObject(forKey: "pc_catalogURL")
        defaults.removeObject(forKey: "pc_recentCatalogs")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-empty-import-\(UUID().uuidString)")
        let source = dir.appendingPathComponent("Empty")
        let package = dir.appendingPathComponent("Library.photolibrary")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try CatalogStore(packageURL: package)
        let sessionId = UUID().uuidString
        try store.startImportSession(id: sessionId)
        try store.startImportJob(id: "job-empty", sessionId: sessionId, sourcePath: source.path,
                                 mode: .referenced, autoTag: false, archiveRule: .date,
                                 readSidecar: true, previewMaxPixel: 2048)

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))

        for _ in 0..<30 where app.importing {
            try await Task.sleep(for: .milliseconds(100))
        }

        XCTAssertFalse(app.importing)
        XCTAssertTrue(try store.loadSourceRoots().isEmpty)
        app.rescanCurrentSource()
        XCTAssertEqual(app.toastCenter.toasts.last?.message, "当前没有可重新扫描的源")
    }

    @MainActor
    func testRecoveredImportDoesNotPublishUnsavedAssetsWhenCatalogSaveFails() async throws {
        let defaults = UserDefaults.app
        let previousOnboarded = defaults.object(forKey: "pc_onboarded")
        let previousCatalogURL = defaults.object(forKey: "pc_catalogURL")
        let previousRecent = defaults.object(forKey: "pc_recentCatalogs")
        defer {
            if let previousOnboarded {
                defaults.set(previousOnboarded, forKey: "pc_onboarded")
            } else {
                defaults.removeObject(forKey: "pc_onboarded")
            }
            if let previousCatalogURL {
                defaults.set(previousCatalogURL, forKey: "pc_catalogURL")
            } else {
                defaults.removeObject(forKey: "pc_catalogURL")
            }
            if let previousRecent {
                defaults.set(previousRecent, forKey: "pc_recentCatalogs")
            } else {
                defaults.removeObject(forKey: "pc_recentCatalogs")
            }
        }
        defaults.removeObject(forKey: "pc_onboarded")
        defaults.removeObject(forKey: "pc_catalogURL")
        defaults.removeObject(forKey: "pc_recentCatalogs")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-import-save-failure-\(UUID().uuidString)")
        let source = dir.appendingPathComponent("Source")
        let package = dir.appendingPathComponent("Library.photolibrary")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let photo = source.appendingPathComponent("new-photo.jpg")
        try writeTestJPEG(to: photo, black: false)

        let store = try CatalogStore(packageURL: package)
        let sessionId = UUID().uuidString
        try store.startImportSession(id: sessionId)
        try store.startImportJob(id: "job-failing-import", sessionId: sessionId, sourcePath: source.path,
                                 mode: .referenced, autoTag: false, archiveRule: .date,
                                 readSidecar: true, previewMaxPixel: 2048)
        let db = try Database(path: package.appendingPathComponent("catalog.sqlite").path)
        try db.execChecked("""
        CREATE TRIGGER fail_import_insert BEFORE INSERT ON assets
        BEGIN
          SELECT RAISE(ABORT, 'forced import save failure');
        END;
        """)

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))

        try await waitUntil("Timed out waiting for import save failure", timeout: 2) {
            app.importRun?.errorMessage?.contains("写入目录库失败") == true
        }
        XCTAssertEqual(app.importRun?.phase, .failed)
        // the import holds on until the file it was on is done (a slow machine is still in it)
        try await waitUntil("Timed out waiting for the failed import to stop", timeout: 10) { !app.importing }
        XCTAssertFalse(app.assets.contains { $0.filename == photo.lastPathComponent })
        XCTAssertTrue(try store.loadAssets().isEmpty)
        XCTAssertTrue(try store.loadSourceRoots().isEmpty)

        app.rescanCurrentSource()
        XCTAssertEqual(app.toastCenter.toasts.last?.message, "当前没有可重新扫描的源")
    }

    @MainActor
    func testRescanDoesNotReimportCanonicalPathAliases() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-rescan-alias-\(UUID().uuidString)")
        let source = dir.appendingPathComponent("Source")
        let package = dir.appendingPathComponent("Library.photolibrary")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let photo = source.appendingPathComponent("photo.jpg")
        try writeTestJPEG(to: photo, black: false)
        let canonicalPath = try XCTUnwrap(try photo.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath)
        let plainPath = photo.path
        try XCTSkipIf(canonicalPath == plainPath, "filesystem does not expose a canonical path alias")

        let store = try CatalogStore(packageURL: package)
        let attrs = try FileManager.default.attributesOfItem(atPath: plainPath)
        let size = try XCTUnwrap(attrs[.size] as? Int64)
        var asset = DemoData.assets[0]
        asset.filename = photo.lastPathComponent
        asset.fileMB = Double(size) / (1024 * 1024)
        asset.fileModifiedAt = attrs[.modificationDate] as? Date
        asset.fileCreatedAt = attrs[.creationDate] as? Date
        asset.quickHash = HashService.quickHash(photo, fileSize: size)
        asset.contentHash = HashService.contentHash(photo)
        asset.localPath = plainPath
        asset.status = .ready
        asset.isDemo = false
        asset.deleted = false
        try store.upsert([asset])

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))
        app.replaceWatchedSourceRoot(oldRootPath: nil, newRoot: source)

        app.rescanCurrentSource()
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertEqual(app.assets.filter { !$0.deleted }.count, 1)
        XCTAssertFalse(app.assets.contains { $0.id != asset.id && $0.localPath == canonicalPath })
    }

    @MainActor
    func testRescanUsesExistingSourceRootIdentityForNewAssets() async throws {
        let defaults = UserDefaults.app
        let previousCatalogURL = defaults.object(forKey: "pc_catalogURL")
        let previousRecent = defaults.object(forKey: "pc_recentCatalogs")
        defer {
            if let previousCatalogURL {
                defaults.set(previousCatalogURL, forKey: "pc_catalogURL")
            } else {
                defaults.removeObject(forKey: "pc_catalogURL")
            }
            if let previousRecent {
                defaults.set(previousRecent, forKey: "pc_recentCatalogs")
            } else {
                defaults.removeObject(forKey: "pc_recentCatalogs")
            }
        }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-rescan-source-id-\(UUID().uuidString)")
        let source = dir.appendingPathComponent("Source")
        let package = dir.appendingPathComponent("Library.photolibrary")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try CatalogStore(packageURL: package)
        try store.addSourceRoot(id: "source-1", displayName: "Source", path: source.path, bookmark: nil)

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))

        let photo = source.appendingPathComponent("new-photo.jpg")
        try writeTestJPEG(to: photo, black: false)
        app.rescanCurrentSource()

        for _ in 0..<30 where app.assets.allSatisfy({ $0.filename != photo.lastPathComponent }) {
            try await Task.sleep(for: .milliseconds(100))
        }

        let imported = try XCTUnwrap(app.assets.first { $0.filename == photo.lastPathComponent })
        XCTAssertEqual(imported.folderId, "source-1")
        let sourceItem = try XCTUnwrap(app.folderTree.first { $0.id == "source-1" })
        XCTAssertEqual(app.countForFolderTreeItem(sourceItem), 1)
        let persisted = try XCTUnwrap(try store.loadAssets().first { $0.filename == photo.lastPathComponent })
        XCTAssertEqual(persisted.folderId, "source-1")
    }

    @MainActor
    func testRescanRefreshesCacheStatusAfterGeneratingThumbnails() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-rescan-cache-status-\(UUID().uuidString)")
        let source = dir.appendingPathComponent("Source")
        let package = dir.appendingPathComponent("Library.photolibrary")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try CatalogStore(packageURL: package)
        try store.addSourceRoot(id: "source-1", displayName: "Source", path: source.path, bookmark: nil)

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))
        try await waitUntil("Timed out waiting for initial cache status") {
            app.statusCacheText == "缓存 0 KB"
        }

        let photo = source.appendingPathComponent("new-photo.jpg")
        try writeTestJPEG(to: photo, black: false)
        app.rescanCurrentSource()

        try await waitUntil("Timed out waiting for generated thumbnail status") {
            app.assets.contains { $0.filename == photo.lastPathComponent }
                && app.statusCacheText != "缓存 0 KB"
        }
    }

    @MainActor
    func testIncrementalRescanReportsSaveFailure() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-rescan-save-failure-\(UUID().uuidString)")
        let source = dir.appendingPathComponent("Source")
        let package = dir.appendingPathComponent("Library.photolibrary")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try CatalogStore(packageURL: package)
        try store.addSourceRoot(id: "source-1", displayName: "Source", path: source.path, bookmark: nil)

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))

        let db = try Database(path: package.appendingPathComponent("catalog.sqlite").path)
        try db.execChecked("""
        CREATE TRIGGER fail_rescan_insert BEFORE INSERT ON assets
        BEGIN
          SELECT RAISE(ABORT, 'forced rescan save failure');
        END;
        """)

        let photo = source.appendingPathComponent("new-photo.jpg")
        try writeTestJPEG(to: photo, black: false)
        app.rescanCurrentSource()

        try await waitUntil("Timed out waiting for rescan save failure") {
            app.toastCenter.toasts.last?.message == "重新扫描保存失败"
        }
        XCTAssertFalse(app.assets.contains { $0.filename == photo.lastPathComponent })
        XCTAssertFalse(try store.loadAssets().contains { $0.filename == photo.lastPathComponent })
    }

    @MainActor
    func testIncrementalRescanPreservesCatalogMetadataForChangedOriginal() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-rescan-preserve-metadata-\(UUID().uuidString)")
        let source = dir.appendingPathComponent("Source")
        let package = dir.appendingPathComponent("Library.photolibrary")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let photo = source.appendingPathComponent("changed.jpg")
        try writeTestJPEG(to: photo, black: false)

        let store = try CatalogStore(packageURL: package)
        try store.addSourceRoot(id: "source-1", displayName: "Source", path: source.path, bookmark: nil)

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))
        app.rescanCurrentSource()

        try await waitUntil("initial import finished") {
            app.assets.contains { $0.filename == photo.lastPathComponent }
        }

        let imported = try XCTUnwrap(app.assets.first { $0.filename == photo.lastPathComponent })
        let originalImportedAt = imported.importedAt
        let originalQuickHash = try XCTUnwrap(imported.quickHash)
        app.mutateAsset(imported.id) {
            $0.rating = 5
            $0.flag = .pick
            $0.colorLabel = .green
            $0.keywords = ["客户", "精选"]
            $0.title = "Keep title"
            $0.caption = "Keep caption"
            $0.project = "Graduation"
            $0.client = "Chen"
            $0.faces = 2
        }

        try writeTestJPEG(to: photo, black: true)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_900_000_000)],
                                              ofItemAtPath: photo.path)
        app.rescanCurrentSource()

        try await waitUntil("changed original was refreshed") {
            app.assets.first { $0.id == imported.id }?.quickHash != originalQuickHash
        }

        let refreshed = try XCTUnwrap(app.assets.first { $0.id == imported.id })
        XCTAssertEqual(refreshed.rating, 5)
        XCTAssertEqual(refreshed.flag, .pick)
        XCTAssertEqual(refreshed.colorLabel, .green)
        XCTAssertEqual(refreshed.keywords, ["客户", "精选"])
        XCTAssertEqual(refreshed.title, "Keep title")
        XCTAssertEqual(refreshed.caption, "Keep caption")
        XCTAssertEqual(refreshed.project, "Graduation")
        XCTAssertEqual(refreshed.client, "Chen")
        XCTAssertEqual(refreshed.faces, 2)
        XCTAssertEqual(refreshed.importedAt, originalImportedAt)
        let persisted = try XCTUnwrap(try store.loadAssets().first { $0.id == imported.id })
        XCTAssertEqual(persisted.rating, 5)
        XCTAssertEqual(persisted.title, "Keep title")
        XCTAssertLessThan(abs(persisted.importedAt.timeIntervalSince(originalImportedAt)), 0.001)
    }
}
