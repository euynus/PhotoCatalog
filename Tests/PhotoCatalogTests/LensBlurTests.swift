import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoCatalog

final class LensBlurTests: XCTestCase {
    private var folder: URL?

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    /// Depth by column: the left half far (0), the right half near (1).
    private let leftFarRightNear = DepthMap.Map(width: 2, height: 1, values: [0, 1])
    /// Depth by row of a 512 × 512 photo: the top quarter far (0), the rest near (1).
    private let topQuarterFar = DepthMap.Map(width: 512, height: 512, values: (0..<(512 * 512)).map { $0 / 512 < 128 ? 0 : 1 })

    func testPickFocusReadsTheDepthUnderThePointer() {
        let size = CGSize(width: 6000, height: 4000)
        let plain = DevelopSettings()
        XCTAssertEqual(leftFarRightNear.depth(atFinished: CGPoint(x: 0.25, y: 0.5), settings: plain, sourceSize: size),
                       0, accuracy: 1e-6)
        XCTAssertEqual(leftFarRightNear.depth(atFinished: CGPoint(x: 0.75, y: 0.5), settings: plain, sourceSize: size),
                       1, accuracy: 1e-6)
    }

    func testPickFocusFollowsAQuarterTurn() {
        let size = CGSize(width: 6000, height: 4000)
        var turned = DevelopSettings()
        turned.rotation = 1   // clockwise: the photo's left edge is now at the top
        XCTAssertEqual(leftFarRightNear.depth(atFinished: CGPoint(x: 0.5, y: 0.25), settings: turned, sourceSize: size),
                       0, accuracy: 1e-6)
        XCTAssertEqual(leftFarRightNear.depth(atFinished: CGPoint(x: 0.5, y: 0.75), settings: turned, sourceSize: size),
                       1, accuracy: 1e-6)
    }

    func testPickFocusFollowsManualDistortion() {
        let size = CGSize(width: 512, height: 512)
        var settings = DevelopSettings()
        settings.distortion = 100
        // at the left edge the correction pulls the far quarter's edge from row 128 up to about 114:
        // row 120 shows what was below it, near
        XCTAssertEqual(topQuarterFar.depth(atFinished: CGPoint(x: 4.0 / 512, y: 120.0 / 512), settings: settings,
                                           sourceSize: size), 1, accuracy: 1e-6)
        XCTAssertEqual(topQuarterFar.depth(atFinished: CGPoint(x: 4.0 / 512, y: 120.0 / 512), settings: DevelopSettings(),
                                           sourceSize: size), 0, accuracy: 1e-6)
    }

    /// The depth view lines up with the photo when manual distortion bends it.
    func testDepthIsBentByManualDistortionAsThePhotoIs() throws {
        XCTAssertTrue(DevelopKernels.failedKernels.isEmpty, "every develop kernel compiles: \(DevelopKernels.failedKernels)")
        // the photo shows what the depth says: its top quarter (the far part) dark, the rest light
        let width = 512, height = 512
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width { pixels[y * width + x] = y < 128 ? 50 : 205 } }
        let url = try png(pixels, width: width, height: height)
        DepthMap.remember(topQuarterFar, for: url)
        let source = try XCTUnwrap(DevelopRenderer.Source(url: url, isRaw: false, maxPixel: nil))
        // down the left edge, where the correction moves the edge most: the first row past halfway
        // from dark to light, and from far (cool) to near (warm)
        func edge(_ pixels: [UInt8], channel: Int) -> Int? {
            let value = { (y: Int) in Int(pixels[(y * width + 4) * 4 + channel]) }
            return (0..<height).first { value($0) * 2 > value(0) + value(height - 1) }
        }
        for distortion in [100.0, -100.0] {
            var settings = DevelopSettings()
            settings.distortion = distortion
            let photo = try rgba(try XCTUnwrap(source.image(settings)))
            let depth = try rgba(try XCTUnwrap(source.image(settings, visualizeDepth: true)))
            let photoEdge = try XCTUnwrap(edge(photo, channel: 1)), depthEdge = try XCTUnwrap(edge(depth, channel: 0))
            // at row 128 as decoded; either way the correction moves it up here (barrel's zooms in)
            XCTAssertLessThan(photoEdge, 124, "distortion \(distortion) moves the photo's edge")
            XCTAssertLessThanOrEqual(abs(photoEdge - depthEdge), 2,
                                     "distortion \(distortion): photo edge \(photoEdge), depth edge \(depthEdge)")
            // Pick Focus reads the depth the view shows
            for (row, near) in [(photoEdge - 4, 0.0), (photoEdge + 4, 1.0)] {
                XCTAssertEqual(topQuarterFar.depth(atFinished: CGPoint(x: 4.5 / Double(width), y: (Double(row) + 0.5) / Double(height)),
                                                   settings: settings, sourceSize: CGSize(width: width, height: height)),
                               near, accuracy: 1e-6, "distortion \(distortion), row \(row)")
            }
        }
    }

    private func png(_ gray: [UInt8], width: Int, height: Int) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LensBlurTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.folder = folder
        let provider = try XCTUnwrap(CGDataProvider(data: Data(gray) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                          provider: provider, decode: nil, shouldInterpolate: false,
                                          intent: .defaultIntent))
        let url = folder.appendingPathComponent("photo.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func rgba(_ image: CIImage) throws -> [UInt8] {
        try XCTUnwrap(SemanticMasks.rgba(try XCTUnwrap(DevelopRenderer.render(image))))
    }
}
