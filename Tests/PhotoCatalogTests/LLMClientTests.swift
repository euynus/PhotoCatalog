import XCTest
@testable import PhotoCatalog

/// What the language-model client sends where: an API key goes only over https or to this Mac,
/// a service elsewhere on plain http is asked without one, and a reply's size is bounded.
final class LLMClientTests: XCTestCase {
    /// Stands in for the service: answers every request with `reply` (and `headers`) and keeps
    /// what was asked.
    final class StubService: URLProtocol {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var asked: [URLRequest] = []
        nonisolated(unsafe) private static var answer = Data()
        nonisolated(unsafe) private static var answerHeaders: [String: String] = [:]

        static var requests: [URLRequest] { lock.withLock { asked } }
        static func reset(reply: Data, headers: [String: String] = [:]) {
            lock.withLock { asked = []; answer = reply; answerHeaders = headers }
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let (reply, headers) = Self.lock.withLock {
                Self.asked.append(request)
                return (Self.answer, Self.answerHeaders)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: headers.merging(["Content-Type": "application/json"]) { $1 })!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubService.self]
        session = URLSession(configuration: configuration)
        StubService.reset(reply: Data(#"{"choices":[{"message":{"role":"assistant","content":"OK"}}]}"#.utf8))
    }

    override func tearDown() {
        session.invalidateAndCancel()
        session = nil
        super.tearDown()
    }

    private func complete(_ configuration: LLMConfiguration, key: String?) async -> Result<String, Error> {
        do {
            return .success(try await LLMClient.complete(LLMRequest(system: "s", prompt: "p"), configuration: configuration,
                                                         key: key, session: session))
        } catch {
            return .failure(error)
        }
    }

    /// A key typed for a service at a plain http address off this Mac never goes out in clear.
    func testKeyIsNotSentInClearToAnotherMachine() async {
        let lan = LLMConfiguration(kind: .openAICompatible, baseURL: "http://192.0.2.1:11434/v1", model: "m")
        let result = await complete(lan, key: "sk-secret")
        let sentKeys = StubService.requests.compactMap { $0.value(forHTTPHeaderField: "authorization") }
        XCTAssertEqual(sentKeys, [], "the key went out over plain http")
        XCTAssertEqual(StubService.requests.count, 0, "nothing is sent")
        if case .success = result { XCTFail("a key that can't be sent safely is an error, not a quiet success") }
        XCTAssertEqual(result.failure as? LLMError, .keyNeedsHTTPS)
        XCTAssertEqual(lan.keyError(for: "sk-secret"), .keyNeedsHTTPS, "the settings say so before anything is asked")
    }

    /// Anthropic always sends its key, so a plain http address off this Mac can't be used at all.
    func testAnthropicAtAPlainHTTPAddressElsewhereSendsNothing() async {
        let proxy = LLMConfiguration(kind: .anthropic, baseURL: "http://192.0.2.1:8080", model: "m")
        let withKey = await complete(proxy, key: "sk-ant")
        let withoutKey = await complete(proxy, key: nil)
        XCTAssertEqual(withKey.failure as? LLMError, .keyNeedsHTTPS)
        XCTAssertEqual(withoutKey.failure as? LLMError, .keyNeedsHTTPS, "not a missing key: one couldn't be sent")
        XCTAssertEqual(StubService.requests.count, 0)
    }

    /// A service on another machine at a plain http address (Ollama on the LAN) is asked without a key.
    func testServiceOnPlainHTTPElsewhereIsAskedWithoutAKey() async throws {
        let lan = LLMConfiguration(kind: .openAICompatible, baseURL: "http://192.0.2.1:11434/v1", model: "m")
        XCTAssertFalse(lan.needsKey, "a key it could never be sent isn't asked for")
        let result = await complete(lan, key: nil)
        XCTAssertEqual(try result.get(), "OK")
        XCTAssertEqual(StubService.requests.count, 1)
        XCTAssertNil(StubService.requests.first?.value(forHTTPHeaderField: "authorization"))
    }

    /// A key still goes to a service on this Mac over http, and to any service over https.
    func testKeyGoesToThisMacOrOverHTTPS() async throws {
        for base in ["http://localhost:11434/v1", "http://127.0.0.1:1234/v1", "http://[::1]:1234/v1", "https://api.example.com/v1"] {
            StubService.reset(reply: Data(#"{"choices":[{"message":{"role":"assistant","content":"OK"}}]}"#.utf8))
            let configuration = LLMConfiguration(kind: .openAICompatible, baseURL: base, model: "m")
            let result = await complete(configuration, key: "sk-1")
            XCTAssertEqual(try result.get(), "OK", base)
            XCTAssertEqual(StubService.requests.first?.value(forHTTPHeaderField: "authorization"), "Bearer sk-1", base)
        }
    }

    /// A reply bigger than any answer could be (16 MB) is refused rather than buffered whole.
    func testOversizeReplyIsRefused() async {
        let text = String(repeating: "x", count: 16 * 1024 * 1024 + 1024)
        StubService.reset(reply: Data(#"{"choices":[{"message":{"role":"assistant","content":""#.utf8) + Data(text.utf8)
                          + Data(#""}}]}"#.utf8))
        let local = LLMConfiguration(kind: .openAICompatible, baseURL: "http://localhost:11434/v1", model: "m")
        let result = await complete(local, key: nil)
        if case .success(let reply) = result { XCTFail("a \(reply.utf8.count)-byte reply was read whole") }
        XCTAssertEqual(result.failure as? LLMError, .replyTooLarge)
    }

    /// One that says up front it's bigger than that isn't read.
    func testReplyDeclaredOversizeIsRefused() async {
        StubService.reset(reply: Data(#"{"choices":[{"message":{"role":"assistant","content":"OK"}}]}"#.utf8),
                          headers: ["Content-Length": "\(LLMClient.replyLimit + 1)"])
        let local = LLMConfiguration(kind: .openAICompatible, baseURL: "http://localhost:11434/v1", model: "m")
        let result = await complete(local, key: nil)
        XCTAssertEqual(result.failure as? LLMError, .replyTooLarge)
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
