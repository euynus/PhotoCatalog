import XCTest
@testable import PhotoCatalog

/// A managed import copies each original into the catalog's Originals folder.
final class ManagedImportTests: CatalogTestCase {
    /// A Canon IMG_1234.CR3 is already in Originals for the day; an iPhone's IMG_1234.HEIC
    /// from that day is copied beside it under a name of its own, so it never passes for the
    /// RAW's JPEG.
    func testAnotherCamerasPhotoByTheSameNameGetsItsOwnName() throws {
        let store = try CatalogStore(packageURL: scratch.appendingPathComponent("Library.photolibrary"))
        let day = store.originalsURL.appendingPathComponent("2026/10/12")
        // a TIFF under a RAW's name: Image I/O reads it by its content
        try makeShot(at: day.appendingPathComponent("IMG_1234.CR3"), type: .tiff,
                     make: "Canon", model: "Canon EOS R5", taken: "2026:10:12 10:00:00", shade: 1)
        let folder = scratch.appendingPathComponent("iPhone")
        let phone = folder.appendingPathComponent("IMG_1234.HEIC")
        try makeShot(at: phone, type: .heic, make: "Apple", model: "iPhone 15 Pro", taken: "2026:10:12 18:30:00",
                     shade: 7)

        let imported = try XCTUnwrap(ImportCoordinator(store: store)
            .importFiles([phone], from: folder, mode: .managed, readSidecar: false).first)

        let copy = URL(fileURLWithPath: try XCTUnwrap(imported.localPath))
        XCTAssertEqual(copy.deletingLastPathComponent().path, day.path)
        XCTAssertNotEqual(copy.deletingPathExtension().lastPathComponent.lowercased(), "img_1234",
                          "the iPhone photo doesn't share the Canon RAW's name")
    }

    /// The JPEG of a RAW already in Originals (the same camera, the same second) keeps the RAW's
    /// name, so the two still make one photo.
    func testJpegOfARawAlreadyCopiedKeepsItsName() throws {
        let store = try CatalogStore(packageURL: scratch.appendingPathComponent("Library.photolibrary"))
        let day = store.originalsURL.appendingPathComponent("2026/10/12")
        try makeShot(at: day.appendingPathComponent("IMG_1234.CR3"), type: .tiff,
                     make: "Canon", model: "Canon EOS R5", taken: "2026:10:12 10:00:00", shade: 1)
        let folder = scratch.appendingPathComponent("Card")
        let jpeg = folder.appendingPathComponent("IMG_1234.JPG")
        try makeShot(at: jpeg, make: "Canon", model: "Canon EOS R5", taken: "2026:10:12 10:00:00", shade: 1)

        let imported = try XCTUnwrap(ImportCoordinator(store: store)
            .importFiles([jpeg], from: folder, mode: .managed, readSidecar: false).first)

        XCTAssertEqual(imported.localPath, day.appendingPathComponent("IMG_1234.JPG").path)
    }

    /// A managed import whose catalog write fails leaves its copy in Originals; the same import
    /// run again takes that copy for the photo rather than copying the original a second time.
    @MainActor
    func testImportAfterAFailedOneAdoptsTheCopyItLeft() async throws {
        let folder = scratch.appendingPathComponent("Card")
        try makeTestJPEG(at: folder.appendingPathComponent("shot.jpg"), shade: 5)
        let package = scratch.appendingPathComponent("Library.photolibrary")
        let store = try CatalogStore(packageURL: package)
        try store.db.execChecked("""
        CREATE TRIGGER fail_import_insert BEFORE INSERT ON assets
        BEGIN
          SELECT RAISE(ABORT, 'forced import save failure');
        END;
        """)
        func copies() -> [String] {
            (FileManager.default.enumerator(atPath: store.originalsURL.path)?.allObjects as? [String] ?? [])
                .filter { $0.hasSuffix(".jpg") }
        }

        let app = AppState()
        app.onboarded = true
        app.importMode = .managed
        XCTAssertTrue(app.openCatalog(at: package))
        app.importFolder(folder)
        try await waitUntil("failed import finished") { !app.importing }
        XCTAssertEqual(app.importRun?.phase, .failed)
        XCTAssertTrue(try store.loadAssets().isEmpty)
        XCTAssertEqual(copies().count, 1, "the failed import left its copy behind")
        try store.db.execChecked("DROP TRIGGER fail_import_insert;")

        app.importFolder(folder)
        try await waitUntil("second import finished") { !app.importing }

        XCTAssertEqual(copies().count, 1, "the original is copied a second time")
        let photo = try XCTUnwrap(try store.loadAssets().first)
        XCTAssertEqual(photo.localPath, store.originalsURL.appendingPathComponent(try XCTUnwrap(copies().first)).path)
    }

    /// A folder holding a link to a photo kept elsewhere: Originals gets the photo itself, so the
    /// copy outlives the file the link pointed to.
    func testLinkedPhotoIsCopiedAsAFile() throws {
        let store = try CatalogStore(packageURL: scratch.appendingPathComponent("Library.photolibrary"))
        let elsewhere = scratch.appendingPathComponent("Elsewhere/photo.jpg")
        try makeTestJPEG(at: elsewhere, shade: 3)
        let bytes = try Data(contentsOf: elsewhere)
        let folder = scratch.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let link = folder.appendingPathComponent("linked.jpg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)

        let imported = try XCTUnwrap(ImportCoordinator(store: store)
            .importFiles([link], from: folder, mode: .managed, readSidecar: false).first)

        let copy = URL(fileURLWithPath: try XCTUnwrap(imported.localPath))
        XCTAssertTrue(copy.path.hasPrefix(store.originalsURL.path + "/"))
        XCTAssertEqual(copy.lastPathComponent, "linked.jpg", "named as the folder shows it")
        XCTAssertEqual(try copy.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, false,
                       "the copy is a file, not a link")
        try FileManager.default.removeItem(at: elsewhere)
        XCTAssertEqual(try? Data(contentsOf: copy), bytes, "the copy outlives the photo the link pointed to")
    }
}
