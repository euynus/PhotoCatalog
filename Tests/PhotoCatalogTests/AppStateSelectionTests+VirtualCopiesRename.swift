import XCTest
@testable import PhotoCatalog

extension AppStateSelectionTests {
    @MainActor
    func testBatchRenameFallsBackToPrimarySelection() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = dir.appendingPathComponent("original.jpg")
        try Data("image".utf8).write(to: original)

        let app = AppState()
        app.onboarded = true
        var asset = try XCTUnwrap(app.assets.first)
        asset.filename = original.lastPathComponent
        asset.localPath = original.path
        asset.isDemo = false
        app.assets = [asset]
        app.primaryId = asset.id
        app.selectedIds = []

        app.renameOriginals(template: "RENAMED")

        let renamed = dir.appendingPathComponent("RENAMED_0001.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
        XCTAssertEqual(app.assets.first?.filename, renamed.lastPathComponent)
        XCTAssertEqual(app.assets.first?.localPath, renamed.path)
    }

    @MainActor
    func testBatchRenameRequiresExistingLocalFile() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-missing-rename-\(UUID().uuidString).jpg")

        let app = AppState()
        app.onboarded = true
        var asset = try XCTUnwrap(app.assets.first)
        asset.localPath = missing.path
        asset.status = .missing
        asset.isDemo = false
        app.assets = [asset]
        app.primaryId = asset.id
        app.selectedIds = [asset.id]

        app.renameOriginals(template: "RENAMED")

        XCTAssertEqual(app.assets.first?.localPath, missing.path)
        XCTAssertEqual(app.toastCenter.toasts.last?.message, "仅可重命名已导入照片")
    }

    @MainActor
    func testRenameSheetCancellationKeepsOriginals() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-rename-confirm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = dir.appendingPathComponent("original.jpg")
        try Data("image".utf8).write(to: original)

        let app = AppState()
        app.onboarded = true
        var asset = try XCTUnwrap(app.assets.first)
        asset.filename = original.lastPathComponent
        asset.localPath = original.path
        asset.isDemo = false
        app.assets = [asset]
        app.primaryId = asset.id
        app.selectedIds = [asset.id]

        app.showRenameSheet()
        XCTAssertEqual(app.sheet, "rename")
        XCTAssertEqual(app.renameSheetTargets.map(\.id), [asset.id])
        XCTAssertTrue(app.handleKey("escape", hasCommand: false))

        XCTAssertNil(app.sheet)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("RENAMED_0001.jpg").path))
        XCTAssertEqual(app.assets.first?.localPath, original.path)
    }

    @MainActor
    func testBatchRenameReportsReadOnlyFolders() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-rename-fail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let original = dir.appendingPathComponent("original.jpg")
        try Data("image".utf8).write(to: original)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)

        let app = AppState()
        app.onboarded = true
        var asset = try XCTUnwrap(app.assets.first)
        asset.filename = original.lastPathComponent
        asset.localPath = original.path
        asset.isDemo = false
        app.assets = [asset]
        app.primaryId = asset.id
        app.selectedIds = [asset.id]

        app.renameOriginals(template: "RENAMED")

        XCTAssertEqual(app.assets.first?.localPath, original.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(app.toastCenter.toasts.last?.message, "1 张照片所在的文件夹是只读的，无法重命名")
        XCTAssertEqual(app.toastCenter.toasts.last?.icon, "warning")
    }

    @MainActor
    func testBatchRenameRollsBackWhenCatalogSaveFails() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-rename-rollback-\(UUID().uuidString)")
        let package = dir.appendingPathComponent("Library.photolibrary")
        let sourceDir = dir.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = sourceDir.appendingPathComponent("original.jpg")
        try Data("image".utf8).write(to: original)

        let store = try CatalogStore(packageURL: package)
        var asset = try XCTUnwrap(DemoData.assets.first)
        asset.filename = original.lastPathComponent
        asset.localPath = original.path
        asset.isDemo = false
        asset.deleted = false
        try store.upsert([asset])

        let db = try Database(path: package.appendingPathComponent("catalog.sqlite").path)
        try db.failWrites("fail_rename_update", before: "UPDATE OF filename", on: "assets",
                          when: "WHEN NEW.filename != OLD.filename", message: "forced rename save failure")

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))
        app.primaryId = asset.id
        app.selectedIds = [asset.id]

        app.renameOriginals(template: "RENAMED")

        let renamed = sourceDir.appendingPathComponent("RENAMED_0001.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamed.path))
        XCTAssertEqual(app.assets.first?.localPath, original.path)
        XCTAssertEqual(try store.loadAssets().first?.localPath, original.path)
        XCTAssertEqual(app.toastCenter.toasts.last?.message,
                       "重命名未完成 · 已回滚 1 张照片 · 目录库保存失败")
    }

    func testPrefixRenameDoesNotAddTrailingDotForExtensionlessFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-extensionless-rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = dir.appendingPathComponent("original")
        try Data("image".utf8).write(to: original)

        var asset = DemoData.assets[0]
        asset.localPath = original.path
        asset.isDemo = false

        let renamed = try XCTUnwrap(RenameService.renameWithTemplate([asset], template: "RENAMED_{seq}")[asset.id])
        XCTAssertEqual(renamed.lastPathComponent, "RENAMED_0001")
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
    }

    /// A virtual copy is saved with the develop settings it starts from, or not at all: copies
    /// the catalog kept without them would show up at the next launch, unseen until then.
    @MainActor
    func testVirtualCopiesThatFailToSaveLeaveNothingInTheCatalog() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-virtual-copy-\(UUID().uuidString)")
        let package = dir.appendingPathComponent("Library.photolibrary")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try CatalogStore(packageURL: package)
        var asset = try XCTUnwrap(DemoData.assets.first)
        asset.isDemo = false
        asset.deleted = false
        try store.upsert([asset])
        var edit = DevelopSettings.neutral
        edit.exposure = 0.7
        try store.saveDevelopSettings([asset.id: edit])

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))
        app.primaryId = asset.id
        app.selectedIds = [asset.id]
        let db = try Database(path: package.appendingPathComponent("catalog.sqlite").path)
        try db.failWrites("fail_copy_settings", before: "INSERT", on: "develop_settings",
                          message: "forced develop settings save failure")

        app.createVirtualCopies()

        XCTAssertEqual(app.toastCenter.toasts.last?.message, "创建虚拟副本失败，目录库未保存")
        XCTAssertFalse(app.assets.contains { $0.isVirtualCopy })
        XCTAssertEqual(try store.db.query("SELECT id FROM assets WHERE master_id IS NOT NULL;").count, 0,
                       "a copy is in the catalog without its develop settings")
    }

    @MainActor
    func testOriginalFileOperationsHandleConflictsAndUnavailableSources() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-file-ops-\(UUID().uuidString)")
        let sourceDir = dir.appendingPathComponent("Source")
        let destination = dir.appendingPathComponent("Dest")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = sourceDir.appendingPathComponent("photo.jpg")
        try Data("original".utf8).write(to: source)
        try Data("existing".utf8).write(to: destination.appendingPathComponent("photo.jpg"))

        var copied = DemoData.assets[0]
        copied.localPath = source.path
        var skipped = DemoData.assets[1]
        skipped.localPath = nil
        var missing = DemoData.assets[2]
        missing.localPath = sourceDir.appendingPathComponent("missing.jpg").path

        let report = OriginalFileOperationService.perform(.copy, assets: [copied, skipped, missing],
                                                          destination: destination)

        XCTAssertEqual(report.copied, 1)
        XCTAssertEqual(report.skipped, 1)
        XCTAssertEqual(report.failed, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("photo (1).jpg").path))

        let moveSource = sourceDir.appendingPathComponent("move.jpg")
        try Data("move".utf8).write(to: moveSource)
        var moved = DemoData.assets[3]
        moved.localPath = moveSource.path

        let moveReport = OriginalFileOperationService.perform(.move, assets: [moved],
                                                              destination: destination)
        let movedURL = try XCTUnwrap(moveReport.updatedLocations[moved.id])
        XCTAssertEqual(moveReport.moved, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: moveSource.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedURL.path))

        XCTAssertEqual(OriginalFileOperationService.rollBackMoves(moveReport.updatedLocations,
                                                                  originals: [moved]), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: moveSource.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: movedURL.path))

        let trashSource = sourceDir.appendingPathComponent("trash.jpg")
        try Data("trash".utf8).write(to: trashSource)
        var trashed = DemoData.assets[4]
        trashed.localPath = trashSource.path

        let trashReport = OriginalFileOperationService.trashOriginals([trashed])
        let trashLocation = try XCTUnwrap(trashReport.locations[trashed.id])
        XCTAssertEqual(trashReport.trashedIds, [trashed.id])
        XCTAssertEqual(trashReport.failed, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashSource.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashLocation.trashed.path))

        XCTAssertEqual(OriginalFileOperationService.rollBackTrash(trashReport.locations), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashSource.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashLocation.trashed.path))
    }

    @MainActor
    func testMovedOriginalLocationWriteRequiresSameCatalog() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-move-catalog-guard-\(UUID().uuidString)")
        let firstPackage = dir.appendingPathComponent("First.photolibrary")
        let secondPackage = dir.appendingPathComponent("Second.photolibrary")
        let movedURL = dir.appendingPathComponent("Moved").appendingPathComponent("photo.jpg")
        defer { try? FileManager.default.removeItem(at: dir) }

        let firstStore = try makeCatalogWithOneAsset(at: firstPackage, assetIndex: 0)
        _ = try makeCatalogWithOneAsset(at: secondPackage, assetIndex: 1)
        let asset = try XCTUnwrap(try firstStore.loadAssets().first)
        try FileManager.default.createDirectory(at: movedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("moved".utf8).write(to: movedURL)

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: firstPackage))

        XCTAssertFalse(app.applyMovedOriginalLocations([asset.id: movedURL], expectedCatalogURL: secondPackage))
        XCTAssertEqual(app.assets.first { $0.id == asset.id }?.localPath, asset.localPath)
        XCTAssertEqual(try firstStore.loadAssets().first { $0.id == asset.id }?.localPath, asset.localPath)
    }

    @MainActor
    func testTrashedOriginalWriteRequiresSameCatalog() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-trash-catalog-guard-\(UUID().uuidString)")
        let firstPackage = dir.appendingPathComponent("First.photolibrary")
        let secondPackage = dir.appendingPathComponent("Second.photolibrary")
        defer { try? FileManager.default.removeItem(at: dir) }

        let firstStore = try makeCatalogWithOneAsset(at: firstPackage, assetIndex: 0)
        _ = try makeCatalogWithOneAsset(at: secondPackage, assetIndex: 1)
        let asset = try XCTUnwrap(try firstStore.loadAssets().first)

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: firstPackage))

        var report = OriginalTrashReport()
        report.trashedIds = [asset.id]
        XCTAssertFalse(app.applyTrashedOriginals(report, expectedCatalogURL: secondPackage))
        XCTAssertFalse(app.assets.first { $0.id == asset.id }?.deleted ?? true)
        XCTAssertFalse(try firstStore.loadAssets().first { $0.id == asset.id }?.deleted ?? true)
    }
}
