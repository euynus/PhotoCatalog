import XCTest
import Observation
@testable import PhotoCatalog

private actor ObservationFlag {
    private var changed = false
    func markChanged() { changed = true }
    func value() -> Bool { changed }
}

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

    func testExposureFormattingHidesUnknownValues() {
        XCTAssertEqual(formatFocalLength(0), "—")
        XCTAssertEqual(formatApertureValue(0), "—")
        XCTAssertEqual(formatShutterSpeed(""), "—")
        XCTAssertEqual(formatISO(0), "—")

        XCTAssertEqual(formatFocalLength(63), "63mm")
        XCTAssertEqual(formatApertureValue(2.8), "ƒ/2.8")
        XCTAssertEqual(formatShutterSpeed("1/200"), "1/200s")
        XCTAssertEqual(formatISO(400), "ISO400")
    }

    func testGPSFormattingHidesMissingCoordinates() {
        XCTAssertFalse(hasGPS((0, 0)))
        XCTAssertEqual(formatGPSLabel((0, 0), altitude: nil), "无 GPS")

        XCTAssertTrue(hasGPS((31.2345, 121.4567)))
        XCTAssertEqual(formatGPSLabel((31.2345, 121.4567), altitude: 88.5),
                       "31.2345, 121.4567 · 88.5 m")
    }

    func testMetadataReaderAcceptsImageIOISOTypes() {
        XCTAssertEqual(MetadataReader.isoSpeed(from: [NSNumber(value: 640)]), 640)
        XCTAssertEqual(MetadataReader.isoSpeed(from: NSNumber(value: 800)), 800)
        XCTAssertEqual(MetadataReader.isoSpeed(from: [100]), 100)
        XCTAssertNil(MetadataReader.isoSpeed(from: nil))
    }

    func testMetadataReaderAvoidsDuplicateCameraMake() {
        XCTAssertEqual(MetadataReader.cameraName(make: "Canon", model: "Canon EOS R6m2"), "Canon EOS R6m2")
        XCTAssertEqual(MetadataReader.cameraName(make: "Canon", model: "Canon Canon EOS R6m2"), "Canon EOS R6m2")
        XCTAssertEqual(MetadataReader.normalizedCameraName("Canon Canon EOS R6m2"), "Canon EOS R6m2")
        XCTAssertEqual(MetadataReader.cameraName(make: "Canon", model: "EOS R5"), "Canon EOS R5")
        XCTAssertEqual(MetadataReader.cameraName(make: "", model: "X-T5"), "X-T5")
    }

    @MainActor
    func testSelectionMutationRefreshesCachedListAndPrimary() throws {
        let app = AppState()
        app.onboarded = true
        let id = try XCTUnwrap(app.primaryId)
        _ = app.list

        XCTAssertTrue(app.handleKey("4", hasCommand: false))

        XCTAssertEqual(app.primary?.rating, 4)
        XCTAssertEqual(app.list.first { $0.id == id }?.rating, 4)
    }

    @MainActor
    func testPrimaryObservationInvalidatesAfterSelectionMutation() async throws {
        let app = AppState()
        app.onboarded = true
        let flag = ObservationFlag()
        withObservationTracking {
            _ = app.primary?.rating
        } onChange: {
            Task { await flag.markChanged() }
        }

        XCTAssertTrue(app.handleKey("4", hasCommand: false))
        try await Task.sleep(for: .milliseconds(50))

        let didChange = await flag.value()
        XCTAssertTrue(didChange)
        XCTAssertEqual(app.primary?.rating, 4)
    }

    @MainActor
    func testSingleAssetMutationRefreshesCachedList() throws {
        let app = AppState()
        app.onboarded = true
        let id = try XCTUnwrap(app.primaryId)
        _ = app.list

        app.mutateAsset(id) { $0.flag = .pick }

        XCTAssertEqual(app.primary?.flag, .pick)
        XCTAssertEqual(app.list.first { $0.id == id }?.flag, .pick)
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
    func testDuplicateResolutionRejectsKeepIdOutsideGroup() throws {
        var assets = Array(DemoData.assets.prefix(2))
        let group = DuplicateGroup(id: "dg-invalid-keep", method: "contentHash", score: 1, items: assets)

        let report = DuplicateResolutionService.resolve(group, keepId: "not-in-group",
                                                        in: &assets, action: .removeFromCatalog)

        XCTAssertTrue(report.removedIds.isEmpty)
        XCTAssertEqual(report.failedCount, 1)
        XCTAssertTrue(assets.allSatisfy { !$0.deleted })
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
    func testClearingSecurityBookmarksRequiresSourceReauthorization() throws {
        let defaults = UserDefaults.standard
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
        XCTAssertTrue(app.openCatalog(at: package))
        XCTAssertEqual(app.folders.first { $0.id == "source-1" }?.status, "online")

        app.clearSecurityBookmarks()

        let root = try XCTUnwrap(try store.loadSourceRoots().first { $0.id == "source-1" })
        XCTAssertNil(root.bookmarkData)
        XCTAssertEqual(root.status, "permissionLost")
        XCTAssertEqual(app.folders.first { $0.id == "source-1" }?.status, "permissionLost")

        app.rescanCurrentSource()
        XCTAssertEqual(app.toastCenter.toasts.last?.message, "当前没有可重新扫描的源")
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
            Asset(id: base.id, pid: base.pid, ori: base.ori, thumb: base.thumb, preview: base.preview,
                  filename: path.lastPathComponent, type: base.type, isRaw: base.isRaw, folderId: folderId,
                  folderName: folderId, date: base.date, width: base.width, height: base.height,
                  orientation: base.orientation, camera: base.camera, lens: base.lens, focal: base.focal,
                  aperture: base.aperture, shutter: base.shutter, iso: base.iso,
                  colorSpace: base.colorSpace, hasICCProfile: base.hasICCProfile, fileMB: base.fileMB,
                  fileModifiedAt: base.fileModifiedAt, fileCreatedAt: base.fileCreatedAt,
                  rating: base.rating, flag: base.flag, colorLabel: base.colorLabel,
                  keywords: base.keywords, title: base.title, caption: base.caption,
                  author: base.author, copyright: base.copyright, makerNotes: base.makerNotes,
                  project: base.project, client: base.client, location: base.location, gps: base.gps,
                  gpsAltitude: base.gpsAltitude, status: status, importedAt: base.importedAt,
                  deleted: base.deleted, localPath: path.path,
                  captureDateSource: base.captureDateSource, contentHash: base.contentHash,
                  quickHash: base.quickHash, isDemo: false, faces: base.faces,
                  perceptualHash: base.perceptualHash)
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
    func testMaintenanceActionsCleanLocalCatalogState() throws {
        let defaults = UserDefaults.standard
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
        XCTAssertTrue(app.openCatalog(at: package))

        XCTAssertTrue(app.recentCatalogs.contains { $0.path == package.path })
        app.clearRecentCatalogs()
        XCTAssertTrue(app.recentCatalogs.isEmpty)

        app.clearLogs()
        XCTAssertFalse(FileManager.default.fileExists(atPath: logFile.path))

        app.clearCache()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.thumb256URL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.preview2048URL.path))

        app.runBackup()
        XCTAssertEqual(BackupService.listBackups(store).count, 1)
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
    }

    @MainActor
    func testSourcePriorityReordersRealCatalogFolders() throws {
        let defaults = UserDefaults.standard
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
