// ============================================================
//  Photo describer — titles, captions and keywords from a model that reads images
// ============================================================
import CoreGraphics
import Darwin
import Foundation
import ImageIO

/// Asks a language model that reads images for a photo's title, caption and keywords, and reads
/// its answer.
enum PhotoDescriber {
    struct Description: Equatable, Sendable {
        var title: String
        var caption: String
        var keywords: [String]
    }

    /// Catalog hints, sent only when the user explicitly includes metadata.
    struct Details: Sendable {
        var date: Date?
        var camera = ""
        var place = ""
        var keywords: [String] = []
    }

    /// Safe to display in consent and review, without URL credentials or query tokens.
    struct Destination: Equatable, Sendable {
        let provider: String
        let model: String
        let endpoint: String?
        let isLoopback: Bool

        init(configuration: LLMConfiguration) {
            let url = configuration.endpoint
            let preset = configuration.kind == .openAICompatible ? LLMConfiguration.presets.first {
                guard let candidate = URL(string: $0.baseURL), let url else { return false }
                return candidate.host?.lowercased() == url.host?.lowercased() && candidate.port == url.port
            } : nil
            provider = preset?.name ?? configuration.kind.title
            model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
            var components = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
            components?.user = nil
            components?.password = nil
            components?.query = nil
            components?.fragment = nil
            endpoint = components?.url?.absoluteString
            isLoopback = Self.isLoopbackHost(url?.host)
        }

        private static func isLoopbackHost(_ host: String?) -> Bool {
            guard var host = host?.lowercased() else { return false }
            if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
            if host == "localhost" || host == "localhost." { return true }
            var ipv4 = in_addr()
            if inet_pton(AF_INET, host, &ipv4) == 1 { return UInt32(bigEndian: ipv4.s_addr) >> 24 == 127 }
            var ipv6 = in6_addr()
            guard inet_pton(AF_INET6, host, &ipv6) == 1 else { return false }
            return withUnsafeBytes(of: ipv6) { bytes in
                let loopback = bytes.prefix(15).allSatisfy { $0 == 0 } && bytes[15] == 1
                let mappedLoopback = bytes.prefix(10).allSatisfy { $0 == 0 }
                    && bytes[10] == 255 && bytes[11] == 255 && bytes[12] == 127
                return loopback || mappedLoopback
            }
        }
    }

    /// Whether answers should be in Chinese: the language the app is showing.
    static var answersInChinese: Bool {
        (Bundle.main.preferredLocalizations.first ?? "zh-Hans").hasPrefix("zh")
    }

    static func request(image: Data, details: Details, chinese: Bool, includeMetadata: Bool = false) -> LLMRequest {
        let language = chinese ? "Simplified Chinese" : "English"
        let system = """
        You write catalog metadata for photographs. Look at the photo and reply with only a JSON object:
        {"title": string, "caption": string, "keywords": [string]}
        - title: short and specific (at most 8 words; in Chinese at most 16 characters).
        - caption: one or two factual sentences about what the photo shows.
        - keywords: 8 to 15 plain nouns or short phrases — the main subjects, the setting and kind of place, season or \
        time of day, weather, mood, dominant colours, photographic style.
        Don't mention the camera, the lens or camera settings. Don't guess who people are. Write everything in \(language).
        """
        var hints: [String] = []
        if includeMetadata {
            if let date = details.date { hints.append("taken: \(date.formatted(.iso8601.year().month().day()))") }
            if !details.camera.isEmpty { hints.append("camera: \(details.camera)") }
            if !details.place.isEmpty { hints.append("place: \(details.place)") }
            if !details.keywords.isEmpty { hints.append("existing keywords: \(details.keywords.joined(separator: ", "))") }
        }
        let prompt = hints.isEmpty ? "Describe this photo." : "Describe this photo. What the catalog knows:\n" + hints.joined(separator: "\n")
        return LLMRequest(system: system, prompt: prompt, images: [image], maxTokens: 600)
    }

    /// The description in a reply, leaving out keywords that only repeat `excluding` (the camera
    /// named in the hints); nil when there's none to be found.
    static func parse(_ reply: String, excluding: [String] = []) -> Description? {
        guard let json = LLMClient.jsonObject(in: reply) else { return nil }
        func text(_ key: String) -> String {
            (json[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let raw: [String] = (json["keywords"] as? [Any])?.compactMap { $0 as? String }
            ?? (json["keywords"] as? String).map { [$0] } ?? []
        let excluded = Set(excluding.map { $0.lowercased() }.filter { !$0.isEmpty })
        let keywords = KeywordService.normalize(raw.flatMap { KeywordService.normalize($0) })
            .filter { $0.count <= 40 && !excluded.contains($0.lowercased()) }
        let description = Description(title: text("title"), caption: text("caption"), keywords: Array(keywords.prefix(20)))
        return description.title.isEmpty && description.caption.isEmpty && description.keywords.isEmpty ? nil : description
    }

    /// The photo as the model sees it: its develop settings applied (so a crop counts), at most
    /// 1024 px, as a JPEG — from the original, or from the catalog's preview when the original
    /// is away.
    static func image(source: (url: URL, isRaw: Bool)?, settings: DevelopSettings, preview: URL?) -> Data? {
        if let source, let image = DevelopRenderer.Source(url: source.url, isRaw: source.isRaw, maxPixel: 1400)?.image(settings),
           let rendered = DevelopRenderer.render(image) {
            return LLMClient.jpeg(rendered)
        }
        guard let preview, let file = CGImageSourceCreateWithURL(preview as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(file, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1024,
              ] as CFDictionary) else { return nil }
        return LLMClient.jpeg(image)
    }
}
