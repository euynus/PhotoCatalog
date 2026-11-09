// ============================================================
//  Point mapping — source photo ⇄ finished photo, for one photo's settings
// ============================================================
import Foundation
import CoreGraphics

extension DevelopGeometry {
    /// `finishedPoint` and `sourcePoint` with what doesn't depend on the point worked out once:
    /// the perspective correction and its inverse, the straighten angle's sine and cosine and the
    /// crop. A mask editor maps every brush point of a redraw through one; each point's arithmetic
    /// is the same, in the same order, as those functions do it.
    struct PointMapping: Sendable {
        private let w: Double, h: Double
        private let fw: Double, fh: Double
        /// Quarter turns clockwise, 0…3.
        private let quarterTurns: Int
        private let flipped: Bool
        private let perspective: Homography?
        private let inversePerspective: Homography?
        private let straightens: Bool
        /// cos and sin of the straighten angle, and of its negative for the way back.
        private let forwardCos: Double, forwardSin: Double
        private let backwardCos: Double, backwardSin: Double
        private let crop: DevelopCrop

        init(settings s: DevelopSettings, sourceSize: CGSize) {
            w = Double(sourceSize.width)
            h = Double(sourceSize.height)
            quarterTurns = ((s.rotation % 4) + 4) % 4
            let frame = rotatedSize(sourceSize, s.rotation)
            fw = Double(frame.width)
            fh = Double(frame.height)
            flipped = s.flipped
            let perspective = DevelopGeometry.perspective(s, frame: frame)
            self.perspective = perspective
            inversePerspective = perspective?.inverse
            straightens = s.straighten != 0
            let forward = s.straighten * .pi / 180, backward = -s.straighten * .pi / 180
            forwardCos = cos(forward)
            forwardSin = sin(forward)
            backwardCos = cos(backward)
            backwardSin = sin(backward)
            crop = effectiveCrop(s, frame: frame)
        }

        func finished(fromSource p: CGPoint) -> CGPoint {
            var x = Double(p.x) * w, y = Double(p.y) * h
            switch quarterTurns {
            case 1: (x, y) = (h - y, x)
            case 2: (x, y) = (w - x, h - y)
            case 3: (x, y) = (y, w - x)
            default: break
            }
            if flipped { x = fw - x }
            if let perspective, let p = perspective.apply(CGPoint(x: x, y: y)) {
                (x, y) = (Double(p.x), Double(p.y))
            }
            if straightens {
                // y points down, so this matrix turns clockwise for a positive angle
                let dx = x - fw / 2, dy = y - fh / 2
                (x, y) = (fw / 2 + dx * forwardCos - dy * forwardSin, fh / 2 + dx * forwardSin + dy * forwardCos)
            }
            return CGPoint(x: (x / fw - crop.x) / crop.width, y: (y / fh - crop.y) / crop.height)
        }

        func source(fromFinished p: CGPoint) -> CGPoint {
            var x = (crop.x + Double(p.x) * crop.width) * fw, y = (crop.y + Double(p.y) * crop.height) * fh
            if straightens {
                let dx = x - fw / 2, dy = y - fh / 2
                (x, y) = (fw / 2 + dx * backwardCos - dy * backwardSin, fh / 2 + dx * backwardSin + dy * backwardCos)
            }
            if let inversePerspective, let p = inversePerspective.apply(CGPoint(x: x, y: y)) {
                (x, y) = (Double(p.x), Double(p.y))
            }
            if flipped { x = fw - x }
            switch quarterTurns {
            case 1: (x, y) = (y, h - x)
            case 2: (x, y) = (w - x, h - y)
            case 3: (x, y) = (w - y, x)
            default: break
            }
            return CGPoint(x: x / max(w, 1e-9), y: y / max(h, 1e-9))
        }
    }
}
