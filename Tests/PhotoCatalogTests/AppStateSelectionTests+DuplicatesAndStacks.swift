import XCTest
@testable import PhotoCatalog

extension AppStateSelectionTests {
    @MainActor
    func testStackToggleKeepsSelectionVisible() throws {
        let app = AppState()
        app.onboarded = true
        let stackAssets = Array(app.list.prefix(2))
        XCTAssertEqual(stackAssets.count, 2)
        app.duplicateGroupsCache = [
            DuplicateGroup(id: "dg-test", method: "contentHash", score: 1, items: stackAssets)
        ]
        let fullCount = app.list.count

        app.setPrimary(stackAssets[1].id)
        app.toggleStack(containing: stackAssets[1].id)

        XCTAssertEqual(app.list.count, fullCount - 1)
        XCTAssertTrue(app.list.contains { $0.id == stackAssets[0].id })
        XCTAssertFalse(app.list.contains { $0.id == stackAssets[1].id })
        XCTAssertEqual(app.primaryId, app.list.first?.id)
        XCTAssertTrue(app.primaryId.map { app.selectedIds.contains($0) } ?? false)
        XCTAssertEqual(app.stackInfo(for: stackAssets[0])?.collapsed, true)

        app.toggleStack(containing: stackAssets[0].id)

        XCTAssertEqual(app.list.count, fullCount)
        XCTAssertTrue(app.list.contains { $0.id == stackAssets[1].id })
        XCTAssertEqual(app.stackInfo(for: stackAssets[0])?.collapsed, false)
    }

    @MainActor
    func testDuplicateBadgeRefreshKeepsUncollapsedListCache() throws {
        let app = AppState()
        app.onboarded = true
        let stackAssets = Array(app.list.prefix(2))
        XCTAssertEqual(stackAssets.count, 2)

        _ = app.stackInfo(for: stackAssets[0])
        let before = app.list
        let beforeStorage = before.withUnsafeBufferPointer { buffer in
            buffer.baseAddress.map { UInt(bitPattern: UnsafeRawPointer($0)) }
        }

        app.duplicateGroupsCache = [
            DuplicateGroup(id: "dg-refresh", method: "contentHash", score: 1, items: stackAssets)
        ]

        let after = app.list
        let afterStorage = after.withUnsafeBufferPointer { buffer in
            buffer.baseAddress.map { UInt(bitPattern: UnsafeRawPointer($0)) }
        }
        XCTAssertEqual(afterStorage, beforeStorage)
        XCTAssertEqual(app.stackInfo(for: stackAssets[0])?.count, 2)
    }

    @MainActor
    func testRemovingDemoAssetDropsDuplicateGhosts() throws {
        let app = AppState()
        app.onboarded = true
        let duplicateAssetId = try XCTUnwrap(app.duplicateGroups.first?.items.first?.id)

        app.setPrimary(duplicateAssetId)
        app.removeSelected()

        XCTAssertTrue(app.assets.first { $0.id == duplicateAssetId }?.deleted ?? false)
        XCTAssertFalse(app.list.contains { $0.id == duplicateAssetId })
        XCTAssertFalse(app.duplicateGroups.contains { group in
            group.items.contains { $0.id == duplicateAssetId }
        })
        XCTAssertFalse(app.selectedIds.contains(duplicateAssetId))
    }

    @MainActor
    func testDuplicateResolutionRejectsKeepIdOutsideGroup() throws {
        var assets = Array(DemoData.assets.prefix(2))
        let group = DuplicateGroup(id: "dg-invalid-keep", method: "contentHash", score: 1, items: assets)

        let report = DuplicateResolutionService.resolve(group, keepId: "not-in-group",
                                                        in: &assets, action: .removeFromCatalog)

        XCTAssertTrue(report.removedIds.isEmpty)
        XCTAssertEqual(report.failedCount, 1)
        XCTAssertTrue(assets.allSatisfy { !$0.deleted })
    }

    func testDuplicateReclaimEstimateSkipsKeptAsset() {
        var first = DemoData.assets[0]
        var second = DemoData.assets[1]
        var third = DemoData.assets[2]
        first.fileMB = 10
        second.fileMB = 2.5
        third.fileMB = 3.5
        let group = DuplicateGroup(id: "dg-reclaim", method: "contentHash", score: 1,
                                   items: [first, second, third])

        XCTAssertEqual(duplicateReclaimMegabytes([group]), 6)
    }

    @MainActor
    func testDuplicateTrashResolutionRequiresConfirmation() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-duplicate-trash-confirm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var assets = Array(DemoData.assets.prefix(2))
        for index in assets.indices {
            let file = dir.appendingPathComponent("duplicate-\(index).jpg")
            try Data("duplicate-\(index)".utf8).write(to: file)
            assets[index].isDemo = false
            assets[index].deleted = false
            assets[index].localPath = file.path
            assets[index].contentHash = "same-content"
        }

        let app = AppState()
        app.onboarded = true
        app.assets = assets
        let group = DuplicateGroup(id: "dg-confirm-trash", method: "contentHash", score: 1, items: assets)
        app.duplicateGroupsCache = [group]

        var prompts: [(String, String, String)] = []
        app.confirmDestructiveAction = { title, message, confirmTitle in
            prompts.append((title, message, confirmTitle))
            return false
        }

        XCTAssertFalse(app.resolveDuplicateGroup(group, keepId: assets[0].id, action: .moveToTrash))
        XCTAssertEqual(prompts.count, 1)
        XCTAssertEqual(prompts[0].0, "移到废纸篓？")
        XCTAssertTrue(prompts[0].1.contains("1 个重复照片"))
        XCTAssertEqual(prompts[0].2, "移到废纸篓")
        XCTAssertTrue(app.assets.allSatisfy { !$0.deleted })
        XCTAssertEqual(app.duplicateGroups.count, 1)
        for asset in assets {
            XCTAssertTrue(FileManager.default.fileExists(atPath: asset.localPath ?? ""))
        }
    }

    @MainActor
    func testDuplicateCatalogRemovalRequiresConfirmation() throws {
        var assets = Array(DemoData.assets.prefix(2))
        for index in assets.indices {
            assets[index].isDemo = false
            assets[index].deleted = false
            assets[index].contentHash = "same-content"
        }

        let app = AppState()
        app.onboarded = true
        app.assets = assets
        let group = DuplicateGroup(id: "dg-confirm-remove", method: "contentHash", score: 1, items: assets)
        app.duplicateGroupsCache = [group]

        var prompts: [(String, String, String)] = []
        app.confirmDestructiveAction = { title, message, confirmTitle in
            prompts.append((title, message, confirmTitle))
            return false
        }

        XCTAssertFalse(app.resolveDuplicateGroup(group, keepId: assets[0].id, action: .removeFromCatalog))
        XCTAssertEqual(prompts.count, 1)
        XCTAssertEqual(prompts[0].0, "从目录库移除？")
        XCTAssertTrue(prompts[0].1.contains("1 个重复照片记录"))
        XCTAssertEqual(prompts[0].2, "移除")
        XCTAssertTrue(app.assets.allSatisfy { !$0.deleted })
        XCTAssertEqual(app.duplicateGroups.count, 1)
    }

    @MainActor
    func testDuplicateTrashResolutionRollsBackWhenCatalogSaveFails() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-duplicate-trash-rollback-\(UUID().uuidString)")
        let package = dir.appendingPathComponent("Library.photolibrary")
        let sourceDir = dir.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try CatalogStore(packageURL: package)
        var assets = Array(DemoData.assets.prefix(2))
        for index in assets.indices {
            let file = sourceDir.appendingPathComponent("duplicate-\(index).jpg")
            try Data("duplicate-\(index)".utf8).write(to: file)
            assets[index].isDemo = false
            assets[index].deleted = false
            assets[index].localPath = file.path
            assets[index].contentHash = "same-content"
        }
        try store.upsert(assets)

        let db = try Database(path: package.appendingPathComponent("catalog.sqlite").path)
        try db.execChecked("""
        CREATE TRIGGER fail_duplicate_delete BEFORE UPDATE OF deleted ON assets
        WHEN NEW.deleted = 1
        BEGIN
          SELECT RAISE(ABORT, 'forced duplicate delete failure');
        END;
        """)

        let app = AppState()
        app.onboarded = true
        app.confirmDestructiveAction = { _, _, _ in true }
        XCTAssertTrue(app.openCatalog(at: package))
        let group = DuplicateGroup(id: "dg-trash-rollback", method: "contentHash", score: 1, items: assets)
        app.duplicateGroupsCache = [group]

        XCTAssertFalse(app.resolveDuplicateGroup(group, keepId: assets[0].id, action: .moveToTrash))

        XCTAssertTrue(FileManager.default.fileExists(atPath: assets[1].localPath ?? ""))
        XCTAssertFalse(app.assets.first { $0.id == assets[1].id }?.deleted ?? true)
        XCTAssertFalse(try store.loadAssets().first { $0.id == assets[1].id }?.deleted ?? true)
        XCTAssertEqual(app.toastCenter.toasts.last?.message,
                       "重复文件处理未完成 · 已回滚 1 个原件 · 目录库保存失败")
    }

    @MainActor
    func testStaleDuplicateRecomputeResultIsIgnored() async throws {
        let app = AppState()
        app.onboarded = true
        let realDuplicates = app.assets.prefix(2).map { asset -> Asset in
            var copy = asset
            copy.isDemo = false
            copy.deleted = false
            copy.fileMB = 1
            copy.contentHash = "same-content"
            return copy
        }
        XCTAssertEqual(realDuplicates.count, 2)

        app.assets = realDuplicates
        app.duplicateGroupsCache = []
        app.recomputeDuplicates()
        app.assets = DemoData.assets
        app.recomputeDuplicates()

        try await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(app.duplicateGroups.contains { group in
            group.items.contains { !$0.isDemo }
        })
    }

    @MainActor
    func testClosingCatalogInvalidatesDuplicateRecomputeResult() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-close-duplicates-\(UUID().uuidString)")
        let package = root.appendingPathComponent("Library.photolibrary")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try CatalogStore(packageURL: package)

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))

        let realDuplicates = DemoData.assets.prefix(2).map { asset -> Asset in
            var copy = asset
            copy.isDemo = false
            copy.deleted = false
            copy.fileMB = 1
            copy.contentHash = "same-content"
            return copy
        }
        XCTAssertEqual(realDuplicates.count, 2)

        app.assets = realDuplicates
        app.duplicateGroupsCache = []
        app.recomputeDuplicates()
        app.closeCatalog()

        try await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(app.duplicateGroups.contains { group in
            group.items.contains { !$0.isDemo }
        })
    }
}
