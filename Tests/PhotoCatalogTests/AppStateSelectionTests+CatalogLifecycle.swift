import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import PhotoCatalog

extension AppStateSelectionTests {
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
        let defaults = UserDefaults.app

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

        let defaults = UserDefaults.app
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
        let defaults = UserDefaults.app
        defaults.set(true, forKey: "pc_openLast")
        defaults.set(missing, forKey: "pc_catalogURL")
        defaults.set("1", forKey: "pc_onboarded")

        let app = AppState()

        XCTAssertFalse(app.hasOpenCatalog)
        XCTAssertFalse(app.onboarded)
        XCTAssertEqual(app.catalogPath, "未打开目录库")
    }

    @MainActor
    func testLaunchArgumentTakesPriorityOverConfiguredCatalog() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-launch-priority-\(UUID().uuidString)")
        let target = root.appendingPathComponent("Target.photolibrary")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeCatalogWithOneAsset(at: target, assetIndex: 1)

        let defaults = UserDefaults.app
        defaults.set(true, forKey: "pc_openLast")
        defaults.set("1", forKey: "pc_onboarded")
        defaults.set(root.appendingPathComponent("Missing.photolibrary"), forKey: "pc_catalogURL")

        let app = AppState(arguments: ["PhotoCatalog", target.path])

        XCTAssertTrue(app.hasOpenCatalog)
        XCTAssertFalse(app.hasCatalogPreview)
        XCTAssertEqual(app.catalogPath, target.path)
        XCTAssertEqual(app.contentAssetCount, 1)
        XCTAssertEqual(app.assets.map(\.id), [DemoData.assets[1].id])
    }

    @MainActor
    func testDeferredLaunchLoadsCatalogAfterInitializerReturns() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-deferred-launch-\(UUID().uuidString)")
        let target = root.appendingPathComponent("Target.photolibrary")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeCatalogWithOneAsset(at: target, assetIndex: 1)

        let defaults = UserDefaults.app
        defaults.set(true, forKey: "pc_openLast")
        defaults.set("1", forKey: "pc_onboarded")

        let app = AppState(arguments: ["PhotoCatalog", target.path], deferCatalogLoading: true)

        XCTAssertTrue(app.isLoadingCatalog)
        XCTAssertFalse(app.hasOpenCatalog)
        XCTAssertTrue(app.assets.isEmpty)

        app.startDeferredCatalogLoadingIfNeeded()
        try await waitUntil("Timed out waiting for deferred catalog load", timeout: 3) {
            !app.isLoadingCatalog
        }

        XCTAssertTrue(app.hasOpenCatalog)
        XCTAssertFalse(app.hasCatalogPreview)
        XCTAssertEqual(app.catalogPath, target.path)
        XCTAssertEqual(app.contentAssetCount, 1)
        XCTAssertEqual(app.assets.map(\.id), [DemoData.assets[1].id])
    }

    @MainActor
    func testSystemCatalogOpenLoadsReplacementInBackground() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-system-open-\(UUID().uuidString)")
        let first = root.appendingPathComponent("First.photolibrary")
        let second = root.appendingPathComponent("Second.photolibrary")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeCatalogWithOneAsset(at: first, assetIndex: 0)
        _ = try makeCatalogWithOneAsset(at: second, assetIndex: 2)

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: first))

        app.openCatalogFromSystem(second)

        XCTAssertTrue(app.isLoadingCatalog)
        XCTAssertEqual(app.catalogPath, second.path)
        try await waitUntil("Timed out waiting for system catalog open", timeout: 3) {
            !app.isLoadingCatalog
        }
        XCTAssertFalse(app.hasCatalogPreview)
        XCTAssertEqual(app.contentAssetCount, 1)
        XCTAssertEqual(app.catalogPath, second.path)
        XCTAssertEqual(app.assets.map(\.id), [DemoData.assets[2].id])
    }

    @MainActor
    func testInvalidLaunchArgumentFallsBackToConfiguredCatalog() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-launch-fallback-\(UUID().uuidString)")
        let configured = root.appendingPathComponent("Configured.photolibrary")
        let missing = root.appendingPathComponent("Missing.photolibrary")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeCatalogWithOneAsset(at: configured, assetIndex: 2)

        let defaults = UserDefaults.app
        defaults.set(true, forKey: "pc_openLast")
        defaults.set("1", forKey: "pc_onboarded")
        defaults.set(configured, forKey: "pc_catalogURL")

        let app = AppState(arguments: ["PhotoCatalog", missing.path])

        XCTAssertTrue(app.hasOpenCatalog)
        XCTAssertEqual(app.catalogPath, configured.path)
        XCTAssertEqual(app.assets.map(\.id), [DemoData.assets[2].id])
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
    func testOpeningEmptyCatalogDoesNotExposeDemoAssets() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-empty-catalog-\(UUID().uuidString)")
        let package = root.appendingPathComponent("Empty.photolibrary")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try CatalogStore(packageURL: package)

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))

        XCTAssertTrue(app.assets.isEmpty)
        XCTAssertTrue(app.list.isEmpty)
        XCTAssertTrue(app.duplicateGroups.isEmpty)
        XCTAssertNil(app.primaryId)
        XCTAssertTrue(app.selectedIds.isEmpty)
        XCTAssertEqual(app.libraryCounts.all, 0)
        XCTAssertEqual(app.catalogDisplayName, "Empty")
    }

    @MainActor
    func testCreatingCatalogStartsWithEmptyLibraryState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-new-catalog-\(UUID().uuidString)")
        let package = root.appendingPathComponent("New Library.photolibrary")
        defer { try? FileManager.default.removeItem(at: root) }

        let app = AppState()
        app.onboarded = true
        XCTAssertFalse(app.assets.isEmpty)

        XCTAssertTrue(app.createCatalog(at: package))

        XCTAssertTrue(app.assets.isEmpty)
        XCTAssertTrue(app.albums.isEmpty)
        XCTAssertTrue(app.smartAlbums.isEmpty)
        XCTAssertTrue(app.folders.isEmpty)
        XCTAssertTrue(app.duplicateGroups.isEmpty)
        XCTAssertNil(app.primaryId)
        XCTAssertTrue(app.selectedIds.isEmpty)
        XCTAssertEqual(app.libraryCounts.all, 0)
        XCTAssertEqual(app.catalogDisplayName, "New Library")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: package.appendingPathComponent("catalog.sqlite").path
        ))
    }

    @MainActor
    func testCreatingCatalogRefusesToReuseExistingPackage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-existing-catalog-\(UUID().uuidString)")
        let package = root.appendingPathComponent("Existing.photolibrary")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try CatalogStore(packageURL: package)
        var existing = try XCTUnwrap(DemoData.assets.first)
        existing.isDemo = false
        try store.upsert([existing])

        let app = AppState()
        app.onboarded = true
        let visibleBefore = app.assets

        XCTAssertFalse(app.createCatalog(at: package))

        XCTAssertEqual(app.assets, visibleBefore)
        XCTAssertEqual(try store.loadAssets().map(\.id), [existing.id])
        XCTAssertEqual(app.toastCenter.toasts.last?.message, "目录库已存在，请选择其他名称")
    }

    @MainActor
    func testEmptyCatalogManagementTextUsesConfiguredImportMode() {
        let app = AppState()
        app.onboarded = true
        app.assets = []

        app.importMode = .managed
        XCTAssertEqual(app.catalogManagementText, "原件已复制到目录库")

        app.importMode = .referenced
        XCTAssertEqual(app.catalogManagementText, "原位添加 · 原件只读")
    }
}
