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

    /// ⌘-clicking the active photo off the selection left it active: the inspector showed it while
    /// edits went to the photos still selected.
    @MainActor
    func testCommandClickingTheActivePhotoOffHandsOverToAnotherSelectedOne() throws {
        let app = makeApp()
        let ids = app.list.map(\.id)
        app.selectCell(ids[1], shift: false, meta: false)
        app.selectCell(ids[3], shift: false, meta: true)
        app.selectCell(ids[5], shift: false, meta: true)
        XCTAssertEqual(app.primaryId, ids[5])

        app.selectCell(ids[5], shift: false, meta: true)
        XCTAssertEqual(app.selectedIds, [ids[1], ids[3]])
        XCTAssertEqual(app.primaryId, ids[3], "the nearest photo still selected becomes active")

        app.selectCell(ids[1], shift: false, meta: true)
        XCTAssertEqual(app.selectedIds, [ids[3]])
        XCTAssertEqual(app.primaryId, ids[3], "⌘-clicking another photo off leaves the active one")

        app.selectCell(ids[3], shift: false, meta: true)
        XCTAssertTrue(app.selectedIds.isEmpty)
        XCTAssertNil(app.primaryId, "with nothing selected nothing is active")
        XCTAssertFalse(app.handleKey("5", hasCommand: false))
        XCTAssertTrue(app.assets.allSatisfy { $0.rating == 0 }, "a rating key then rates nothing")
    }

    /// In 未评分, rating the active photo in Survey takes it out of the list though Survey still
    /// shows it: the first photo of the list, not one of the surveyed, became active, and the next
    /// key edited it out of sight.
    @MainActor
    func testSurveyKeepsItsActivePhotoWhenARatingFiltersItOut() throws {
        let app = makeApp()
        app.select(Selection(type: .lib, id: "unrated", name: "Unrated"))
        let ids = app.list.map(\.id)
        app.selectCell(ids[2], shift: false, meta: false)
        app.selectCell(ids[3], shift: false, meta: true)
        app.selectCell(ids[4], shift: false, meta: true)
        app.switchView(.survey)
        XCTAssertEqual(app.view, .survey)
        let surveyed = Set(app.surveyIds)
        XCTAssertEqual(surveyed, [ids[2], ids[3], ids[4]])
        app.activateInSurvey(ids[3])

        XCTAssertTrue(app.handleKey("3", hasCommand: false))
        XCTAssertFalse(app.list.contains { $0.id == ids[3] }, "rated, it left 未评分")
        XCTAssertEqual(app.primaryId, ids[3], "Survey still shows it, and it stays active")
        XCTAssertEqual(app.selectedIds, [ids[3]])
        XCTAssertTrue(app.handleKey("p", hasCommand: false))
        XCTAssertEqual(app.asset(id: ids[3])?.flag, .pick)
        for asset in app.assets where !surveyed.contains(asset.id) {
            XCTAssertEqual(asset.rating, 0, "\(asset.id) isn't in the survey")
            XCTAssertEqual(asset.flag, .none, "\(asset.id) isn't in the survey")
        }

        app.switchView(.grid)
        XCTAssertEqual(app.selectedIds, [ids[2], ids[4]], "back in the grid, only the photos it shows are selected")
        XCTAssertTrue(app.selectedIds.contains(app.primaryId ?? ""))
    }
}
