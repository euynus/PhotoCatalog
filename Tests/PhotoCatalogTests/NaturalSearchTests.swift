import XCTest
@testable import PhotoCatalog

/// 用自然语言查找: the model's reply sets the filter bar and the search box.
final class NaturalSearchTests: XCTestCase {
    private var savedConfiguration: Data?

    override func setUp() {
        super.setUp()
        savedConfiguration = UserDefaults.app.data(forKey: "pc_llm")
    }

    override func tearDown() {
        if let savedConfiguration {
            UserDefaults.app.set(savedConfiguration, forKey: "pc_llm")
        } else {
            UserDefaults.app.removeObject(forKey: "pc_llm")
        }
        super.tearDown()
    }

    /// Eight demo photos, every other one rated four stars, and a model that answers `reply`.
    @MainActor
    private func makeApp(reply: @escaping (LLMRequest) async throws -> String) -> AppState {
        let app = AppState.selfCheckFixture()
        app.assets = DemoData.assets.prefix(8).enumerated().map { index, asset in
            var asset = asset
            asset.rating = index.isMultiple(of: 2) ? 4 : 0
            asset.flag = .none
            return asset
        }
        app.select(Selection(type: .lib, id: "all", name: "Natural search"))
        app.llmConfiguration = LLMConfiguration(kind: .openAICompatible, baseURL: "http://127.0.0.1:9/v1", model: "stand-in")
        app.llmOverride = reply
        return app
    }

    /// The search set the filters directly, so photos it hid stayed selected and the next key
    /// edited them out of sight.
    @MainActor
    func testSearchLeavesOnlyPhotosItShowsSelected() async throws {
        let app = makeApp { _ in #"{"minRating": 4}"# }
        XCTAssertTrue(app.selectAllVisible())
        XCTAssertEqual(app.selectedIds.count, 8)

        let understood = await app.searchNaturally("四星以上的照片")
        XCTAssertTrue(understood)
        let shown = Set(app.list.map(\.id))
        XCTAssertEqual(shown.count, 4)
        XCTAssertTrue(app.selectedIds.isSubset(of: shown), "hidden photos left selected: \(app.selectedIds.subtracting(shown))")
        XCTAssertTrue(shown.contains(app.primaryId ?? ""))

        XCTAssertTrue(app.handleKey("x", hasCommand: false))
        let rejected = Set(app.assets.filter { $0.flag == .reject }.map(\.id))
        XCTAssertFalse(rejected.isEmpty)
        XCTAssertTrue(rejected.isSubset(of: shown), "the reject key reached hidden photos: \(rejected.subtracting(shown))")
    }

    /// Cancel only closed the dialog: the reply, arriving later, still set the filters and closed
    /// whatever dialog was up by then.
    @MainActor
    func testCancelledSearchsLateReplyChangesNothing() async throws {
        let reply = HeldReply()
        let app = makeApp { _ in
            await reply.wait()   // a slow service, deaf to cancellation
            return #"{"minRating": 4}"#
        }
        let filters = app.filters
        app.showNaturalSearch()
        app.startNaturalSearch("四星以上的照片")
        try await waitUntil("the request is out") { app.naturalSearchRunning }

        app.sheet = nil            // 取消, or Esc
        app.sheet = "print"        // another dialog, opened while the request was out
        reply.release()
        try await waitUntil("the reply is in") { !app.naturalSearchRunning }
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(app.filters, filters, "a cancelled search changes no filter")
        XCTAssertEqual(app.sheet, "print", "and closes no other dialog")
        XCTAssertTrue(app.toastCenter.toasts.isEmpty, "nor says what it found")
    }

    /// The dialog still closes on the answer to a search left running.
    @MainActor
    func testSearchClosesItsDialogWhenTheAnswerComes() async throws {
        let reply = HeldReply()
        let app = makeApp { _ in
            await reply.wait()
            return #"{"minRating": 4}"#
        }
        app.showNaturalSearch()
        app.startNaturalSearch("四星以上的照片")
        try await waitUntil("the request is out") { app.naturalSearchRunning }
        reply.release()
        try await waitUntil("the dialog closes") { app.sheet == nil }
        XCTAssertEqual(app.filters.minRating, 4)
    }

    @MainActor
    private func waitUntil(_ message: String, condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(message)
    }
}

/// A reply the test lets through when it chooses; waiting ignores cancellation, as a request
/// already on the wire may.
@MainActor
private final class HeldReply {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
