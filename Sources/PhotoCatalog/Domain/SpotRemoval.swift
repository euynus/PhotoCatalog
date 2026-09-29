// ============================================================
//  Spot removal — Lightroom's heal and clone spots
// ============================================================
import Foundation
import CoreGraphics

/// A circle painted over with another part of the photo. Heal brings the source's texture and
/// matches the target's surrounding color and brightness; clone copies the source as it is.
/// Positions are fractions of the source photo (top-left origin, before quarter turns,
/// mirroring, straighten and crop), like masks.
struct SpotRemoval: Codable, Hashable, Sendable, Identifiable {
    enum Mode: String, Codable, CaseIterable, Identifiable, Sendable {
        case heal, clone
        var id: Self { self }
        var title: String {
            switch self {
            case .heal: L("修复")
            case .clone: L("仿制")
            }
        }
    }

    var id = UUID().uuidString
    var mode = Mode.heal
    /// The spot painted over, and where its replacement comes from.
    var target = CGPoint(x: 0.5, y: 0.5)
    var source = CGPoint(x: 0.55, y: 0.5)
    /// Radius as a fraction of the source's long edge.
    var radius = 0.01
    /// How much of the radius the edge fades over, 0…100, and the spot's strength, 0…100.
    var feather = 50.0
    var opacity = 100.0

    init(target: CGPoint, source: CGPoint, radius: Double) {
        self.target = target
        self.source = source
        self.radius = radius
    }

    var fingerprintText: String {
        [target.x, target.y, source.x, source.y, radius, feather, opacity].map { String(format: "%.4f", $0) }
            .joined(separator: ",") + (mode == .clone ? "c" : "h")
    }
}

extension SpotRemoval {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        mode = (try? c.decodeIfPresent(Mode.self, forKey: .mode)) ?? .heal   // a mode added later heals
        target = try c.decodeIfPresent(CGPoint.self, forKey: .target) ?? CGPoint(x: 0.5, y: 0.5)
        source = try c.decodeIfPresent(CGPoint.self, forKey: .source) ?? CGPoint(x: 0.55, y: 0.5)
        radius = try c.decodeIfPresent(Double.self, forKey: .radius) ?? 0.01
        feather = try c.decodeIfPresent(Double.self, forKey: .feather) ?? 50
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 100
    }
}

/// The spot tool's settings for new spots.
struct SpotBrush: Equatable, Sendable {
    /// 1…100: a radius of up to 8% of the photo's long edge.
    var size = 12.0
    var feather = 50.0
    var opacity = 100.0
    var mode = SpotRemoval.Mode.heal

    /// Spot radius as a fraction of the source's long edge.
    var radius: Double { size / 100 * 0.08 }

    /// The size whose radius is `radius`, within the slider's range.
    static func size(forRadius radius: Double) -> Double { min(100, max(1, radius / 0.08 * 100)) }
}
