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
