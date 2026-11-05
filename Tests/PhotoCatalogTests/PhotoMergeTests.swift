import XCTest
import CoreImage
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

/// The focal length a panorama is projected with, and the projection at its extremes.
final class PanoramaFocalTests: XCTestCase {
    private func frames(_ focals: [Double?]) -> [PhotoMerge.Frame] {
        focals.map { PhotoMerge.Frame(url: URL(fileURLWithPath: "/dev/null"), isRaw: false, brightness: nil, focalLength35: $0) }
    }

    func testTheMiddleFocalLengthOfTheFrames() {
        XCTAssertEqual(PhotoMerge.panoramaFocal35(frames([24, 28, 200])), 28)
        XCTAssertEqual(PhotoMerge.panoramaFocal35(frames([nil, nil])), 35)
    }

    /// Metadata that says a lens no camera has (a phone's actual 4 mm taken as a 35 mm
    /// equivalent, a broken focal-plane size) is kept to a lens that exists.
    func testAFocalLengthNoLensHasIsKeptToOneThatExists() {
        XCTAssertEqual(PhotoMerge.panoramaFocal35(frames([0.5, 0.5, 0.5])), PhotoMerge.panoramaFocal35Range.lowerBound)
        XCTAssertEqual(PhotoMerge.panoramaFocal35(frames([1e6, 1e6])), PhotoMerge.panoramaFocal35Range.upperBound)
        XCTAssertEqual(PhotoMerge.panoramaFocal35(frames([24])), 24)
    }

    /// Even a cylinder so tight that the edge of its rounded projection lies past a quarter
    /// turn never shows a place from the other side of the photo there.
    func testTheCylinderNeverReachesPastAQuarterTurn() throws {
        XCTAssertTrue(DevelopKernels.failedKernels.isEmpty, "every kernel compiles: \(DevelopKernels.failedKernels)")
        // red on the left half, blue on the right
        let image = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 50, height: 40))
            .composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 1))
                .cropped(to: CGRect(x: 0, y: 0, width: 100, height: 40)))
        // f = 0.4 px: the projection is about a pixel wide, its rounded extent reaching 2 radians
        let center = CGPoint(x: 10.3, y: 20)
        let warped = DevelopKernels.cylinderWarp(image, f: 0.4, center: center, vertical: false)
        let rect = warped.extent
        let width = Int(rect.width), height = Int(rect.height)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        DevelopRenderer.context.render(warped, toBitmap: &pixels, rowBytes: width * 16, bounds: rect,
                                       format: .RGBAf, colorSpace: nil)
        XCTAssertTrue(pixels.allSatisfy(\.isFinite))
        // on the rows through the middle (further out, the steep cylinder looks past the photo's
        // top and bottom), a place left of the middle shows the left (red), never the right (blue)
        for y in [height / 2 - 1, height / 2] {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let left = rect.minX + CGFloat(x) + 0.5 < center.x
                XCTAssertGreaterThan(left ? pixels[i] : pixels[i + 2], 0.5,
                                     "pixel \(x),\(y) of \(rect) shows the photo's other side: \(pixels[i..<(i + 4)])")
            }
        }
    }
}
