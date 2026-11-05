import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoCatalog

/// Places picked on the photo as the manual distortion correction shows it, found in the photo
/// as decoded, where spot sources and objects are looked for.
final class DistortionPickTests: XCTestCase {
    private var url: URL?

    override func tearDownWithError() throws {
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    private let size = CGSize(width: 1024, height: 683)

    /// Taking a point of the corrected photo to where it comes from, and back.
    func testTheCorrectionIsUndoneExactly() {
        for distortion in [-100.0, -40, 35, 100] {
            for p in [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.95, y: 0.95), CGPoint(x: 0.1, y: 0.8), CGPoint(x: 0.7, y: 0.02)] {
                let decoded = DevelopGeometry.distortionSource(p, distortion: distortion, sourceSize: size)
                let back = DevelopGeometry.distortionTarget(decoded, distortion: distortion, sourceSize: size)
                XCTAssertEqual(back.x, p.x, accuracy: 1e-6, "\(p) at \(distortion)")
                XCTAssertEqual(back.y, p.y, accuracy: 1e-6, "\(p) at \(distortion)")
            }
        }
        XCTAssertEqual(DevelopGeometry.distortionTarget(CGPoint(x: 0.3, y: 0.9), distortion: 0, sourceSize: size),
                       CGPoint(x: 0.3, y: 0.9))
    }

    /// A spot clicked near a corner of a photo with Distortion +100: the only clean place to take
    /// its replacement from lies just left of it, as the photo shows it. The search looked around
    /// the click's position in the photo as decoded, 67 pixels from the speck, and took its
    /// replacement from a place it never saw.
    func testASpotSourceIsFoundWhereTheCorrectedPhotoShowsIt() {
        let width = 1024, height = 683, distortion = 100.0
        let target = CGPoint(x: 0.95, y: 0.95)
        let decoded = DevelopGeometry.distortionSource(target, distortion: distortion, sourceSize: size)
        let s = (x: Double(decoded.x) * Double(width), y: Double(decoded.y) * Double(height))
        let r = 6.0
        // noise everywhere but around the speck and to its left (as decoded)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        var luma = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let px = Double(x) + 0.5, py = Double(y) + 0.5
                let clean = hypot(px - s.x, py - s.y) <= 2.5 * r || (px >= s.x - 7 * r && px <= s.x && abs(py - s.y) <= 2.5 * r)
                luma[y * width + x] = clean ? 0.5 : Double(seed >> 40) / Double(1 << 24)
            }
        }
        let found = SpotFinder.source(for: target, radius: r / Double(width), luma: luma, width: width, height: height,
                                      distortion: distortion)
        // the replacement comes from the clean place left of the speck, as the corrected photo shows it
        let from = DevelopGeometry.distortionSource(found, distortion: distortion, sourceSize: size)
        let x = Double(from.x) * Double(width), y = Double(from.y) * Double(height)
        XCTAssertTrue(x < s.x - 1.5 * r && x > s.x - 4.5 * r && abs(y - s.y) < r,
                      "taken from \(x), \(y) as decoded; the clean place is left of \(s.x), \(s.y) (found \(found))")
    }

    /// A box drawn on the corrected photo covers, as decoded, what it was drawn around.
    func testABoxIsTakenToThePhotoAsDecoded() throws {
        let box = CGRect(x: 0.8, y: 0.75, width: 0.15, height: 0.2)
        let prompt = ObjectPrompt(box: box, points: [.init(point: CGPoint(x: 0.9, y: 0.9), include: false)])
        let decoded = prompt.inPhotoAsDecoded(distortion: 100, sourceSize: size)
        let decodedBox = try XCTUnwrap(decoded.box)
        for corner in [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.midX, y: box.maxY)] {
            let p = DevelopGeometry.distortionSource(corner, distortion: 100, sourceSize: size)
            XCTAssertTrue(decodedBox.insetBy(dx: -1e-6, dy: -1e-6).contains(p), "\(p) outside \(decodedBox)")
        }
        XCTAssertEqual(decoded.points.count, 1)
        XCTAssertFalse(decoded.points[0].include)
        XCTAssertEqual(decoded.points[0].point, DevelopGeometry.distortionSource(CGPoint(x: 0.9, y: 0.9), distortion: 100,
                                                                                    sourceSize: size))
        XCTAssertEqual(prompt.inPhotoAsDecoded(distortion: 0, sourceSize: size), prompt)
    }

    /// Select Object clicked on a red disc near a corner of a photo with Distortion +100: the model
    /// was asked about the click's position in the photo as decoded, 60 pixels off, in the
    /// background.
    func testAnObjectClickedOnTheCorrectedPhotoIsSelected() throws {
        guard [AIModels.Name.objectEncoder, .objectPrompt, .objectDecoder].allSatisfy(AIModels.isAvailable) else {
            throw XCTSkip("the object models aren't bundled")
        }
        let width = 1024, height = 683, distortion = 100.0
        let click = CGPoint(x: 0.92, y: 0.9)
        let decoded = DevelopGeometry.distortionSource(click, distortion: distortion, sourceSize: size)
        let disc = (x: Double(decoded.x) * Double(width), y: Double(decoded.y) * Double(height), r: 30.0)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0.55, green: 0.6, blue: 0.65, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 0.85, green: 0.15, blue: 0.1, alpha: 1)
        // the context's y points up
        context.fillEllipse(in: CGRect(x: disc.x - disc.r, y: Double(height) - disc.y - disc.r, width: 2 * disc.r, height: 2 * disc.r))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pc-object-\(UUID().uuidString).png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        self.url = url

        let prompt = ObjectPrompt(points: [.init(point: click)]).inPhotoAsDecoded(distortion: distortion, sourceSize: size)
        guard case .found(let result) = ObjectSelection.lookup(prompt, url: url, isRaw: false) else {
            return XCTFail("something is selected")
        }
        // the mask covers the disc, and little else
        var weights = [UInt8](repeating: 0, count: result.mask.width * result.mask.height)
        let gray = try XCTUnwrap(CGContext(data: &weights, width: result.mask.width, height: result.mask.height, bitsPerComponent: 8,
                                           bytesPerRow: result.mask.width, space: CGColorSpaceCreateDeviceGray(),
                                           bitmapInfo: CGImageAlphaInfo.none.rawValue))
        gray.draw(result.mask, in: CGRect(x: 0, y: 0, width: result.mask.width, height: result.mask.height))
        let sx = Double(result.mask.width) / Double(width), sy = Double(result.mask.height) / Double(height)
        let center = weights[Int(disc.y * sy) * result.mask.width + Int(disc.x * sx)]
        XCTAssertGreaterThan(center, 127, "the disc is selected")
        let discShare = Double.pi * disc.r * disc.r / Double(width * height)
        XCTAssertLessThan(result.coverage, discShare * 2, "the background isn't")
    }

    /// A found mask's pin marks its centroid, which is found (and kept) in the photo as decoded:
    /// with Distortion +100 it showed where that place would be undistorted, off the mask.
    func testAFoundMasksPinShowsWhereTheCorrectedPhotoShowsIt() {
        var settings = DevelopSettings.neutral
        settings.distortion = 100
        let mapper = MaskMapper(display: CGRect(x: 0, y: 0, width: 600, height: 400), settings: settings,
                                sourceSize: size)
        let centroid = CGPoint(x: 0.9, y: 0.85)
        for kind in [LocalAdjustment.Kind.subject, .sky, .person, .object, .landscape] {
            var mask = LocalAdjustment(kind: kind)
            mask.center = centroid
            let pin = mapper.pin(of: mask), shown = mapper.screen(decoded: centroid)
            XCTAssertGreaterThan(hypot(mapper.screen(centroid).x - shown.x, mapper.screen(centroid).y - shown.y), 5)
            XCTAssertEqual(pin.x, shown.x, accuracy: 0.01, "\(kind)")
            XCTAssertEqual(pin.y, shown.y, accuracy: 0.01, "\(kind)")
        }
        // a radial mask's center is placed on the corrected photo, and shown there
        var radial = LocalAdjustment(kind: .radial)
        radial.center = centroid
        XCTAssertEqual(mapper.pin(of: radial), mapper.screen(centroid))
    }
}
