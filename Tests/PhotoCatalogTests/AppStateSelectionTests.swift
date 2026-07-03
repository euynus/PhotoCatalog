import XCTest
@testable import PhotoCatalog

final class AppStateSelectionTests: XCTestCase {
    private var previousOpenLast: Any?
    private var previousPinnedSidebarItems: Any?

    override func setUp() {
        super.setUp()
        previousOpenLast = UserDefaults.standard.object(forKey: "pc_openLast")
        previousPinnedSidebarItems = UserDefaults.standard.object(forKey: "pc_pinnedSidebarItems")
        UserDefaults.standard.set(false, forKey: "pc_openLast")
        UserDefaults.standard.removeObject(forKey: "pc_pinnedSidebarItems")
    }

    override func tearDown() {
        if let previousOpenLast {
            UserDefaults.standard.set(previousOpenLast, forKey: "pc_openLast")
        } else {
            UserDefaults.standard.removeObject(forKey: "pc_openLast")
        }
        if let previousPinnedSidebarItems {
            UserDefaults.standard.set(previousPinnedSidebarItems, forKey: "pc_pinnedSidebarItems")
        } else {
            UserDefaults.standard.removeObject(forKey: "pc_pinnedSidebarItems")
        }
        super.tearDown()
    }

    @MainActor
    func testCompareSelectionTracksSearchResults() {
        let app = AppState()
        app.onboarded = true
        app.switchView(.compare)

        XCTAssertEqual(app.compareIds.count, 3)
        let firstId = app.compareIds[0]
        let firstFilename = app.assets.first { $0.id == firstId }?.filename
        XCTAssertNotNil(firstFilename)

        app.setSearch(firstFilename ?? "")
        XCTAssertEqual(app.compareIds, [firstId])
        XCTAssertEqual(app.selectedIds, Set([firstId]))

        app.setSearch("NO_SUCH_PHOTO_123")
        XCTAssertTrue(app.compareIds.isEmpty)
        XCTAssertTrue(app.selectedIds.isEmpty)
        XCTAssertNil(app.primaryId)
    }

    @MainActor
    func testMetadataKeyboardShortcutsApplyToCurrentSelection() throws {
        let app = AppState()
        app.onboarded = true
        let id = try XCTUnwrap(app.primaryId)

        XCTAssertTrue(app.handleKey("5", hasCommand: false))
        XCTAssertEqual(app.assets.first { $0.id == id }?.rating, 5)

        XCTAssertTrue(app.handleKey("0", hasCommand: false))
        XCTAssertEqual(app.assets.first { $0.id == id }?.rating, 0)

        XCTAssertTrue(app.handleKey("p", hasCommand: false))
        XCTAssertEqual(app.assets.first { $0.id == id }?.flag, .pick)
        XCTAssertTrue(app.handleKey("x", hasCommand: false))
        XCTAssertEqual(app.assets.first { $0.id == id }?.flag, .reject)
        XCTAssertTrue(app.handleKey("u", hasCommand: false))
        XCTAssertEqual(app.assets.first { $0.id == id }?.flag, Flag.none)

        XCTAssertTrue(app.handleKey("6", hasCommand: false))
        XCTAssertEqual(app.assets.first { $0.id == id }?.colorLabel, .red)
        XCTAssertTrue(app.handleKey("9", hasCommand: false))
        XCTAssertEqual(app.assets.first { $0.id == id }?.colorLabel, .blue)
    }

    @MainActor
    func testMetadataKeyboardShortcutsRequireASelection() {
        let app = AppState()
        app.onboarded = true
        let ratings = Dictionary(uniqueKeysWithValues: app.assets.map { ($0.id, $0.rating) })
        let flags = Dictionary(uniqueKeysWithValues: app.assets.map { ($0.id, $0.flag) })
        let colors = Dictionary(uniqueKeysWithValues: app.assets.map { ($0.id, $0.colorLabel) })

        app.setSearch("NO_SUCH_PHOTO_123")
        XCTAssertNil(app.primaryId)
        XCTAssertTrue(app.selectedIds.isEmpty)

        XCTAssertFalse(app.handleKey("5", hasCommand: false))
        XCTAssertFalse(app.handleKey("p", hasCommand: false))
        XCTAssertFalse(app.handleKey("6", hasCommand: false))
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: app.assets.map { ($0.id, $0.rating) }), ratings)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: app.assets.map { ($0.id, $0.flag) }), flags)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: app.assets.map { ($0.id, $0.colorLabel) }), colors)
    }

    @MainActor
    func testNavigationAndSheetKeyboardGuards() throws {
        let app = AppState()
        app.onboarded = true
        app.gridWidth = 900
        let firstId = try XCTUnwrap(app.primaryId)

        XCTAssertTrue(app.handleKey("right", hasCommand: false))
        XCTAssertNotEqual(app.primaryId, firstId)

        app.sheet = "settings"
        let selectedId = try XCTUnwrap(app.primaryId)
        let currentRating = app.assets.first { $0.id == selectedId }?.rating
        XCTAssertFalse(app.handleKey("5", hasCommand: false))
        XCTAssertEqual(app.assets.first { $0.id == selectedId }?.rating, currentRating)
        XCTAssertTrue(app.handleKey("escape", hasCommand: false))
        XCTAssertNil(app.sheet)
    }

    @MainActor
    func testSafeCommandKeyboardShortcuts() {
        let app = AppState()
        app.onboarded = true

        XCTAssertTrue(app.handleKey("f", hasCommand: true))
        XCTAssertEqual(app.searchFocusToken, 1)

        XCTAssertFalse(app.filterOpen)
        XCTAssertTrue(app.handleKey("f", hasCommand: true, hasShift: true))
        XCTAssertTrue(app.filterOpen)

        XCTAssertTrue(app.showInspector)
        XCTAssertTrue(app.handleKey("i", hasCommand: true))
        XCTAssertFalse(app.showInspector)

        XCTAssertEqual(app.thumbSize, 168)
        XCTAssertTrue(app.handleKey("=", hasCommand: true))
        XCTAssertEqual(app.thumbSize, 184)
        XCTAssertTrue(app.handleKey("-", hasCommand: true))
        XCTAssertEqual(app.thumbSize, 168)
        app.thumbSize = 220
        XCTAssertTrue(app.handleKey("0", hasCommand: true))
        XCTAssertEqual(app.thumbSize, 168)
    }

    @MainActor
    func testSelectionCommandKeyboardShortcuts() {
        let app = AppState()
        app.onboarded = true
        let visible = Set(app.list.map(\.id))
        XCTAssertFalse(visible.isEmpty)

        XCTAssertTrue(app.handleKey("a", hasCommand: true))
        XCTAssertEqual(app.selectedIds, visible)

        XCTAssertTrue(app.handleKey("a", hasCommand: true, hasShift: true))
        XCTAssertTrue(app.selectedIds.isEmpty)
        XCTAssertNil(app.primaryId)
    }

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
    func testCommandKeyboardShortcutsRespectSheets() {
        let app = AppState()
        app.onboarded = true
        app.sheet = "settings"
        let initialFilterOpen = app.filterOpen
        let initialShowInspector = app.showInspector
        let initialThumbSize = app.thumbSize

        XCTAssertFalse(app.handleKey("f", hasCommand: true, hasShift: true))
        XCTAssertFalse(app.handleKey("i", hasCommand: true))
        XCTAssertFalse(app.handleKey("=", hasCommand: true))
        XCTAssertEqual(app.filterOpen, initialFilterOpen)
        XCTAssertEqual(app.showInspector, initialShowInspector)
        XCTAssertEqual(app.thumbSize, initialThumbSize)
        XCTAssertEqual(app.sheet, "settings")
    }

    @MainActor
    func testBatchCaptureTimeActionsApplyToSelection() throws {
        let app = AppState()
        app.onboarded = true
        let id = try XCTUnwrap(app.primaryId)
        let originalDate = try XCTUnwrap(app.assets.first { $0.id == id }?.date)

        app.shiftCaptureTime(hours: 1, minutes: -15)
        let shifted = try XCTUnwrap(app.assets.first { $0.id == id })
        XCTAssertEqual(shifted.date.timeIntervalSince(originalDate), 45 * 60, accuracy: 0.1)
        XCTAssertEqual(shifted.captureDateSource, "手动调整")

        let absolute = Date(timeIntervalSince1970: 1_700_000_000)
        app.setCaptureDate(absolute)
        let updated = try XCTUnwrap(app.assets.first { $0.id == id })
        XCTAssertEqual(updated.date, absolute)
        XCTAssertEqual(updated.captureDateSource, "手动设置")
    }

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

        app.batchRename(template: "RENAMED")

        let renamed = dir.appendingPathComponent("RENAMED_0001.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
        XCTAssertEqual(app.assets.first?.filename, renamed.lastPathComponent)
        XCTAssertEqual(app.assets.first?.localPath, renamed.path)
    }

    @MainActor
    func testKeywordActionsExpandDedupeAndFilterSelection() throws {
        let app = AppState()
        app.onboarded = true
        let ids = Array(app.list.prefix(2).map(\.id))
        XCTAssertEqual(ids.count, 2)
        app.selectedIds = Set(ids)
        app.primaryId = ids[0]

        app.addKeyword("客户 / 婚礼 / 精修, 客户>婚礼>精修")

        for id in ids {
            let keywords = try XCTUnwrap(app.assets.first { $0.id == id }?.keywords)
            XCTAssertEqual(keywords.filter { $0 == "客户" }.count, 1)
            XCTAssertEqual(keywords.filter { $0 == "客户/婚礼" }.count, 1)
            XCTAssertEqual(keywords.filter { $0 == "客户/婚礼/精修" }.count, 1)
        }

        app.select(Selection(type: .keyword, id: "客户/婚礼/精修", name: "客户/婚礼/精修"))
        XCTAssertEqual(Set(app.list.map(\.id)), Set(ids))
        XCTAssertEqual(app.primaryId, ids[0])

        app.removeKeyword("客户/婚礼/精修")
        XCTAssertTrue(app.list.isEmpty)
        XCTAssertNil(app.primaryId)
        XCTAssertTrue(app.selectedIds.isEmpty)
    }

    @MainActor
    func testSearchFiltersAndSortKeepListConsistent() throws {
        let app = AppState()
        app.onboarded = true
        let filename = try XCTUnwrap(app.assets.first?.filename)

        app.setSearch(filename)
        XCTAssertFalse(app.list.isEmpty)
        XCTAssertTrue(app.list.allSatisfy { $0.filename.localizedStandardContains(filename) })
        XCTAssertEqual(app.primaryId, app.list.first?.id)

        app.setSearch("")
        var filters = Filters()
        filters.minRating = 2
        filters.type = "RAW"
        app.setFilters(filters)
        XCTAssertFalse(app.list.isEmpty)
        XCTAssertTrue(app.list.allSatisfy { $0.rating >= 2 && $0.isRaw })

        app.setFilters(Filters())
        app.setSort(Sort(field: .name, descending: false))
        let ascending = app.list.map(\.filename)
        XCTAssertEqual(ascending, ascending.sorted { $0.localizedCompare($1) == .orderedAscending })

        app.setSort(Sort(field: .name, descending: true))
        let descending = app.list.map(\.filename)
        XCTAssertEqual(descending, ascending.reversed())
    }

    @MainActor
    func testAdvancedFiltersMatchMetadataStatusAndLocation() throws {
        let app = AppState()
        app.onboarded = true

        var filters = Filters()
        filters.flag = Flag.pick.rawValue
        app.setFilters(filters)
        XCTAssertFalse(app.list.isEmpty)
        XCTAssertTrue(app.list.allSatisfy { $0.flag == .pick })

        let color = try XCTUnwrap(app.assets.first { $0.colorLabel != nil }?.colorLabel)
        filters = Filters()
        filters.color = color.rawValue
        app.setFilters(filters)
        XCTAssertFalse(app.list.isEmpty)
        XCTAssertTrue(app.list.allSatisfy { $0.colorLabel == color })

        let camera = try XCTUnwrap(app.assets.first?.camera)
        filters = Filters()
        filters.camera = camera
        app.setFilters(filters)
        XCTAssertFalse(app.list.isEmpty)
        XCTAssertTrue(app.list.allSatisfy { $0.camera.localizedStandardContains(camera) })

        let lens = try XCTUnwrap(app.assets.first?.lens)
        filters = Filters()
        filters.lens = lens
        app.setFilters(filters)
        XCTAssertFalse(app.list.isEmpty)
        XCTAssertTrue(app.list.allSatisfy { $0.lens.localizedStandardContains(lens) })

        filters = Filters()
        filters.gps = "yes"
        app.setFilters(filters)
        XCTAssertFalse(app.list.isEmpty)
        XCTAssertTrue(app.list.allSatisfy { !($0.gps.0 == 0 && $0.gps.1 == 0) })

        filters = Filters()
        filters.status = AssetStatus.missing.rawValue
        app.setFilters(filters)
        XCTAssertFalse(app.list.isEmpty)
        XCTAssertTrue(app.list.allSatisfy { $0.status == .missing })
    }

    @MainActor
    func testLibrarySelectionsFilterExpectedAssets() {
        let app = AppState()
        app.onboarded = true

        app.select(Selection(type: .lib, id: "unrated", name: "未评分"))
        XCTAssertFalse(app.list.isEmpty)
        XCTAssertTrue(app.list.allSatisfy { $0.rating == 0 && $0.flag != .reject })

        app.select(Selection(type: .lib, id: "missing", name: "缺失 / 离线"))
        XCTAssertFalse(app.list.isEmpty)
        XCTAssertTrue(app.list.allSatisfy { $0.status == .missing || $0.status == .offline })
        XCTAssertEqual(app.primaryId, app.list.first?.id)
    }

    @MainActor
    func testProjectAndClientSelectionsFilterExpectedAssets() throws {
        let app = AppState()
        app.onboarded = true
        let project = try XCTUnwrap(app.projectList.first)
        let client = try XCTUnwrap(app.clientList.first)

        app.select(Selection(type: .project, id: project.name, name: project.name))
        XCTAssertEqual(app.list.count, project.count)
        XCTAssertTrue(app.list.allSatisfy { $0.project == project.name })
        XCTAssertEqual(app.primaryId, app.list.first?.id)

        app.select(Selection(type: .client, id: client.name, name: client.name))
        XCTAssertEqual(app.list.count, client.count)
        XCTAssertTrue(app.list.allSatisfy { $0.client == client.name })
        XCTAssertEqual(app.primaryId, app.list.first?.id)
    }

    @MainActor
    func testSettingsPersistAcrossAppStateInstances() throws {
        let keys = [
            "pc_importMode", "pc_managedArchive", "pc_importDuplicateStrategy",
            "pc_importPostKeywords", "pc_importPostColorLabel", "pc_importPostAlbumName",
            "pc_exportXMP", "pc_readXMP", "pc_autoWriteXMP", "pc_exportDirectoryStructure",
            "pc_exportPresets", "pc_recentDays", "pc_lowPower", "pc_vision",
            "pc_cacheLimitMB", "pc_previewMaxPixel", "pc_autoBackupFrequency",
        ]
        let defaults = UserDefaults.standard
        let saved = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        keys.forEach { defaults.removeObject(forKey: $0) }
        defer {
            for key in keys {
                if let value = saved[key] ?? nil {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        let app = AppState()
        app.onboarded = true
        app.importMode = .managed
        app.managedArchiveRule = .camera
        app.importDuplicateStrategy = .skipExact
        app.importPostKeywords = "旅行,客户"
        app.importPostColorLabel = ColorLabel.blue.rawValue
        app.importPostAlbumName = "客户交付"
        app.exportDirectoryStructure = .album
        app.exportWritesXMP = true
        app.readXMPSidecar = false
        app.autoWriteXMPSidecar = true
        app.recentImportDays = 30
        app.reduceBackgroundOnLowPower = false
        app.visionEnabled = true
        app.cacheLimitMB = 4_096
        app.previewMaxPixel = 1_600
        app.automaticBackupFrequency = "daily"
        app.saveExportPreset(name: "客户交付")

        let restored = AppState()

        XCTAssertEqual(restored.importMode, .managed)
        XCTAssertEqual(restored.managedArchiveRule, .camera)
        XCTAssertEqual(restored.importDuplicateStrategy, .skipExact)
        XCTAssertEqual(restored.importPostKeywords, "旅行,客户")
        XCTAssertEqual(restored.importPostColorLabel, ColorLabel.blue.rawValue)
        XCTAssertEqual(restored.importPostAlbumName, "客户交付")
        XCTAssertEqual(restored.exportDirectoryStructure, .album)
        XCTAssertTrue(restored.exportWritesXMP)
        XCTAssertFalse(restored.readXMPSidecar)
        XCTAssertTrue(restored.autoWriteXMPSidecar)
        XCTAssertEqual(restored.recentImportDays, 30)
        XCTAssertFalse(restored.reduceBackgroundOnLowPower)
        XCTAssertTrue(restored.visionEnabled)
        XCTAssertEqual(restored.cacheLimitMB, 4_096)
        XCTAssertEqual(restored.previewMaxPixel, 1_600)
        XCTAssertEqual(restored.automaticBackupFrequency, "daily")
        XCTAssertEqual(restored.exportPresets, [
            ExportPreset(name: "客户交付", directoryStructure: "album", writesXMP: true)
        ])
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
    func testThumbnailMaintenanceSkipsSoftDeletedAssets() throws {
        let app = AppState()
        var live = try XCTUnwrap(app.assets.first)
        var deleted = try XCTUnwrap(app.assets.dropFirst().first)
        live.isDemo = false
        live.localPath = "/tmp/live.jpg"
        live.deleted = false
        deleted.isDemo = false
        deleted.localPath = "/tmp/deleted.jpg"
        deleted.deleted = true
        app.assets = [live, deleted]

        XCTAssertEqual(app.thumbnailMaintenanceAssets.map(\.id), [live.id])
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
    func testExportingDemoOriginalsShowsAccurateMessage() {
        let app = AppState()
        app.onboarded = true

        app.exportSelection()

        XCTAssertEqual(app.toastCenter.toasts.last?.message, "演示照片没有本地原件可导出")
        XCTAssertEqual(app.toastCenter.toasts.last?.icon, "warning")
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
}
