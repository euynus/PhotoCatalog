// ============================================================
//  Develop settings — non-destructive adjustments (Lightroom Basic)
// ============================================================
import Foundation

/// Adjustments stored per photo in the catalog; the original is never modified.
/// Zero / nil values mean "as shot".
struct DevelopSettings: Codable, Equatable, Hashable, Sendable {
    /// White balance. RAW: absolute Kelvin and tint (nil = as shot, as the camera recorded).
    /// Other formats: relative shifts on a -100…100 scale.
    var temperature: Double?
    var tint: Double?
    var exposure: Double = 0      // EV, -5…5
    var contrast: Double = 0      // -100…100
    var highlights: Double = 0
    var shadows: Double = 0
    var whites: Double = 0
    var blacks: Double = 0
    var vibrance: Double = 0
    var saturation: Double = 0

    static let neutral = DevelopSettings()

    var isNeutral: Bool { self == .neutral }

    /// Tone and color without white balance — what can be pasted between RAW and non-RAW photos,
    /// whose white-balance scales differ.
    var withoutWhiteBalance: DevelopSettings {
        var copy = self
        copy.temperature = nil
        copy.tint = nil
        return copy
    }

    /// Short fingerprint for cache file names, so a new edit never reuses an old render.
    var fingerprint: String {
        let fields: [Double?] = [temperature, tint, exposure, contrast, highlights, shadows,
                                 whites, blacks, vibrance, saturation]
        let text = fields.map { $0.map { String(format: "%.3f", $0) } ?? "-" }.joined(separator: ",")
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return String(hash, radix: 36)
    }
}

/// One slider in the Basic panel: range, neutral value and display format.
struct DevelopControl: Identifiable {
    let id: WritableKeyPath<DevelopSettings, Double>
    let title: String
    let range: ClosedRange<Double>
    let step: Double
    let format: @Sendable (Double) -> String

    static let exposure = DevelopControl(id: \.exposure, title: "曝光度", range: -5...5, step: 0.01) {
        String(format: "%+.2f", $0)
    }
    static let tone: [DevelopControl] = [
        .exposure,
        signed(\.contrast, "对比度"),
        signed(\.highlights, "高光"),
        signed(\.shadows, "阴影"),
        signed(\.whites, "白色色阶"),
        signed(\.blacks, "黑色色阶"),
    ]
    static let presence: [DevelopControl] = [
        signed(\.vibrance, "鲜艳度"),
        signed(\.saturation, "饱和度"),
    ]

    private static func signed(_ keyPath: WritableKeyPath<DevelopSettings, Double>, _ title: String) -> DevelopControl {
        DevelopControl(id: keyPath, title: title, range: -100...100, step: 1) { value in
            value == 0 ? "0" : String(format: "%+.0f", value)
        }
    }
}

/// Tone distribution of a rendered photo, per channel, as fractions of all pixels.
struct DevelopHistogram: Equatable, Sendable {
    static let binCount = 64
    let red: [Double]
    let green: [Double]
    let blue: [Double]

    /// Share of pixels in the darkest / brightest bin of any channel — clipping warnings.
    var shadowClipping: Double { max(red.first ?? 0, green.first ?? 0, blue.first ?? 0) }
    var highlightClipping: Double { max(red.last ?? 0, green.last ?? 0, blue.last ?? 0) }
    /// Clipping worth flagging: more than a sliver of the photo sits in an end bin.
    static let clippingWarning = 0.005
}
