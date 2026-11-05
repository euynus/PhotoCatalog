import XCTest
import CoreGraphics
import Darwin
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoCatalog

/// Print photos rendered larger than their original: their pixels live outside malloc, so the
/// memory they free isn't reused for Image I/O's decode cache, where it stayed resident.
final class PrintMemoryTests: XCTestCase {
    private var url: URL?

    override func tearDownWithError() throws {
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    /// A 3000 × 2000 JPEG of colored squares: big enough for its decode to take a block of its own.
    private func photo() throws -> URL {
        let width = 3000, height = 2000
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        for y in stride(from: 0, to: height, by: 20) {
            for x in stride(from: 0, to: width, by: 20) {
                context.setFillColor(red: CGFloat(x % 256) / 255, green: CGFloat(y % 256) / 255,
                                     blue: CGFloat((x + y) % 256) / 255, alpha: 1)
                context.fill(CGRect(x: x, y: y, width: 20, height: 20))
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pc-print-memory-\(UUID().uuidString).jpg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        self.url = url
        return url
    }

    private var footprint: Int64 {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? Int64(info.ri_phys_footprint) : 0
    }

    /// How much the footprint grew over `count` print renders of the photo at `pixels`, each
    /// by a renderer of its own (so none is kept for a redraw).
    private func growth(_ url: URL, pixels: CGSize, count: Int) -> Int64 {
        let item = PrintItem(sourcePath: url.path, isRaw: false, develop: .neutral,
                             originalSize: CGSize(width: 3000, height: 2000), filename: "photo.jpg", title: "")
        let before = footprint
        for _ in 0..<count {
            autoreleasepool {
                XCTAssertNotNil(PrintRenderer(items: [item], settings: PrintSettings()).photo(0, pixels: pixels))
            }
        }
        return footprint - before
    }

    func testRenderedPixelsAreMapped() throws {
        var pixels: UnsafeMutableRawPointer?
        autoreleasepool {
            let image = MappedPixels.image(width: 640, height: 480, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 640 * 4,
                                           space: DevelopRenderer.outputColorSpace,
                                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)) {
                pixels = $0
                $0.storeBytes(of: 0xFF, as: UInt8.self)
                return true
            }
            XCTAssertNotNil(image)
            if let pixels {
                XCTAssertNil(malloc_zone_from_ptr(pixels), "the pixels aren't malloc's")
                XCTAssertEqual(msync(pixels, 1, MS_ASYNC), 0, "mapped while the image lives")
            }
        }
        // (that it's unmapped once the image goes isn't asked of the address, which another
        // thread may map again by then: renders that kept it would grow the footprint below)
        XCTAssertNotNil(pixels)
        XCTAssertNil(MappedPixels.image(width: 8, height: 8, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 32,
                                        space: DevelopRenderer.outputColorSpace,
                                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)) { _ in false },
                     "no image when filling fails")
    }

    /// Enlarged renders (a print bigger than the photo) left one decoded original resident per
    /// render — 40 pages kept about a gigabyte. They now grow the footprint no more than
    /// renders at the photo's own size do.
    func testEnlargedPrintRendersDontAccumulate() throws {
        let url = try photo()
        let count = 24
        let bitmap = Int64(3208 * 2139 * 4)
        // Core Image's working surfaces made for both sizes first
        _ = growth(url, pixels: CGSize(width: 3000, height: 2000), count: 2)
        _ = growth(url, pixels: CGSize(width: 3208, height: 2139), count: 2)
        let sameSize = growth(url, pixels: CGSize(width: 3000, height: 2000), count: count)
        let enlarged = growth(url, pixels: CGSize(width: 3208, height: 2139), count: count)
        XCTAssertLessThan(enlarged, sameSize + 6 * bitmap,
                          "enlarged: \(enlarged >> 20) MB, same size: \(sameSize >> 20) MB over \(count) renders")
    }
}
