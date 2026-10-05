// ============================================================
//  Upright — Lightroom's automatic perspective correction
// ============================================================
import Foundation
import CoreGraphics

/// Finds the photo's straight lines, where its near-vertical ones meet (and its near-horizontal
/// ones, for Auto), and the Transform and straighten settings that make the verticals parallel
/// and plumb: the camera turned back to level.
enum Upright {
    enum Mode: Sendable {
        /// Verticals upright; a facade's horizontals turned most of the way to parallel, where
        /// the photo clearly shows one.
        case auto
        /// Verticals upright only.
        case vertical
    }

    struct Correction: Equatable, Sendable {
        var vertical: Double
        var horizontal: Double
        var straighten: Double
    }

    /// A straight line found in the photo: x = c + (y - height/2)·t for near-vertical lines,
    /// y = c + (x - width/2)·t for near-horizontal ones.
    struct Line: Equatable {
        let c: Double
        let t: Double
        let votes: Double
    }

    /// Lines no more than this far from vertical (or horizontal) count.
    private static let maxTilt = 30.0

    /// The correction for a photo given as luma (0…1, row-major, top row first), or nil when
    /// it shows too few vertical lines to tell.
    static func correction(luma: [Float], width: Int, height: Int, mode: Mode) -> Correction? {
        guard width > 16, height > 16, luma.count == width * height else { return nil }
        let (vertical, horizontal) = lines(luma: luma, width: width, height: height)
        let w = Double(width), h = Double(height)
        let f = DevelopGeometry.perspectiveFocal * hypot(w, h) / 2
        guard let verticals = consensus(vertical, along: h), verticals.inliers.count >= 2 else { return nil }

        // where the verticals meet, relative to the center (nil: parallel, or too little spread
        // between them to tell a meeting point from measuring error)
        let meeting = verticals.spread >= 1.5
            ? verticals.point.map { (x: Double($0.x) - w / 2, y: Double($0.y) - h / 2) } : nil
        var pitch = 0.0
        if let meeting, abs(meeting.y) < 60 * f {
            pitch = atan(-f / meeting.y)
        }
        var yaw = 0.0
        // horizontals only when a facade's clearly meet: many lines, spread over the photo, far to
        // one side — a few stray ones (a shoulder, a door) would turn the photo sideways
        if mode == .auto, let horizontals = consensus(horizontal, along: w), horizontals.inliers.count >= 4,
           horizontals.share >= 0.5, horizontals.spread >= 3, horizontals.extent >= 0.3 * h,
           let point = horizontals.point,
           case let side = (x: Double(point.y) - w / 2, y: Double(point.x) - h / 2),
           abs(side.x) >= 1.5 * w, abs(side.x) < 20 * f {
            // after the pitch, the horizontals' meeting point sent to infinity by a turn sideways —
            // most of the way, as Lightroom's balanced Auto does: a meeting point far to the side
            // is only roughly measured, and turning too far distorts more than it straightens
            let a = side.x, c = sin(pitch) * side.y + cos(pitch) * f
            yaw = atan(c / a) * 0.7
            if abs(yaw) > DevelopGeometry.maxPerspectiveAngle * .pi / 180 * 0.9 { yaw = 0 }   // no clear facade
        }
        let limit = DevelopGeometry.maxPerspectiveAngle * .pi / 180
        pitch = min(limit, max(-limit, pitch))
        yaw = min(limit, max(-limit, yaw))

        // the verticals' direction once turned: the straighten angle sets it plumb
        let direction: (x: Double, y: Double)
        if let meeting {
            let turned = rotate((meeting.x, meeting.y, f), pitch: pitch, yaw: yaw)
            let center = rotate((0, 0, f), pitch: pitch, yaw: yaw)
            let c = (x: f * center.0 / center.2, y: f * center.1 / center.2)
            if abs(turned.2) < 1e-9 * f {
                direction = (turned.0, turned.1)
            } else {
                let v = (x: f * turned.0 / turned.2, y: f * turned.1 / turned.2)
                direction = turned.2 > 0 ? (v.x - c.x, v.y - c.y) : (c.x - v.x, c.y - v.y)
            }
        } else {
            // parallel: their common lean, as the weighted median so a stray line doesn't sway it
            let sorted = verticals.inliers.sorted { $0.t < $1.t }
            let half = sorted.reduce(0) { $0 + $1.votes } / 2
            var running = 0.0
            let slope = sorted.first { running += $0.votes; return running >= half }?.t ?? 0
            direction = (slope, 1)
        }
        let up: (x: Double, y: Double) = direction.y < 0 ? direction : (-direction.x, -direction.y)
        let lean = atan2(up.x, -up.y) * 180 / .pi
        let straighten = min(DevelopGeometry.maxStraighten, max(-DevelopGeometry.maxStraighten, -lean))

        let scale = 100 / DevelopGeometry.maxPerspectiveAngle * 180 / .pi
        return Correction(vertical: (-pitch * scale).rounded(), horizontal: (yaw * scale).rounded(),
                          straighten: (straighten * 10).rounded() / 10)
    }

    private static func rotate(_ p: (Double, Double, Double), pitch: Double, yaw: Double) -> (Double, Double, Double) {
        let (x, y, z) = p
        let y1 = cos(pitch) * y - sin(pitch) * z, z1 = sin(pitch) * y + cos(pitch) * z
        return (cos(yaw) * x + sin(yaw) * z1, y1, -sin(yaw) * x + cos(yaw) * z1)
    }

    /// How far a line may point from a meeting point and still agree with it.
    private static let agreement = 1.2 * Double.pi / 180

    /// The meeting point most of the lines' length agrees on (RANSAC over pairs, then least
    /// squares), in the lines' own axes (x across, y along): nil when they agree on being
    /// parallel. With the lines that agree, their share of all the length, how far apart their
    /// angles are (degrees) and how far apart they cross the middle (pixels).
    static func consensus(_ lines: [Line], along: Double)
        -> (point: CGPoint?, inliers: [Line], share: Double, spread: Double, extent: Double)? {
        let candidates = Array(lines.sorted { $0.votes > $1.votes }.prefix(40))
        guard candidates.count >= 2 else { return nil }
        func agrees(_ line: Line, x: Double, u: Double) -> Bool {
            abs(remainder(atan2(x - line.c, u) - atan(line.t), .pi)) < agreement
        }
        func agreesParallel(_ line: Line, _ t: Double) -> Bool { abs(atan(line.t) - atan(t)) < agreement }
        var parallel: (score: Double, t: Double) = (0, 0)
        var meeting: (score: Double, x: Double, u: Double)?
        for i in candidates.indices {
            // parallel to this line
            let t = candidates[i].t
            let parallelScore = candidates.filter { agreesParallel($0, t) }.reduce(0) { $0 + $1.votes }
            if parallelScore > parallel.score { parallel = (parallelScore, t) }
            for j in candidates.indices where j > i {
                let a = candidates[i], b = candidates[j]
                guard abs(a.t - b.t) > 1e-6 else { continue }
                let u = (b.c - a.c) / (a.t - b.t), x = a.c + u * a.t
                // lines of a building meet well outside the photo; two stray lines cross anywhere
                guard abs(u) >= 0.75 * along, abs(u) < 200 * along else { continue }
                let score = candidates.filter { agrees($0, x: x, u: u) }.reduce(0) { $0 + $1.votes }
                if score > (meeting?.score ?? 0) { meeting = (score, x, u) }
            }
        }
        // meeting has to explain clearly more of the lines than their being parallel does
        let best: (point: (x: Double, u: Double)?, parallel: Double?) = if let meeting, meeting.score > 1.1 * parallel.score {
            ((meeting.x, meeting.u), nil)
        } else {
            (nil, parallel.score > 0 ? parallel.t : nil)
        }
        let total = lines.reduce(0) { $0 + $1.votes }
        var inliers: [Line]
        var point: CGPoint?
        if let t = best.parallel {
            inliers = lines.filter { agreesParallel($0, t) }
        } else if let found = best.point {
            inliers = lines.filter { agrees($0, x: found.x, u: found.u) }
            // least squares over the lines that agree: residual c + u·t - x, long ones counting
            // more (a segment's angle is only as precise as it is long)
            var stt = 0.0, st = 0.0, s1 = 0.0, sct = 0.0, sc = 0.0
            for line in inliers {
                let w = line.votes * line.votes
                stt += w * line.t * line.t; st += w * line.t; s1 += w; sct += w * line.c * line.t; sc += w * line.c
            }
            let det = stt * s1 - st * st
            if det > 1e-9 * max(s1 * s1, 1) {
                let u = (-sct * s1 + st * sc) / det, x = (stt * sc - st * sct) / det
                point = CGPoint(x: x, y: u + along / 2)
            } else {
                point = CGPoint(x: found.x, y: found.u + along / 2)
            }
        } else {
            return nil
        }
        guard !inliers.isEmpty else { return nil }
        let angles = inliers.map { atan($0.t) * 180 / .pi }, crossings = inliers.map(\.c)
        return (point, inliers, inliers.reduce(0) { $0 + $1.votes } / max(total, 1e-9),
                (angles.max() ?? 0) - (angles.min() ?? 0), (crossings.max() ?? 0) - (crossings.min() ?? 0))
    }

    // ---- lines: straight segments, found as runs of pixels whose edges line up ----
    /// A straight edge: its center, unit direction and length, in pixels.
    struct Segment: Equatable {
        let x: Double, y: Double
        let dx: Double, dy: Double
        let length: Double
    }

    /// Near-vertical and near-horizontal straight lines, each weighted by its segment's length.
    static func lines(luma: [Float], width: Int, height: Int) -> (vertical: [Line], horizontal: [Line]) {
        let maxTangent = tan(maxTilt * .pi / 180)
        var vertical: [Line] = [], horizontal: [Line] = []
        for segment in segments(luma: luma, width: width, height: height) {
            if abs(segment.dy) > 1e-9, abs(segment.dx / segment.dy) <= maxTangent {
                let t = segment.dx / segment.dy
                vertical.append(Line(c: segment.x - (segment.y - Double(height) / 2) * t, t: t, votes: segment.length))
            } else if abs(segment.dx) > 1e-9, abs(segment.dy / segment.dx) <= maxTangent {
                let t = segment.dy / segment.dx
                horizontal.append(Line(c: segment.y - (segment.x - Double(width) / 2) * t, t: t, votes: segment.length))
            }
        }
        return (vertical, horizontal)
    }

    /// Straight segments, after the Line Segment Detector's idea: neighboring pixels whose
    /// edges run the same way grow into a region; long, thin regions are lines. Texture makes
    /// short, ragged regions and is left out.
    static func segments(luma input: [Float], width: Int, height: Int) -> [Segment] {
        // a light 3×3 blur first: jagged or noisy edges would scatter the directions
        var luma = input
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                var sum: Float = 0
                for dy in -1...1 { for dx in -1...1 { sum += input[(y + dy) * width + x + dx] } }
                luma[y * width + x] = sum / 9
            }
        }
        let count = width * height
        var magnitude = [Float](repeating: 0, count: count), angle = magnitude
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let a = luma[i - width - 1], b = luma[i - width], c = luma[i - width + 1]
                let d = luma[i - 1], e = luma[i + 1]
                let f = luma[i + width - 1], g = luma[i + width], h = luma[i + width + 1]
                let gx = (c + 2 * e + h) - (a + 2 * d + f)
                let gy = (f + 2 * g + h) - (a + 2 * b + c)
                magnitude[i] = (gx * gx + gy * gy).squareRoot()
                angle[i] = atan2(gx, -gy)   // along the edge, across the gradient
            }
        }
        var strong = (0..<count).filter { magnitude[$0] >= 0.12 }
        strong.sort { magnitude[$0] > magnitude[$1] }
        var used = [Bool](repeating: false, count: count)
        let tolerance: Float = 22.5 * .pi / 180
        let minimumLength = 0.04 * hypot(Double(width), Double(height))
        var found: [Segment] = []
        var region: [Int] = []
        for seed in strong where !used[seed] {
            region.removeAll(keepingCapacity: true)
            region.append(seed)
            used[seed] = true
            var sumCos = cos(angle[seed]), sumSin = sin(angle[seed])
            var next = 0
            while next < region.count {
                let i = region[next]; next += 1
                let x = i % width, y = i / width
                let regionAngle = atan2(sumSin, sumCos)
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx, ny = y + dy
                        guard nx > 0, ny > 0, nx < width - 1, ny < height - 1 else { continue }
                        let j = ny * width + nx
                        guard !used[j], magnitude[j] >= 0.12 else { continue }
                        let difference = abs(remainder(angle[j] - regionAngle, 2 * .pi))
                        guard difference < tolerance else { continue }
                        used[j] = true
                        region.append(j)
                        sumCos += cos(angle[j]); sumSin += sin(angle[j])
                    }
                }
            }
            guard region.count >= 12 else { continue }
            // the region's axis from its weighted second moments
            var total = 0.0, mx = 0.0, my = 0.0
            for i in region {
                let w = Double(magnitude[i])
                total += w; mx += w * Double(i % width); my += w * Double(i / width)
            }
            mx /= total; my /= total
            var sxx = 0.0, syy = 0.0, sxy = 0.0
            for i in region {
                let w = Double(magnitude[i]), dx = Double(i % width) - mx, dy = Double(i / width) - my
                sxx += w * dx * dx; syy += w * dy * dy; sxy += w * dx * dy
            }
            let theta = 0.5 * atan2(2 * sxy, sxx - syy)
            let ux = cos(theta), uy = sin(theta)
            var low = Double.infinity, high = -Double.infinity, near = Double.infinity, far = -Double.infinity
            for i in region {
                let dx = Double(i % width) - mx, dy = Double(i / width) - my
                let along = dx * ux + dy * uy, across = -dx * uy + dy * ux
                low = min(low, along); high = max(high, along); near = min(near, across); far = max(far, across)
            }
            let length = high - low, thickness = max(1, far - near)
            guard length >= minimumLength, length >= 6 * thickness else { continue }
            found.append(Segment(x: mx + ux * (low + high) / 2, y: my + uy * (low + high) / 2,
                                 dx: uy < 0 ? -ux : ux, dy: abs(uy), length: length))
        }
        return found
    }
}
