import XCTest
@testable import PhotoCatalog

/// 用自然语言查找: the model's reply sets the filter bar and the search box.
final class NaturalSearchTests: XCTestCase {
    private var savedConfiguration: Data?

    override func setUp() {
        super.setUp()
        savedConfiguration = UserDefaults.standard.data(forKey: "pc_llm")
    }

    override func tearDown() {
        if let savedConfiguration {
            UserDefaults.standard.set(savedConfiguration, forKey: "pc_llm")
        } else {
            UserDefaults.standard.removeObject(forKey: "pc_llm")
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
}
