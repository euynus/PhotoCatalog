import XCTest
@testable import PhotoCatalog

/// The keys that edit photos act on the selection; these keep it to photos the user can see.
final class SelectionSafetyTests: XCTestCase {
    /// Demo photos, unrated and unflagged, in a fixture that never opens a catalog.
    @MainActor
    private func makeApp(count: Int = 8, _ configure: (inout Asset) -> Void = { _ in }) -> AppState {
        let app = AppState.selfCheckFixture()
        app.assets = DemoData.assets.prefix(count).map {
            var asset = $0
            asset.rating = 0
            asset.flag = .none
            asset.colorLabel = nil
            configure(&asset)
            return asset
        }
        app.select(Selection(type: .lib, id: "all", name: "Selection safety"))
        return app
    }

    /// Duplicate review and the Places map stand in for the grid, the selection out of sight
    /// behind them: rating, flag and color keys edited photos nobody was looking at.
    @MainActor
    func testReviewKeysDoNothingWhereTheSelectionIsNotShown() throws {
        for library in ["duplicates", "places"] {
            let app = makeApp { $0.gps = (31.23, 121.47) }
            app.select(Selection(type: .lib, id: library, name: library))
            let id = try XCTUnwrap(app.primaryId, "\(library) keeps a selection behind its own view")
            XCTAssertFalse(app.showsSelection, library)
            for key in ["5", "x", "6", "b", "right"] {
                XCTAssertFalse(app.handleKey(key, hasCommand: false), "\(key) in \(library)")
            }
            let asset = try XCTUnwrap(app.asset(id: id))
            XCTAssertEqual(asset.rating, 0, library)
            XCTAssertEqual(asset.flag, .none, library)
            XCTAssertNil(asset.colorLabel, library)
            XCTAssertFalse(app.quickCollection.contains(id), library)
            XCTAssertEqual(app.primaryId, id, "arrows don't move an unseen cursor in \(library)")

            // the photos open in the loupe from there, and the keys apply to the one shown
            app.view = .loupe
            XCTAssertEqual(app.showsSelection, library == "places")
        }
    }
}
