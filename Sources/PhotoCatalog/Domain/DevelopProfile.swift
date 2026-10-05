// ============================================================
//  Develop profiles — the base look every other adjustment starts from
// ============================================================
import Foundation

/// A profile, as in Lightroom's Profile browser: how the photo looks before any slider moves.
/// Each is the app's own look — a tone curve, a response per color band and an overall
/// saturation — applied after white balance and exposure and before the Basic tone controls,
/// at an amount of 0…200%. Standard is the RAW engine's own rendering, untouched. Monochrome is
/// black and white: the color mixer gives way to the black-and-white mix (see `DevelopSettings.grayMixer`).
enum DevelopProfile: String, CaseIterable, Identifiable, Sendable {
    case standard, neutral, vivid, portrait, landscape, monochrome

    var id: Self { self }

    /// The profile `name` stored in settings (nil, or a name this version doesn't know: Standard).
    init(stored name: String?) {
        self = name.flatMap(DevelopProfile.init(rawValue:)) ?? .standard
    }

    /// What settings store: nil for Standard, so an untouched photo stays neutral.
    var stored: String? { self == .standard ? nil : rawValue }

    var title: String {
        switch self {
        case .standard: L("标准")
        case .neutral: L("中性")
        case .vivid: L("鲜艳")
        case .portrait: L("人像")
        case .landscape: L("风景")
        case .monochrome: L("单色")
        }
    }

    var help: String {
        switch self {
        case .standard: L("相机引擎的原始渲染")
        case .neutral: L("低对比、柔和的颜色，适合细致后期")
        case .vivid: L("更高的对比度与饱和度")
        case .portrait: L("柔和的影调，自然、明亮的肤色")
        case .landscape: L("更浓的绿色与蓝色，更深的天空")
        case .monochrome: L("黑白：混色器换成各颜色的黑白混合")
        }
    }

    /// The nearest profiles in Lightroom and Camera Raw presets.
    static func named(cameraRaw name: String) -> DevelopProfile? {
        switch name.trimmingCharacters(in: .whitespaces).lowercased() {
        case "adobe standard", "adobe color", "camera standard": .standard
        case "adobe neutral", "camera neutral", "camera faithful": .neutral
        case "adobe vivid", "camera vivid": .vivid
        case "adobe portrait", "camera portrait": .portrait
        case "adobe landscape", "camera landscape": .landscape
        case "adobe monochrome", "camera monochrome": .monochrome
        default: nil
        }
    }

    /// The look at 100%: a curve on display-encoded values, the color mixer's adjustments and a
    /// saturation change (-100…100).
    struct Look: Sendable {
        var curve: [CurvePoint] = []
        var mixer = ColorMixer()
        var saturation: Double = 0
    }

    var look: Look {
        func points(_ values: [(Double, Double)]) -> [CurvePoint] { values.map { CurvePoint(x: $0.0, y: $0.1) } }
        var look = Look()
        switch self {
        case .standard, .monochrome:
            break   // black and white happens in place of the color mixer
        case .neutral:
            // a gentle reverse S: open shadows, softer highlights, quieter color
            look.curve = points([(0, 0), (0.15, 0.185), (0.5, 0.5), (0.85, 0.83), (1, 1)])
            look.saturation = -12
        case .vivid:
            look.curve = points([(0, 0), (0.2, 0.17), (0.5, 0.5), (0.8, 0.835), (1, 1)])
            look.saturation = 15
            look.mixer.saturation[ColorMixer.Band.green.rawValue] = 8
            look.mixer.saturation[ColorMixer.Band.blue.rawValue] = 8
        case .portrait:
            // a slightly lifted, softer curve; reds and oranges calmer and lighter, so skin glows
            look.curve = points([(0, 0), (0.25, 0.28), (0.5, 0.535), (0.75, 0.765), (1, 1)])
            look.saturation = -5
            look.mixer.hue[ColorMixer.Band.red.rawValue] = 8
            look.mixer.saturation[ColorMixer.Band.red.rawValue] = -10
            look.mixer.saturation[ColorMixer.Band.orange.rawValue] = -14
            look.mixer.luminance[ColorMixer.Band.orange.rawValue] = 16
            look.mixer.saturation[ColorMixer.Band.yellow.rawValue] = -8
            look.mixer.luminance[ColorMixer.Band.yellow.rawValue] = 6
        case .landscape:
            look.curve = points([(0, 0), (0.25, 0.235), (0.5, 0.5), (0.75, 0.77), (1, 1)])
            look.saturation = 5
            look.mixer.saturation[ColorMixer.Band.yellow.rawValue] = 8
            look.mixer.saturation[ColorMixer.Band.green.rawValue] = 18
            look.mixer.saturation[ColorMixer.Band.aqua.rawValue] = 12
            look.mixer.saturation[ColorMixer.Band.blue.rawValue] = 15
            look.mixer.luminance[ColorMixer.Band.blue.rawValue] = -10
        }
        return look
    }

    /// The look at `amount` percent (0…200): the curve's bend, the mixer and the saturation
    /// scaled, each kept inside its range.
    func look(amount: Double) -> Look {
        let full = look, t = max(0, min(200, amount)) / 100
        var scaled = Look()
        scaled.curve = full.curve.map { CurvePoint(x: $0.x, y: min(1, max(0, $0.x + ($0.y - $0.x) * t))) }
        for i in 0..<8 {
            scaled.mixer.hue[i] = min(100, max(-100, full.mixer.hue[i] * t))
            scaled.mixer.saturation[i] = min(100, max(-100, full.mixer.saturation[i] * t))
            scaled.mixer.luminance[i] = min(100, max(-100, full.mixer.luminance[i] * t))
        }
        scaled.saturation = min(100, max(-100, full.saturation * t))
        return scaled
    }
}
