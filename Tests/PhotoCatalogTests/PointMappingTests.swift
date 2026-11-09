import XCTest
import CoreGraphics
@testable import PhotoCatalog

/// A `PointMapping` built once maps every point to exactly the bits the per-point functions did
/// before it existed, both ways, for every combination of quarter turns, mirror, straighten,
/// perspective and crop.
final class PointMappingTests: XCTestCase {
    // ---- the per-point functions as they were, the oracle ----

    private static func oldFinishedPoint(fromSource p: CGPoint, settings s: DevelopSettings, sourceSize: CGSize) -> CGPoint {
        let w = Double(sourceSize.width), h = Double(sourceSize.height)
        var x = Double(p.x) * w, y = Double(p.y) * h
        switch ((s.rotation % 4) + 4) % 4 {
        case 1: (x, y) = (h - y, x)
        case 2: (x, y) = (w - x, h - y)
        case 3: (x, y) = (y, w - x)
        default: break
        }
        let frame = DevelopGeometry.rotatedSize(sourceSize, s.rotation)
        let fw = Double(frame.width), fh = Double(frame.height)
        if s.flipped { x = fw - x }
        if let perspective = DevelopGeometry.perspective(s, frame: frame), let p = perspective.apply(CGPoint(x: x, y: y)) {
            (x, y) = (Double(p.x), Double(p.y))
        }
        if s.straighten != 0 {
            let a = s.straighten * .pi / 180, dx = x - fw / 2, dy = y - fh / 2
            (x, y) = (fw / 2 + dx * cos(a) - dy * sin(a), fh / 2 + dx * sin(a) + dy * cos(a))
        }
        let crop = DevelopGeometry.effectiveCrop(s, frame: frame)
        return CGPoint(x: (x / fw - crop.x) / crop.width, y: (y / fh - crop.y) / crop.height)
    }

    private static func oldSourcePoint(fromFinished p: CGPoint, settings s: DevelopSettings, sourceSize: CGSize) -> CGPoint {
        let w = Double(sourceSize.width), h = Double(sourceSize.height)
        let frame = DevelopGeometry.rotatedSize(sourceSize, s.rotation)
        let fw = Double(frame.width), fh = Double(frame.height)
        let crop = DevelopGeometry.effectiveCrop(s, frame: frame)
        var x = (crop.x + Double(p.x) * crop.width) * fw, y = (crop.y + Double(p.y) * crop.height) * fh
        if s.straighten != 0 {
            let a = -s.straighten * .pi / 180, dx = x - fw / 2, dy = y - fh / 2
            (x, y) = (fw / 2 + dx * cos(a) - dy * sin(a), fh / 2 + dx * sin(a) + dy * cos(a))
        }
        if let perspective = DevelopGeometry.perspective(s, frame: frame),
           let p = perspective.inverse.apply(CGPoint(x: x, y: y)) {
            (x, y) = (Double(p.x), Double(p.y))
        }
        if s.flipped { x = fw - x }
        switch ((s.rotation % 4) + 4) % 4 {
        case 1: (x, y) = (y, h - x)
        case 2: (x, y) = (w - x, h - y)
        case 3: (x, y) = (w - y, x)
        default: break
        }
        return CGPoint(x: x / max(w, 1e-9), y: y / max(h, 1e-9))
    }

    // ---- cases ----

    private static var settingsCases: [DevelopSettings] {
        var cases: [DevelopSettings] = []
        for rotation in [0, 1, 2, 3, -1] {
            for flipped in [false, true] {
                for straighten in [0, 7.5, -12.25] {
                    for perspective in [(0.0, 0.0), (30.0, 0.0), (-45.0, 20.0)] {
                        for yawFirst in perspective == (0, 0) ? [false] : [false, true] {
                            for crop in [nil, DevelopCrop(x: 0.1, y: 0.05, width: 0.7, height: 0.8)] {
                                var s = DevelopSettings()
                                s.rotation = rotation
                                s.flipped = flipped
                                s.straighten = straighten
                                s.perspectiveVertical = perspective.0
                                s.perspectiveHorizontal = perspective.1
                                s.perspectiveYawFirst = yawFirst
                                s.crop = crop
                                cases.append(s)
                            }
                        }
                    }
                }
            }
        }
        return cases
    }

    private static let sizes = [CGSize(width: 6000, height: 4000), CGSize(width: 997, height: 1501)]

    private static let points: [CGPoint] = {
        var points: [CGPoint] = []
        for x in [-0.25, 0, 0.3, 0.77, 1, 1.4] {
            for y in [-0.1, 0, 0.42, 0.999, 1.2] { points.append(CGPoint(x: x, y: y)) }
        }
        return points
    }()

    private static func sameBits(_ a: CGPoint, _ b: CGPoint) -> Bool {
        Double(a.x).bitPattern == Double(b.x).bitPattern && Double(a.y).bitPattern == Double(b.y).bitPattern
    }

    private func assertSameBits(_ a: CGPoint, _ b: CGPoint, _ message: @autoclosure () -> String) {
        if !Self.sameBits(a, b) { XCTFail("\(a) ≠ \(b): \(message())") }
    }

    func testMappingMatchesThePerPointFunctionsBitForBit() {
        var compared = 0
        for size in Self.sizes {
            for s in Self.settingsCases {
                let mapping = DevelopGeometry.PointMapping(settings: s, sourceSize: size)
                let label = "rot \(s.rotation) flip \(s.flipped) str \(s.straighten) persp \(s.perspectiveVertical),"
                    + "\(s.perspectiveHorizontal) yaw \(s.perspectiveYawFirst) crop \(s.crop != nil) size \(size)"
                for (index, p) in Self.points.enumerated() {
                    let finished = Self.oldFinishedPoint(fromSource: p, settings: s, sourceSize: size)
                    assertSameBits(mapping.finished(fromSource: p), finished, "finished \(p) \(label)")
                    let source = Self.oldSourcePoint(fromFinished: p, settings: s, sourceSize: size)
                    assertSameBits(mapping.source(fromFinished: p), source, "source \(p) \(label)")
                    if index.isMultiple(of: 7) {
                        // the one-point wrappers, which DepthMap and the checks call
                        assertSameBits(DevelopGeometry.finishedPoint(fromSource: p, settings: s, sourceSize: size), finished,
                                       "finishedPoint \(p) \(label)")
                        assertSameBits(DevelopGeometry.sourcePoint(fromFinished: p, settings: s, sourceSize: size), source,
                                       "sourcePoint \(p) \(label)")
                    }
                    compared += 1
                }
            }
        }
        XCTAssertEqual(compared, Self.sizes.count * Self.settingsCases.count * Self.points.count)
        XCTAssertGreaterThan(compared, 15_000)
    }

    /// The screen mapper the mask and spot editors build per redraw maps as the functions do.
    func testMaskMapperUsesTheSameMapping() {
        var s = DevelopSettings()
        s.rotation = 1
        s.straighten = 4
        s.perspectiveVertical = 25
        let size = CGSize(width: 6000, height: 4000)
        let display = CGRect(x: 40, y: 20, width: 600, height: 900)
        let mapper = MaskMapper(display: display, settings: s, sourceSize: size)
        for p in Self.points {
            let finished = Self.oldFinishedPoint(fromSource: p, settings: s, sourceSize: size)
            let screen = CGPoint(x: display.minX + finished.x * display.width, y: display.minY + finished.y * display.height)
            assertSameBits(mapper.screen(p), screen, "screen \(p)")
            let back = CGPoint(x: (screen.x - display.minX) / display.width, y: (screen.y - display.minY) / display.height)
            assertSameBits(mapper.source(screen), Self.oldSourcePoint(fromFinished: back, settings: s, sourceSize: size),
                           "source \(p)")
        }
    }
}
