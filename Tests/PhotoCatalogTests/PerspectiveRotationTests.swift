import XCTest
import CoreGraphics
@testable import PhotoCatalog

/// ⌘] / ⌘[ turn the finished photo a quarter turn and nothing else, however it's corrected.
final class PerspectiveRotationTests: XCTestCase {
    private let size = CGSize(width: 6000, height: 4000)
    private let points = [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.15), CGPoint(x: 0.5, y: 0.5),
                          CGPoint(x: 0.25, y: 0.8), CGPoint(x: 0.85, y: 0.9), CGPoint(x: 0.6, y: 0.35)]

    /// Where `point` of the source photo ends up in the finished photo turned a quarter turn.
    private func turned(_ point: CGPoint, clockwise: Bool) -> CGPoint {
        clockwise ? CGPoint(x: 1 - point.y, y: point.x) : CGPoint(x: point.y, y: 1 - point.x)
    }

    /// The largest distance, in pixels of the finished photo's long edge, between the photo
    /// developed then turned and the photo turned (as ⌘] does) then developed.
    private func mismatch(_ settings: DevelopSettings, clockwise: Bool) -> Double {
        let next = DevelopGeometry.rotated(settings, clockwise: clockwise)
        let output = DevelopGeometry.outputSize(next, original: size)
        let longEdge = Double(max(output.width, output.height))
        return points.map { point in
            let before = turned(DevelopGeometry.finishedPoint(fromSource: point, settings: settings, sourceSize: size),
                                clockwise: clockwise)
            let after = DevelopGeometry.finishedPoint(fromSource: point, settings: next, sourceSize: size)
            return hypot(Double(before.x - after.x) * Double(output.width), Double(before.y - after.y) * Double(output.height))
                / longEdge * 6000
        }.max() ?? 0
    }

    /// The correction as every edit so far was rendered: the camera tilted, then turned sideways
    /// (R = Ry(yaw)·Rx(pitch)), centered and scaled to fit the frame.
    private func tiltFirstCorrection(vertical: Double, horizontal: Double, frame: CGSize) -> [Double] {
        let w = Double(frame.width), h = Double(frame.height), f = 1.4 * hypot(w, h) / 2
        let pitch = -vertical / 100 * 35 * .pi / 180, yaw = horizontal / 100 * 35 * .pi / 180
        let (cp, sp, cy, sy) = (cos(pitch), sin(pitch), cos(yaw), sin(yaw))
        func times(_ a: [Double], _ b: [Double]) -> [Double] {
            (0..<9).map { i in (0..<3).map { a[i / 3 * 3 + $0] * b[$0 * 3 + i % 3] }.reduce(0, +) }
        }
        func move(_ dx: Double, _ dy: Double) -> [Double] { [1, 0, dx, 0, 1, dy, 0, 0, 1] }
        func apply(_ m: [Double], _ x: Double, _ y: Double) -> (Double, Double) {
            let z = m[6] * x + m[7] * y + m[8]
            return ((m[0] * x + m[1] * y + m[2]) / z, (m[3] * x + m[4] * y + m[5]) / z)
        }
        let r = [cy, sy * sp, sy * cp, 0, cp, -sp, -sy, cy * sp, cy * cp]
        let turn = times(move(w / 2, h / 2), times([f, 0, 0, 0, f, 0, 0, 0, 1],
                                                  times(r, times([1 / f, 0, 0, 0, 1 / f, 0, 0, 0, 1], move(-w / 2, -h / 2)))))
        let corners = [(0.0, 0.0), (w, 0), (w, h), (0, h)].map { apply(turn, $0.0, $0.1) }
        let xs = corners.map(\.0), ys = corners.map(\.1)
        let s = min(w / (xs.max()! - xs.min()!), h / (ys.max()! - ys.min()!))
        return times(move(w / 2, h / 2), times([s, 0, 0, 0, s, 0, 0, 0, 1],
                                               times(move(-(xs.min()! + xs.max()!) / 2, -(ys.min()! + ys.max()!) / 2), turn)))
    }

    func testStoredEditsRenderAsBefore() throws {
        for rotation in 0..<4 {
            // as stored before the correction knew its order
            let json = #"{"rotation": \#(rotation), "perspectiveVertical": -30, "perspectiveHorizontal": 20}"#
            let stored = try JSONDecoder().decode(DevelopSettings.self, from: Data(json.utf8))
            let frame = DevelopGeometry.rotatedSize(size, rotation)
            let correction = try XCTUnwrap(DevelopGeometry.perspective(stored, frame: frame)).m
            let before = tiltFirstCorrection(vertical: -30, horizontal: 20, frame: frame)
            for i in 0..<9 {
                XCTAssertEqual(correction[i] / correction[8], before[i] / before[8], accuracy: 1e-9, "turned \(rotation), m[\(i)]")
            }
        }
    }

    func testFourQuarterTurnsComeBackToTheSameSettings() {
        var settings = DevelopSettings()
        settings.perspectiveVertical = -30
        settings.perspectiveHorizontal = 20
        settings.straighten = 2
        for clockwise in [true, false] {
            var turned = settings
            for _ in 0..<4 { turned = DevelopGeometry.rotated(turned, clockwise: clockwise) }
            XCTAssertEqual(turned, settings)
        }
        XCTAssertEqual(DevelopGeometry.rotated(DevelopGeometry.rotated(settings, clockwise: true), clockwise: false), settings)
    }

    func testTheOrderIsKeptWithTheTransform() throws {
        var settings = DevelopSettings()
        settings.perspectiveVertical = -30
        settings.perspectiveHorizontal = 20
        let turned = DevelopGeometry.rotated(settings, clockwise: true)
        XCTAssertTrue(turned.perspectiveYawFirst)
        XCTAssertEqual(try JSONDecoder().decode(DevelopSettings.self, from: JSONEncoder().encode(turned)), turned, "stored")
        var otherOrder = turned
        otherOrder.perspectiveYawFirst = false
        XCTAssertNotEqual(turned.fingerprint, otherOrder.fingerprint, "renders of the two orders are cached apart")

        // copy, sync and presets take it with the sliders, so the photos match
        var other = DevelopSettings()
        other.rotation = 1
        let copied = other.applying(turned, fields: [.perspective])
        let frame = DevelopGeometry.rotatedSize(size, 1)
        XCTAssertTrue(copied.perspectiveYawFirst)
        XCTAssertEqual(DevelopGeometry.perspective(copied, frame: frame), DevelopGeometry.perspective(turned, frame: frame))
        XCTAssertFalse(turned.applying(DevelopSettings(), fields: [.perspective]).perspectiveYawFirst)
        let half = DevelopSettings.blend(other, copied, amount: 0.5, isRaw: false, whiteBalanceOrigin: nil)
        XCTAssertTrue(half.perspectiveYawFirst && half.perspectiveVertical == 10, "a preset's amount scales it in its order")

        // no Transform, no order: a photo without one turns, and comes back, as it was
        var reset = turned
        reset.perspectiveVertical = 0
        reset.perspectiveHorizontal = 0
        XCTAssertFalse(reset.perspectiveYawFirst)
        XCTAssertFalse(DevelopGeometry.rotated(DevelopSettings(), clockwise: true).perspectiveYawFirst)
        XCTAssertTrue(DevelopGeometry.rotated(DevelopGeometry.rotated(DevelopSettings(), clockwise: true), clockwise: false).isNeutral)
    }

    func testQuarterTurnKeepsBothPerspectiveCorrections() {
        var settings = DevelopSettings()
        settings.perspectiveVertical = -30
        settings.perspectiveHorizontal = 20
        XCTAssertEqual(mismatch(settings, clockwise: true), 0, accuracy: 0.01)
        XCTAssertEqual(mismatch(settings, clockwise: false), 0, accuracy: 0.01)
    }

    func testQuarterTurnsFromAnyStart() {
        for (vertical, horizontal) in [(-30.0, 20.0), (-50, 50), (45, -25), (-100, 100), (-60, 0), (0, 40)] {
            for rotation in 0..<4 {
                for flipped in [false, true] {
                    for straighten in [0.0, 3.5] {
                        var settings = DevelopSettings()
                        settings.perspectiveVertical = vertical
                        settings.perspectiveHorizontal = horizontal
                        settings.rotation = rotation
                        settings.flipped = flipped
                        settings.straighten = straighten
                        for clockwise in [true, false] {
                            XCTAssertEqual(mismatch(settings, clockwise: clockwise), 0, accuracy: 0.01,
                                           "V \(vertical) H \(horizontal), turned \(rotation), flipped \(flipped), "
                                           + "straightened \(straighten), \(clockwise ? "⌘]" : "⌘[")")
                        }
                    }
                }
            }
        }
    }

    func testQuarterTurnKeepsAnExplicitCrop() {
        var settings = DevelopSettings()
        settings.perspectiveVertical = -40
        settings.perspectiveHorizontal = -15
        settings.crop = DevelopCrop(x: 0.2, y: 0.15, width: 0.5, height: 0.6)
        XCTAssertEqual(mismatch(settings, clockwise: true), 0, accuracy: 0.01)
        XCTAssertEqual(mismatch(DevelopGeometry.rotated(settings, clockwise: true), clockwise: true), 0, accuracy: 0.01)
    }
}
