import XCTest
@testable import PhotoCatalog

extension AppStateSelectionTests {
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
    func testPreviewExportAllowsCachedPreviewWithoutOriginal() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-preview-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let preview = dir.appendingPathComponent("preview.jpg")
        try Data("preview".utf8).write(to: preview)

        let app = AppState()
        app.onboarded = true
        let base = try XCTUnwrap(app.assets.first)
        let asset = rebuiltAsset(base, preview: preview.path, status: .offline, localPath: nil)
        app.assets = [asset]
        app.primaryId = asset.id
        app.selectedIds = [asset.id]

        XCTAssertFalse(app.canOperateOnSelectedOriginals)
        XCTAssertFalse(app.canExportOriginalSelection)
        XCTAssertTrue(app.canExportPreviewSelection)
    }

    @MainActor
    func testExportFinishRequiresSameCatalog() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-export-guard-\(UUID().uuidString)")
        let firstPackage = dir.appendingPathComponent("First.photolibrary")
        let secondPackage = dir.appendingPathComponent("Second.photolibrary")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try makeCatalogWithOneAsset(at: firstPackage, assetIndex: 0)
        _ = try makeCatalogWithOneAsset(at: secondPackage, assetIndex: 1)

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: firstPackage))
        let toastCount = app.toastCenter.toasts.count

        XCTAssertFalse(app.finishOriginalExport((ExportReport(copied: 1), true),
                                                xmp: false,
                                                expectedCatalogURL: secondPackage))
        XCTAssertFalse(app.finishPreviewExport(ExportReport(copied: 1),
                                               expectedCatalogURL: secondPackage))
        XCTAssertEqual(app.toastCenter.toasts.count, toastCount)
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
    func testSelectionCapabilitiesUseCatalogMetadataBeforeFilesystemValidation() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-late-missing-\(UUID().uuidString).jpg")

        let app = AppState()
        app.onboarded = true
        var asset = try XCTUnwrap(app.assets.first)
        asset.localPath = missing.path
        asset.status = .ready
        asset.isDemo = false
        app.assets = [asset]
        app.primaryId = asset.id
        app.selectedIds = [asset.id]

        XCTAssertTrue(app.canOperateOnSelectedOriginals)
        XCTAssertTrue(app.canExportOriginalSelection)
        XCTAssertTrue(app.canExportPreviewSelection)

        app.exportSelection()
        XCTAssertEqual(app.toastCenter.toasts.last?.message, "没有可导出的本地原件")
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
}
