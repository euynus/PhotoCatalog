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
            checkDescribe()
            checkSearch(server)
            checkDevelopByText(server)
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
    static func checkDescribe() {
        // Optional metadata still reaches the prompt when no capture date is available.
        let image = Data([0xFF, 0xD8, 0x42])
        let chinese = PhotoDescriber.request(image: image, details: PhotoDescriber.Details(camera: "Canon EOS R6m2", place: "成都",
                                                                                          keywords: ["夜景"]), chinese: true, includeMetadata: true)
        assert(chinese.prompt.contains("place: 成都") && chinese.prompt.contains("existing keywords: 夜景")
               && chinese.prompt.contains("camera: Canon EOS R6m2"),
               "a describe request retains Unicode metadata even without a capture date")

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
    }
}

extension LLMCheck {
    /// Runs `body` on the main actor, turning the run loop until it's done.
    @MainActor
    static func run<T>(_ body: @escaping @MainActor () async -> T) -> T {
        var result: T?
        Task { @MainActor in result = await body() }
        while result == nil { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
        return result!
    }

    @MainActor
    static func checkSearch(_ server: StandInServer) {
        let vocabulary = PhotoSearch.Vocabulary(cameras: ["Canon EOS R6m2"], lenses: ["RF24-105mm F4-7.1 IS STM"],
                                                keywords: ["海边", "日落"], types: ["CR3", "JPG"])
        let today = ISO8601DateFormatter().date(from: "2026-09-30T12:00:00Z")!
        let request = PhotoSearch.request("去年夏天在海边拍的四星照片", today: today, vocabulary: vocabulary, chinese: true)
        assert(request.images.isEmpty && request.prompt.contains("去年夏天在海边拍的四星照片") && request.system.contains("2026-09-30")
               && request.prompt.contains("Canon EOS R6m2") && request.prompt.contains("海边") && request.system.contains("Simplified Chinese"),
               "a search request carries the sentence, today's date and the catalog's own names, and no photo")

        let full = PhotoSearch.parse(#"""
        {"text": "海边", "minRating": 4, "flag": "pick", "color": "blue", "type": "cr3", "camera": "Canon EOS R6m2",
         "dateStart": "2025-06-01", "dateEnd": "2025-08-31", "gps": "yes"}
        """#, vocabulary: vocabulary, query: "去年夏天用佳能拍的、带位置的蓝色标签精选 CR3，四星以上的海边")
        let f = full?.filters
        let calendar = Calendar.captureWallClock
        assert(full?.text == "海边" && f?.minRating == 4 && f?.flag == "pick" && f?.color == "blue" && f?.type == "CR3"
               && f?.camera == "Canon EOS R6m2" && f?.date == "custom" && f?.gps == "yes"
               && f?.dateStart.map { calendar.dateComponents([.year, .month, .day], from: $0) } == DateComponents(year: 2025, month: 6, day: 1)
               && f?.dateEnd.map { calendar.dateComponents([.year, .month, .day], from: $0) } == DateComponents(year: 2025, month: 8, day: 31),
               "every filter the model names is set (\(String(describing: full)))")
        let odd = PhotoSearch.parse(#"{"minRating": 9, "flag": "maybe", "color": "pink", "type": "WEIRD", "gps": "sometimes"}"#,
                                    vocabulary: vocabulary, query: "9星以上 flag pink label WEIRD 格式 位置")
        assert(odd?.filters.minRating == 5 && odd?.filters.flag == "any" && odd?.filters.color == "any" && odd?.filters.type == "any"
               && odd?.filters.gps == "any" && odd?.filters.date == "any",
               "values the filter bar doesn't know are left out, and ratings kept within five")
        // what smaller models do: every field filled in from the catalog's lists
        let eager = PhotoSearch.parse(#"""
        {"text": "人像", "minRating": 1, "flag": "pick", "color": "red", "type": "CR3", "camera": "Canon EOS R6m2",
         "lens": "RF24-70mm F2.8 L IS USM", "dateStart": "2025-03-01", "dateEnd": "2025-09-30", "gps": "yes"}
        """#, vocabulary: vocabulary, query: "人像照片")
        assert(eager == PhotoSearch.Interpretation(filters: Filters(), text: "人像"),
               "filters the sentence says nothing about are dropped (\(String(describing: eager)))")
        let lookalikes = PhotoSearch.parse(#"{"text": "红叶", "color": "red", "minRating": 3, "dateStart": "2025-09-01"}"#,
                                           vocabulary: vocabulary, query: "星空下的红叶和waterfall")
        assert(lookalikes == PhotoSearch.Interpretation(filters: Filters(), text: "红叶"),
               "red leaves aren't a red label, a starry sky isn't a rating, and a waterfall isn't autumn")
        let restated = PhotoSearch.parse(#"{"text": "精选", "flag": "pick", "gps": "yes"}"#, vocabulary: vocabulary, query: "带位置的精选")
        let summer = PhotoSearch.parse(#"{"text": "去年夏天", "dateStart": "2025-06-01", "dateEnd": "2025-08-31"}"#,
                                       vocabulary: vocabulary, query: "去年夏天拍的")
        assert(restated?.text == "" && restated?.filters.flag == "pick" && summer?.text == "" && summer?.filters.date == "custom"
               && PhotoSearch.parse(#"{"text": "海边的日落", "flag": "pick"}"#, vocabulary: vocabulary, query: "精选的海边日落")?.text == "海边的日落"
               && PhotoSearch.parse(#"{"text": "夏天"}"#, vocabulary: vocabulary, query: "夏天")?.text == "夏天",
               "search words that only restate the filters are dropped; words about the photos, or the only words there are, stay")
        let misplaced = PhotoSearch.parse(#"{"text": "红色标签"}"#, vocabulary: vocabulary, query: "红色标签的照片")
        assert(misplaced == PhotoSearch.Interpretation(filters: Filters(color: "red"), text: "")
               && PhotoSearch.parse(#"{"text": "精选"}"#, vocabulary: vocabulary, query: "精选")?.filters.flag == "pick"
               && PhotoSearch.parse(#"{"text": "red"}"#, vocabulary: vocabulary, query: "red flowers")?.text == "red",
               "a flag or label put in the search words becomes that filter; a color alone stays a search word")
        // a camera or lens has to be one the catalog has, or the filter finds nothing
        let gear = PhotoSearch.Vocabulary(cameras: ["Canon EOS R6m2", "Canon EOS R5", "SONY ILCE-7M4"],
                                          lenses: ["RF24-70mm F2.8 L IS USM", "RF50mm F1.8 STM"], types: ["CR3"])
        func camera(_ name: String, _ query: String) -> String? {
            PhotoSearch.parse(#"{"camera": "\#(name)"}"#, vocabulary: gear, query: query)?.filters.camera
        }
        func lens(_ name: String, _ query: String) -> String? {
            PhotoSearch.parse(#"{"lens": "\#(name)"}"#, vocabulary: gear, query: query)?.filters.lens
        }
        assert(lens("RF24-70mm F2.8 L IS USM", "用 24-70 拍的") == "RF24-70mm F2.8 L IS USM" && camera("R6m2", "R6m2 拍的") == "R6m2"
               && camera("Canon", "佳能拍的") == "Canon", "a lens named by its focal lengths counts, and so does part of a camera's name")
        assert(lens("RF 24-70mm f/2.8L IS USM", "用24-70拍的") == "RF24-70mm F2.8 L IS USM"
               && camera("Sony ILCE 7M4", "索尼拍的") == "SONY ILCE-7M4",
               "a name spelled differently becomes the catalog's spelling")
        assert(lens("EF 24-70mm f/2.8L II USM", "用24-70拍的") == "RF24-70mm F2.8 L IS USM"
               && lens("EF50mm f/1.4 USM", "50mm 拍的") == "RF50mm F1.8 STM"
               && camera("Canon EOS R8", "用佳能拍的") == "canon" && camera("Canon EOS R6 Mark II", "佳能 R6m2") == "Canon EOS R6m2",
               "a made-up name gives way to what the sentence names: the one camera or lens it fits, or the word they share")
        assert(camera("Nikon Z8", "尼康拍的") == "" && lens("RF100mm F2.8 L Macro", "100mm 微距") == "",
               "a camera or lens the catalog doesn't have filters nothing")

        // the whole of it, against the stand-in: the filter bar and the search box end up set
        let saved = UserDefaults.standard.data(forKey: "pc_llm")
        defer { UserDefaults.standard.set(saved, forKey: "pc_llm") }
        let app = AppState.selfCheckFixture()
        app.assets = Array(DemoData.assets.prefix(40))
        app.llmConfiguration = LLMConfiguration(kind: .openAICompatible, baseURL: "http://127.0.0.1:\(server.port)/v1", model: "stand-in")
        server.reply = (200, #"{"choices":[{"message":{"content":"{\"minRating\": 3, \"text\": \"海\"}"}}]}"#)
        let understood = run { await app.searchNaturally("三星以上的海") }
        assert(understood && app.filters.minRating == 3 && app.search == "海" && app.naturalSearchQuery == "三星以上的海",
               "a sentence becomes the filter bar and the search box")
        server.reply = (200, #"{"choices":[{"message":{"content":"Sorry, I can't help with that."}}]}"#)
        assert(!run { await app.searchNaturally("随便") } && app.filters.minRating == 3, "an answer without filters changes nothing")
    }
}

extension LLMCheck {
    @MainActor
    static func checkDevelopByText(_ server: StandInServer) {
        var current = DevelopSettings()
        current.exposure = 0.3
        current.contrast = 10
        let image = Data([0xFF, 0xD8, 9])
        let asShot = DevelopByText.AsShot(temperature: 5200, tint: 4)
        let raw = DevelopByText.request("暖一点的胶片感", settings: current, isRaw: true, asShot: asShot, image: image, chinese: true)
        assert(raw.images == [image] && raw.system.contains("Kelvin") && raw.prompt.contains("temperature: 5200 K")
               && raw.prompt.contains("tint: 4") && raw.prompt.contains("exposure: 0.30") && raw.prompt.contains("contrast: 10")
               && raw.prompt.contains("暖一点的胶片感") && raw.system.contains("Simplified Chinese"),
               "a look request carries the photo, its current values — a RAW's as-shot white balance in Kelvin among them")
        assert(DevelopByText.request("x", settings: current, isRaw: false, image: nil, chinese: false).images.isEmpty,
               "and no image when there's none")

        let look = DevelopByText.parse(#"""
        {"exposure": 9, "grain": -5, "shadow": "25", "temperature": 15000, "tint": 12,
         "grading": {"shadows": {"hue": 400, "saturation": 150}}, "explanation": "更暖、更有颗粒"}
        """#, onto: current, isRaw: true)
        assert(look?.settings.exposure == 5 && look?.settings.grain == 0 && look?.settings.shadows == 25
               && look?.settings.temperature == 12000 && look?.settings.tint == 12 && look?.settings.contrast == 10
               && look?.settings.grading.shadows.hue == 40 && look?.settings.grading.shadows.saturation == 100
               && look?.explanation == "更暖、更有颗粒",
               "every value is kept within its slider, a slider named in the singular counts, and untouched sliders keep theirs (\(String(describing: look?.settings)))")
        assert(DevelopByText.parse(#"{"temperature": 150}"#, onto: current, isRaw: false)?.settings.temperature == 100,
               "white balance for other files stays on its relative scale")
        assert(DevelopByText.parse(#"{"explanation": "nothing to do"}"#, onto: current, isRaw: false) == nil,
               "a reply that sets nothing changes nothing")
        // smaller models repeat every current value, white balance included
        assert(DevelopByText.parse(#"{"exposure": 0.3, "contrast": 10, "clarity": 0, "temperature": 5200, "tint": 4, "explanation": "更暖"}"#,
                                   onto: current, isRaw: true, asShot: asShot) == nil,
               "a reply that only repeats the current values changes nothing, and says so")
        let warmer = DevelopByText.parse(#"{"exposure": 0.3, "temperature": 5700, "tint": 4}"#, onto: current, isRaw: true, asShot: asShot)
        assert(warmer?.settings.temperature == 5700 && warmer?.settings.tint == nil,
               "a repeated as-shot tint stays as shot beside a changed temperature")

        // the whole of it, against the stand-in: the photo in Develop takes the look
        let saved = UserDefaults.standard.data(forKey: "pc_llm")
        defer { UserDefaults.standard.set(saved, forKey: "pc_llm") }
        let app = AppState.selfCheckFixture()
        guard var photo = DemoData.assets.first(where: { !$0.isRaw }) ?? DemoData.assets.first else { return }
        photo.isDemo = false
        photo.localPath = "/tmp/pc-look/\(photo.filename)"
        photo.status = .ready
        app.assets = [photo]
        app.setPrimary(photo.id)
        app.view = .develop
        var configuration = LLMConfiguration(kind: .openAICompatible, baseURL: "http://127.0.0.1:\(server.port)/v1", model: "stand-in")
        configuration.acceptsImages = false
        app.llmConfiguration = configuration
        server.reply = (200, #"{"choices":[{"message":{"content":"{\"exposure\": 0.5, \"vibrance\": 20, \"explanation\": \"提亮一点\"}"}}]}"#)
        let done = run { await app.developByText("提亮一点") }
        let settings = app.developSettings[photo.id]
        assert(done && settings?.exposure == 0.5 && settings?.vibrance == 20 && app.developByTextQuery == "提亮一点",
               "a described look is applied to the photo in Develop (\(String(describing: settings)))")

        // a photo goes to a service off this Mac only once the user agrees, asked once per service
        let savedConsent = UserDefaults.standard.object(forKey: "pc_developByTextConsent")
        defer { UserDefaults.standard.set(savedConsent, forKey: "pc_developByTextConsent") }
        UserDefaults.standard.removeObject(forKey: "pc_developByTextConsent")
        var asked: [String] = []
        app.confirmSendingPhoto = { _, endpoint in asked.append(endpoint); return endpoint.contains("agreed") }
        var remote = LLMConfiguration(kind: .openAICompatible, baseURL: "https://agreed.example/v1", model: "m")
        remote.acceptsImages = true
        app.llmConfiguration = remote
        assert(app.mayDevelopByTextSendPhoto() && app.mayDevelopByTextSendPhoto() && asked.count == 1,
               "a service off this Mac is asked about once (\(asked))")
        remote.baseURL = "https://declined.example/v1"
        app.llmConfiguration = remote
        assert(!app.mayDevelopByTextSendPhoto() && !app.mayDevelopByTextSendPhoto() && asked.count == 3,
               "a declined service gets nothing, and is asked again next time")
        configuration.acceptsImages = true
        app.llmConfiguration = configuration
        assert(app.mayDevelopByTextSendPhoto() && asked.count == 3, "a service on this Mac isn't asked")
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
