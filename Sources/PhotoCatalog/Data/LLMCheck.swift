import Foundation
import Network

/// The language-model client against a stand-in server on this Mac: requests are shaped as
/// Anthropic's Messages API and OpenAI's chat completions expect, replies and errors are read.
enum LLMCheck {
    static func run() {
        guard let server = StandInServer() else { return assertionFailure("a stand-in server started") }
        defer { server.stop() }
        checkAnthropic(server)
        checkOpenAICompatible(server)
        checkErrors(server)
        checkParsing()
        MainActor.assumeIsolated {
            checkDescribe(server)
        }
        print("--- llm assertions passed ---")
    }

    /// `body` run to completion from synchronous code.
    static func wait<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: T?
        Task.detached {
            result = await body()
            semaphore.signal()
        }
        semaphore.wait()
        return result!
    }

    static func complete(_ request: LLMRequest, _ configuration: LLMConfiguration, key: String?) -> Result<String, LLMError> {
        wait {
            do { return .success(try await LLMClient.complete(request, configuration: configuration, key: key)) } catch {
                return .failure(error as? LLMError ?? .malformed)
            }
        }
    }

    private static func checkAnthropic(_ server: StandInServer) {
        server.reply = (200, #"{"id":"msg_1","type":"message","content":[{"type":"text","text":"{\"title\": \"海边\"}"}],"stop_reason":"end_turn"}"#)
        let configuration = LLMConfiguration(kind: .anthropic, baseURL: "http://127.0.0.1:\(server.port)", model: "claude-test")
        let image = Data([0xFF, 0xD8, 0xFF, 0x01, 0x02])
        let result = complete(LLMRequest(system: "system text", prompt: "describe", images: [image], maxTokens: 300),
                              configuration, key: "sk-test")
        let sent = server.last
        let body = sent.flatMap { (try? JSONSerialization.jsonObject(with: $0.body)) as? [String: Any] }
        let content = ((body?["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]) ?? []
        let source = content.first?["source"] as? [String: Any]
        assert(result == .success(#"{"title": "海边"}"#), "Anthropic's reply text is read (\(result))")
        assert(sent?.path == "/v1/messages" && sent?.headers["x-api-key"] == "sk-test"
               && sent?.headers["anthropic-version"] == "2023-06-01" && body?["model"] as? String == "claude-test"
               && body?["max_tokens"] as? Int == 300 && body?["system"] as? String == "system text"
               && content.count == 2 && content[0]["type"] as? String == "image" && source?["media_type"] as? String == "image/jpeg"
               && source?["data"] as? String == image.base64EncodedString() && content[1]["text"] as? String == "describe",
               "a Messages API request carries the key, the version, the system prompt, and the image before the text")
    }

    private static func checkOpenAICompatible(_ server: StandInServer) {
        server.reply = (200, #"{"id":"c1","choices":[{"index":0,"message":{"role":"assistant","content":"你好"},"finish_reason":"stop"}]}"#)
        var configuration = LLMConfiguration(kind: .openAICompatible, baseURL: "http://127.0.0.1:\(server.port)/v1/",
                                             model: "qwen-test")
        let image = Data([0xFF, 0xD8, 0x07])
        let result = complete(LLMRequest(system: "sys", prompt: "hi", images: [image]), configuration, key: "key-1")
        let sent = server.last
        let body = sent.flatMap { (try? JSONSerialization.jsonObject(with: $0.body)) as? [String: Any] }
        let messages = body?["messages"] as? [[String: Any]] ?? []
        let parts = messages.last?["content"] as? [[String: Any]] ?? []
        assert(result == .success("你好") && sent?.path == "/v1/chat/completions" && sent?.headers["authorization"] == "Bearer key-1"
               && messages.first?["role"] as? String == "system" && messages.first?["content"] as? String == "sys"
               && parts.first?["type"] as? String == "text" && parts.first?["text"] as? String == "hi"
               && (parts.last?["image_url"] as? [String: Any])?["url"] as? String == "data:image/jpeg;base64," + image.base64EncodedString(),
               "an OpenAI-compatible request carries a bearer key, a system message, and the image as a data URL")
        // text alone is plain content; a service on this Mac needs no key
        _ = complete(LLMRequest(system: "sys", prompt: "just text"), configuration, key: nil)
        let plain = server.last
        let plainBody = plain.flatMap { (try? JSONSerialization.jsonObject(with: $0.body)) as? [String: Any] }
        assert(((plainBody?["messages"] as? [[String: Any]])?.last?["content"] as? String) == "just text"
               && plain?.headers["authorization"] == nil, "text-only requests send plain content, and local ones no key")
        configuration.baseURL = "https://api.example.com/v1"
        assert(configuration.needsKey && complete(LLMRequest(system: "", prompt: "x"), configuration, key: " ") == .failure(.missingKey),
               "a remote service without a key isn't asked")
    }

    private static func checkErrors(_ server: StandInServer) {
        let anthropic = LLMConfiguration(kind: .anthropic, baseURL: "http://127.0.0.1:\(server.port)", model: "m")
        server.reply = (401, #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#)
        assert(complete(LLMRequest(system: "", prompt: "x"), anthropic, key: "bad") == .failure(.http(status: 401, message: "invalid x-api-key")),
               "a rejected key comes back as the service's message")
        server.reply = (500, "Internal trouble")
        assert(complete(LLMRequest(system: "", prompt: "x"), anthropic, key: "k") == .failure(.http(status: 500, message: "Internal trouble")),
               "a failure without JSON keeps the body")
        server.reply = (200, #"{"content":[]}"#)
        assert(complete(LLMRequest(system: "", prompt: "x"), anthropic, key: "k") == .failure(.malformed), "an empty reply is malformed")
        let requests = server.count
        var textOnly = LLMConfiguration(kind: .openAICompatible, baseURL: "http://127.0.0.1:\(server.port)/v1", model: "deepseek-chat")
        textOnly.acceptsImages = false
        assert(complete(LLMRequest(system: "", prompt: "x", images: [Data([1])]), textOnly, key: nil) == .failure(.imagesNotSupported)
               && server.count == requests, "a text-only model isn't sent images")
        assert(complete(LLMRequest(system: "", prompt: "x"), anthropic, key: nil) == .failure(.missingKey), "Anthropic needs a key")
        let closed = LLMConfiguration(kind: .openAICompatible, baseURL: "http://127.0.0.1:1/v1", model: "m")
        if case .failure(.network) = complete(LLMRequest(system: "", prompt: "x"), closed, key: nil) {} else {
            assertionFailure("an unreachable service is a network error")
        }
    }

    private static func checkParsing() {
        let fenced = LLMClient.jsonObject(in: "Here you go:\n```json\n{\"keywords\": [\"sea\", \"sky\"]}\n```")
        assert((fenced?["keywords"] as? [String]) == ["sea", "sky"], "JSON is found inside a code fence and prose")
        assert(LLMClient.jsonObject(in: "no json here") == nil, "and not invented where there's none")
        let quoted = LLMClient.jsonObject(in: "{'title': 'woman', 'keywords': ['umbrella', 'sky']}")
        assert(quoted?["title"] as? String == "woman" && (quoted?["keywords"] as? [String]) == ["umbrella", "sky"],
               "single-quoted JSON from smaller models is read")
        let cut = LLMClient.jsonObject(in: #"{"title": "海边", "keywords": ["海", "沙滩", "日落", "云"#)
        assert(cut?["title"] as? String == "海边" && (cut?["keywords"] as? [String]) == ["海", "沙滩", "日落"],
               "a reply cut off by the token limit keeps what came through whole")
        assert(LLMConfiguration(kind: .anthropic, baseURL: "https://api.anthropic.com/", model: "m").endpoint?.absoluteString
               == "https://api.anthropic.com/v1/messages"
               && LLMConfiguration(kind: .anthropic, baseURL: "https://proxy.example.com/v1", model: "m").endpoint?.absoluteString
               == "https://proxy.example.com/v1/messages"
               && LLMConfiguration(kind: .openAICompatible, baseURL: "ftp://x", model: "m").endpoint == nil,
               "endpoints are built from the service address")
    }
}

extension LLMCheck {
    @MainActor
    static func checkDescribe(_ server: StandInServer) {
        // the request: the image, the language, and what the catalog knows
        let image = Data([0xFF, 0xD8, 0x42])
        let chinese = PhotoDescriber.request(image: image, details: PhotoDescriber.Details(camera: "Canon EOS R6m2", place: "成都",
                                                                                          keywords: ["夜景"]), chinese: true)
        assert(chinese.images == [image] && chinese.system.contains("Simplified Chinese") && chinese.prompt.contains("成都")
               && chinese.prompt.contains("夜景") && chinese.prompt.contains("Canon"),
               "a describe request shows the photo, asks for the app's language and passes on what's known")
        assert(PhotoDescriber.request(image: image, details: .init(), chinese: false).system.contains("English"), "or English")

        // the answer: found in prose, keywords as a list or a comma string, tidied
        let reply = "好的：\n```json\n{\"title\": \" 锦江夜色 \", \"caption\": \"夜晚河边的灯笼与游船。\", \"keywords\": [\"夜景\", \"灯笼\", \"灯笼\", \"河流\", \"\"]}\n```"
        let parsed = PhotoDescriber.parse(reply)
        assert(parsed == PhotoDescriber.Description(title: "锦江夜色", caption: "夜晚河边的灯笼与游船。", keywords: ["夜景", "灯笼", "河流"]),
               "a description is read from the reply and tidied (\(String(describing: parsed)))")
        assert(PhotoDescriber.parse(#"{"keywords": "sea, sky, sunset"}"#)?.keywords == ["sea", "sky", "sunset"],
               "keywords given as one string are split")
        assert(PhotoDescriber.parse(#"{"keywords": ["gymnastics", "Canon EOS R6m2"]}"#, excluding: ["Canon EOS R6m2"])?.keywords
               == ["gymnastics"], "the camera passed as a hint doesn't come back as a keyword")
        assert(PhotoDescriber.parse("I can't see an image.") == nil && PhotoDescriber.parse(#"{"title": ""}"#) == nil,
               "no description is made up from an empty answer")

        // into the catalog: keywords added, titles and captions kept unless replacing
        let app = AppState.selfCheckFixture()
        app.assets = Array(DemoData.assets.prefix(2)).map { demo in
            var photo = demo
            photo.isDemo = false
            photo.localPath = "/tmp/pc-describe/\(demo.filename)"
            return photo
        }
        guard app.assets.count >= 2 else { return assertionFailure("the fixture has photos") }
        let first = app.assets[0].id, second = app.assets[1].id
        _ = app.mutate([first, second]) { asset in
            asset.keywords = ["旧"]
            asset.title = asset.id == first ? "" : "原来的标题"
            asset.caption = ""
        }
        let described = PhotoDescriber.Description(title: "新标题", caption: "新说明", keywords: ["旧", "海"])
        var options = AppState.DescribeOptions()
        let changed = app.applyDescriptions([first: described, second: described], options: options)
        func asset(_ id: String) -> Asset { app.assets.first { $0.id == id }! }
        assert(changed == 2 && asset(first).keywords == ["旧", "海"] && asset(first).title == "新标题"
               && asset(second).title == "原来的标题" && asset(second).caption == "新说明",
               "descriptions add keywords and fill empty titles and captions, keeping the ones there")
        options.replace = true
        options.keywords = false
        app.applyDescriptions([second: PhotoDescriber.Description(title: "替换", caption: "", keywords: ["不加"])], options: options)
        assert(asset(second).title == "替换" && asset(second).caption == "新说明" && !asset(second).keywords.contains("不加"),
               "replacing swaps titles, leaves what the model didn't give, and adds no keywords when they're off")
    }
}

/// A one-request-per-connection HTTP server on 127.0.0.1 that records what it's sent and
/// answers with `reply`.
final class StandInServer: @unchecked Sendable {
    struct Request {
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "PhotoCatalog.standin")
    private let lock = NSLock()
    private var requests: [Request] = []
    private var answer: (status: Int, body: String) = (200, "{}")
    private(set) var port: UInt16 = 0

    var reply: (status: Int, body: String) {
        get { lock.withLock { answer } }
        set { lock.withLock { answer = newValue } }
    }
    var last: Request? { lock.withLock { requests.last } }
    var count: Int { lock.withLock { requests.count } }

    init?() {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: parameters) else { return nil }
        self.listener = listener
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let bound = listener.port?.rawValue, bound != 0 else { return nil }
        port = bound
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                self.lock.withLock { self.requests.append(request) }
                let (status, body) = self.reply
                let payload = Data(body.utf8)
                let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: application/json\r\n"
                    + "Content-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in connection.cancel() })
            } else if complete || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    /// The request in `data` once all of it has arrived.
    private static func parse(_ data: Data) -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[end.upperBound...]
        guard body.count >= length, requestLine.count >= 2 else { return nil }
        return Request(path: String(requestLine[1]), headers: headers, body: Data(body.prefix(length)))
    }
}
