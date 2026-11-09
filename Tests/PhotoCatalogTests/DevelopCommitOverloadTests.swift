import XCTest
@testable import PhotoCatalog

/// The one-photo `commitDevelop` commits like the dictionary form, and `setSpotMode` keeps the
/// spot mode picker's rules.
final class DevelopCommitOverloadTests: CatalogTestCase {
    private var undo: UndoManager!

    override func tearDown() {
        undo = nil
        super.tearDown()
    }

    @MainActor
    private func makeApp() throws -> (AppState, CatalogStore) {
        let store = try CatalogStore(packageURL: scratch.appendingPathComponent("Commit.photolibrary"))
        let app = AppState.selfCheckFixture(store: store)
        undo = UndoManager()
        undo.groupsByEvent = false   // no run loop here to close event groups
        app.undoManager = undo
        return (app, store)
    }

    @MainActor
    private func step(_ action: () -> Void) {
        undo.beginUndoGrouping()
        action()
        undo.endUndoGrouping()
    }

    // ---- the overload ----
    @MainActor
    func testTheOverloadCommitsLikeTheDictionaryForm() throws {
        let (app, store) = try makeApp()
        var start = DevelopSettings()
        start.exposure = 0.5
        step { app.commitDevelop(["one": start, "two": start], undoName: "粘贴设置") }

        // a drag under way on each photo: both forms build on the saved settings and drop it
        for id in ["one", "two"] {
            var dragging = start
            dragging.contrast = 60
            app.updateDevelopDraft(dragging, for: id)
            if id == "one" {
                step { app.commitDevelop("one", undoName: "复位色温") { $0.temperature = 300 } }
            } else {
                var next = app.developSettings["two"] ?? .neutral
                next.temperature = 300
                step { app.commitDevelop(["two": next], undoName: "复位色温") }
            }
            XCTAssertNil(app.developDraft)
            XCTAssertEqual(undo.undoActionName, "复位色温")
        }

        var expected = start
        expected.temperature = 300
        XCTAssertEqual(app.developSettings["one"], expected, "the saved settings changed, not the draft")
        XCTAssertEqual(app.developSettings["one"], app.developSettings["two"])
        XCTAssertEqual(try store.loadDevelopHistory("one").map(\.name), try store.loadDevelopHistory("two").map(\.name))
        XCTAssertEqual(try store.loadDevelopSettings()["one"], expected)

        undo.undo()
        undo.undo()
        XCTAssertEqual(app.developSettings["one"], start)
        XCTAssertEqual(app.developSettings["two"], start)
    }

    @MainActor
    func testAnOverloadCommitThatChangesNothingRecordsNothing() throws {
        let (app, store) = try makeApp()
        // outside a group: registering an undo step here would fail the test
        app.commitDevelop("one", undoName: "复位曝光度") { $0.exposure = 0 }
        XCTAssertFalse(undo.canUndo)
        XCTAssertTrue(try store.loadDevelopHistory("one").isEmpty)
        XCTAssertNil(app.developSettings["one"])
    }

    // ---- setSpotMode ----
    private func spot(_ mode: SpotRemoval.Mode, radius: Double = 0.02) -> SpotRemoval {
        var spot = SpotRemoval(target: CGPoint(x: 0.3, y: 0.4), source: CGPoint(x: 0.5, y: 0.4), radius: radius)
        spot.mode = mode
        return spot
    }

    @MainActor
    private func appWithSpots(_ spots: [SpotRemoval]) throws -> (AppState, CatalogStore, Asset) {
        let (app, store) = try makeApp()
        let asset = Asset(id: "photo", pid: 1, ori: "l", thumb: "", preview: "", filename: "photo.jpg", type: "JPG",
                          isRaw: false, folderId: "src", folderName: "Source", date: .now, width: 600, height: 400,
                          orientation: 1, camera: "", lens: "", focal: 0, aperture: 0, shutter: "", iso: 0,
                          colorSpace: "sRGB", fileMB: 0.01, rating: 0, flag: .none, keywords: [], title: "",
                          caption: "", location: "", gps: (0, 0), status: .ready, importedAt: .now,
                          localPath: nil, isDemo: false)
        var settings = DevelopSettings()
        settings.spots = spots
        step { app.commitDevelop([asset.id: settings], undoName: "污点去除") }
        return (app, store, asset)
    }

    @MainActor
    func testHealAndCloneTradePlaces() throws {
        let heal = spot(.heal), clone = spot(.clone)
        let (app, store, asset) = try appWithSpots([heal, clone])
        app.developSelectedSpotId = heal.id

        step { app.setSpotMode(.clone, for: asset) }

        XCTAssertEqual(app.developSettings[asset.id]?.spots.map(\.mode), [.clone, .clone])
        XCTAssertEqual(app.developSpotBrush.mode, .clone)
        XCTAssertEqual(app.developSelectedSpotId, heal.id, "the spot stays selected")
        XCTAssertEqual(undo.undoActionName, "污点模式")
        XCTAssertEqual(try store.loadDevelopHistory(asset.id).last?.name, "污点模式")

        app.developSelectedSpotId = clone.id
        step { app.setSpotMode(.heal, for: asset) }
        XCTAssertEqual(app.developSettings[asset.id]?.spots.map(\.mode), [.clone, .heal])
        XCTAssertEqual(app.developSpotBrush.mode, .heal)
    }

    @MainActor
    func testARemoveSpotIsNotSwitchedAndDeselects() throws {
        let remove = spot(.remove)
        let (app, store, asset) = try appWithSpots([remove])
        app.developSelectedSpotId = remove.id

        step { app.setSpotMode(.clone, for: asset) }

        XCTAssertEqual(app.developSettings[asset.id]?.spots.map(\.mode), [.remove], "remove spots are painted")
        XCTAssertNil(app.developSelectedSpotId)
        XCTAssertEqual(app.developSpotBrush.mode, .clone, "the next spot is made in the new mode")
        XCTAssertEqual(try store.loadDevelopHistory(asset.id).count, 1, "nothing committed")
    }

    @MainActor
    func testChoosingRemoveDeselectsWithoutCommitting() throws {
        let heal = spot(.heal)
        let (app, store, asset) = try appWithSpots([heal])
        app.developSelectedSpotId = heal.id

        step { app.setSpotMode(.remove, for: asset) }

        XCTAssertEqual(app.developSettings[asset.id]?.spots.map(\.mode), [.heal])
        XCTAssertNil(app.developSelectedSpotId)
        XCTAssertEqual(app.developSpotBrush.mode, .remove)
        XCTAssertEqual(try store.loadDevelopHistory(asset.id).count, 1)
    }

    @MainActor
    func testWithNoSpotSelectedOnlyTheBrushChanges() throws {
        let (app, store, asset) = try appWithSpots([spot(.heal)])
        app.developSelectedSpotId = nil

        app.setSpotMode(.clone, for: asset)

        XCTAssertEqual(app.developSpotBrush.mode, .clone)
        XCTAssertEqual(app.developSettings[asset.id]?.spots.map(\.mode), [.heal])
        XCTAssertEqual(try store.loadDevelopHistory(asset.id).count, 1)
    }

    @MainActor
    func testAStaleIndexCommitsNothing() throws {
        let saved = spot(.heal), drawn = spot(.heal)
        let (app, store, asset) = try appWithSpots([saved])
        // a spot only the draft has yet: its index is past the saved spots
        var dragging = app.developSettings(for: asset.id)
        dragging.spots.append(drawn)
        app.updateDevelopDraft(dragging, for: asset.id)
        app.developSelectedSpotId = drawn.id

        app.setSpotMode(.clone, for: asset)

        XCTAssertEqual(app.developSettings[asset.id]?.spots.map(\.id), [saved.id])
        XCTAssertEqual(app.developDraft?.settings, dragging, "the drag carries on")
        XCTAssertEqual(app.developSpotBrush.mode, .clone)
        XCTAssertEqual(try store.loadDevelopHistory(asset.id).count, 1)
    }

    @MainActor
    func testTheModeIsReadFromTheDraftAndCommittedToTheSavedSettings() throws {
        let heal = spot(.heal, radius: 0.02)
        let (app, _, asset) = try appWithSpots([heal])
        app.developSelectedSpotId = heal.id
        // mid-drag, the spot is bigger in the draft than in the saved settings
        var dragging = app.developSettings(for: asset.id)
        dragging.spots[0].radius = 0.05
        app.updateDevelopDraft(dragging, for: asset.id)

        step { app.setSpotMode(.clone, for: asset) }

        let spots = try XCTUnwrap(app.developSettings[asset.id]?.spots)
        XCTAssertEqual(spots.map(\.mode), [.clone])
        XCTAssertEqual(spots.first?.radius, 0.02, "the saved spot switched, without the draft's size")
        XCTAssertNil(app.developDraft, "a commit of the photo ends its drag, as before")

        // a spot that is remove in the draft is left alone even when the saved one isn't
        var removing = app.developSettings(for: asset.id)
        removing.spots[0].mode = .remove
        app.updateDevelopDraft(removing, for: asset.id)
        app.setSpotMode(.heal, for: asset)
        XCTAssertEqual(app.developSettings[asset.id]?.spots.map(\.mode), [.clone])
        XCTAssertNil(app.developSelectedSpotId)
    }
}
