import XCTest
import CoreGraphics
import CoreImage
@testable import PhotoCatalog

/// Measuring chromatic aberration fits red and blue side by side: each fit only reads the
/// photo's planes, so the correction is the one the fits found one after the other.
final class ChromaticAberrationFitTests: XCTestCase {
    /// The develop check's scene, 480 × 360: gray, black and white rectangles with a few colored
    /// ones, each channel drawn at its own magnification about the middle, as a lens with
    /// lateral chromatic aberration shows it.
    private func photographed(red: Double, blue: Double) throws -> CGImage {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func random(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }
        var boxes: [(x: Int, y: Int, w: Int, h: Int, c: (Double, Double, Double))] = []
        let grays = [0.08, 0.3, 0.7, 0.92]
        for _ in 0..<90 {
            let v = grays[random(4)]
            boxes.append((random(470), random(350), 8 + random(50), 8 + random(50), (v, v, v)))
        }
        for i in 0..<8 {
            let color = i.isMultiple(of: 2) ? (0.8, 0.15, 0.1) : (0.12, 0.25, 0.8)
            boxes.append((random(440), random(320), 20 + random(30), 20 + random(30), color))
        }
        let planes = try [red, 1, blue].enumerated().map { channel, scale -> [UInt8] in
            var plane = [UInt8](repeating: 0, count: 480 * 360)
            let context = try XCTUnwrap(CGContext(data: &plane, width: 480, height: 360, bitsPerComponent: 8, bytesPerRow: 480,
                                                  space: CGColorSpaceCreateDeviceGray(),
                                                  bitmapInfo: CGImageAlphaInfo.none.rawValue))
            context.setFillColor(gray: 0.45, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 480, height: 360))
            context.translateBy(x: 240, y: 180)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -240, y: -180)
            for box in boxes {
                context.setFillColor(gray: [box.c.0, box.c.1, box.c.2][channel], alpha: 1)
                context.fill(CGRect(x: box.x, y: box.y, width: box.w, height: box.h))
            }
            return plane
        }
        var data = [UInt8](repeating: 255, count: 480 * 360 * 4)
        for y in 0..<360 {
            for x in 0..<480 {
                // the planes' rows run bottom up; the picture's top down
                let source = (359 - y) * 480 + x, i = (y * 480 + x) * 4
                data[i] = planes[0][source]; data[i + 1] = planes[1][source]; data[i + 2] = planes[2][source]
            }
        }
        let context = try XCTUnwrap(CGContext(data: &data, width: 480, height: 360, bitsPerComponent: 8, bytesPerRow: 480 * 4,
                                              space: DevelopRenderer.outputColorSpace,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }

    func testConcurrentFitsFindTheSerialCorrection() throws {
        // red magnified 0.4%, blue shrunk 0.3%: the develop check's lens
        let fringed = CIImage(cgImage: try photographed(red: 1.004, blue: 0.997))
        let serial = ChromaticAberration.measure(fringed, fitsConcurrently: false)
        XCTAssertFalse(serial.red.isNone, "red's fringe is measured")
        XCTAssertFalse(serial.blue.isNone, "blue's fringe is measured")
        XCTAssertEqual(ChromaticAberration.measure(fringed, fitsConcurrently: true), serial)
    }
}
