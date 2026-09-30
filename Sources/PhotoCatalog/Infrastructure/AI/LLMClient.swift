// ============================================================
//  LLM client — Anthropic's Messages API and OpenAI-compatible chat
// ============================================================
import CoreGraphics
import Foundation
import ImageIO
import Security

/// Where language-model requests go (Settings → AI): Anthropic's Messages API, or any service
/// speaking OpenAI's chat-completions format — OpenAI, DeepSeek, Qwen, Doubao, Kimi, GLM, or a
/// local Ollama / LM Studio. Nothing is sent until a feature is used; photos go as small JPEG
/// previews, and the API key stays in the keychain.
struct LLMConfiguration: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case anthropic, openAICompatible

        var title: String {
            switch self {
            case .anthropic: "Anthropic Claude"
            case .openAICompatible: L("兼容 OpenAI 的接口")
            }
        }
    }

    var kind: Kind = .anthropic
    var baseURL = "https://api.anthropic.com"
    var model = "claude-haiku-4-5-20251001"
    /// Whether the model reads images (DeepSeek's API, for one, takes text only).
    var acceptsImages = true

    static let anthropic = LLMConfiguration()

    /// Services with an OpenAI-compatible endpoint, as starting points: model names change, so
    /// they stay editable.
    struct Preset: Identifiable, Sendable {
        let name: String
        let baseURL: String
        let model: String
        let acceptsImages: Bool
        var id: String { name }
    }

    static let presets: [Preset] = [
        Preset(name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini", acceptsImages: true),
        Preset(name: "DeepSeek", baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat", acceptsImages: false),
        Preset(name: L("通义千问"), baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "qwen-vl-max",
               acceptsImages: true),
        Preset(name: L("豆包"), baseURL: "https://ark.cn-beijing.volces.com/api/v3", model: "", acceptsImages: true),
        Preset(name: "Kimi", baseURL: "https://api.moonshot.cn/v1", model: "moonshot-v1-8k-vision-preview", acceptsImages: true),
        Preset(name: L("智谱"), baseURL: "https://open.bigmodel.cn/api/paas/v4", model: "glm-4v-flash", acceptsImages: true),
        Preset(name: L("Ollama（本机）"), baseURL: "http://localhost:11434/v1", model: "qwen2.5vl", acceptsImages: true),
        Preset(name: L("LM Studio（本机）"), baseURL: "http://localhost:1234/v1", model: "", acceptsImages: true),
    ]

    /// The endpoint requests are posted to.
    var endpoint: URL? {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base), url.scheme == "https" || url.scheme == "http", url.host != nil else { return nil }
        switch kind {
        case .anthropic: return URL(string: base.hasSuffix("/v1") ? base + "/messages" : base + "/v1/messages")
        case .openAICompatible: return URL(string: base + "/chat/completions")
        }
    }

    /// A key is needed: Anthropic always; an OpenAI-compatible service unless it's on this Mac.
    var needsKey: Bool {
        kind == .anthropic || !["localhost", "127.0.0.1", "::1"].contains(endpoint?.host ?? "")
    }

    var isComplete: Bool { endpoint != nil && !model.trimmingCharacters(in: .whitespaces).isEmpty }
}

struct LLMRequest: Sendable {
    var system: String
    var prompt: String
    /// JPEG images, shown to the model before the prompt.
    var images: [Data] = []
    var maxTokens = 1024
}

enum LLMError: Error, Equatable {
    case notConfigured
    case missingKey
    case imagesNotSupported
    case http(status: Int, message: String)
    case network(String)
    case malformed

    var message: String {
        switch self {
        case .notConfigured: L("请先在“设置 → AI”中设置服务地址和模型")
        case .missingKey: L("请先在“设置 → AI”中填写 API Key")
        case .imagesNotSupported: L("所选模型不能识别图片")
        case .http(let status, let message):
            status == 401 || status == 403 ? L("API Key 无效或没有权限（\(status)）") : L("服务返回错误（\(status)）：\(message)")
        case .network(let message): L("无法连接服务：\(message)")
        case .malformed: L("服务的回复无法读取")
        }
    }
}

enum LLMClient {
    /// Sends `request` and returns the model's text.
    static func complete(_ request: LLMRequest, configuration: LLMConfiguration, key: String?,
                         session: URLSession = .shared) async throws -> String {
        guard configuration.isComplete, let url = configuration.endpoint else { throw LLMError.notConfigured }
        let key = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if configuration.needsKey && key.isEmpty { throw LLMError.missingKey }
        if !request.images.isEmpty && !configuration.acceptsImages { throw LLMError.imagesNotSupported }
        // generous: a model on this Mac can take minutes over a photo
        var urlRequest = URLRequest(url: url, timeoutInterval: 300)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any]
        switch configuration.kind {
        case .anthropic:
            urlRequest.setValue(key, forHTTPHeaderField: "x-api-key")
            urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            var content: [[String: Any]] = request.images.map { image in
                ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": image.base64EncodedString()]]
            }
            content.append(["type": "text", "text": request.prompt])
            body = ["model": configuration.model, "max_tokens": request.maxTokens, "system": request.system,
                    "messages": [["role": "user", "content": content]]]
        case .openAICompatible:
            if !key.isEmpty { urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "authorization") }
            let user: Any = request.images.isEmpty ? request.prompt : [["type": "text", "text": request.prompt]]
                + request.images.map { ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + $0.base64EncodedString()]] }
            body = ["model": configuration.model, "max_tokens": request.maxTokens,
                    "messages": [["role": "system", "content": request.system], ["role": "user", "content": user]]]
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw LLMError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else {
            let detail = ((json?["error"] as? [String: Any])?["message"] as? String)
                ?? (json?["message"] as? String) ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw LLMError.http(status: status, message: detail)
        }
        let text: String?
        switch configuration.kind {
        case .anthropic:
            text = (json?["content"] as? [[String: Any]])?
                .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
        case .openAICompatible:
            text = ((json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LLMError.malformed }
        return text
    }

    /// The JSON object in a model's reply, which may come wrapped in prose or a code fence — and,
    /// from smaller models, written with single quotes or cut off by the token limit.
    static func jsonObject(in text: String) -> [String: Any]? {
        func object(_ candidate: String) -> [String: Any]? {
            guard let data = candidate.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        guard let start = text.firstIndex(of: "{") else { return nil }
        var body = String(text[start...])
        if let end = body.lastIndex(of: "}"), let found = object(String(body[...end])) { return found }
        // Python-style quoting, when there's no double quote to confuse it with
        if !body.contains("\"") { body = body.replacingOccurrences(of: "'", with: "\"") }
        if let end = body.lastIndex(of: "}"), let found = object(String(body[...end])) { return found }
        // cut off: drop the unfinished last item and close what's open
        var trimmed = body
        while let comma = trimmed.lastIndex(of: ",") {
            trimmed = String(trimmed[..<comma])
            if let found = object(trimmed + closers(for: trimmed)) { return found }
        }
        return nil
    }

    /// The brackets and braces `text` leaves open, closed in order.
    private static func closers(for text: String) -> String {
        var open: [Character] = []
        var inString = false, escaped = false
        for character in text {
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "\"" { inString.toggle(); continue }
            guard !inString else { continue }
            if character == "{" || character == "[" { open.append(character) }
            if character == "}" || character == "]" { _ = open.popLast() }
        }
        return (inString ? "\"" : "") + String(open.reversed().map { $0 == "{" ? "}" : "]" })
    }

    /// A photo as the model sees it: at most `maxPixel` on the long edge, as a JPEG.
    static func jpeg(_ image: CGImage, maxPixel: Int = 1024) -> Data? {
        let scale = min(1, Double(maxPixel) / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let small = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, small, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

/// API keys, one per service, in the login keychain.
enum LLMKeychain {
    static let service = "com.photocatalog.app.llm"

    static func account(for configuration: LLMConfiguration) -> String {
        "\(configuration.kind.rawValue)|\(configuration.endpoint?.host ?? configuration.baseURL)"
    }

    static func key(for configuration: LLMConfiguration) -> String? {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                      kSecAttrAccount: account(for: configuration), kSecReturnData: true,
                                      kSecMatchLimit: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Saves `key` for the service (an empty key removes it).
    @discardableResult
    static func save(_ key: String, for configuration: LLMConfiguration) -> Bool {
        let item: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                     kSecAttrAccount: account(for: configuration)]
        SecItemDelete(item as CFDictionary)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        var attributes = item
        attributes[kSecValueData] = Data(trimmed.utf8)
        attributes[kSecAttrLabel] = "PhotoCatalog AI (\(configuration.endpoint?.host ?? configuration.baseURL))"
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }
}
