import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoCatalog

/// A photo without an EXIF date takes its capture time from the file, whose dates are instants;
/// the capture time is the wall clock this Mac showed then, like a camera's.
final class MetadataFileDateTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-metadata-file-date-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    /// 20:00 UTC: already the next day east of UTC+4, still the same hour nowhere but UTC.
    private let fileDate = ISO8601DateFormatter().date(from: "2026-03-01T20:00:00Z")!

    /// The wall clock `instant` shows on this Mac, as capture-time components.
    private func localClock(_ instant: Date) -> DateComponents {
        Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: instant)
    }

    private func captureClock(_ date: Date) -> DateComponents {
        Calendar.captureWallClock.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }

    private func stamp(_ url: URL, created: Date, modified: Date) throws {
        try FileManager.default.setAttributes([.creationDate: created, .modificationDate: modified],
                                              ofItemAtPath: url.path)
    }

    func testPhotoWithoutEXIFDateTakesItsFileCreationTimeAsWallClock() throws {
        let url = folder.appendingPathComponent("scan.jpg")
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        try stamp(url, created: fileDate, modified: fileDate.addingTimeInterval(3600))

        let meta = MetadataReader.read(url)
        XCTAssertEqual(meta.width, 32, "the photo itself is read")
        XCTAssertEqual(meta.captureDateSource, "文件创建时间")
        XCTAssertEqual(captureClock(meta.captureDate), localClock(fileDate))
        XCTAssertEqual(meta.fileCreatedAt, fileDate, "the file's own dates stay instants")
    }

    func testUnreadablePhotoTakesItsModificationTimeAsWallClock() throws {
        let url = folder.appendingPathComponent("broken.jpg")
        try Data("not a photo".utf8).write(to: url)
        try stamp(url, created: fileDate, modified: fileDate)

        let meta = MetadataReader.read(url)
        XCTAssertEqual(meta.captureDateSource, "文件修改时间")
        XCTAssertEqual(captureClock(meta.captureDate), localClock(fileDate))
        XCTAssertEqual(meta.fileModifiedAt, fileDate)
    }

    func testUnreadableVideoTakesItsModificationTimeAsWallClock() throws {
        let url = folder.appendingPathComponent("broken.mov")
        try Data("not a movie".utf8).write(to: url)
        try stamp(url, created: fileDate, modified: fileDate)

        let meta = MetadataReader.read(url)
        XCTAssertEqual(captureClock(meta.captureDate), localClock(fileDate))
    }
}
