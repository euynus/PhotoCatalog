import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoCatalog

/// Locate (finding a moved original the user points at): the photo's own file is found, another
/// photo that merely shares its name is not.
final class RelocationTests: CatalogTestCase {
    private func importedAsset(at url: URL) throws -> Asset {
        let store = try CatalogStore(packageURL: scratch.appendingPathComponent("Library.photolibrary"))
        return try XCTUnwrap(ImportCoordinator(store: store)
            .importFiles([url], from: url.deletingLastPathComponent(), sourceRootId: "source-1", folderName: "Source").first)
    }

    private func makeJPEG(at url: URL, width: Int, height: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    /// Camera counters repeat: a folder holding another IMG_0001.JPG — same size class, same
    /// dimensions, made about when the original was — isn't the photo once its bytes differ.
    func testLocateRejectsASameNamedPhotoWhoseContentDiffers() throws {
        let original = scratch.appendingPathComponent("Source/IMG_0001.JPG")
        try makeTestJPEG(at: original, shade: 1)
        let asset = try importedAsset(at: original)
        XCTAssertNotNil(asset.contentHash)
        let other = scratch.appendingPathComponent("Elsewhere/IMG_0001.JPG")
        try makeTestJPEG(at: other, shade: 9)

        XCTAssertNil(RelocationService.replacement(for: asset, selected: other.deletingLastPathComponent()))
        XCTAssertNil(RelocationService.replacement(for: asset, selected: other))
    }

    /// The original itself, moved and renamed, is found by its content.
    func testLocateFindsTheMovedOriginalByItsContent() throws {
        let original = scratch.appendingPathComponent("Source/IMG_0001.JPG")
        try makeTestJPEG(at: original, shade: 1)
        let asset = try importedAsset(at: original)
        let folder = scratch.appendingPathComponent("Moved")
        try makeTestJPEG(at: folder.appendingPathComponent("IMG_0001.JPG"), shade: 9)
        let moved = folder.appendingPathComponent("Holiday 001.JPG")
        try FileManager.default.moveItem(at: original, to: moved)

        XCTAssertEqual(RelocationService.replacement(for: asset, selected: folder)?.lastPathComponent,
                       moved.lastPathComponent)
    }

    /// A photo without a content hash: a file sharing only its name and type, nothing of what
    /// the file holds (size, dimensions, capture time), isn't taken for it.
    func testLocateWithoutAHashNeedsMoreThanTheName() throws {
        let original = scratch.appendingPathComponent("Source/IMG_0001.JPG")
        try makeTestJPEG(at: original, shade: 1)
        var asset = try importedAsset(at: original)
        asset.contentHash = nil
        asset.fileMB = 24.5
        asset.date = Date(timeIntervalSince1970: 1_000_000_000)
        // another camera's IMG_0001.JPG: other dimensions, another size, shot another day
        let other = scratch.appendingPathComponent("Elsewhere/IMG_0001.JPG")
        try makeJPEG(at: other, width: 64, height: 64)

        XCTAssertNil(RelocationService.replacement(for: asset, selected: other.deletingLastPathComponent()))
    }

    /// Without a content hash, the same name backed by what the file holds is still found.
    func testLocateWithoutAHashFindsTheOriginalByNameAndContents() throws {
        let original = scratch.appendingPathComponent("Source/IMG_0001.JPG")
        try makeTestJPEG(at: original, shade: 1)
        var asset = try importedAsset(at: original)
        asset.contentHash = nil
        let folder = scratch.appendingPathComponent("Moved")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let moved = folder.appendingPathComponent("IMG_0001.JPG")
        try FileManager.default.moveItem(at: original, to: moved)

        XCTAssertEqual(RelocationService.replacement(for: asset, selected: folder), moved)
    }
}
