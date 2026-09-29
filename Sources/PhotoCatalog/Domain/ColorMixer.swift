// ============================================================
//  Color mixer — Lightroom's HSL panel
// ============================================================
import Foundation

/// Hue, saturation and luminance shifts for eight color bands, -100…100 each. Hue moves a band
/// toward its neighbors (±30°), saturation scales its color (-100 is gray), luminance changes
/// its brightness (±1 stop). Grays are never touched.
struct ColorMixer: Codable, Hashable, Sendable {
    enum Band: Int, CaseIterable, Identifiable, Sendable {
        case red, orange, yellow, green, aqua, blue, purple, magenta
        var id: Self { self }

        var title: String {
            switch self {
            case .red: L("红色")
            case .orange: L("橙色")
            case .yellow: L("黄色")
            case .green: L("绿色")
            case .aqua: L("浅绿色")
            case .blue: L("蓝色")
            case .purple: L("紫色")
            case .magenta: L("洋红色")
            }
        }

        /// Band center on the hue wheel, in degrees (the kernel's centers must match).
        var hue: Double { [0, 30, 60, 120, 180, 240, 270, 300][rawValue] }
    }

    enum Property: String, CaseIterable, Identifiable, Sendable {
        case hue, saturation, luminance
        var id: Self { self }
        var title: String {
            switch self {
            case .hue: L("色相")
            case .saturation: L("饱和度")
            case .luminance: L("明亮度")
            }
        }
    }

    var hue = [Double](repeating: 0, count: 8)
    var saturation = [Double](repeating: 0, count: 8)
    var luminance = [Double](repeating: 0, count: 8)

    var isNeutral: Bool { (hue + saturation + luminance).allSatisfy { $0 == 0 } }

    var fingerprintText: String {
        (hue + saturation + luminance).map { String(format: "%.0f", $0) }.joined(separator: ",")
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func band(_ key: CodingKeys) throws -> [Double] {
            let values = try container.decodeIfPresent([Double].self, forKey: key) ?? []
            return values.count == 8 ? values : [Double](repeating: 0, count: 8)
        }
        hue = try band(.hue)
        saturation = try band(.saturation)
        luminance = try band(.luminance)
    }
}
