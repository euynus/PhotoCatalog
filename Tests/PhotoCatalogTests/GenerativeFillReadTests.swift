import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import PhotoCatalog

/// A fill read from a file keeps the pixels of the file it was read from, as its file identity
/// says, even when that file is replaced before the fill is first drawn (FullBackupCheck's
/// "replaced fill resources invalidate cached pixels" failed once that way).
final class GenerativeFillReadTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pc-fill-read-\(UUID().uuidString)")
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    private func writeFill(at url: URL, gray: CGFloat) throws {
        let side = GenerativeFill.side
        let context = try XCTUnwrap(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), [
            kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription: "0.25,0.25,0.5,0.5"],
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func red(_ image: CGImage) -> Int {
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Int(data[0])
    }

    func testAFillKeepsThePixelsOfTheFileItWasReadFrom() throws {
        let fm = FileManager.default
        let library = root.appendingPathComponent("Restored.photolibrary")
        let original = library.appendingPathComponent("Originals/Frame.CR3")
        try fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("original bytes".utf8).write(to: original)
        var stroke = BrushStroke()
        stroke.append(CGPoint(x: 0.5, y: 0.5))
        var spot = SpotRemoval(target: CGPoint(x: 0.5, y: 0.5), source: CGPoint(x: 0.5, y: 0.5), radius: 0.05)
        spot.mode = .remove
        spot.strokes = [stroke]
        var settings = DevelopSettings()
        settings.spots = [spot]
        let fill = library.appendingPathComponent(
            FullBackupService.fillPath(original: "Originals/Frame.CR3", index: 0, settings: settings))
        try fm.createDirectory(at: fill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeFill(at: fill, gray: 0.2)
        let replacement = root.appendingPathComponent("Replacement.png")
        try writeFill(at: replacement, gray: 0.9)

        // read, but not drawn yet
        let loaded = try XCTUnwrap(GenerativeFill.fill(for: 0, settings: settings, url: original, isRaw: true, make: false))
        let written = try XCTUnwrap(fill.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        try Data(contentsOf: replacement).write(to: fill, options: .atomic)
        try fm.setAttributes([.modificationDate: written], ofItemAtPath: fill.path)
        let changed = try XCTUnwrap(GenerativeFill.fill(for: 0, settings: settings, url: original, isRaw: true, make: false))

        XCTAssertLessThan(red(loaded.image), 100, "the fill read first shows the file it was read from")
        XCTAssertGreaterThan(red(changed.image), red(loaded.image) + 100, "the replaced file is read again")
        GenerativeFill.forget(index: 0, settings: settings, url: original)
    }
}
