import XCTest
import ImageIO
@testable import PhotoCatalog

extension AppStateSelectionTests {
    @MainActor
    func testRatingShortcutDoesNotPublishUnsavedChanges() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-rating-save-failure-\(UUID().uuidString)")
        let package = dir.appendingPathComponent("Library.photolibrary")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try CatalogStore(packageURL: package)
        var asset = try XCTUnwrap(DemoData.assets.first)
        asset.isDemo = false
        asset.deleted = false
        asset.rating = 0
        try store.upsert([asset])

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))
        app.primaryId = asset.id
        app.selectedIds = [asset.id]

        let db = try Database(path: package.appendingPathComponent("catalog.sqlite").path)
        try db.execChecked("""
        CREATE TRIGGER fail_rating_update BEFORE UPDATE ON assets
        BEGIN
          SELECT RAISE(ABORT, 'forced rating save failure');
        END;
        """)

        XCTAssertFalse(app.handleKey("5", hasCommand: false))
        XCTAssertEqual(app.assets.first { $0.id == asset.id }?.rating, 0)
        XCTAssertEqual(try store.loadAssets().first { $0.id == asset.id }?.rating, 0)
        XCTAssertEqual(app.toastCenter.toasts.last?.message, "保存失败，更改未写入目录库")
    }

    @MainActor
    func testIndexedMetadataMutationsPersistToCatalog() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-indexed-metadata-\(UUID().uuidString)")
        let package = dir.appendingPathComponent("Library.photolibrary")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try CatalogStore(packageURL: package)
        var asset = try XCTUnwrap(DemoData.assets.first)
        asset.isDemo = false
        asset.deleted = false
        try store.upsert([asset])

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))
        app.primaryId = asset.id
        app.selectedIds = [asset.id]

        XCTAssertTrue(app.setRating(4))
        XCTAssertTrue(app.setFlag(.pick))
        XCTAssertTrue(app.setColor(.green))

        let saved = try XCTUnwrap(store.loadAssets().first { $0.id == asset.id })
        XCTAssertEqual(saved.rating, 4)
        XCTAssertEqual(saved.flag, .pick)
        XCTAssertEqual(saved.colorLabel, .green)
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
        XCTAssertEqual(formatGPSLabel((0, 0), altitude: nil, isPresent: true), "0.0000, 0.0000")

        XCTAssertTrue(hasGPS((31.2345, 121.4567)))
        XCTAssertEqual(formatGPSLabel((31.2345, 121.4567), altitude: 88.5),
                       "31.2345, 121.4567 · 88.5 m")
    }

    func testLocationTextAloneDoesNotCountAsGPS() {
        XCTAssertFalse(Asset.hasGPSCoordinates((0, 0), location: "Lab"))
        XCTAssertTrue(Asset.hasGPSCoordinates((0, 0), location: "0.000, 0.000"))
        XCTAssertTrue(Asset.hasGPSCoordinates((31.2345, 121.4567), location: "Shanghai"))
    }

    func testImportPreservesZeroCoordinateGPS() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-zero-gps-\(UUID().uuidString)")
        let source = dir.appendingPathComponent("Source")
        let package = dir.appendingPathComponent("Library.photolibrary")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let photo = source.appendingPathComponent("zero-gps.jpg")
        try writeTestJPEG(to: photo, black: false, gps: [
            kCGImagePropertyGPSLatitude: 0,
            kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 0,
            kCGImagePropertyGPSLongitudeRef: "E",
        ])

        let store = try CatalogStore(packageURL: package)
        let asset = try XCTUnwrap(ImportCoordinator(store: store).importFolder(source).first)

        XCTAssertTrue(asset.hasGPS)
        XCTAssertEqual(asset.gps.0, 0)
        XCTAssertEqual(asset.gps.1, 0)
        XCTAssertEqual(asset.location, "0.000, 0.000")
        XCTAssertTrue(SmartMatcher.eval(asset, SmartCondition(field: "gps", op: "=", value: "yes")))
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
        preservingPreferences(["pc_autoWriteXMP"])

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

    func testAutomaticXMPWriterDoesNotOverwriteNewerMetadata() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-xmp-order-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = dir.appendingPathComponent("photo.jpg")
        try Data("image".utf8).write(to: original)
        var older = try XCTUnwrap(DemoData.assets.first)
        older.localPath = original.path
        older.isDemo = false
        older.rating = 1
        var newer = older
        newer.rating = 5

        let writer = AutomaticXMPWriter()
        let newerResult = await writer.write([newer], sequence: 2)
        let olderResult = await writer.write([older], sequence: 1)
        XCTAssertEqual(newerResult.failures, 0)
        XCTAssertEqual(olderResult.failures, 0)
        XCTAssertNotNil(newerResult.written[newer.id])
        XCTAssertTrue(olderResult.written.isEmpty)

        let sidecar = XMPSidecar.sidecarURL(for: original)
        XCTAssertEqual(XMPSidecar.read(sidecar)?.rating, 5)
    }

    @MainActor
    func testIndexedMetadataMutationQueuesAutomaticXMPWrite() async throws {
        preservingPreferences(["pc_autoWriteXMP"])

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-xmp-queue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = dir.appendingPathComponent("photo.jpg")
        try Data("image".utf8).write(to: original)
        let sidecar = XMPSidecar.sidecarURL(for: original)
        var asset = try XCTUnwrap(DemoData.assets.first)
        asset.localPath = original.path
        asset.status = .ready
        asset.isDemo = false

        let app = AppState()
        app.onboarded = true
        app.autoWriteXMPSidecar = true
        app.assets = [asset]
        app.primaryId = asset.id
        app.selectedIds = [asset.id]
        XCTAssertTrue(app.setRating(5))

        for _ in 0..<20 where XMPSidecar.read(sidecar)?.rating != 5 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(XMPSidecar.read(sidecar)?.rating, 5)
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
}
