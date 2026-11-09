import XCTest
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoCatalog

/// A panorama takes its first frame's full long edge from the small decode it lines frames up
/// on, rather than decoding that frame at full size for it; a preview scales the small decodes
/// down rather than decoding each frame again. Non-RAW frames only.
final class PanoramaLongEdgeTests: XCTestCase {
    private var urls: [URL] = []

    override func tearDownWithError() throws {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    /// A scene around the camera: a dark floor with discs of other brightness (the merge check's).
    private func scene(_ angle: Double, _ height: Double) -> Double {
        func hash(_ a: Int, _ b: Int) -> Double {
            var z = UInt64(bitPattern: Int64(a)) &* 0x9E37_79B9_7F4A_7C15 ^ UInt64(bitPattern: Int64(b)) &* 0xC2B2_AE3D_27D4_EB4F
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Double(z % 10_000) / 10_000
        }
        let u = angle * 400, v = height * 400
        var value = 0.18 * (0.8 + 0.4 * hash(Int(floor(u / 2)), Int(floor(v / 2))))
        for disc in 0..<60 {
            let cx = -500 + hash(disc, 1) * 1000, cy = -150 + hash(disc, 2) * 300, r = 6 + hash(disc, 3) * 40
            if hypot(u - cx, v - cy) < r { value *= 0.3 + 1.7 * hash(disc, 4) }
        }
        return value
    }

    /// The scene through a camera turned `turn` radians with a 500 px lens, 400 × 300, drawn at
    /// `upscale` times that size (a lens as many times longer), saved as `type` with `orientation`.
    private func frame(turn: Double, upscale: Int = 4, type: UTType = .png, orientation: Int = 1) throws -> URL {
        let (width, height, f) = (400, 300, 500.0)
        var data = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let dx = Double(x) - Double(width) / 2, dy = Double(y) - Double(height) / 2
                let v = min(1, scene(turn + atan(dx / f), dy / hypot(dx, f)))
                let encoded = v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
                let byte = UInt8(max(0, min(255, encoded * 255)))
                let i = (y * width + x) * 4
                data[i] = byte; data[i + 1] = byte; data[i + 2] = byte
            }
        }
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let small = try XCTUnwrap(CGContext(data: &data, width: width, height: height, bitsPerComponent: 8,
                                            bytesPerRow: width * 4, space: space,
                                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage())
        let large = try XCTUnwrap(CGContext(data: nil, width: width * upscale, height: height * upscale, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        large.interpolationQuality = .high
        large.draw(small, in: CGRect(x: 0, y: 0, width: width * upscale, height: height * upscale))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-pano-edge-\(UUID().uuidString).\(type.preferredFilenameExtension ?? "img")")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(large.makeImage()), [
            kCGImagePropertyOrientation: orientation,
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        urls.append(url)
        return url
    }

    private func longEdge(_ image: CIImage) -> CGFloat { max(image.extent.width, image.extent.height) }

    /// The long edge known from the small decode is the full decode's, for PNG and JPEG frames,
    /// larger and smaller than the size frames are lined up at, and turned by their orientation.
    func testTheSmallDecodeKnowsTheFullLongEdge() throws {
        let fixtures = [
            try frame(turn: 0), try frame(turn: 0, type: .jpeg), try frame(turn: 0, type: .jpeg, orientation: 6),
            try frame(turn: 0, upscale: 1), try frame(turn: 0, upscale: 1, type: .jpeg),
        ]
        for url in fixtures {
            let photo = PhotoMerge.Frame(url: url, isRaw: false, brightness: nil)
            let small = try XCTUnwrap(PhotoMerge.decodeWithSize(photo, maxPixel: PhotoMerge.analysisPixel))
            let full = try XCTUnwrap(PhotoMerge.decode(photo, maxPixel: nil))
            XCTAssertEqual(small.fullLongEdge, longEdge(full), url.lastPathComponent)
            XCTAssertEqual(longEdge(small.image), min(longEdge(full), CGFloat(PhotoMerge.analysisPixel)), url.lastPathComponent)
        }
    }

    /// Three 400 × 300 PNG frames 0.35 rad apart, the merge check's (lining frames up is slow in
    /// a debug build, so they're small; the test above covers JPEG and larger frames, and the merge
    /// check the full panorama against its layout): a preview at 300 px, scaled down from the
    /// frames as they were lined up, is the full panorama at three quarters the size.
    func testAPreviewIsThePanoramaScaledDown() throws {
        let urls = try [-0.35, 0, 0.35].map { try frame(turn: $0, upscale: 1) }
        let focal35 = 500 * 43.27 / hypot(400.0, 300)
        let frames = urls.map { PhotoMerge.Frame(url: $0, isRaw: false, brightness: nil, focalLength35: focal35) }
        guard case .success(let full) = PhotoMerge.panorama(frames, maxPixel: nil),
              case .success(let preview) = PhotoMerge.panorama(frames, maxPixel: 300) else {
            return XCTFail("the frames merge")
        }
        XCTAssertGreaterThan(full.extent.width, 2 * full.extent.height, "the panorama spans the three frames")
        XCTAssertEqual(Double(preview.extent.width), Double(full.extent.width) * 0.75, accuracy: 4)
        XCTAssertEqual(Double(preview.extent.height), Double(full.extent.height) * 0.75, accuracy: 4)
        XCTAssertNotNil(DevelopRenderer.render(preview), "the preview renders")
    }
}
