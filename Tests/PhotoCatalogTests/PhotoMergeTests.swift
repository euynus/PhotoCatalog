import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoCatalog

/// Which frames an HDR merge takes.
final class PhotoMergeTests: CatalogTestCase {
    /// A `width` × `height` JPEG, brighter with `level` (0…1).
    private func frame(_ name: String, width: Int, height: Int, level: CGFloat) throws -> PhotoMerge.Frame {
        let url = scratch.appendingPathComponent("Brackets/\(name).jpg")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw NSError(domain: "PhotoMergeTests", code: 1)
        }
        context.setFillColor(CGColor(red: level, green: level, blue: level, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: level * 0.5, green: level * 0.4, blue: level * 0.2, alpha: 1))
        context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 3))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString,
                                                                1, nil) else {
            throw NSError(domain: "PhotoMergeTests", code: 2)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "PhotoMergeTests", code: 3) }
        return PhotoMerge.Frame(url: url, isRaw: false, brightness: nil)
    }

    private func mergesAsHDR(_ frames: [PhotoMerge.Frame]) -> Bool {
        if case .success = PhotoMerge.merge(frames, kind: .hdr, options: .init(), maxPixel: nil) { return true }
        return false
    }

    /// A frame turned the other way, or of another size, was merged anyway: it couldn't be
    /// lined up, and the result was cut to the part the frames happened to share.
    func testHDRRefusesFramesOfAnotherSizeOrOrientation() throws {
        let dark = try frame("dark", width: 120, height: 80, level: 0.2)
        let bright = try frame("bright", width: 120, height: 80, level: 0.8)
        let portrait = try frame("portrait", width: 80, height: 120, level: 0.8)
        let larger = try frame("larger", width: 240, height: 160, level: 0.8)

        XCTAssertTrue(mergesAsHDR([dark, bright]), "frames of one size merge")
        XCTAssertFalse(mergesAsHDR([dark, portrait]), "a frame turned the other way is refused")
        XCTAssertFalse(mergesAsHDR([dark, larger]), "a frame of another size is refused")

        // which frame, for the dialog and the toast
        guard case .failure(let failure) = PhotoMerge.merge([dark, bright, portrait], kind: .hdr, options: .init(),
                                                            maxPixel: nil) else {
            return XCTFail("a turned frame among the brackets is refused")
        }
        XCTAssertEqual(failure, .mismatchedFrame(2))
        // the dialog's preview decodes both to its small size, where they'd look alike
        let full = try frame("full", width: 2400, height: 1600, level: 0.2)
        let half = try frame("half", width: 1200, height: 800, level: 0.8)
        guard case .failure(let preview) = PhotoMerge.merge([full, half], kind: .hdr, options: .init(), maxPixel: 900) else {
            return XCTFail("the preview refuses frames of different sizes too")
        }
        XCTAssertEqual(preview, .mismatchedFrame(1))
    }
}
