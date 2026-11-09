// ============================================================
//  Soft proof — the proofing settings: profile, intent, paper, gamut warning
// ============================================================
import Foundation

/// How Develop proofs the photo (Lightroom's Soft Proofing): the profile it's shown through,
/// the rendering intent, whether paper white and ink black are simulated, and whether colors
/// the profile can't hold are marked.
struct SoftProof: Codable, Equatable, Sendable {
    enum Intent: String, Codable, CaseIterable, Identifiable, Sendable {
        case perceptual, relative

        var id: Self { self }
        var title: String {
            switch self {
            case .perceptual: L("可感知")
            case .relative: L("相对比色")
            }
        }
    }

    /// A built-in space ("sRGB", "displayP3", "adobeRGB") or the path of an ICC profile.
    var profile = "sRGB"
    var intent = Intent.perceptual
    var simulatePaper = false
    var gamutWarning = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profile = try c.decodeIfPresent(String.self, forKey: .profile) ?? "sRGB"
        intent = try c.decodeIfPresent(Intent.self, forKey: .intent) ?? .perceptual
        simulatePaper = try c.decodeIfPresent(Bool.self, forKey: .simulatePaper) ?? false
        gamutWarning = try c.decodeIfPresent(Bool.self, forKey: .gamutWarning) ?? false
    }
}
