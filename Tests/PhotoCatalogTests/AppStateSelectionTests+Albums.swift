import XCTest
@testable import PhotoCatalog

extension AppStateSelectionTests {
    @MainActor
    func testAlbumCountsIgnoreSoftDeletedAssets() throws {
        let app = AppState()
        app.onboarded = true
        let album = try XCTUnwrap(app.albums.first { $0.assetIds.count > 1 })
        let firstId = try XCTUnwrap(album.assetIds.first)
        app.select(Selection(type: .album, id: album.id, name: album.name))
        app.setPrimary(firstId)
        app.togglePinCurrentSelection()

        app.removeSelected()

        XCTAssertEqual(app.countForAlbum(album), album.assetIds.count - 1)
        let pinned = try XCTUnwrap(app.pinnedSidebarFavorites.first)
        XCTAssertEqual(app.countForPinnedSidebarItem(pinned), "\(album.assetIds.count - 1)")
    }

    @MainActor
    func testPinnedKeywordSidebarFavoriteTogglesAndCounts() throws {
        let app = AppState()
        app.onboarded = true
        let keyword = try XCTUnwrap(app.keywordList.first)

        app.select(Selection(type: .keyword, id: keyword.name, name: keyword.name))

        XCTAssertTrue(app.canPinCurrentSelection)
        XCTAssertFalse(app.isCurrentSelectionPinned)

        app.togglePinCurrentSelection()

        XCTAssertTrue(app.isCurrentSelectionPinned)
        let pinned = try XCTUnwrap(app.pinnedSidebarFavorites.first)
        XCTAssertEqual(pinned.type, .keyword)
        XCTAssertEqual(pinned.selectionId, keyword.name)
        XCTAssertEqual(app.countForPinnedSidebarItem(pinned), "\(keyword.count)")

        app.togglePinCurrentSelection()

        XCTAssertFalse(app.isCurrentSelectionPinned)
        XCTAssertTrue(app.pinnedSidebarFavorites.isEmpty)
    }

    @MainActor
    func testSavingSmartAlbumSelectsMatchingDynamicCollection() {
        let app = AppState()
        app.onboarded = true
        app.sheet = "smart"
        let target = app.assets.first { $0.id != app.primaryId && !$0.deleted }!
        let rule = SmartRule(match: "all", conditions: [
            SmartCondition(field: "search", op: "包含", value: target.filename),
        ])
        let expectedCount = SmartMatcher.count(app.assets.filter { !$0.deleted }, rule)

        app.saveSmart(name: "高分 RAW", rule: rule, count: expectedCount)

        XCTAssertNil(app.sheet)
        XCTAssertEqual(app.selection.type, .smart)
        XCTAssertEqual(app.selection.name, "高分 RAW")
        XCTAssertEqual(app.smartAlbums.last?.name, "高分 RAW")
        XCTAssertEqual(app.smartAlbums.last?.count, expectedCount)
        XCTAssertEqual(app.list.count, expectedCount)
        XCTAssertTrue(app.list.allSatisfy { $0.filename.localizedStandardContains(target.filename) })
        XCTAssertEqual(app.primaryId, app.list.first?.id)
        XCTAssertEqual(app.selectedIds, Set(app.list.prefix(1).map(\.id)))
    }

    @MainActor
    func testSmartAlbumBuilderStateDoesNotLeakIntoNewAlbums() throws {
        let app = AppState()
        app.onboarded = true
        let album = try XCTUnwrap(app.smartAlbums.first)

        app.editSmartAlbum(album.id)
        XCTAssertEqual(app.smartAlbumEditingID, album.id)

        app.sheet = nil
        XCTAssertNil(app.smartAlbumEditingID)

        app.editSmartAlbum(album.id)
        app.showNewSmartAlbumBuilder()
        XCTAssertEqual(app.sheet, "smart")
        XCTAssertNil(app.smartAlbumEditingID)
    }

    @MainActor
    func testRemovingFromManualAlbumKeepsSelectionVisible() throws {
        let app = AppState()
        app.onboarded = true
        let album = try XCTUnwrap(app.albums.first { $0.assetIds.count > 1 })
        app.select(Selection(type: .album, id: album.id, name: album.name))
        let firstVisible = try XCTUnwrap(app.list.first?.id)

        app.setPrimary(firstVisible)
        app.removeSelectionFromCurrentAlbum()

        XCTAssertFalse(app.albums.first { $0.id == album.id }?.assetIds.contains(firstVisible) ?? true)
        XCTAssertFalse(app.list.contains { $0.id == firstVisible })
        XCTAssertFalse(app.selectedIds.contains(firstVisible))
        XCTAssertEqual(app.primaryId, app.list.first?.id)
        XCTAssertTrue(app.primaryId.map { app.selectedIds.contains($0) } ?? app.selectedIds.isEmpty)

        XCTAssertTrue(app.selectAllVisible())
        app.removeSelectionFromCurrentAlbum()

        XCTAssertTrue(app.list.isEmpty)
        XCTAssertNil(app.primaryId)
        XCTAssertTrue(app.selectedIds.isEmpty)
    }

    @MainActor
    func testRenamingAndDeletingManualAlbumKeepsPhotos() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-album-appstate-crud-\(UUID().uuidString)")
        let package = dir.appendingPathComponent("Library.photolibrary")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try CatalogStore(packageURL: package)
        var asset = DemoData.assets[0]
        asset.isDemo = false
        try store.upsert([asset])
        try store.saveAlbum(Album(id: "album-1", name: "Before", assetIds: [asset.id]))

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))
        app.select(Selection(type: .album, id: "album-1", name: "Before"))

        XCTAssertTrue(app.renameAlbum("album-1", to: "After"))
        XCTAssertEqual(app.selection.name, "After")
        XCTAssertEqual(try store.loadAlbums().first?.name, "After")

        app.confirmDestructiveAction = { title, message, confirmTitle in
            XCTAssertEqual(title, "删除相册？")
            XCTAssertTrue(message.contains("不会删除任何照片或原件"))
            XCTAssertEqual(confirmTitle, "删除相册")
            return true
        }
        app.deleteAlbum("album-1")

        XCTAssertTrue(app.albums.isEmpty)
        XCTAssertEqual(app.selection, Selection(type: .lib, id: "all", name: "全部照片"))
        XCTAssertEqual(app.assets.map(\.id), [asset.id])
        XCTAssertTrue(try store.loadAlbums().isEmpty)
        XCTAssertEqual(store.assetCount(), 1)
    }

    @MainActor
    func testEditingAndDeletingSmartAlbumKeepsPhotos() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-smart-album-appstate-crud-\(UUID().uuidString)")
        let package = dir.appendingPathComponent("Library.photolibrary")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try CatalogStore(packageURL: package)
        var asset = DemoData.assets[0]
        asset.isDemo = false
        asset.rating = 5
        try store.upsert([asset])
        let initialRule = SmartRule(match: "all", conditions: [
            SmartCondition(field: "rating", op: ">=", value: "4"),
        ])
        try store.saveSmartAlbum(SmartAlbum(id: "smart-1", name: "Before", rule: initialRule, count: 1))

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))
        app.select(Selection(type: .smart, id: "smart-1", name: "Before"))
        app.editSmartAlbum("smart-1")

        XCTAssertEqual(app.sheet, "smart")
        XCTAssertEqual(app.smartAlbumEditingID, "smart-1")

        let updatedRule = SmartRule(match: "all", conditions: [
            SmartCondition(field: "search", op: "包含", value: asset.filename),
        ])
        app.saveSmart(name: "After", rule: updatedRule, count: 1)

        XCTAssertNil(app.sheet)
        XCTAssertNil(app.smartAlbumEditingID)
        XCTAssertEqual(app.smartAlbums.count, 1)
        XCTAssertEqual(app.smartAlbums.first?.name, "After")
        XCTAssertEqual(app.smartAlbums.first?.rule, updatedRule)
        XCTAssertEqual(app.selection, Selection(type: .smart, id: "smart-1", name: "After"))
        XCTAssertEqual(try store.loadSmartAlbums().first?.name, "After")

        app.confirmDestructiveAction = { title, message, confirmTitle in
            XCTAssertEqual(title, "删除智能相册？")
            XCTAssertTrue(message.contains("不会删除任何照片或原件"))
            XCTAssertEqual(confirmTitle, "删除智能相册")
            return true
        }
        app.deleteSmartAlbum("smart-1")

        XCTAssertTrue(app.smartAlbums.isEmpty)
        XCTAssertEqual(app.selection, Selection(type: .lib, id: "all", name: "全部照片"))
        XCTAssertEqual(app.assets.map(\.id), [asset.id])
        XCTAssertTrue(try store.loadSmartAlbums().isEmpty)
        XCTAssertEqual(store.assetCount(), 1)
    }
}
