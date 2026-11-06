import XCTest
import AppKit
@testable import PhotoCatalog

extension AppStateSelectionTests {
    @MainActor
    func testSourceReauthorizationPanelStartsAtCurrentRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-source-reauthorization-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let app = AppState()
        let panel = NSOpenPanel()
        app.configureSourceReauthorizationPanel(panel, currentPath: root.path)

        XCTAssertTrue(panel.canChooseDirectories)
        XCTAssertFalse(panel.canChooseFiles)
        XCTAssertFalse(panel.allowsMultipleSelection)
        XCTAssertEqual(panel.prompt, "重新授权")
        XCTAssertEqual(panel.message, "选择源文件夹以恢复访问权限")
        XCTAssertEqual(panel.directoryURL?.standardizedFileURL.path, root.standardizedFileURL.path)
    }

    @MainActor
    func testClearingSecurityBookmarksRequiresSourceReauthorization() throws {
        preservingPreferences(["pc_catalogURL", "pc_recentCatalogs"])

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-bookmarks-\(UUID().uuidString)")
        let source = dir.appendingPathComponent("Source")
        let package = dir.appendingPathComponent("Library.photolibrary")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try CatalogStore(packageURL: package)
        let bookmark = try XCTUnwrap(FileAccessService.createBookmark(for: source))
        try store.addSourceRoot(id: "source-1", displayName: "Source", path: source.path,
                                bookmark: bookmark, volumeIdentifier: nil)

        let app = AppState()
        app.onboarded = true
        app.confirmDestructiveAction = { _, _, _ in true }
        XCTAssertTrue(app.openCatalog(at: package))
        XCTAssertEqual(app.folders.first { $0.id == "source-1" }?.status, "online")

        app.confirmClearSecurityBookmarks()

        let root = try XCTUnwrap(try store.loadSourceRoots().first { $0.id == "source-1" })
        XCTAssertNil(root.bookmarkData)
        XCTAssertEqual(root.status, "permissionLost")
        XCTAssertEqual(app.folders.first { $0.id == "source-1" }?.status, "permissionLost")

        app.rescanCurrentSource()
        XCTAssertEqual(app.toastCenter.toasts.last?.message, "当前没有可重新扫描的源")
    }

    @MainActor
    func testRenamedSourceFolderReopensWithItsPhotos() throws {
        preservingPreferences(["pc_catalogURL", "pc_recentCatalogs", "pc_rememberedLocations"])

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-renamed-source-\(UUID().uuidString)")
        let source = dir.appendingPathComponent("Source")
        let renamed = dir.appendingPathComponent("Renamed")
        let package = dir.appendingPathComponent("Library.photolibrary")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("photo".utf8).write(to: source.appendingPathComponent("photo.jpg"))

        let store = try CatalogStore(packageURL: package)
        let bookmark = try XCTUnwrap(FileAccessService.createBookmark(for: source))
        try store.addSourceRoot(id: "source-1", displayName: "Source", path: source.path,
                                bookmark: bookmark, volumeIdentifier: nil)
        var photo = DemoData.assets[0]
        photo.isDemo = false
        photo.folderId = "source-1"
        photo.folderName = "Source"
        photo.localPath = source.appendingPathComponent("photo.jpg").path
        photo.status = .ready
        try store.upsert([photo])

        // renamed while the app was closed: its bookmark still finds it
        try FileManager.default.moveItem(at: source, to: renamed)

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))
        XCTAssertEqual(app.folders.first { $0.id == "source-1" }?.status, "online")
        // the bookmark resolves temporary folders to /private/var
        let renamedTail = "/\(dir.lastPathComponent)/Renamed"
        let reopened = try XCTUnwrap(app.assets.first { $0.id == photo.id })
        XCTAssertTrue(reopened.localPath?.hasSuffix(renamedTail + "/photo.jpg") == true, reopened.localPath ?? "nil")
        XCTAssertEqual(reopened.status, .ready)
        let root = try XCTUnwrap(try store.loadSourceRoots().first { $0.id == "source-1" })
        XCTAssertTrue(root.pathHint.hasSuffix(renamedTail), root.pathHint)
        XCTAssertNotNil(root.bookmarkData)
    }

    @MainActor
    func testReauthorizingSourceRebasesMovedAssetPaths() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-rebase-source-\(UUID().uuidString)")
        let oldRoot = dir.appendingPathComponent("Old")
        let newRoot = dir.appendingPathComponent("New")
        let nested = newRoot.appendingPathComponent("Nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let newPhoto = nested.appendingPathComponent("photo.jpg")
        try Data("photo".utf8).write(to: newPhoto)

        func asset(_ base: Asset, folderId: String, path: URL, status: AssetStatus) -> Asset {
            rebuiltAsset(base, filename: path.lastPathComponent, folderId: folderId, folderName: folderId,
                         status: status, localPath: path.path)
        }

        let moved = asset(DemoData.assets[0], folderId: "source-1",
                          path: oldRoot.appendingPathComponent("Nested/photo.jpg"),
                          status: .missing)
        let otherPath = oldRoot.appendingPathComponent("other.jpg")
        let other = asset(DemoData.assets[1], folderId: "other", path: otherPath, status: .missing)
        let app = AppState()
        app.onboarded = true
        app.assets = [moved, other]

        app.rebaseSourceRootAssetPaths(folderId: "source-1", oldRoot: oldRoot.path, newRoot: newRoot.path)

        XCTAssertEqual(app.assets.first { $0.id == moved.id }?.localPath, newPhoto.path)
        XCTAssertEqual(app.assets.first { $0.id == moved.id }?.status, .ready)
        XCTAssertEqual(app.assets.first { $0.id == other.id }?.localPath, otherPath.path)
        XCTAssertEqual(app.assets.first { $0.id == other.id }?.status, .missing)
    }

    @MainActor
    func testManagedSourceModeRestoresIntoCatalogAndInspectorText() throws {
        preservingPreferences(["pc_catalogURL", "pc_recentCatalogs"])

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-managed-mode-\(UUID().uuidString)")
        let source = dir.appendingPathComponent("Source")
        let package = dir.appendingPathComponent("Library.photolibrary")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = source.appendingPathComponent("managed.jpg")
        try Data("photo".utf8).write(to: original)
        let store = try CatalogStore(packageURL: package)
        try store.addSourceRoot(id: "source-1", displayName: "Source", path: source.path,
                                bookmark: nil, mode: .managed)
        let base = DemoData.assets[0]
        let asset = rebuiltAsset(base, filename: original.lastPathComponent, folderId: "source-1",
                                 folderName: "Source", status: .ready, localPath: original.path)
        try store.upsert([asset])

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))
        let restored = try XCTUnwrap(app.assets.first { $0.id == asset.id })

        XCTAssertEqual(try store.loadSourceRoots().first?.managementMode, ImportMode.managed.rawValue)
        XCTAssertEqual(app.catalogManagementText, "原件已复制到目录库")
        XCTAssertEqual(app.managementDisplayText(for: restored), "复制到目录库")
    }

    @MainActor
    func testManagedSourceDoesNotRequireOriginalFolderAuthorization() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-managed-offline-source-\(UUID().uuidString)")
        let package = dir.appendingPathComponent("Library.photolibrary")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try CatalogStore(packageURL: package)
        let managedOriginal = store.originalsURL.appendingPathComponent("managed.jpg")
        try Data("managed photo".utf8).write(to: managedOriginal)
        try store.addSourceRoot(
            id: "managed-source",
            displayName: "Disconnected Camera Card",
            path: dir.appendingPathComponent("Missing Source").path,
            bookmark: Data([0]),
            mode: .managed
        )

        var asset = try XCTUnwrap(DemoData.assets.first)
        asset.folderId = "managed-source"
        asset.folderName = "Disconnected Camera Card"
        asset.localPath = managedOriginal.path
        asset.status = .ready
        asset.isDemo = false
        try store.upsert([asset])

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))
        app.selection = Selection(
            type: .folder,
            id: "managed-source",
            name: "Disconnected Camera Card"
        )

        XCTAssertEqual(app.folders.first { $0.id == "managed-source" }?.status, "online")
        XCTAssertFalse(app.canReauthorizeSelectedSource)
        XCTAssertEqual(app.assets.first?.status, .ready)

        try FileManager.default.removeItem(at: managedOriginal)
        let reopened = AppState()
        reopened.onboarded = true
        XCTAssertTrue(reopened.openCatalog(at: package))
        try await waitUntil("Timed out waiting for managed original availability", timeout: 1) {
            !reopened.isCheckingOriginals
        }

        XCTAssertEqual(reopened.assets.first?.status, .missing)
        XCTAssertEqual(reopened.folders.first { $0.id == "managed-source" }?.status, "missing")
        XCTAssertFalse(reopened.canReauthorizeSelectedSource)
    }

    @MainActor
    func testMissingDetectionDoesNotPublishUnsavedStatus() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-missing-save-fail-\(UUID().uuidString)")
        let package = dir.appendingPathComponent("Library.photolibrary")
        let source = dir.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = source.appendingPathComponent("photo.jpg")
        try Data("image".utf8).write(to: original)
        let store = try CatalogStore(packageURL: package)
        var asset = DemoData.assets[0]
        asset.filename = original.lastPathComponent
        asset.localPath = original.path
        asset.status = .ready
        asset.isDemo = false
        asset.deleted = false
        try store.upsert([asset])

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))

        let db = try Database(path: package.appendingPathComponent("catalog.sqlite").path)
        try db.execChecked("""
        CREATE TRIGGER fail_status_update BEFORE UPDATE OF status ON assets
        WHEN NEW.status != OLD.status
        BEGIN
          SELECT RAISE(ABORT, 'forced status save failure');
        END;
        """)
        try FileManager.default.removeItem(at: original)

        app.detectMissingRealAssets()
        try await waitUntil("Timed out waiting for missing-original scan", timeout: 1) {
            !app.isCheckingOriginals
        }

        XCTAssertEqual(app.assets.first?.status, .ready)
        XCTAssertEqual(try store.loadAssets().first?.status, .ready)
        XCTAssertEqual(app.toastCenter.toasts.last?.message, "缺失状态保存失败")
    }

    func testAvailabilityPersistenceOnlyUpdatesChangedColumns() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-availability-columns-\(UUID().uuidString)")
        let package = dir.appendingPathComponent("Library.photolibrary")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try CatalogStore(packageURL: package)
        var asset = try XCTUnwrap(DemoData.assets.first)
        asset.isDemo = false
        asset.deleted = false
        asset.status = .ready
        asset.localPath = "/tmp/original.jpg"
        try store.upsert([asset])

        let db = try Database(path: package.appendingPathComponent("catalog.sqlite").path)
        try db.execChecked("""
        CREATE TRIGGER reject_unrelated_availability_write
        BEFORE UPDATE OF filename, title, caption, keywords, camera, lens ON assets
        BEGIN
          SELECT RAISE(ABORT, 'availability update touched unrelated metadata');
        END;
        """)

        try store.updateAssetAvailability([
            AssetAvailabilityUpdate(assetId: asset.id, status: .missing, localPath: asset.localPath)
        ])

        let saved = try XCTUnwrap(store.loadAssets().first)
        XCTAssertEqual(saved.status, .missing)
        XCTAssertEqual(saved.filename, asset.filename)
        XCTAssertEqual(saved.title, asset.title)
    }
}
