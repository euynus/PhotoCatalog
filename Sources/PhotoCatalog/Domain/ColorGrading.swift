// ============================================================
//  Color grading — Lightroom's shadows / midtones / highlights wheels
// ============================================================
import Foundation

/// A tint and brightness for each tonal region and for the whole photo. Blending widens the
/// hand-over between regions; balance favors the shadows (-) or highlights (+), as in
/// Lightroom, by moving the hand-over away from them.
struct ColorGrading: Codable, Hashable, Sendable {
    /// One region's grade: hue 0…360°, saturation 0…100 (strength of the tint), luminance -100…100.
    struct Grade: Codable, Hashable, Sendable {
        var hue: Double = 0
        var saturation: Double = 0
        var luminance: Double = 0

        var isNeutral: Bool { saturation == 0 && luminance == 0 }
    }

    enum Region: String, CaseIterable, Identifiable, Sendable {
        case shadows, midtones, highlights, global
        var id: Self { self }
        var title: String {
            switch self {
            case .shadows: L("阴影")
            case .midtones: L("中间调")
            case .highlights: L("高光")
            case .global: L("全局")
            }
        }
    }

    var shadows = Grade()
    var midtones = Grade()
    var highlights = Grade()
    var global = Grade()
    var blending: Double = 50
    var balance: Double = 0

    /// No visible effect: every region untinted and unbrightened (hue, blending and balance
    /// only matter once a region has a tint).
    var isNeutral: Bool { shadows.isNeutral && midtones.isNeutral && highlights.isNeutral && global.isNeutral }

    var fingerprintText: String {
        ([shadows, midtones, highlights, global].flatMap { [$0.hue, $0.saturation, $0.luminance] } + [blending, balance])
            .map { String(format: "%.0f", $0) }.joined(separator: ",")
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shadows = try container.decodeIfPresent(Grade.self, forKey: .shadows) ?? Grade()
        midtones = try container.decodeIfPresent(Grade.self, forKey: .midtones) ?? Grade()
        highlights = try container.decodeIfPresent(Grade.self, forKey: .highlights) ?? Grade()
        global = try container.decodeIfPresent(Grade.self, forKey: .global) ?? Grade()
        blending = try container.decodeIfPresent(Double.self, forKey: .blending) ?? 50
        balance = try container.decodeIfPresent(Double.self, forKey: .balance) ?? 0
    }
}

extension ColorGrading.Grade {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hue = try container.decodeIfPresent(Double.self, forKey: .hue) ?? 0
        saturation = try container.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        luminance = try container.decodeIfPresent(Double.self, forKey: .luminance) ?? 0
    }
}
