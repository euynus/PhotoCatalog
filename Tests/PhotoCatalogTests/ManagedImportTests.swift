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
        try store.db.failWrites("fail_import_insert", before: "INSERT", on: "assets",
                                message: "forced import save failure")
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

    /// A sidecar as Lightroom or darktable leaves one: a capture time, and a property of another
    /// app's this one doesn't read.
    private func writeSidecar(_ url: URL, taken: String) throws {
        let xmp = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about="" xmlns:exif="http://ns.adobe.com/exif/1.0/"
            xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
            exif:DateTimeOriginal="\(taken)" crs:Exposure2012="+0.50"/>
         </rdf:RDF>
        </x:xmpmeta>
        """
        try Data(xmp.utf8).write(to: url)
    }

    /// A camera whose model reads "..": its photos are filed inside Originals, not above it.
    func testCameraNamedDotDotStaysInsideOriginals() throws {
        let store = try CatalogStore(packageURL: scratch.appendingPathComponent("Library.photolibrary"))
        let folder = scratch.appendingPathComponent("Card")
        let shot = folder.appendingPathComponent("IMG_0001.JPG")
        try makeShot(at: shot, make: "", model: "..", taken: "2026:10:12 10:00:00")

        let imported = try XCTUnwrap(ImportCoordinator(store: store)
            .importFiles([shot], from: folder, mode: .managed, archiveRule: .camera, readSidecar: false).first)

        let copy = URL(fileURLWithPath: try XCTUnwrap(imported.localPath)).standardizedFileURL
        let originals = store.originalsURL.standardizedFileURL
        XCTAssertTrue(copy.path.hasPrefix(originals.path + "/"), "copied outside Originals, to \(copy.path)")
        XCTAssertEqual(copy.pathComponents.count - originals.pathComponents.count, 4,
                       "not filed as <camera>/YYYY/MM")
    }

    /// The original's sidecar comes into Originals with it, so what other apps keep there (their
    /// develop settings) stays with the photo once the card is wiped.
    func testSidecarIsCopiedWithTheOriginal() throws {
        let store = try CatalogStore(packageURL: scratch.appendingPathComponent("Library.photolibrary"))
        let folder = scratch.appendingPathComponent("Card")
        let shot = folder.appendingPathComponent("IMG_0002.JPG")
        try makeShot(at: shot, make: "Canon", model: "Canon EOS R5", taken: "2026:10:12 10:00:00")
        let sidecar = folder.appendingPathComponent("IMG_0002.xmp")
        try writeSidecar(sidecar, taken: "2026-10-12T10:00:00")

        let imported = try XCTUnwrap(ImportCoordinator(store: store)
            .importFiles([shot], from: folder, mode: .managed).first)

        let copy = URL(fileURLWithPath: try XCTUnwrap(imported.localPath))
        XCTAssertEqual(try? Data(contentsOf: XMPSidecar.sidecarURL(for: copy)), try Data(contentsOf: sidecar),
                       "the sidecar was left behind on the card")
    }

    /// A photo whose sidecar gives another capture time than its camera did (corrected in another
    /// app) is filed under the day the catalog shows for it.
    func testArchiveFolderFollowsTheSidecarCaptureTime() throws {
        let store = try CatalogStore(packageURL: scratch.appendingPathComponent("Library.photolibrary"))
        let folder = scratch.appendingPathComponent("Card")
        let shot = folder.appendingPathComponent("IMG_0003.JPG")
        try makeShot(at: shot, make: "Canon", model: "Canon EOS R5", taken: "2026:01:01 00:00:00")
        try writeSidecar(folder.appendingPathComponent("IMG_0003.xmp"), taken: "2026-10-12T10:00:00")

        let imported = try XCTUnwrap(ImportCoordinator(store: store)
            .importFiles([shot], from: folder, mode: .managed).first)

        XCTAssertEqual(imported.captureDateSource, "sidecar")
        XCTAssertEqual(URL(fileURLWithPath: try XCTUnwrap(imported.localPath)).deletingLastPathComponent().path,
                       store.originalsURL.appendingPathComponent("2026/10/12").path,
                       "filed under the camera's date, not the one the catalog shows")
    }
}
