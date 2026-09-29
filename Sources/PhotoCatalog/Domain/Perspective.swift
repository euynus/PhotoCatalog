// ============================================================
//  Perspective — Lightroom's Transform: turning the camera back
// ============================================================
import Foundation
import CoreGraphics

/// A projective map of the plane, row-major 3×3.
struct Homography: Equatable, Sendable {
    var m: [Double]

    static let identity = Homography(m: [1, 0, 0, 0, 1, 0, 0, 0, 1])

    /// Where `p` lands; nil when it goes to infinity (or behind).
    func apply(_ p: CGPoint) -> CGPoint? {
        let x = Double(p.x), y = Double(p.y)
        let w = m[6] * x + m[7] * y + m[8]
        guard w > 1e-12 else { return nil }
        return CGPoint(x: (m[0] * x + m[1] * y + m[2]) / w, y: (m[3] * x + m[4] * y + m[5]) / w)
    }

    /// `self` after `other`: other applied first.
    func after(_ other: Homography) -> Homography {
        var r = [Double](repeating: 0, count: 9)
        for i in 0..<3 { for j in 0..<3 { for k in 0..<3 { r[i * 3 + j] += m[i * 3 + k] * other.m[k * 3 + j] } } }
        return Homography(m: r)
    }

    var inverse: Homography {
        let a = m
        let c00 = a[4] * a[8] - a[5] * a[7], c01 = a[5] * a[6] - a[3] * a[8], c02 = a[3] * a[7] - a[4] * a[6]
        let det = a[0] * c00 + a[1] * c01 + a[2] * c02
        guard abs(det) > 1e-18 else { return .identity }
        let inv = [
            c00, a[2] * a[7] - a[1] * a[8], a[1] * a[5] - a[2] * a[4],
            c01, a[0] * a[8] - a[2] * a[6], a[2] * a[3] - a[0] * a[5],
            c02, a[1] * a[6] - a[0] * a[7], a[0] * a[4] - a[1] * a[3],
        ]
        // keep w positive for points in front, so `apply` can tell them from ones behind
        let scale = (inv[8] >= 0 ? 1 : -1) / det
        return Homography(m: inv.map { $0 * scale })
    }

    static func translation(_ dx: Double, _ dy: Double) -> Homography { Homography(m: [1, 0, dx, 0, 1, dy, 0, 0, 1]) }
    static func scale(_ s: Double) -> Homography { Homography(m: [s, 0, 0, 0, s, 0, 0, 0, 1]) }
}

extension DevelopGeometry {
    /// The Transform sliders at ±100 turn the camera this far.
    static let maxPerspectiveAngle = 35.0
    /// The focal length the correction assumes, in half-diagonals of the frame (a moderate wide
    /// angle). Any fixed value makes converging lines parallel; it only sets how much the photo
    /// stretches on the way.
    static let perspectiveFocal = 1.4

    /// The camera turn the Transform sliders stand for, in radians: pitch from Vertical
    /// (negative widens the top, as when a building shot from below is set upright) and yaw from
    /// Horizontal (positive enlarges the right side).
    static func perspectiveAngles(vertical: Double, horizontal: Double) -> (pitch: Double, yaw: Double) {
        (-vertical / 100 * maxPerspectiveAngle * .pi / 180, horizontal / 100 * maxPerspectiveAngle * .pi / 180)
    }

    /// The re-projection for a camera turn in a frame of `frame` pixels, about its center: K·R·K⁻¹.
    static func rotation(pitch: Double, yaw: Double, frame: CGSize) -> Homography {
        let w = Double(frame.width), h = Double(frame.height)
        let f = perspectiveFocal * hypot(w, h) / 2
        let (cp, sp, cy, sy) = (cos(pitch), sin(pitch), cos(yaw), sin(yaw))
        // R = Ry(yaw)·Rx(pitch), with y pointing down and z into the scene
        let r = [cy, sy * sp, sy * cp,
                 0, cp, -sp,
                 -sy, cy * sp, cy * cp]
        let k = Homography(m: [f, 0, 0, 0, f, 0, 0, 0, 1])
        let kInverse = Homography(m: [1 / f, 0, 0, 0, 1 / f, 0, 0, 0, 1])
        let centered = Homography.translation(-w / 2, -h / 2)
        return Homography.translation(w / 2, h / 2).after(k).after(Homography(m: r)).after(kInverse).after(centered)
    }

    /// The photo's perspective correction in its frame (pixels, top-left origin, after quarter
    /// turns and the mirror), or nil when there is none. The corrected photo is centered and
    /// scaled to fit the frame, so none of it is lost; the crop then leaves out the empty corners.
    static func perspective(_ s: DevelopSettings, frame: CGSize) -> Homography? {
        guard s.perspectiveVertical != 0 || s.perspectiveHorizontal != 0, frame.width > 0, frame.height > 0 else {
            return nil
        }
        let angles = perspectiveAngles(vertical: s.perspectiveVertical, horizontal: s.perspectiveHorizontal)
        let turn = rotation(pitch: angles.pitch, yaw: angles.yaw, frame: frame)
        let w = Double(frame.width), h = Double(frame.height)
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0), CGPoint(x: w, y: h), CGPoint(x: 0, y: h)]
        let mapped = corners.compactMap(turn.apply)
        guard mapped.count == 4 else { return nil }
        let xs = mapped.map { Double($0.x) }, ys = mapped.map { Double($0.y) }
        let (minX, maxX, minY, maxY) = (xs.min()!, xs.max()!, ys.min()!, ys.max()!)
        let scale = min(w / max(maxX - minX, 1e-9), h / max(maxY - minY, 1e-9))
        return Homography.translation(w / 2, h / 2).after(.scale(scale))
            .after(.translation(-(minX + maxX) / 2, -(minY + maxY) / 2)).after(turn)
    }
}
