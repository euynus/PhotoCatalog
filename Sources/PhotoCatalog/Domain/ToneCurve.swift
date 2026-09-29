// ============================================================
//  Tone curve — Lightroom's point curve, composite and per channel
// ============================================================
import Foundation

/// A point on a curve: input and output, 0…1 in display-encoded values.
struct CurvePoint: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
}

/// Point curves for the composite (RGB) and each channel. An empty list is a straight line.
/// Each channel's curve applies after the composite, as in Lightroom.
struct ToneCurve: Codable, Hashable, Sendable {
    enum Channel: String, CaseIterable, Codable, Identifiable, Sendable {
        case rgb, red, green, blue
        var id: Self { self }
        var title: String {
            switch self {
            case .rgb: "RGB"
            case .red: L("红")
            case .green: L("绿")
            case .blue: L("蓝")
            }
        }
    }

    var rgb: [CurvePoint] = []
    var red: [CurvePoint] = []
    var green: [CurvePoint] = []
    var blue: [CurvePoint] = []

    static let linear = ToneCurve()
    static let identity = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]

    /// Smallest horizontal gap kept between neighboring points.
    static let minimumGap = 0.01

    var isLinear: Bool { Channel.allCases.allSatisfy { Self.isStraight(points(for: $0)) } }

    func points(for channel: Channel) -> [CurvePoint] {
        switch channel {
        case .rgb: rgb
        case .red: red
        case .green: green
        case .blue: blue
        }
    }

    /// The channel's points with the ends filled in, for editing and drawing.
    func editablePoints(for channel: Channel) -> [CurvePoint] {
        let points = self.points(for: channel)
        return points.count >= 2 ? points : Self.identity
    }

    mutating func setPoints(_ points: [CurvePoint], for channel: Channel) {
        // a straight line is stored as nothing, so an untouched curve stays out of the fingerprint
        let stored = Self.isStraight(points) ? [] : Self.normalized(points)
        switch channel {
        case .rgb: rgb = stored
        case .red: red = stored
        case .green: green = stored
        case .blue: blue = stored
        }
    }

    /// Output for `x` through the composite, then the channel's own curve.
    func value(_ x: Double, channel: Channel) -> Double {
        let composite = Self.evaluate(rgb, at: x)
        return channel == .rgb ? composite : Self.evaluate(points(for: channel), at: composite)
    }

    /// Short text for render fingerprints.
    var fingerprintText: String {
        Channel.allCases.map { channel in
            points(for: channel).map { String(format: "%.3f:%.3f", $0.x, $0.y) }.joined(separator: ";")
        }.joined(separator: "/")
    }

    // ---- presets ----
    static let mediumContrast: [CurvePoint] = [
        CurvePoint(x: 0, y: 0), CurvePoint(x: 0.25, y: 0.21), CurvePoint(x: 0.5, y: 0.5),
        CurvePoint(x: 0.75, y: 0.79), CurvePoint(x: 1, y: 1),
    ]
    static let strongContrast: [CurvePoint] = [
        CurvePoint(x: 0, y: 0), CurvePoint(x: 0.25, y: 0.16), CurvePoint(x: 0.5, y: 0.5),
        CurvePoint(x: 0.75, y: 0.84), CurvePoint(x: 1, y: 1),
    ]

    // ---- math ----
    static func isStraight(_ points: [CurvePoint]) -> Bool {
        points.count < 2 || points.allSatisfy { abs($0.x - $0.y) < 1e-6 }
    }

    /// Sorted by input, inside the unit square, at least `minimumGap` apart.
    static func normalized(_ points: [CurvePoint]) -> [CurvePoint] {
        var result: [CurvePoint] = []
        for point in points.sorted(by: { $0.x < $1.x }) {
            let clamped = CurvePoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)))
            if let last = result.last, clamped.x - last.x < minimumGap { continue }
            result.append(clamped)
        }
        return result
    }

    /// Monotone cubic interpolation (Fritsch–Carlson) through the points: smooth like
    /// Lightroom's curve, without overshooting between points. Flat beyond the end points.
    static func evaluate(_ points: [CurvePoint], at x: Double) -> Double {
        guard points.count >= 2 else { return min(1, max(0, x)) }
        let p = points
        if x <= p[0].x { return p[0].y }
        if x >= p[p.count - 1].x { return p[p.count - 1].y }
        let n = p.count
        var secants = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) { secants[i] = (p[i + 1].y - p[i].y) / max(p[i + 1].x - p[i].x, 1e-9) }
        var tangents = [Double](repeating: 0, count: n)
        tangents[0] = secants[0]
        tangents[n - 1] = secants[n - 2]
        for i in 1..<(n - 1) {
            tangents[i] = secants[i - 1] * secants[i] <= 0 ? 0 : (secants[i - 1] + secants[i]) / 2
        }
        for i in 0..<(n - 1) where secants[i] == 0 {
            tangents[i] = 0
            tangents[i + 1] = 0
        }
        for i in 0..<(n - 1) where secants[i] != 0 {
            let a = tangents[i] / secants[i], b = tangents[i + 1] / secants[i]
            let s = a * a + b * b
            if s > 9 {
                let t = 3 / s.squareRoot()
                tangents[i] = t * a * secants[i]
                tangents[i + 1] = t * b * secants[i]
            }
        }
        let i = (0..<(n - 1)).last { p[$0].x <= x } ?? 0
        let h = p[i + 1].x - p[i].x
        let t = (x - p[i].x) / h
        let t2 = t * t, t3 = t2 * t
        let value = (2 * t3 - 3 * t2 + 1) * p[i].y + (t3 - 2 * t2 + t) * h * tangents[i]
            + (-2 * t3 + 3 * t2) * p[i + 1].y + (t3 - t2) * h * tangents[i + 1]
        return min(1, max(0, value))
    }
}
