import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoCatalog

/// The card import's rename example names a photo the way its copy will be named.
final class CardImportExampleTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-card-example-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("DCIM"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func options() -> CardImportOptions {
        var options = CardImportOptions(destination: folder.appendingPathComponent("Imported", isDirectory: true))
        options.organize = .flat
        options.rename = true
        options.renameTemplate = "{date}_{time}_{camera}_{seq}"
        options.sequenceStart = 7
        return options
    }

    func testExampleIsTheNameTheCopyGets() throws {
        // shot at 23:30 on 1 June by a Canon; the card's file time says another day
        let url = folder.appendingPathComponent("DCIM/IMG_0042.JPG")
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2025:06:01 23:30:00"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Canon", kCGImagePropertyTIFFModel: "Canon EOS R6m2"],
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let fileTime = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-15T20:00:00Z"))
        try FileManager.default.setAttributes([.creationDate: fileTime, .modificationDate: fileTime], ofItemAtPath: url.path)

        let file = try XCTUnwrap(CardImportService.scan(folder.appendingPathComponent("DCIM"),
                                                        catalog: CardImportService.CatalogIndex([])).first)
        let options = options()
        let example = CardImportSheet.exampleName(for: file, options: options)
        XCTAssertTrue(example.hasPrefix("20250601_233000_Canon EOS R6m2_0007"), example)

        let copy = try CardCopier(options: options, files: [file]).copy(file.url)
        XCTAssertEqual(example, copy.lastPathComponent)
    }

    func testExampleOfAPhotoOnADeviceUsesItsTimeOnThisMacsClock() throws {
        // a camera's photo can't be read before it's downloaded: its date stands in, as wall clock
        let taken = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-01T20:00:00Z"))
        let file = CardFile(url: CameraDevicePaths.url(device: "test-camera", folders: ["DCIM", "100CANON"], name: "IMG_0001.CR3"),
                            size: 1, modified: taken, isRaw: true, deviceID: "test-camera")
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = .current
        local.dateFormat = "yyyyMMdd_HHmmss"
        XCTAssertEqual(CardImportSheet.exampleName(for: file, options: options()),
                       "\(local.string(from: taken))__0007.CR3")
    }

    func testNoExampleWithoutAPhoto() {
        XCTAssertEqual(CardImportSheet.exampleName(for: nil, options: options()), "—")
    }
}
