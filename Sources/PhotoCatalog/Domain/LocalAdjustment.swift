// ============================================================
//  Local adjustments — Lightroom's masks: gradients, brush, subject and sky
// ============================================================
import Foundation
import CoreGraphics

/// Adjustments applied through a mask, on top of the photo's global settings. Positions are
/// fractions of the source photo (top-left origin, before quarter turns, mirroring, straighten
/// and crop), so a mask stays on the same part of the picture when the framing changes.
struct LocalAdjustment: Codable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case linear, radial, brush, subject, sky, colorRange, luminanceRange

        /// Masks drawn on the photo, masks found in it, and masks of a range of its colors or tones.
        static let drawn: [Kind] = [.linear, .radial, .brush]
        static let automatic: [Kind] = [.subject, .sky]
        static let ranges: [Kind] = [.colorRange, .luminanceRange]

        var isAutomatic: Bool { Self.automatic.contains(self) }
        /// The whole photo, narrowed to its range.
        var isRange: Bool { Self.ranges.contains(self) }

        var title: String {
            switch self {
            case .linear: L("线性渐变")
            case .radial: L("径向渐变")
            case .brush: L("画笔")
            case .subject: L("主体")
            case .sky: L("天空")
            case .colorRange: L("颜色范围")
            case .luminanceRange: L("明亮度范围")
            }
        }

        var symbol: String {
            switch self {
            case .linear: "rectangle.tophalf.inset.filled"
            case .radial: "circle.dashed"
            case .brush: "paintbrush.pointed"
            case .subject: "person.and.background.dotted"
            case .sky: "cloud.sun"
            case .colorRange: "eyedropper.halffull"
            case .luminanceRange: "circle.lefthalf.striped.horizontal"
            }
        }
    }

    var id = UUID().uuidString
    var kind: Kind
    /// Linear: full effect at `start`, none at `end`, a smooth fall-off between.
    var start = CGPoint(x: 0.5, y: 0.1)
    var end = CGPoint(x: 0.5, y: 0.45)
    /// Radial: an ellipse around `center` (for a subject or sky, the center of what was found,
    /// where its pin sits); radii are fractions of the source's long edge and
    /// `angle` turns the ellipse's first axis clockwise, in degrees. Feather 0…100 is how much
    /// of the radius the effect fades over.
    var center = CGPoint(x: 0.5, y: 0.5)
    var radiusX = 0.25
    var radiusY = 0.18
    var angle = 0.0
    var feather = 50.0
    /// Brush: strokes painted, and erased, in order. On other masks, strokes that add to or
    /// erase from what the mask covers.
    var strokes: [BrushStroke] = []
    /// Applies outside the mask instead of inside it.
    var inverted = false
    /// Narrows the mask to a range of the photo's tones or colors; a range mask is only this.
    var range: MaskRange?

    // adjustments, -100…100 unless noted
    var exposure = 0.0      // EV, -4…4
    var contrast = 0.0
    var highlights = 0.0
    var shadows = 0.0
    var whites = 0.0
    var blacks = 0.0
    var temperature = 0.0   // relative warmth
    var tint = 0.0
    var texture = 0.0
    var clarity = 0.0
    var dehaze = 0.0
    var saturation = 0.0

    init(kind: Kind) {
        self.kind = kind
        switch kind {
        case .colorRange: range = MaskRange(kind: .color)
        case .luminanceRange: range = MaskRange(kind: .luminance)
        default: break
        }
    }

    /// Whether any adjustment is set; a mask without one changes nothing.
    var hasEffect: Bool {
        [exposure, contrast, highlights, shadows, whites, blacks, temperature, tint, texture, clarity, dehaze, saturation]
            .contains { $0 != 0 }
    }

    /// The same mask with every adjustment back at zero.
    var withoutAdjustments: LocalAdjustment {
        var copy = LocalAdjustment(kind: kind)
        copy.id = id
        copy.start = start; copy.end = end
        copy.center = center; copy.radiusX = radiusX; copy.radiusY = radiusY; copy.angle = angle
        copy.feather = feather; copy.strokes = strokes; copy.inverted = inverted; copy.range = range
        return copy
    }

    /// Global settings carrying this mask's tone and presence adjustments, for the renderer's
    /// shared tone code (white balance and exposure are applied separately).
    var toneSettings: DevelopSettings {
        var s = DevelopSettings()
        s.contrast = contrast; s.highlights = highlights; s.shadows = shadows
        s.whites = whites; s.blacks = blacks; s.saturation = saturation
        s.texture = texture; s.clarity = clarity; s.dehaze = dehaze
        return s
    }

    var fingerprintText: String {
        let geometry: [Double] = switch kind {
        case .linear: [start.x, start.y, end.x, end.y]
        case .radial: [center.x, center.y, radiusX, radiusY, angle, feather]
        case .brush: [Double(strokes.count), Double(BrushStroke.hash(strokes))]
        case .subject, .sky, .colorRange, .luminanceRange: []   // found in the photo itself
        }
        let values = [exposure, contrast, highlights, shadows, whites, blacks, temperature, tint,
                      texture, clarity, dehaze, saturation]
        let refinement = kind != .brush && !strokes.isEmpty ? ":s\(strokes.count),\(BrushStroke.hash(strokes))" : ""
        return kind.rawValue + (inverted ? "!" : "") + ":"
            + geometry.map { String(format: "%.4f", $0) }.joined(separator: ",") + ":"
            + values.map { String(format: "%.2f", $0) }.joined(separator: ",") + refinement
            + (range.map { ":" + $0.fingerprintText } ?? "")
    }
}

/// A range of the photo's tones or colors a mask is narrowed to (Lightroom's Luminance Range and
/// Color Range), judged on the photo as adjusted before its masks.
struct MaskRange: Codable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case luminance, color
    }

    var kind: Kind
    /// Luminance, 0…100: the tones fully in the range, and how far (0…100) it fades beyond them.
    var low = 50.0
    var high = 100.0
    var smoothness = 50.0
    /// Color: places sampled on the photo (source fractions, up to `maxSamples`) whose colors
    /// are in the range, and how widely around them it reaches, 0…100.
    var samples: [CGPoint] = []
    var amount = 50.0

    static let maxSamples = 5

    init(kind: Kind) { self.kind = kind }

    var fingerprintText: String {
        switch kind {
        case .luminance: String(format: "l%.1f,%.1f,%.1f", low, high, smoothness)
        case .color: String(format: "c%.1f;", amount) + samples.map { String(format: "%.4f,%.4f", $0.x, $0.y) }.joined(separator: ";")
        }
    }
}

extension MaskRange {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .luminance
        low = try c.decodeIfPresent(Double.self, forKey: .low) ?? 50
        high = try c.decodeIfPresent(Double.self, forKey: .high) ?? 100
        smoothness = try c.decodeIfPresent(Double.self, forKey: .smoothness) ?? 50
        samples = try c.decodeIfPresent([CGPoint].self, forKey: .samples) ?? []
        amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 50
    }
}

extension LocalAdjustment {
    /// Every field is optional in storage, so masks saved by an older version still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .radial
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        start = try c.decodeIfPresent(CGPoint.self, forKey: .start) ?? CGPoint(x: 0.5, y: 0.1)
        end = try c.decodeIfPresent(CGPoint.self, forKey: .end) ?? CGPoint(x: 0.5, y: 0.45)
        center = try c.decodeIfPresent(CGPoint.self, forKey: .center) ?? CGPoint(x: 0.5, y: 0.5)
        radiusX = try c.decodeIfPresent(Double.self, forKey: .radiusX) ?? 0.25
        radiusY = try c.decodeIfPresent(Double.self, forKey: .radiusY) ?? 0.18
        angle = try c.decodeIfPresent(Double.self, forKey: .angle) ?? 0
        feather = try c.decodeIfPresent(Double.self, forKey: .feather) ?? 50
        strokes = try c.decodeIfPresent([BrushStroke].self, forKey: .strokes) ?? []
        inverted = try c.decodeIfPresent(Bool.self, forKey: .inverted) ?? false
        range = try c.decodeIfPresent(MaskRange.self, forKey: .range)
        func value(_ key: CodingKeys) throws -> Double { try c.decodeIfPresent(Double.self, forKey: key) ?? 0 }
        exposure = try value(.exposure)
        contrast = try value(.contrast)
        highlights = try value(.highlights)
        shadows = try value(.shadows)
        whites = try value(.whites)
        blacks = try value(.blacks)
        temperature = try value(.temperature)
        tint = try value(.tint)
        texture = try value(.texture)
        clarity = try value(.clarity)
        dehaze = try value(.dehaze)
        saturation = try value(.saturation)
    }
}

/// The brush tool's settings, which each new stroke takes on.
struct BrushSettings: Equatable, Sendable {
    /// 1…100: a radius of up to a fifth of the photo's long edge.
    var size = 25.0
    var feather = 50.0
    var density = 100.0
    var erase = false

    /// Stroke radius as a fraction of the source's long edge.
    var radius: Double { size / 100 * 0.2 }
}

/// One brush stroke: a path of round dabs. Points are source-photo fractions, flattened
/// (x0, y0, x1, y1, …) and rounded to 1/10 000 so long strokes stay small in the catalog.
struct BrushStroke: Codable, Hashable, Sendable {
    var points: [Double] = []
    /// Dab radius as a fraction of the source's long edge.
    var radius = 0.05
    /// How much of the radius the dab fades over, 0…100.
    var feather = 50.0
    /// The strongest the stroke paints (or erases), 0…100.
    var density = 100.0
    var erase = false

    var pointCount: Int { points.count / 2 }

    func point(_ index: Int) -> CGPoint { CGPoint(x: points[index * 2], y: points[index * 2 + 1]) }

    mutating func append(_ point: CGPoint) {
        points.append((Double(point.x) * 10_000).rounded() / 10_000)
        points.append((Double(point.y) * 10_000).rounded() / 10_000)
    }

    /// A compact hash of every stroke, for fingerprints and the rasterized-mask cache.
    static func hash(_ strokes: [BrushStroke]) -> UInt32 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ value: Double) {
            var bits = value.bitPattern
            for _ in 0..<8 { hash = (hash ^ (bits & 0xff)) &* 0x100_0000_01b3; bits >>= 8 }
        }
        for stroke in strokes {
            stroke.points.forEach(mix)
            [stroke.radius, stroke.feather, stroke.density, stroke.erase ? 1 : 0].forEach(mix)
        }
        return UInt32(truncatingIfNeeded: hash ^ (hash >> 32))
    }
}

extension BrushStroke {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let points = try c.decodeIfPresent([Double].self, forKey: .points) ?? []
        self.points = points.count.isMultiple(of: 2) ? points : Array(points.dropLast())
        radius = try c.decodeIfPresent(Double.self, forKey: .radius) ?? 0.05
        feather = try c.decodeIfPresent(Double.self, forKey: .feather) ?? 50
        density = try c.decodeIfPresent(Double.self, forKey: .density) ?? 100
        erase = try c.decodeIfPresent(Bool.self, forKey: .erase) ?? false
    }
}

/// Converting between the source photo, where masks live, and the finished photo on screen.
/// Both in fractions with a top-left origin; `sourceSize` is the decoded photo's pixel size
/// before quarter turns (any scale — only its shape matters).
extension DevelopGeometry {
    static func finishedPoint(fromSource p: CGPoint, settings s: DevelopSettings, sourceSize: CGSize) -> CGPoint {
        let w = Double(sourceSize.width), h = Double(sourceSize.height)
        var x = Double(p.x) * w, y = Double(p.y) * h
        switch ((s.rotation % 4) + 4) % 4 {   // quarter turns clockwise
        case 1: (x, y) = (h - y, x)
        case 2: (x, y) = (w - x, h - y)
        case 3: (x, y) = (y, w - x)
        default: break
        }
        let frame = rotatedSize(sourceSize, s.rotation)
        let fw = Double(frame.width), fh = Double(frame.height)
        if s.flipped { x = fw - x }
        if let perspective = perspective(s, frame: frame), let p = perspective.apply(CGPoint(x: x, y: y)) {
            (x, y) = (Double(p.x), Double(p.y))
        }
        if s.straighten != 0 {
            // y points down, so this matrix turns clockwise for a positive angle
            let a = s.straighten * .pi / 180, dx = x - fw / 2, dy = y - fh / 2
            (x, y) = (fw / 2 + dx * cos(a) - dy * sin(a), fh / 2 + dx * sin(a) + dy * cos(a))
        }
        let crop = effectiveCrop(s, frame: frame)
        return CGPoint(x: (x / fw - crop.x) / crop.width, y: (y / fh - crop.y) / crop.height)
    }

    static func sourcePoint(fromFinished p: CGPoint, settings s: DevelopSettings, sourceSize: CGSize) -> CGPoint {
        let w = Double(sourceSize.width), h = Double(sourceSize.height)
        let frame = rotatedSize(sourceSize, s.rotation)
        let fw = Double(frame.width), fh = Double(frame.height)
        let crop = effectiveCrop(s, frame: frame)
        var x = (crop.x + Double(p.x) * crop.width) * fw, y = (crop.y + Double(p.y) * crop.height) * fh
        if s.straighten != 0 {
            let a = -s.straighten * .pi / 180, dx = x - fw / 2, dy = y - fh / 2
            (x, y) = (fw / 2 + dx * cos(a) - dy * sin(a), fh / 2 + dx * sin(a) + dy * cos(a))
        }
        if let perspective = perspective(s, frame: frame), let p = perspective.inverse.apply(CGPoint(x: x, y: y)) {
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
}
