// ============================================================
//  Develop by text — a described look turned into slider values
// ============================================================
import Foundation

/// Asks a language model to turn "a warmer film look, darker sky" into develop settings: the Basic,
/// Presence and Effects sliders, white balance and color grading, as absolute values, each
/// checked against its slider's range. It sees the photo's current values (and the photo, when
/// the model reads images).
enum DevelopByText {
    /// The sliders the model may set, by the names it's given.
    static let sliders: [(name: String, path: WritableKeyPath<DevelopSettings, Double>, range: ClosedRange<Double>)] = [
        ("exposure", \.exposure, -5...5), ("contrast", \.contrast, -100...100), ("highlights", \.highlights, -100...100),
        ("shadows", \.shadows, -100...100), ("whites", \.whites, -100...100), ("blacks", \.blacks, -100...100),
        ("texture", \.texture, -100...100), ("clarity", \.clarity, -100...100), ("dehaze", \.dehaze, -100...100),
        ("vibrance", \.vibrance, -100...100), ("saturation", \.saturation, -100...100),
        ("vignette", \.vignette, -100...100), ("grain", \.grain, 0...100),
    ]
    private static let regions: [(name: String, path: WritableKeyPath<DevelopSettings, ColorGrading.Grade>)] = [
        ("shadows", \.grading.shadows), ("midtones", \.grading.midtones), ("highlights", \.grading.highlights),
    ]

    struct Look: Equatable, Sendable {
        var settings: DevelopSettings
        /// The model's one-line account of what it did.
        var explanation: String
    }

    /// A photo's white balance as its sliders show it: a RAW's own (as shot unless changed) in
    /// Kelvin, anything else's relative shift.
    static func whiteBalance(_ settings: DevelopSettings, isRaw: Bool, asShot: AsShot) -> (temperature: Double, tint: Double) {
        (settings.temperature ?? (isRaw ? asShot.temperature ?? 5500 : 0), settings.tint ?? (isRaw ? asShot.tint ?? 0 : 0))
    }

    /// A RAW's white balance as the camera recorded it.
    struct AsShot: Equatable, Sendable {
        var temperature: Double?
        var tint: Double?
    }

    static func request(_ description: String, settings: DevelopSettings, isRaw: Bool, asShot: AsShot = AsShot(),
                        image: Data?, chinese: Bool) -> LLMRequest {
        let temperature = isRaw
            ? "temperature: Kelvin 2000–12000, higher is warmer; tint -150…150, positive is magenta, negative green"
            : "temperature: -100…100 relative, positive is warmer; tint: -100…100, positive is magenta, negative green"
        let example = isRaw ? ("temperature 5200 K", 5700) : ("temperature 0", 15)
        let system = """
        You are a photo editor working Lightroom-style sliders. Turn the request into new slider values and reply with only \
        a JSON object holding the sliders to change (absolute values; leave out sliders to keep) and a short explanation:
        {"exposure": EV -5…5, "contrast", "highlights", "shadows", "whites", "blacks", "texture", "clarity", "dehaze", \
        "vibrance", "saturation": -100…100 (for highlights, shadows, whites and blacks, negative is darker: deeper blacks \
        are negative "blacks"), "vignette": -100…100 (negative darkens the corners), "grain": 0…100, \
        "temperature", "tint", "grading": {"shadows" | "midtones" | "highlights": {"hue": 0…360, "saturation": 0…100}}, \
        "explanation": string}
        \(temperature).
        Values are absolute: start from the current ones below, and reply with only the sliders the request calls for — \
        never repeat the others. Make moderate, photographic changes unless asked for something strong: "a little warmer" \
        is the current temperature plus about 300 to 800 K (10 to 25 on the relative scale), "slightly brighter" exposure \
        plus 0.2 to 0.4, "more contrast" plus 10 to 25, "some grain" 15 to 30; double that for "much". Only when black and \
        white is asked for, set saturation to -100. Leave tint alone unless asked about green or magenta. Every change the \
        explanation mentions must be in the JSON. Write the explanation in \(chinese ? "Simplified Chinese" : "English"), \
        one sentence.
        Example: with exposure 0.50 and \(example.0) now, "a little warmer and brighter" → \
        {"exposure": 0.8, "temperature": \(example.1), "explanation": "..."}
        """
        var current = sliders.map { "\($0.name): \(format(settings[keyPath: $0.path]))" }
        let balance = whiteBalance(settings, isRaw: isRaw, asShot: asShot)
        current.append("temperature: " + format(balance.temperature.rounded()) + (isRaw ? " K" : ""))
        current.append("tint: " + format(balance.tint.rounded()))
        for region in regions {
            let grade = settings[keyPath: region.path]
            if grade.saturation > 0 { current.append("grading \(region.name): hue \(format(grade.hue)) saturation \(format(grade.saturation))") }
        }
        let prompt = "Request: \(description)\n\nCurrent values:\n" + current.joined(separator: "\n")
        return LLMRequest(system: system, prompt: prompt, images: image.map { [$0] } ?? [], maxTokens: 500)
    }

    /// `settings` with the reply's values applied, each within its slider's range; nil when the
    /// reply changes nothing. A white balance that only repeats the current one stays as it was
    /// (as shot, for a RAW).
    static func parse(_ reply: String, onto settings: DevelopSettings, isRaw: Bool, asShot: AsShot = AsShot()) -> Look? {
        guard let json = LLMClient.jsonObject(in: reply) else { return nil }
        func number(_ value: Any?) -> Double? {
            (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        }
        var result = settings
        for slider in sliders {
            // "black" for "blacks" and the like
            guard let value = number(json[slider.name] ?? json[String(slider.name.dropLast())]), value.isFinite else { continue }
            result[keyPath: slider.path] = min(slider.range.upperBound, max(slider.range.lowerBound, value))
        }
        let balance = whiteBalance(settings, isRaw: isRaw, asShot: asShot)
        if let temperature = number(json["temperature"]), temperature.isFinite {
            let value = isRaw ? min(12000, max(2000, temperature)).rounded() : min(100, max(-100, temperature)).rounded()
            if value != balance.temperature.rounded() { result.temperature = value }
        }
        if let tint = number(json["tint"]), tint.isFinite {
            let value = isRaw ? min(150, max(-150, tint)).rounded() : min(100, max(-100, tint)).rounded()
            if value != balance.tint.rounded() { result.tint = value }
        }
        if let grading = json["grading"] as? [String: Any] {
            for region in regions {
                guard let grade = grading[region.name] as? [String: Any] else { continue }
                if let hue = number(grade["hue"]), hue.isFinite {
                    result[keyPath: region.path].hue = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
                }
                if let saturation = number(grade["saturation"]), saturation.isFinite {
                    result[keyPath: region.path].saturation = min(100, max(0, saturation))
                }
            }
        }
        guard result != settings else { return nil }
        return Look(settings: result, explanation: (json["explanation"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }
}
