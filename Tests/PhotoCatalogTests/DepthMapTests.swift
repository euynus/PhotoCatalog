import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoCatalog

/// A photo's depth map is made once, however many renders ask for it at the same time.
final class DepthMapTests: XCTestCase {
    private var url: URL?

    override func tearDownWithError() throws {
        if let url {
            DepthMap.forget(url)
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// A 640 × 480 PNG, light at the top and dark below, new each time.
    private func photo() throws -> URL {
        let width = 640, height = 480
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        for y in 0..<height {
            context.setFillColor(gray: 0.9 - 0.8 * CGFloat(y) / CGFloat(height), alpha: 1)
            context.fill(CGRect(x: 0, y: height - 1 - y, width: width, height: 1))
        }
        context.setFillColor(red: 0.8, green: 0.3, blue: 0.2, alpha: 1)
        context.fillEllipse(in: CGRect(x: 240, y: 60, width: 160, height: 200))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pc-depth-\(UUID().uuidString).png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        self.url = url
        return url
    }

    /// The preview, an export and Pick Focus asking for a new photo's depth together each ran
    /// the model on it, on the one shared model, at the same time.
    func testConcurrentRequestsForOnePhotoRunTheModelOnce() throws {
        guard AIModels.isAvailable(.depth), AIModels.model(.depth) != nil else { throw XCTSkip("the depth model isn't bundled") }
        let url = try photo()
        let before = DepthMap.computations
        let maps = Collected<DepthMap.Map?>()
        DispatchQueue.concurrentPerform(iterations: 4) { _ in maps.add(DepthMap.map(for: url, isRaw: false)) }
        XCTAssertEqual(DepthMap.computations - before, 1, "the model runs once for the photo")
        XCTAssertEqual(maps.values.count, 4)
        XCTAssertNotNil(maps.values[0])
        XCTAssertTrue(maps.values.allSatisfy { $0 == maps.values[0] }, "every request gets the same map")
    }
}
