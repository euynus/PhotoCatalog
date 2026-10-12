import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoCatalog

/// Auto Upright on a facade seen from below and from one side, whichever way the photo is turned.
final class UprightTests: XCTestCase {
    private var folder: URL!

    /// The facade as it looks upright: a 400 × 600 frame, its verticals meeting above the photo,
    /// its horizontals far to the right.
    private let frame = (width: 400, height: 600)
    private let top = CGPoint(x: 300, y: -1200), side = CGPoint(x: 900, y: 250)
    /// Where the verticals cross the bottom edge and the horizontals the left one.
    private let bottoms = Array(stride(from: 40.0, through: 360.0, by: 64.0))
    private let lefts = Array(stride(from: 30.0, through: 570.0, by: 60.0))

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("UprightTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    /// The facade's luma in the upright frame, rows from the top.
    private func facade() -> [UInt8] {
        var pixels = [UInt8](repeating: 210, count: frame.width * frame.height)
        func plot(_ x: Double, _ y: Double, across: Bool) {
            for d in -1...1 {
                let xi = Int(x.rounded()) + (across ? 0 : d), yi = Int(y.rounded()) + (across ? d : 0)
                if xi >= 0, xi < frame.width, yi >= 0, yi < frame.height { pixels[yi * frame.width + xi] = 25 }
            }
        }
        for bottom in bottoms {
            for y in 0..<frame.height {
                let t = (Double(y) - top.y) / (Double(frame.height) - top.y)
                plot(top.x + (bottom - top.x) * t, Double(y), across: false)
            }
        }
        for left in lefts {
            for x in 0..<frame.width {
                plot(Double(x), left + (side.y - left) * Double(x) / side.x, across: true)
            }
        }
        return pixels
    }

    /// A photo file that `rotation` quarter turns clockwise (0 or 1) show as the facade upright.
    private func photo(rotation: Int) throws -> URL {
        let upright = facade()
        let (width, height) = rotation == 1 ? (frame.height, frame.width) : (frame.width, frame.height)
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                // turned clockwise, the photo's bottom-left corner becomes the frame's top-left
                pixels[y * width + x] = rotation == 1 ? upright[x * frame.width + (height - 1 - y)] : upright[y * width + x]
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                          provider: provider, decode: nil, shouldInterpolate: false,
                                          intent: .defaultIntent))
        let url = folder.appendingPathComponent("facade-\(rotation).png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    /// How far each vertical leans in the finished photo (degrees) with `settings`.
    private func leans(_ settings: DevelopSettings) -> [Double] {
        let turned = settings.rotation == 1
        let sourceSize = turned ? CGSize(width: frame.height, height: frame.width) : CGSize(width: frame.width, height: frame.height)
        return bottoms.map { bottom in
            func finished(_ y: Double) -> CGPoint {
                let t = (y - top.y) / (Double(frame.height) - top.y)
                let x = top.x + (bottom - top.x) * t
                // the upright frame's point on the photo as stored
                let source = turned
                    ? CGPoint(x: y / Double(frame.height), y: (Double(frame.width) - x) / Double(frame.width))
                    : CGPoint(x: x / Double(frame.width), y: y / Double(frame.height))
                let p = DevelopGeometry.finishedPoint(fromSource: source, settings: settings, sourceSize: sourceSize)
                return CGPoint(x: p.x * CGFloat(frame.width), y: p.y * CGFloat(frame.height))
            }
            let a = finished(50), b = finished(550)
            return atan2(Double(b.x - a.x), Double(b.y - a.y)) * 180 / .pi
        }
    }

    /// Auto Upright on the photo turned `rotation` quarter turns; `settings` are its develop
    /// settings before (a Transform of its own, say).
    private func checkAutoUpright(rotation: Int, settings start: DevelopSettings? = nil,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        var settings = start ?? DevelopSettings()
        settings.rotation = rotation
        let correction = try XCTUnwrap(DevelopRenderer.uprightCorrection(url: try photo(rotation: rotation), isRaw: false,
                                                                         settings: settings, mode: .auto),
                                       "the facade's lines are found", file: file, line: line)
        XCTAssertLessThan(correction.vertical, -10, "the verticals meet above: \(correction)", file: file, line: line)
        XCTAssertGreaterThan(abs(correction.horizontal), 5, "the horizontals meet to the side: \(correction)",
                             file: file, line: line)
        settings = correction.applied(to: settings)
        let leans = leans(settings)
        XCTAssertTrue(leans.allSatisfy { abs($0) < 0.8 },
                      "verticals upright: \(correction), \(leans.map { String(format: "%.2f", $0) })", file: file, line: line)
    }

    func testAutoUprightSetsVerticalsUpright() throws {
        try checkAutoUpright(rotation: 0)
    }

    func testAutoUprightSetsVerticalsUprightOnATurnedPhoto() throws {
        try checkAutoUpright(rotation: 1)
    }

    func testAutoUprightReplacesATransformMadeBeforeATurn() throws {
        var corrected = DevelopSettings()
        corrected.perspectiveVertical = 20
        corrected.perspectiveHorizontal = -15
        let turned = DevelopGeometry.rotated(corrected, clockwise: true)
        XCTAssertEqual(turned.rotation, 1)
        XCTAssertTrue(turned.perspectiveYawFirst, "the turn swapped the order of the camera turns")
        try checkAutoUpright(rotation: 1, settings: turned)
    }
}
