// ============================================================
//  SpotFinder — where a healed spot takes its replacement from
// ============================================================
import CoreGraphics
import Foundation

/// Looks around a spot for the place to copy from, as Lightroom does when you click: the
/// nearby circle whose surroundings best match the spot's own, with a clean inside (not
/// another speck or an edge). Works on the photo as shot at 1024 px.
enum SpotFinder {
    /// A source for a spot at `target` with `radius` (fractions of the source photo and of its
    /// long edge), or nil when the photo can't be read.
    static func source(for target: CGPoint, radius: Double, url: URL, isRaw: Bool) -> CGPoint? {
        guard let image = SemanticMasks.canonical(url: url, isRaw: isRaw), let pixels = SemanticMasks.rgba(image)
        else { return nil }
        let width = image.width, height = image.height
        var luma = [Double](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            luma[i] = (0.2126 * Double(pixels[i * 4]) + 0.7152 * Double(pixels[i * 4 + 1])
                       + 0.0722 * Double(pixels[i * 4 + 2])) / 255
        }
        return source(for: target, radius: radius, luma: luma, width: width, height: height)
    }

    /// The search on a luma image (0…1, row-major, top row first).
    static func source(for target: CGPoint, radius: Double, luma: [Double], width: Int, height: Int) -> CGPoint {
        let longEdge = Double(max(width, height))
        let r = max(2, radius * longEdge)
        let t = CGPoint(x: Double(target.x) * Double(width), y: Double(target.y) * Double(height))
        func value(_ x: Double, _ y: Double) -> Double {
            let xi = min(width - 1, max(0, Int(x))), yi = min(height - 1, max(0, Int(y)))
            return luma[yi * width + xi]
        }
        // the ring just outside a circle, and points inside it
        var ring: [(Double, Double)] = [], inside: [(Double, Double)] = [(0, 0)]
        for k in 0..<24 {
            let a = Double(k) / 24 * 2 * .pi
            for scale in [1.3, 1.7] { ring.append((cos(a) * r * scale, sin(a) * r * scale)) }
            if k.isMultiple(of: 2) { inside.append((cos(a) * r * 0.55, sin(a) * r * 0.55)) }
        }
        let targetRing = ring.map { value(Double(t.x) + $0.0, Double(t.y) + $0.1) }
        let ringMean = targetRing.reduce(0, +) / Double(targetRing.count)
        let margin = r * 1.8
        var best: (score: Double, point: CGPoint)?
        for distance in [2.2, 3.0, 4.0] {
            for k in 0..<24 {
                let a = Double(k) / 24 * 2 * .pi
                let cx = Double(t.x) + cos(a) * r * distance, cy = Double(t.y) + sin(a) * r * distance
                guard cx >= margin, cy >= margin, cx <= Double(width) - margin, cy <= Double(height) - margin else { continue }
                var score = 0.0
                for (index, offset) in ring.enumerated() {
                    let d = value(cx + offset.0, cy + offset.1) - targetRing[index]
                    score += d * d
                }
                score /= Double(ring.count)
                var clean = 0.0
                for offset in inside {
                    let d = value(cx + offset.0, cy + offset.1) - ringMean
                    clean += d * d
                }
                score += 0.5 * clean / Double(inside.count)
                score *= 1 + 0.05 * (distance - 2.2)   // nearer wins a tie
                if best == nil || score < best!.score {
                    best = (score, CGPoint(x: cx / Double(width), y: cy / Double(height)))
                }
            }
        }
        // a spot too big to have room around it takes from beside it, on whichever side has room
        if let best { return best.point }
        let dx = r * 2.5 / Double(width)
        let x = Double(target.x) + dx <= 1 ? Double(target.x) + dx : max(0, Double(target.x) - dx)
        return CGPoint(x: x, y: Double(target.y))
    }
}
