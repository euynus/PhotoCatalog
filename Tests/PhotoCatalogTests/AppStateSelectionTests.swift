import XCTest
import Observation
import ImageIO
import AppKit
import UniformTypeIdentifiers
@testable import PhotoCatalog

private actor ObservationFlag {
    private var changed = false
    func markChanged() { changed = true }
    func value() -> Bool { changed }
}

final class AppStateSelectionTests: XCTestCase {
    private var previousOpenLast: Any?
    private var previousCatalogURL: Any?
    private var previousOnboarded: Any?
    private var previousPinnedSidebarItems: Any?

    override func setUp() {
        super.setUp()
        previousOpenLast = UserDefaults.standard.object(forKey: "pc_openLast")
        previousCatalogURL = UserDefaults.standard.object(forKey: "pc_catalogURL")
        previousOnboarded = UserDefaults.standard.object(forKey: "pc_onboarded")
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
        if let previousCatalogURL {
            UserDefaults.standard.set(previousCatalogURL, forKey: "pc_catalogURL")
        } else {
            UserDefaults.standard.removeObject(forKey: "pc_catalogURL")
        }
        if let previousOnboarded {
            UserDefaults.standard.set(previousOnboarded, forKey: "pc_onboarded")
        } else {
            UserDefaults.standard.removeObject(forKey: "pc_onboarded")
        }
        if let previousPinnedSidebarItems {
            UserDefaults.standard.set(previousPinnedSidebarItems, forKey: "pc_pinnedSidebarItems")
        } else {
            UserDefaults.standard.removeObject(forKey: "pc_pinnedSidebarItems")
        }
        super.tearDown()
    }

    @MainActor
    private func waitUntil(_ message: String, timeout: TimeInterval = 1,
                           condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail(message)
        throw NSError(domain: "PhotoCatalogTests.Wait", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: message])
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
    func testCompareMembershipKeepsKeyboardSelectionAligned() throws {
        let app = AppState()
        app.onboarded = true
        app.switchView(.compare)
        let removed = try XCTUnwrap(app.compareIds.first)
        let replacement = try XCTUnwrap(app.list.first { !app.compareIds.contains($0.id) }?.id)
        app.winner = removed

        app.removeFromCompare(removed)

        XCTAssertFalse(app.compareIds.contains(removed))
        XCTAssertEqual(app.selectedIds, Set(app.compareIds))
        XCTAssertFalse(app.selectedIds.contains(removed))
        XCTAssertNil(app.winner)

        app.addToCompare(replacement)

        XCTAssertTrue(app.compareIds.contains(replacement))
        XCTAssertEqual(app.selectedIds, Set(app.compareIds))
    }

    @MainActor
    func testMetadataKeyboardShortcutsApplyToCurrentSelection() throws {
        let app = AppState()
        app.onboarded = true
        let id = try XCTUnwrap(app.primaryId)

        for rating in 1...5 {
            XCTAssertTrue(app.handleKey("\(rating)", hasCommand: false))
            XCTAssertEqual(app.assets.first { $0.id == id }?.rating, rating)
        }

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
        XCTAssertTrue(app.handleKey("7", hasCommand: false))
        XCTAssertEqual(app.assets.first { $0.id == id }?.colorLabel, .yellow)
        XCTAssertTrue(app.handleKey("8", hasCommand: false))
        XCTAssertEqual(app.assets.first { $0.id == id }?.colorLabel, .green)
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
        XCTAssertFalse(app.hasSelection)

        XCTAssertFalse(app.handleKey("5", hasCommand: false))
        XCTAssertFalse(app.handleKey("p", hasCommand: false))
        XCTAssertFalse(app.handleKey("6", hasCommand: false))
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: app.assets.map { ($0.id, $0.rating) }), ratings)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: app.assets.map { ($0.id, $0.flag) }), flags)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: app.assets.map { ($0.id, $0.colorLabel) }), colors)
    }

    @MainActor
    func testExportSelectionRequiresASelection() {
        let app = AppState()
        app.onboarded = true

        XCTAssertFalse(app.canOperateOnSelectedOriginals)
        XCTAssertFalse(app.canExportOriginalSelection)
        XCTAssertFalse(app.canExportPreviewSelection)

        app.setSearch("NO_SUCH_PHOTO_123")
        XCTAssertFalse(app.canExportOriginalSelection)
        XCTAssertFalse(app.canExportPreviewSelection)

        app.exportSelection()

        XCTAssertEqual(app.toastCenter.toasts.last?.message, "请先选择照片")
    }

    @MainActor
    func testExportActionsRequireLocalOriginals() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-export-actions-\(UUID().uuidString)")
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

        XCTAssertTrue(app.canOperateOnSelectedOriginals)
        XCTAssertTrue(app.canExportOriginalSelection)
        XCTAssertTrue(app.canExportPreviewSelection)
    }

    @MainActor
    func testPreviewExportAllowsCachedPreviewWithoutOriginal() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-preview-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let preview = dir.appendingPathComponent("preview.jpg")
        try Data("preview".utf8).write(to: preview)

        let app = AppState()
        app.onboarded = true
        let base = try XCTUnwrap(app.assets.first)
        let asset = Asset(id: base.id, pid: base.pid, ori: base.ori, thumb: base.thumb, preview: preview.path,
                          filename: base.filename, type: base.type, isRaw: base.isRaw, folderId: base.folderId,
                          folderName: base.folderName, date: base.date, width: base.width, height: base.height,
                          orientation: base.orientation, camera: base.camera, lens: base.lens, focal: base.focal,
                          aperture: base.aperture, shutter: base.shutter, iso: base.iso,
                          colorSpace: base.colorSpace, hasICCProfile: base.hasICCProfile, fileMB: base.fileMB,
                          fileModifiedAt: base.fileModifiedAt, fileCreatedAt: base.fileCreatedAt,
                          rating: base.rating, flag: base.flag, colorLabel: base.colorLabel,
                          keywords: base.keywords, title: base.title, caption: base.caption,
                          author: base.author, copyright: base.copyright, makerNotes: base.makerNotes,
                          project: base.project, client: base.client, location: base.location, gps: base.gps,
                          gpsAltitude: base.gpsAltitude, status: .offline, importedAt: base.importedAt,
                          deleted: base.deleted, localPath: nil, captureDateSource: base.captureDateSource,
                          contentHash: base.contentHash, quickHash: base.quickHash, isDemo: false,
                          faces: base.faces, perceptualHash: base.perceptualHash)
        app.assets = [asset]
        app.primaryId = asset.id
        app.selectedIds = [asset.id]

        XCTAssertFalse(app.canOperateOnSelectedOriginals)
        XCTAssertFalse(app.canExportOriginalSelection)
        XCTAssertTrue(app.canExportPreviewSelection)
    }

    @MainActor
    func testOriginalActionsRequireExistingLocalFile() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-missing-original-\(UUID().uuidString).jpg")

        let app = AppState()
        app.onboarded = true
        var asset = try XCTUnwrap(app.assets.first)
        asset.localPath = missing.path
        asset.status = .missing
        asset.isDemo = false
        app.assets = [asset]
        app.primaryId = asset.id
        app.selectedIds = [asset.id]

        XCTAssertFalse(app.canOperateOnSelectedOriginals)
        XCTAssertFalse(app.canExportOriginalSelection)
        XCTAssertFalse(app.canExportPreviewSelection)

        app.exportSelection()

        XCTAssertEqual(app.toastCenter.toasts.last?.message, "没有可导出的本地原件")
    }

    @MainActor
    func testXMPWritesRequireExistingLocalFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-missing-xmp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appendingPathComponent("missing.jpg")
        let sidecar = XMPSidecar.sidecarURL(for: missing)

        let app = AppState()
        app.onboarded = true
        var asset = try XCTUnwrap(app.assets.first)
        asset.localPath = missing.path
        asset.status = .missing
        asset.isDemo = false
        app.assets = [asset]
        app.primaryId = asset.id
        app.selectedIds = [asset.id]

        app.writeXMPForSelection()

        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
        XCTAssertEqual(app.toastCenter.toasts.last?.message, "仅可为已导入照片写入 XMP")
    }

    @MainActor
    func testAutoXMPWritesSkipMissingOriginals() throws {
        let defaults = UserDefaults.standard
        let previousAutoWrite = defaults.object(forKey: "pc_autoWriteXMP")
        defer {
            if let previousAutoWrite {
                defaults.set(previousAutoWrite, forKey: "pc_autoWriteXMP")
            } else {
                defaults.removeObject(forKey: "pc_autoWriteXMP")
            }
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-auto-missing-xmp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let package = dir.appendingPathComponent("Library.photolibrary")
        let missing = dir.appendingPathComponent("missing.jpg")
        let sidecar = XMPSidecar.sidecarURL(for: missing)
        let store = try CatalogStore(packageURL: package)
        var asset = try XCTUnwrap(DemoData.assets.first)
        asset.localPath = missing.path
        asset.status = .missing
        asset.isDemo = false
        asset.deleted = false
        try store.upsert([asset])

        let app = AppState()
        app.onboarded = true
        app.autoWriteXMPSidecar = true
        XCTAssertTrue(app.openCatalog(at: package))

        app.mutateAsset(asset.id) { $0.rating = 5 }

        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
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
    func testOpeningCatalogIsBlockedDuringImportBeforeShowingPicker() {
        let app = AppState()
        app.onboarded = true
        app.importing = true

        app.openCatalog()

        XCTAssertEqual(app.toastCenter.toasts.last?.message, "导入中无法切换目录库")
        XCTAssertEqual(app.toastCenter.toasts.last?.icon, "warning")
    }

    @MainActor
    func testCloseCatalogReturnsToWelcomeAndKeepsRecentEntry() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-close-catalog-\(UUID().uuidString)")
        let package = root.appendingPathComponent("CloseMe.photolibrary")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try CatalogStore(packageURL: package)

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))
        XCTAssertTrue(app.hasOpenCatalog)

        app.sheet = "settings"
        app.filterOpen = true
        app.search = "charlie"
        app.view = .loupe
        app.closeCatalog()

        XCTAssertFalse(app.hasOpenCatalog)
        XCTAssertFalse(app.onboarded)
        XCTAssertNil(app.sheet)
        XCTAssertFalse(app.filterOpen)
        XCTAssertEqual(app.search, "")
        XCTAssertEqual(app.view, .grid)
        XCTAssertEqual(app.catalogPath, "未打开目录库")
        XCTAssertTrue(app.recentCatalogs.contains { $0.path == package.path })
        XCTAssertEqual(app.toastCenter.toasts.last?.message, "已关闭目录库")
    }

    @MainActor
    func testRecentCatalogsHideInvalidPackages() throws {
        let defaults = UserDefaults.standard
        let previousRecent = defaults.object(forKey: "pc_recentCatalogs")
        defer {
            if let previousRecent {
                defaults.set(previousRecent, forKey: "pc_recentCatalogs")
            } else {
                defaults.removeObject(forKey: "pc_recentCatalogs")
            }
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-recent-catalog-\(UUID().uuidString)")
        let valid = root.appendingPathComponent("Valid.photolibrary")
        let invalid = root.appendingPathComponent("Invalid.photolibrary")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try CatalogStore(packageURL: valid)
        try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
        defaults.set([invalid.path, valid.path], forKey: "pc_recentCatalogs")

        let app = AppState()

        XCTAssertEqual(app.recentCatalogs.map(\.path), [valid.path])
    }

    @MainActor
    func testClosedCatalogDoesNotAutoReopenDefaultOnNextLaunch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-closed-launch-\(UUID().uuidString)")
        let package = root.appendingPathComponent("Closed.photolibrary")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try CatalogStore(packageURL: package)

        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "pc_openLast")
        defaults.set(package, forKey: "pc_catalogURL")
        defaults.set("0", forKey: "pc_onboarded")

        let app = AppState()

        XCTAssertFalse(app.hasOpenCatalog)
        XCTAssertFalse(app.onboarded)
        XCTAssertEqual(app.catalogPath, "未打开目录库")
    }

    @MainActor
    func testMissingLaunchCatalogReturnsToWelcome() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-missing-launch-\(UUID().uuidString)")
            .appendingPathComponent("Missing.photolibrary")
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "pc_openLast")
        defaults.set(missing, forKey: "pc_catalogURL")
        defaults.set("1", forKey: "pc_onboarded")

        let app = AppState()

        XCTAssertFalse(app.hasOpenCatalog)
        XCTAssertFalse(app.onboarded)
        XCTAssertEqual(app.catalogPath, "未打开目录库")
    }

    @MainActor
    func testWelcomeStateDoesNotExposeHiddenDemoSelection() {
        let app = AppState()
        app.onboarded = false

        XCTAssertFalse(app.hasSelection)
        XCTAssertFalse(app.canApplySelectionToAlbum)
        XCTAssertFalse(app.canRemoveSelectionFromCurrentAlbum)
    }

    @MainActor
    func testWelcomeCommandShortcutsDoNotMutateMainViewState() {
        let app = AppState()
        app.onboarded = false
        app.thumbSize = 220

        XCTAssertFalse(app.handleKey("f", hasCommand: true))
        XCTAssertFalse(app.filterOpen)
        XCTAssertFalse(app.handleKey("i", hasCommand: true))
        XCTAssertTrue(app.showInspector)
        XCTAssertFalse(app.handleKey("0", hasCommand: true))
        XCTAssertEqual(app.thumbSize, 220)
        XCTAssertFalse(app.handleKey(",", hasCommand: true))
        XCTAssertNil(app.sheet)
    }

    @MainActor
    func testClosingCatalogIsBlockedDuringImport() {
        let app = AppState()
        app.onboarded = true
        app.importing = true

        app.closeCatalog()

        XCTAssertEqual(app.toastCenter.toasts.last?.message, "导入中无法关闭目录库")
        XCTAssertEqual(app.toastCenter.toasts.last?.icon, "warning")
    }

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
    func testOpenCatalogPanelFiltersPhotoLibraryPackages() throws {
        let app = AppState()
        let panel = NSOpenPanel()
        app.configureCatalogOpenPanel(panel)

        let libraryType = try XCTUnwrap(UTType(filenameExtension: "photolibrary"))
        XCTAssertTrue(panel.canChooseDirectories)
        XCTAssertFalse(panel.canChooseFiles)
        XCTAssertFalse(panel.allowsMultipleSelection)
        XCTAssertEqual(panel.prompt, "打开")
        XCTAssertEqual(panel.message, "选择 .photolibrary 目录库")
        XCTAssertEqual(panel.allowedContentTypes, [libraryType])
    }

    func testCatalogSelectionRequiresCatalogDatabase() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-catalog-selection-\(UUID().uuidString)")
        let plainFolder = root.appendingPathComponent("Backups")
        let package = root.appendingPathComponent("Library.photolibrary")
        try FileManager.default.createDirectory(at: plainFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertFalse(AppState.isValidCatalogSelection(plainFolder))
        XCTAssertFalse(AppState.isValidCatalogSelection(package))

        FileManager.default.createFile(atPath: package.appendingPathComponent("catalog.sqlite").path,
                                       contents: Data())
        XCTAssertTrue(AppState.isValidCatalogSelection(package))
        XCTAssertTrue(AppState.isValidCatalogSelection(root.appendingPathComponent("Library")))
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
    func testSearchFocusCanBeReleasedAfterGridSelection() {
        let app = AppState()
        app.onboarded = true

        XCTAssertEqual(app.searchBlurToken, 0)
        app.blurSearch()
        XCTAssertEqual(app.searchBlurToken, 1)
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

        XCTAssertTrue(app.handleKey("f", hasCommand: true, hasShift: true))
        XCTAssertTrue(app.handleKey("i", hasCommand: true))
        XCTAssertTrue(app.handleKey("=", hasCommand: true))
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

        app.batchRename(template: "RENAMED")

        XCTAssertEqual(app.assets.first?.localPath, missing.path)
        XCTAssertEqual(app.toastCenter.toasts.last?.message, "仅可重命名已导入照片")
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

        let renamed = try XCTUnwrap(RenameService.rename([asset], prefix: "RENAMED")[asset.id])
        XCTAssertEqual(renamed.lastPathComponent, "RENAMED_0001")
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
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
    func testLargeLibrarySearchAndSortSmoke() {
        let app = AppState()
        app.onboarded = true
        app.assets = Self.largeAssetFixture(count: 100_000)
        app.albums = []
        app.smartAlbums = []
        app.folders = [Folder(id: "perf", name: "Performance")]
        app.duplicateGroupsCache = []
        app.filters.minRating = 4
        app.setSearch("needle")
        var sort = Sort()
        sort.field = .name
        sort.descending = false
        app.setSort(sort)

        let start = ContinuousClock.now
        let matches = app.list
        let elapsed = start.duration(to: .now)

        XCTAssertEqual(matches.count, 1_000)
        XCTAssertTrue(matches.allSatisfy { $0.rating >= 4 && $0.title.contains("needle") })
        XCTAssertLessThan(Self.seconds(elapsed), 2.0)
    }

    private static func seconds(_ duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) + Double(c.attoseconds) / 1_000_000_000_000_000_000
    }

    private static func largeAssetFixture(count: Int) -> [Asset] {
        let templates = DemoData.assets
        return (0..<count).map { i in
            let t = templates[i % templates.count]
            let hit = i % 100 == 0
            return Asset(
                id: "perf-\(i)",
                pid: t.pid + i,
                ori: t.ori,
                thumb: t.thumb,
                preview: t.preview,
                filename: String(format: "IMG_%06d.%@", i, t.type),
                type: t.type,
                isRaw: t.isRaw,
                folderId: "perf",
                folderName: "Performance",
                date: t.date.addingTimeInterval(Double(i)),
                width: t.width,
                height: t.height,
                orientation: t.orientation,
                camera: t.camera,
                lens: t.lens,
                focal: t.focal,
                aperture: t.aperture,
                shutter: t.shutter,
                iso: t.iso,
                colorSpace: t.colorSpace,
                fileMB: t.fileMB,
                rating: hit ? 4 : i % 4,
                flag: t.flag,
                colorLabel: t.colorLabel,
                keywords: hit ? ["needle"] : t.keywords,
                title: hit ? "needle \(i)" : "",
                caption: t.caption,
                project: t.project,
                client: t.client,
                location: t.location,
                gps: t.gps,
                status: .ready,
                importedAt: t.importedAt.addingTimeInterval(Double(i))
            )
        }
    }

    private func makeCatalogWithOneAsset(at package: URL, assetIndex: Int) throws -> CatalogStore {
        let source = package.deletingLastPathComponent().appendingPathComponent("Source-\(assetIndex)")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let store = try CatalogStore(packageURL: package)
        var asset = DemoData.assets[assetIndex]
        let original = source.appendingPathComponent(asset.filename)
        try Data("image \(assetIndex)".utf8).write(to: original)
        asset.localPath = original.path
        asset.status = .ready
        asset.isDemo = false
        asset.deleted = false
        try store.upsert([asset])
        return store
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
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-thumbnail-maintenance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let livePath = dir.appendingPathComponent("live.jpg")
        try Data("image".utf8).write(to: livePath)

        let app = AppState()
        var live = try XCTUnwrap(app.assets.first)
        var deleted = try XCTUnwrap(app.assets.dropFirst().first)
        var missing = try XCTUnwrap(app.assets.dropFirst(2).first)
        live.isDemo = false
        live.localPath = livePath.path
        live.deleted = false
        deleted.isDemo = false
        deleted.localPath = "/tmp/deleted.jpg"
        deleted.deleted = true
        missing.isDemo = false
        missing.localPath = dir.appendingPathComponent("missing.jpg").path
        missing.deleted = false
        app.assets = [live, deleted, missing]

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
    func testManagedSourceModeRestoresIntoCatalogAndInspectorText() throws {
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
        let asset = Asset(id: base.id, pid: base.pid, ori: base.ori, thumb: base.thumb, preview: base.preview,
                          filename: original.lastPathComponent, type: base.type, isRaw: base.isRaw,
                          folderId: "source-1", folderName: "Source",
                          date: base.date, width: base.width, height: base.height,
                          orientation: base.orientation, camera: base.camera, lens: base.lens,
                          focal: base.focal, aperture: base.aperture, shutter: base.shutter, iso: base.iso,
                          colorSpace: base.colorSpace, hasICCProfile: base.hasICCProfile,
                          fileMB: base.fileMB, fileModifiedAt: base.fileModifiedAt,
                          fileCreatedAt: base.fileCreatedAt, rating: base.rating, flag: base.flag,
                          colorLabel: base.colorLabel, keywords: base.keywords, title: base.title,
                          caption: base.caption, author: base.author, copyright: base.copyright,
                          makerNotes: base.makerNotes, project: base.project, client: base.client,
                          location: base.location, gps: base.gps, gpsAltitude: base.gpsAltitude,
                          status: .ready, importedAt: base.importedAt, deleted: base.deleted,
                          localPath: original.path, captureDateSource: base.captureDateSource,
                          contentHash: base.contentHash, quickHash: base.quickHash, isDemo: false,
                          faces: base.faces, perceptualHash: base.perceptualHash)
        try store.upsert([asset])

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))
        let restored = try XCTUnwrap(app.assets.first { $0.id == asset.id })

        XCTAssertEqual(try store.loadSourceRoots().first?.managementMode, ImportMode.managed.rawValue)
        XCTAssertEqual(app.catalogManagementText, "托管式管理 · 原件在目录库")
        XCTAssertEqual(app.managementDisplayText(for: restored), "托管式 (Managed)")
    }

    @MainActor
    func testVisibleImageSourceRepairsBlackRawPreviewCache() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-raw-visible-\(UUID().uuidString)")
        let source = dir.appendingPathComponent("Source")
        let package = dir.appendingPathComponent("Library.photolibrary")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = source.appendingPathComponent("CANON.CR3")
        try writeTestJPEG(to: original, black: false)

        let store = try CatalogStore(packageURL: package)
        let thumbnails = ThumbnailService(store: store)
        let assetId = "raw-preview-test"
        let previewURL = thumbnails.cachePath(assetId: assetId, kind: .preview2048)
        try writeTestJPEG(to: previewURL, black: true)

        let base = DemoData.assets[0]
        let asset = Asset(id: assetId, pid: base.pid, ori: base.ori, thumb: base.thumb, preview: previewURL.path,
                          filename: original.lastPathComponent, type: "CR3", isRaw: true, folderId: "source-1",
                          folderName: "Source", date: base.date, width: base.width, height: base.height,
                          orientation: base.orientation, camera: base.camera, lens: base.lens, focal: base.focal,
                          aperture: base.aperture, shutter: base.shutter, iso: base.iso,
                          colorSpace: base.colorSpace, hasICCProfile: base.hasICCProfile, fileMB: base.fileMB,
                          fileModifiedAt: base.fileModifiedAt, fileCreatedAt: base.fileCreatedAt,
                          rating: base.rating, flag: base.flag, colorLabel: base.colorLabel,
                          keywords: base.keywords, title: base.title, caption: base.caption,
                          author: base.author, copyright: base.copyright, makerNotes: base.makerNotes,
                          project: base.project, client: base.client, location: base.location, gps: base.gps,
                          gpsAltitude: base.gpsAltitude, status: .ready, importedAt: base.importedAt,
                          deleted: base.deleted, localPath: original.path,
                          captureDateSource: base.captureDateSource, contentHash: base.contentHash,
                          quickHash: base.quickHash, isDemo: false, faces: base.faces,
                          perceptualHash: base.perceptualHash)

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))
        app.assets = [asset]

        XCTAssertTrue(imageIsUniformBlack(at: previewURL))
        let resolved = await app.visibleImageSource(for: asset,
                                                    requestedSource: previewURL.path,
                                                    kind: .preview2048)

        XCTAssertEqual(resolved, previewURL.path)
        XCTAssertFalse(imageIsUniformBlack(at: previewURL))
    }

    @MainActor
    func testVisibleImageSourceRefreshesStaleBitmapPreviewCache() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-stale-visible-\(UUID().uuidString)")
        let source = dir.appendingPathComponent("Source")
        let package = dir.appendingPathComponent("Library.photolibrary")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = source.appendingPathComponent("photo.jpg")
        try writeTestJPEG(to: original, black: false)
        let store = try CatalogStore(packageURL: package)
        let coordinator = ImportCoordinator(store: store)
        let asset = try XCTUnwrap(coordinator.importFolder(source).first)
        try store.upsert([asset])

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))
        app.cancelBackfill()

        let previewURL = URL(fileURLWithPath: asset.preview)
        try writeTestJPEG(to: previewURL, black: true)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)],
                                              ofItemAtPath: previewURL.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2)],
                                              ofItemAtPath: original.path)

        XCTAssertTrue(imageIsUniformBlack(at: previewURL))
        let resolved = await app.visibleImageSource(for: asset,
                                                    requestedSource: previewURL.path,
                                                    kind: .preview2048)

        XCTAssertEqual(resolved, previewURL.path)
        XCTAssertFalse(imageIsUniformBlack(at: previewURL))
    }

    func testPreviewExportRepairsBlackRawPreviewCache() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-raw-export-\(UUID().uuidString)")
        let source = dir.appendingPathComponent("Source")
        let package = dir.appendingPathComponent("Library.photolibrary")
        let export = dir.appendingPathComponent("Export")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = source.appendingPathComponent("CANON.CR3")
        try writeTestJPEG(to: original, black: false)

        let store = try CatalogStore(packageURL: package)
        let thumbnails = ThumbnailService(store: store)
        let assetId = "raw-export-test"
        let previewURL = thumbnails.cachePath(assetId: assetId, kind: .preview2048)
        try writeTestJPEG(to: previewURL, black: true)

        let base = DemoData.assets[0]
        let asset = Asset(id: assetId, pid: base.pid, ori: base.ori, thumb: base.thumb, preview: previewURL.path,
                          filename: original.lastPathComponent, type: "CR3", isRaw: true, folderId: "source-1",
                          folderName: "Source", date: base.date, width: base.width, height: base.height,
                          orientation: base.orientation, camera: base.camera, lens: base.lens, focal: base.focal,
                          aperture: base.aperture, shutter: base.shutter, iso: base.iso,
                          colorSpace: base.colorSpace, hasICCProfile: base.hasICCProfile, fileMB: base.fileMB,
                          fileModifiedAt: base.fileModifiedAt, fileCreatedAt: base.fileCreatedAt,
                          rating: base.rating, flag: base.flag, colorLabel: base.colorLabel,
                          keywords: base.keywords, title: base.title, caption: base.caption,
                          author: base.author, copyright: base.copyright, makerNotes: base.makerNotes,
                          project: base.project, client: base.client, location: base.location, gps: base.gps,
                          gpsAltitude: base.gpsAltitude, status: .ready, importedAt: base.importedAt,
                          deleted: base.deleted, localPath: original.path,
                          captureDateSource: base.captureDateSource, contentHash: base.contentHash,
                          quickHash: base.quickHash, isDemo: false, faces: base.faces,
                          perceptualHash: base.perceptualHash)

        XCTAssertTrue(imageIsUniformBlack(at: previewURL))
        let report = ExportService.exportPreviews([asset], to: export, thumbnails: thumbnails)
        let exported = export.appendingPathComponent("CANON-preview.jpg")

        XCTAssertEqual(report.copied, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.path))
        XCTAssertFalse(imageIsUniformBlack(at: previewURL))
        XCTAssertFalse(imageIsUniformBlack(at: exported))
    }

    func testPreviewExportRefreshesStaleBitmapCache() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-stale-export-\(UUID().uuidString)")
        let source = dir.appendingPathComponent("Source")
        let package = dir.appendingPathComponent("Library.photolibrary")
        let export = dir.appendingPathComponent("Export")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = source.appendingPathComponent("photo.jpg")
        try writeTestJPEG(to: original, black: false)
        let store = try CatalogStore(packageURL: package)
        let coordinator = ImportCoordinator(store: store)
        let asset = try XCTUnwrap(coordinator.importFolder(source).first)
        let previewURL = URL(fileURLWithPath: asset.preview)
        try writeTestJPEG(to: previewURL, black: true)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)],
                                              ofItemAtPath: previewURL.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2)],
                                              ofItemAtPath: original.path)

        XCTAssertTrue(imageIsUniformBlack(at: previewURL))
        let report = ExportService.exportPreviews([asset], to: export, thumbnails: coordinator.thumbnails)

        XCTAssertEqual(report.copied, 1)
        XCTAssertFalse(imageIsUniformBlack(at: previewURL))
    }

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
    func testRecoveredEmptyImportDoesNotWatchSourceRoot() async throws {
        let defaults = UserDefaults.standard
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

    @MainActor
    func testOpeningCatalogRepairsOrphanedSourceFolderIds() throws {
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
    func testMaintenanceActionsCleanLocalCatalogState() async throws {
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
        app.confirmDestructiveAction = { _, _, _ in true }
        XCTAssertTrue(app.openCatalog(at: package))

        XCTAssertTrue(app.recentCatalogs.contains { $0.path == package.path })
        app.confirmClearRecentCatalogs()
        XCTAssertTrue(app.recentCatalogs.isEmpty)

        app.confirmClearLogs()
        XCTAssertFalse(FileManager.default.fileExists(atPath: logFile.path))

        app.confirmClearCache()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.thumb256URL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.preview2048URL.path))

        app.runBackup()
        try await waitUntil("Timed out waiting for backup") {
            BackupService.listBackups(store).count == 1
        }
        XCTAssertEqual(BackupService.listBackups(store).count, 1)
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
    func testRunBackupStopsWhenSavingCatalogFails() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-backup-failure-\(UUID().uuidString)")
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
        try db.execChecked("""
        CREATE TRIGGER fail_backup_upsert BEFORE UPDATE ON assets
        BEGIN
          SELECT RAISE(ABORT, 'forced backup save failure');
        END;
        """)

        app.runBackup()

        try await waitUntil("Timed out waiting for backup failure") {
            app.toastCenter.toasts.last?.message == "备份失败"
        }
        XCTAssertTrue(BackupService.listBackups(store).isEmpty)
        XCTAssertEqual(app.toastCenter.toasts.last?.message, "备份失败")
    }

    @MainActor
    func testAutomaticBackupIsTrackedPerCatalog() async throws {
        let defaults = UserDefaults.standard
        let keys = [
            "pc_catalogURL", "pc_openLast", "pc_onboarded",
            "pc_autoBackupFrequency", "pc_lastAutoBackupAt",
        ]
        let saved = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        let savedBackupKeys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("pc_lastAutoBackupAt.") }
        let savedBackupValues = Dictionary(uniqueKeysWithValues: savedBackupKeys.map { ($0, defaults.object(forKey: $0)) })
        defer {
            for key in keys + savedBackupKeys { defaults.removeObject(forKey: key) }
            for (key, value) in saved { if let value { defaults.set(value, forKey: key) } }
            for (key, value) in savedBackupValues { if let value { defaults.set(value, forKey: key) } }
        }
        for key in keys + savedBackupKeys { defaults.removeObject(forKey: key) }
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
        try await waitUntil("Timed out waiting for first automatic backup") {
            BackupService.listBackups(firstStore).count == 1
        }
        XCTAssertEqual(BackupService.listBackups(firstStore).count, 1)

        defaults.set(secondPackage, forKey: "pc_catalogURL")
        let secondApp = AppState()
        XCTAssertTrue(secondApp.hasOpenCatalog)

        try await waitUntil("Timed out waiting for second automatic backup") {
            BackupService.listBackups(secondStore).count == 1
        }
        XCTAssertEqual(BackupService.listBackups(secondStore).count, 1)
    }

    @MainActor
    func testStatusCacheTextUsesNumericZero() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-cache-zero-\(UUID().uuidString)")
        let package = dir.appendingPathComponent("Library.photolibrary")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try CatalogStore(packageURL: package)

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))

        app.runHealthCheck()

        try await waitUntil("Timed out waiting for health check status") {
            app.statusCacheText == "缓存 0 KB"
        }
        XCTAssertEqual(app.statusCacheText, "缓存 0 KB")
    }

    @MainActor
    func testPruneCacheToLimitUpdatesStatusAsynchronously() async throws {
        let defaults = UserDefaults.standard
        let previousLimit = defaults.object(forKey: "pc_cacheLimitMB")
        defer {
            if let previousLimit {
                defaults.set(previousLimit, forKey: "pc_cacheLimitMB")
            } else {
                defaults.removeObject(forKey: "pc_cacheLimitMB")
            }
        }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-cache-prune-\(UUID().uuidString)")
        let package = dir.appendingPathComponent("Library.photolibrary")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try CatalogStore(packageURL: package)
        let cacheFile = store.thumb256URL.appendingPathComponent("oversize.jpg")
        try Data(repeating: 1, count: 2 * 1024 * 1024).write(to: cacheFile)

        let app = AppState()
        app.onboarded = true
        app.cacheLimitMB = 1
        XCTAssertTrue(app.openCatalog(at: package))

        app.pruneCacheToLimit()

        try await waitUntil("Timed out waiting for cache pruning") {
            app.statusCacheText == "缓存 0 KB"
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheFile.path))
        XCTAssertEqual(app.toastCenter.toasts.last?.icon, "trash")
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
    func testOpeningRealCatalogSelectsFirstVisibleAsset() throws {
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

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-open-selection-\(UUID().uuidString)")
        let source = dir.appendingPathComponent("Source")
        let package = dir.appendingPathComponent("Library.photolibrary")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try CatalogStore(packageURL: package)
        let realAssets = try DemoData.assets.dropFirst(5).prefix(2).map { base -> Asset in
            try store.addSourceRoot(id: base.folderId, displayName: base.folderName,
                                    path: source.path, bookmark: nil)
            var asset = base
            let file = source.appendingPathComponent(asset.filename)
            try Data("image".utf8).write(to: file)
            asset.localPath = file.path
            asset.status = .ready
            asset.isDemo = false
            asset.deleted = false
            return asset
        }
        try store.upsert(realAssets)

        let app = AppState()
        app.onboarded = true

        XCTAssertTrue(app.openCatalog(at: package))
        let firstVisible = try XCTUnwrap(app.list.first?.id)
        XCTAssertEqual(app.primaryId, firstVisible)
        XCTAssertEqual(app.selectedIds, [firstVisible])
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

        XCTAssertFalse(app.canOperateOnSelectedOriginals)
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

    private func writeTestJPEG(to url: URL, black: Bool) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil,
                                      width: 80,
                                      height: 60,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw NSError(domain: "PhotoCatalogTests", code: 1)
        }
        context.setFillColor(black ? CGColor.black : CGColor(red: 0.7, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        if !black {
            context.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 30))
        }
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                                UTType.jpeg.identifier as CFString,
                                                                1,
                                                                nil) else {
            throw NSError(domain: "PhotoCatalogTests", code: 2)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "PhotoCatalogTests", code: 3)
        }
    }

    private func imageIsUniformBlack(at url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary) else { return true }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 32,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return true
        }

        let bytesPerPixel = 4
        var data = [UInt8](repeating: 0, count: image.width * image.height * bytesPerPixel)
        guard let context = CGContext(data: &data,
                                      width: image.width,
                                      height: image.height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: image.width * bytesPerPixel,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return true
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        var index = 0
        while index < data.count {
            if data[index] > 2 || data[index + 1] > 2 || data[index + 2] > 2 {
                return false
            }
            index += bytesPerPixel
        }
        return true
    }
}
