import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoCatalog

/// Measuring a photo's lateral chromatic aberration: once per file, however many renders ask.
final class ChromaticAberrationTests: XCTestCase {
    private var url: URL?

    override func tearDownWithError() throws {
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    /// A 600 × 400 PNG of gray squares, a new file each time (so nothing about it is known yet).
    private func photo() throws -> URL {
        let width = 600, height = 400
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(gray: 0.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 0.8, alpha: 1)
        for x in stride(from: 20, to: width, by: 80) {
            for y in stride(from: 20, to: height, by: 80) { context.fill(CGRect(x: x, y: y, width: 40, height: 40)) }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pc-ca-\(UUID().uuidString).png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        self.url = url
        return url
    }

    /// Renders of a photo not yet measured (the preview, the export, a thumbnail) each decoded
    /// it at 3000 px and allocated its float planes, side by side.
    func testConcurrentRendersOfOnePhotoMeasureItOnce() throws {
        let url = try photo()
        let before = ChromaticAberration.measurements
        let corrections = Collected<ChromaticAberration.Correction>()
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            corrections.add(ChromaticAberration.correction(url: url, isRaw: false))
        }
        XCTAssertEqual(ChromaticAberration.measurements - before, 1, "the photo is measured once")
        XCTAssertEqual(corrections.values.count, 4)
        XCTAssertTrue(corrections.values.allSatisfy { $0 == corrections.values[0] }, "every render gets the same correction")
    }
}

/// What concurrent work hands back, gathered under a lock.
final class Collected<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var gathered: [Value] = []

    func add(_ value: Value) { lock.withLock { gathered.append(value) } }
    var values: [Value] { lock.withLock { gathered } }
}
