import XCTest
import ImageIO
@testable import PhotoCatalog

extension AppStateSelectionTests {
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
        missing.status = .missing
        app.assets = [live, deleted, missing]

        XCTAssertEqual(app.thumbnailMaintenanceAssets.map(\.id), [live.id])
    }

    @MainActor
    func testThumbnailRebuildFinishRequiresSameCatalog() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-thumbnail-rebuild-guard-\(UUID().uuidString)")
        let firstPackage = dir.appendingPathComponent("First.photolibrary")
        let secondPackage = dir.appendingPathComponent("Second.photolibrary")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try makeCatalogWithOneAsset(at: firstPackage, assetIndex: 0)
        _ = try makeCatalogWithOneAsset(at: secondPackage, assetIndex: 1)

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: firstPackage))
        let generation = app.thumbnailCacheGeneration
        let toastCount = app.toastCenter.toasts.count

        XCTAssertFalse(app.finishThumbnailRebuild(expectedCatalogURL: secondPackage))
        XCTAssertEqual(app.thumbnailCacheGeneration, generation)
        XCTAssertEqual(app.toastCenter.toasts.count, toastCount)
    }

    @MainActor
    func testThumbnailRebuildRefreshesCacheStatus() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-thumbnail-status-\(UUID().uuidString)")
        let package = dir.appendingPathComponent("Library.photolibrary")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try CatalogStore(packageURL: package)

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))
        try await waitUntil("Timed out waiting for initial cache status") {
            app.statusCacheText == "缓存 0 KB"
        }

        let cacheFile = store.thumb256URL.appendingPathComponent("generated.jpg")
        try Data(repeating: 1, count: 1_024).write(to: cacheFile)
        XCTAssertTrue(app.finishThumbnailRebuild(expectedCatalogURL: URL(fileURLWithPath: app.catalogPath)))

        try await waitUntil("Timed out waiting for refreshed cache status") {
            app.statusCacheText != "缓存 0 KB"
        }
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

    func testCatalogModificationDateControlsCacheFreshness() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-cache-freshness-\(UUID().uuidString)")
        let cache = dir.appendingPathComponent("cache.jpg")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: cache)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)],
                                              ofItemAtPath: cache.path)

        XCTAssertFalse(ThumbnailService.cacheIsStale(cache: cache, originalModificationDate: nil))
        XCTAssertFalse(ThumbnailService.cacheIsStale(
            cache: cache, originalModificationDate: Date(timeIntervalSince1970: 100)))
        XCTAssertTrue(ThumbnailService.cacheIsStale(
            cache: cache, originalModificationDate: Date(timeIntervalSince1970: 300)))
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
        let defaults = UserDefaults.app
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

        // a utility-priority pass with a health check (integrity_check included): past a second
        // while the rest of the suite runs
        try await waitUntil("Timed out waiting for cache pruning", timeout: 10) {
            app.statusCacheText == "缓存 0 KB"
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheFile.path))
        XCTAssertEqual(app.toastCenter.toasts.last?.icon, "trash")
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
