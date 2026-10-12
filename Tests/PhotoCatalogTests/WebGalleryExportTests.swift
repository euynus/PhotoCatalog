import XCTest
@testable import PhotoCatalog

/// Where a web gallery is written, and what a cancelled one leaves behind.
final class WebGalleryExportTests: CatalogTestCase {
    /// A gallery named "2024/25" went into a folder "25" inside a new folder "2024", and a
    /// cancelled one took away "25" but left "2024" behind.
    func testAGalleryNamedWithASlashIsOneFolderAndACancelledOneLeavesNothing() throws {
        let parent = scratch.appendingPathComponent("Galleries", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let cancelled = WebGalleryExporter.export([], settings: WebGallerySettings(), name: "2024/25", in: parent,
                                                  progress: { _ in }, cancelled: { true })
        XCTAssertNil(cancelled)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [],
                       "a cancelled gallery leaves nothing in the folder it was written to")

        let photo = scratch.appendingPathComponent("Photos/a.jpg")
        try makeTestJPEG(at: photo, shade: 6)
        let item = PrintItem(sourcePath: photo.path, isRaw: false, develop: .neutral,
                             originalSize: CGSize(width: 80, height: 60), filename: "a.jpg", title: "")
        let page = try XCTUnwrap(WebGalleryExporter.export([WebGalleryPhoto(item: item, baseName: "a", caption: "", details: "")],
                                                           settings: WebGallerySettings(), name: "2024/25", in: parent,
                                                           progress: { _ in }, cancelled: { false }))
        XCTAssertEqual(page.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path,
                       parent.standardizedFileURL.path, "the gallery is one folder in the chosen one")
        XCTAssertEqual(page.deletingLastPathComponent().lastPathComponent, "2024-25")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), ["2024-25"])
    }
}
