// ============================================================
//  Chromatic aberration — lateral color fringes measured and undone
// ============================================================
import CoreImage
import Foundation

/// Lateral chromatic aberration: a lens bends red and blue light a little more or less than
/// green, so each is magnified slightly differently and edges toward the corners grow colored
/// fringes on opposite sides. It is measured per photo on its achromatic edges — where the three
/// channels should line up exactly — and undone by rescaling red and blue about the middle
/// (`DevelopKernels.lateralChromaticAberration`).
enum ChromaticAberration {
    /// Where one channel is sampled, relative to green: 1 + k1 + k2·ρ² times as far from the
    /// middle at radius ρ (the corner is ρ = 1). The same at any render size.
    struct Scale: Equatable, Sendable {
        var k1: Double
        var k2: Double

        static let none = Scale(k1: 0, k2: 0)

        var isNone: Bool { abs(k1) < 1e-6 && abs(k2) < 1e-6 }
    }

    struct Correction: Equatable, Sendable {
        var red: Scale
        var blue: Scale

        static let none = Correction(red: .none, blue: .none)
    }

    /// The long edge photos are measured at: a fringe of a pixel or two in the full photo stays
    /// measurable, and measuring takes a fraction of a second.
    static let analysisPixel = 3000

    private static let lock = NSLock()
    nonisolated(unsafe) private static var measured: [String: Correction] = [:]

    /// The correction for the photo at `url`, measured once per version of the file (a decode
    /// and a fraction of a second the first time).
    static func correction(url: URL, isRaw: Bool) -> Correction {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = "\(url.path)|\(modified?.timeIntervalSinceReferenceDate ?? 0)"
        if let known = lock.withLock({ measured[key] }) { return known }
        let correction = DevelopRenderer.Source(url: url, isRaw: isRaw, maxPixel: analysisPixel)?
            .image(.neutral).map(measure) ?? .none
        lock.withLock { measured[key] = correction }
        return correction
    }

    /// The correction `image` needs; none when it shows too few achromatic edges to tell, or
    /// lining the channels up doesn't bring them closer.
    static func measure(_ image: CIImage) -> Correction {
        let rect = image.extent.integral
        let width = Int(rect.width), height = Int(rect.height)
        guard width >= 64, height >= 64 else { return .none }
        var pixels = [Float](repeating: 0, count: width * height * 4)
        DevelopRenderer.context.render(image, toBitmap: &pixels, rowBytes: width * 16, bounds: rect,
                                       format: .RGBAf, colorSpace: DevelopRenderer.outputColorSpace)
        let planes = Planes(pixels, width: width, height: height)
        return Correction(red: planes.scale(of: 0), blue: planes.scale(of: 2))
    }

    /// The photo's channels as logs of display-encoded values, where an achromatic edge has the
    /// same shape in all three whatever the light's color, and their detail (the log minus its
    /// local mean), where the color of surfaces drops out.
    private struct Planes {
        let width: Int, height: Int
        var smooth: [[Float]] = []
        var detail: [[Float]] = []
        var usable: [Bool]

        init(_ pixels: [Float], width: Int, height: Int) {
            self.width = width
            self.height = height
            let count = width * height
            usable = (0..<count).map { i in
                // neither lost in the dark, where noise rules, nor clipped
                (0..<3).allSatisfy { pixels[i * 4 + $0] > 0.02 && pixels[i * 4 + $0] < 0.98 }
            }
            for channel in 0..<3 {
                let logs = (0..<count).map { log(max(pixels[$0 * 4 + channel], 0) + 0.01) }
                let mean = Planes.boxBlur(logs, width: width, height: height, radius: 4)
                detail.append(zip(logs, mean).map { $0 - $1 })
                smooth.append(Planes.boxBlur(logs, width: width, height: height, radius: 3))
            }
        }

        /// How `channel` is scaled against green: Gauss–Newton on its detail, resampled at the
        /// trial scale, against green's, over the edges both show alike.
        func scale(of channel: Int) -> Scale {
            let center = (x: Double(width - 1) / 2, y: Double(height - 1) / 2)
            let radius2 = Double(width * width + height * height) / 4
            // achromatic edges: strong, and pointing the same way with about the same strength
            // in this channel as in green — judged on logs smoothed wider than any fringe, so
            // the shift being measured doesn't decide which edges count
            var edges: [(index: Int, v: (x: Double, y: Double), rho2: Double)] = []
            let green = smooth[1], other = smooth[channel]
            for y in 1..<(height - 1) {
                for x in 1..<(width - 1) {
                    let i = y * width + x
                    guard usable[i] else { continue }
                    let gx = green[i + 1] - green[i - 1], gy = green[i + width] - green[i - width]
                    let strength = gx * gx + gy * gy
                    guard strength > 0.004 else { continue }
                    let cx = other[i + 1] - other[i - 1], cy = other[i + width] - other[i - width]
                    let ratio = (cx * cx + cy * cy) / strength
                    guard ratio > 0.45, ratio < 2.2, cx * gx + cy * gy > 0.9 * (strength * ratio).squareRoot() * strength.squareRoot()
                    else { continue }
                    let v = (x: Double(x) - center.x, y: Double(y) - center.y)
                    edges.append((i, v, (v.x * v.x + v.y * v.y) / radius2))
                }
            }
            guard edges.count >= 200 else { return .none }
            if edges.count > 300_000 {
                let stride = edges.count / 300_000 + 1
                edges = edges.enumerated().compactMap { $0.offset % stride == 0 ? $0.element : nil }
            }

            let target = detail[1], source = detail[channel]
            func sample(_ x: Double, _ y: Double) -> Double {
                let fx = min(max(x, 0), Double(width - 1)), fy = min(max(y, 0), Double(height - 1))
                let x0 = min(Int(fx), width - 2), y0 = min(Int(fy), height - 2)
                let tx = fx - Double(x0), ty = fy - Double(y0), i = y0 * width + x0
                let top = Double(source[i]) * (1 - tx) + Double(source[i + 1]) * tx
                let bottom = Double(source[i + width]) * (1 - tx) + Double(source[i + width + 1]) * tx
                return top * (1 - ty) + bottom * ty
            }
            /// How far green's detail is from the channel's at `scale`, with the best gain.
            func cost(_ k1: Double, _ k2: Double) -> Double {
                var ww = 0.0, wt = 0.0, tt = 0.0
                for edge in edges {
                    let s = 1 + k1 + k2 * edge.rho2
                    let w = sample(center.x + edge.v.x * s, center.y + edge.v.y * s), t = Double(target[edge.index])
                    ww += w * w; wt += w * t; tt += t * t
                }
                return ww > 0 ? tt - wt * wt / ww : tt
            }

            /// Gauss–Newton from `start`: target ≈ a·W + a·Δk1·J (+ a·Δk2·J·ρ² with the corner
            /// term), where W is the channel sampled at the current scale and J how it changes as
            /// the scale grows.
            func fit(from start: Scale, corner: Bool) -> Scale {
                var k1 = start.k1, k2 = start.k2
                for _ in 0..<8 {
                    var a = [[Double]](repeating: [0, 0, 0], count: 3), b = [0.0, 0.0, 0.0]
                    for edge in edges {
                        let s = 1 + k1 + k2 * edge.rho2
                        let x = center.x + edge.v.x * s, y = center.y + edge.v.y * s
                        let w = sample(x, y)
                        let dx = (sample(x + 1, y) - sample(x - 1, y)) / 2, dy = (sample(x, y + 1) - sample(x, y - 1)) / 2
                        let j = dx * edge.v.x + dy * edge.v.y
                        let f = [w, j, j * edge.rho2], t = Double(target[edge.index])
                        for r in 0..<3 {
                            b[r] += f[r] * t
                            for c in 0..<3 { a[r][c] += f[r] * f[c] }
                        }
                    }
                    if !corner { a[0][2] = 0; a[1][2] = 0; a[2][0] = 0; a[2][1] = 0; a[2][2] = 1; b[2] = 0 }
                    guard let x = Planes.solve(a, b), x[0] > 0.2 else { break }
                    let d1 = x[1] / x[0], d2 = x[2] / x[0]
                    k1 += d1
                    k2 += d2
                    if abs(d1) + abs(d2) < 1e-6 { break }
                }
                return Scale(k1: k1, k2: k2)
            }
            // a plain magnification first; the corner term only when it clearly fits better,
            // since with few edges far out it mostly fits noise
            let plain = fit(from: .none, corner: false)
            let curved = fit(from: plain, corner: true)
            let plainCost = cost(plain.k1, plain.k2)
            let best = cost(curved.k1, curved.k2) < 0.97 * plainCost ? curved : plain
            // implausible for a lens, or no better than leaving the channel alone
            guard abs(best.k1) < 0.01, abs(best.k1 + best.k2) < 0.01, cost(best.k1, best.k2) < 0.99 * cost(0, 0) else {
                return .none
            }
            return best
        }

        /// The 3×3 system `a`·x = `b` by Cramer's rule; nil when singular.
        static func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
            func det(_ m: [[Double]]) -> Double {
                m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
                    + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
            }
            let d = det(a)
            guard abs(d) > 1e-30 else { return nil }
            return (0..<3).map { column in
                var m = a
                for row in 0..<3 { m[row][column] = b[row] }
                return det(m) / d
            }
        }

        /// A box blur of `radius` pixels each way, edges repeated.
        static func boxBlur(_ values: [Float], width: Int, height: Int, radius: Int) -> [Float] {
            var rows = [Float](repeating: 0, count: values.count)
            let span = Float(2 * radius + 1)
            for y in 0..<height {
                let row = y * width
                var sum: Float = 0
                for dx in -radius...radius { sum += values[row + min(max(dx, 0), width - 1)] }
                for x in 0..<width {
                    rows[row + x] = sum / span
                    sum += values[row + min(x + radius + 1, width - 1)] - values[row + max(x - radius, 0)]
                }
            }
            var result = [Float](repeating: 0, count: values.count)
            for x in 0..<width {
                var sum: Float = 0
                for dy in -radius...radius { sum += rows[min(max(dy, 0), height - 1) * width + x] }
                for y in 0..<height {
                    result[y * width + x] = sum / span
                    sum += rows[min(y + radius + 1, height - 1) * width + x] - rows[max(y - radius, 0) * width + x]
                }
            }
            return result
        }
    }
}
