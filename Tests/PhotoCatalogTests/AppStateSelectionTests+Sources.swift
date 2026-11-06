import XCTest
@testable import PhotoCatalog

extension AppStateSelectionTests {
    @MainActor
    func testRemovingSourceStopsWatchingRootWithoutLiveAssets() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-watch-remove-\(UUID().uuidString)")
        let source = dir.appendingPathComponent("Source")
        let package = dir.appendingPathComponent("Library.photolibrary")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = source.appendingPathComponent("deleted.jpg")
        try writeTestJPEG(to: original, black: false)

        let store = try CatalogStore(packageURL: package)
        try store.addSourceRoot(id: "source-1", displayName: "Source", path: source.path, bookmark: nil)
        var asset = DemoData.assets[0]
        asset.filename = original.lastPathComponent
        asset.folderId = "source-1"
        asset.folderName = "Source"
        asset.localPath = original.path
        asset.isDemo = false
        asset.deleted = true
        try store.upsert([asset])

        let app = AppState()
        app.onboarded = true
        app.confirmDestructiveAction = { _, _, _ in true }
        XCTAssertTrue(app.openCatalog(at: package))
        app.select(Selection(type: .folder, id: "source-1", name: "Source"))

        app.removeSelectedSource()

        XCTAssertTrue(try store.loadSourceRoots().isEmpty)
        XCTAssertFalse(app.folders.contains { $0.id == "source-1" })
        app.rescanCurrentSource()
        XCTAssertEqual(app.toastCenter.toasts.last?.message, "当前没有可重新扫描的源")
    }

    @MainActor
    func testRemovingSourceRollsBackWhenSourceRootDeleteFails() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-source-remove-failure-\(UUID().uuidString)")
        let source = dir.appendingPathComponent("Source")
        let package = dir.appendingPathComponent("Library.photolibrary")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = source.appendingPathComponent("live.jpg")
        try writeTestJPEG(to: original, black: false)

        let store = try CatalogStore(packageURL: package)
        try store.addSourceRoot(id: "source-1", displayName: "Source", path: source.path, bookmark: nil)
        var asset = DemoData.assets[0]
        asset.filename = original.lastPathComponent
        asset.folderId = "source-1"
        asset.folderName = "Source"
        asset.localPath = original.path
        asset.isDemo = false
        asset.deleted = false
        try store.upsert([asset])

        let db = try Database(path: package.appendingPathComponent("catalog.sqlite").path)
        try db.execChecked("""
        CREATE TRIGGER fail_source_root_delete BEFORE DELETE ON source_roots
        BEGIN
          SELECT RAISE(ABORT, 'forced source root delete failure');
        END;
        """)

        let app = AppState()
        app.onboarded = true
        app.confirmDestructiveAction = { _, _, _ in true }
        XCTAssertTrue(app.openCatalog(at: package))
        app.select(Selection(type: .folder, id: "source-1", name: "Source"))

        app.removeSelectedSource()

        XCTAssertEqual(app.toastCenter.toasts.last?.message, "源移除失败")
        XCTAssertTrue(app.folders.contains { $0.id == "source-1" })
        XCTAssertFalse(app.assets.first { $0.id == asset.id }?.deleted ?? true)
        XCTAssertFalse(try XCTUnwrap(store.loadAssets().first { $0.id == asset.id }).deleted)
        XCTAssertFalse(try store.loadSourceRoots().isEmpty)
    }

    @MainActor
    func testOpeningCatalogRepairsOrphanedSourceFolderIds() throws {
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

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-repair-source-id-\(UUID().uuidString)")
        let source = dir.appendingPathComponent("Source")
        let package = dir.appendingPathComponent("Library.photolibrary")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let photo = source.appendingPathComponent("orphaned.jpg")
        try writeTestJPEG(to: photo, black: false)

        let store = try CatalogStore(packageURL: package)
        try store.addSourceRoot(id: "source-1", displayName: "Source", path: source.path, bookmark: nil)

        var asset = DemoData.assets[0]
        asset.filename = photo.lastPathComponent
        asset.folderId = "src-orphan"
        asset.folderName = "Source"
        asset.localPath = photo.path
        asset.status = .ready
        asset.isDemo = false
        asset.deleted = false
        try store.upsert([asset])

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))

        let repaired = try XCTUnwrap(app.assets.first { $0.filename == photo.lastPathComponent })
        XCTAssertEqual(repaired.folderId, "source-1")
        XCTAssertFalse(app.folderTree.contains { $0.id == "src-orphan" })
        let sourceItem = try XCTUnwrap(app.folderTree.first { $0.id == "source-1" })
        XCTAssertEqual(app.countForFolderTreeItem(sourceItem), 1)
        let persisted = try XCTUnwrap(try store.loadAssets().first { $0.filename == photo.lastPathComponent })
        XCTAssertEqual(persisted.folderId, "source-1")
    }

    @MainActor
    func testSourcePriorityReordersRealCatalogFolders() throws {
        let defaults = UserDefaults.app
        let previousCatalogURL = defaults.object(forKey: "pc_catalogURL")
        let previousRecent = defaults.object(forKey: "pc_recentCatalogs")
        let previousPriorities = defaults.object(forKey: "pc_sourcePriorities")
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
            if let previousPriorities {
                defaults.set(previousPriorities, forKey: "pc_sourcePriorities")
            } else {
                defaults.removeObject(forKey: "pc_sourcePriorities")
            }
        }
        defaults.removeObject(forKey: "pc_sourcePriorities")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-source-priority-\(UUID().uuidString)")
        let package = dir.appendingPathComponent("Library.photolibrary")
        let firstRoot = dir.appendingPathComponent("First")
        let secondRoot = dir.appendingPathComponent("Second")
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try CatalogStore(packageURL: package)
        try store.addSourceRoot(id: "first", displayName: "First", path: firstRoot.path, bookmark: nil)
        try store.addSourceRoot(id: "second", displayName: "Second", path: secondRoot.path, bookmark: nil)
        func realAsset(_ base: Asset, folderId: String, folderName: String, root: URL) -> Asset {
            Asset(id: base.id, pid: base.pid, ori: base.ori, thumb: base.thumb, preview: base.preview,
                  filename: base.filename, type: base.type, isRaw: base.isRaw, folderId: folderId,
                  folderName: folderName, date: base.date, width: base.width, height: base.height,
                  orientation: base.orientation, camera: base.camera, lens: base.lens, focal: base.focal,
                  aperture: base.aperture, shutter: base.shutter, iso: base.iso,
                  colorSpace: base.colorSpace, hasICCProfile: base.hasICCProfile, fileMB: base.fileMB,
                  fileModifiedAt: base.fileModifiedAt, fileCreatedAt: base.fileCreatedAt,
                  rating: base.rating, flag: base.flag, colorLabel: base.colorLabel,
                  keywords: base.keywords, title: base.title, caption: base.caption,
                  author: base.author, copyright: base.copyright, makerNotes: base.makerNotes,
                  project: base.project, client: base.client, location: base.location, gps: base.gps,
                  gpsAltitude: base.gpsAltitude, status: base.status, importedAt: base.importedAt,
                  deleted: base.deleted, localPath: root.appendingPathComponent(base.filename).path,
                  captureDateSource: base.captureDateSource, contentHash: base.contentHash,
                  quickHash: base.quickHash, isDemo: false, faces: base.faces,
                  perceptualHash: base.perceptualHash)
        }
        let firstAsset = realAsset(DemoData.assets[0], folderId: "first", folderName: "First", root: firstRoot)
        let secondAsset = realAsset(DemoData.assets[1], folderId: "second", folderName: "Second", root: secondRoot)
        try store.upsert([firstAsset, secondAsset])

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))
        XCTAssertEqual(app.orderedFolders.map(\.id), ["first", "second"])

        app.select(Selection(type: .folder, id: "second", name: "Second"))
        XCTAssertTrue(app.canPromoteSelectedSource)
        app.promoteSelectedSource()
        XCTAssertEqual(app.orderedFolders.map(\.id), ["second", "first"])

        let restored = AppState()
        restored.onboarded = true
        XCTAssertTrue(restored.openCatalog(at: package))
        XCTAssertEqual(restored.orderedFolders.map(\.id), ["second", "first"])

        restored.select(Selection(type: .folder, id: "second", name: "Second"))
        XCTAssertFalse(restored.canPromoteSelectedSource)
        XCTAssertTrue(restored.canDemoteSelectedSource)
        restored.demoteSelectedSource()
        XCTAssertEqual(restored.orderedFolders.map(\.id), ["first", "second"])
    }
}
