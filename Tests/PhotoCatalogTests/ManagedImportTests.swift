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
}
