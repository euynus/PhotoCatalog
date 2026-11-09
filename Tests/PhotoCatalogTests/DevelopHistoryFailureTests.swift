import XCTest
@testable import PhotoCatalog

/// A develop history or snapshot write the catalog refuses is reported, and memory keeps what is
/// actually stored. Undoing an edit whose step never stored used to take away the photo's
/// previous, unrelated step, as the store removes a photo's newest step.
final class DevelopHistoryFailureTests: CatalogTestCase {
    private var undo: UndoManager!

    override func tearDown() {
        undo = nil
        super.tearDown()
    }

    @MainActor
    private func makeApp() throws -> (AppState, CatalogStore) {
        let store = try CatalogStore(packageURL: scratch.appendingPathComponent("History.photolibrary"))
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

    /// Makes the catalog refuse `operation` (INSERT or DELETE) on `table`, leaving the rest working.
    private func failing(_ operation: String, on table: String, in store: CatalogStore) throws {
        try store.db.run("""
        CREATE TRIGGER test_fail_\(table)_\(operation.lowercased()) BEFORE \(operation) ON \(table)
        BEGIN SELECT RAISE(ABORT, 'refused by the test'); END;
        """)
    }

    private func settings(exposure: Double = 0, contrast: Double = 0) -> DevelopSettings {
        var settings = DevelopSettings()
        settings.exposure = exposure
        settings.contrast = contrast
        return settings
    }

    @MainActor
    func testUndoingAnEditWhoseStepFailedKeepsTheEarlierStep() throws {
        let (app, store) = try makeApp()
        step { app.commitDevelop(["photo": settings(exposure: 1)], undoName: "调整曝光度") }
        XCTAssertEqual(app.developHistory(for: "photo").map(\.name), ["调整曝光度"])

        try failing("INSERT", on: "develop_history", in: store)
        step { app.commitDevelop(["photo": settings(exposure: 1, contrast: 20)], undoName: "调整对比度") }

        XCTAssertEqual(app.toastCenter.toasts.last?.message, "保存历史记录失败")
        XCTAssertEqual(app.toastCenter.toasts.last?.icon, "warning")
        XCTAssertEqual(app.developSettings["photo"], settings(exposure: 1, contrast: 20), "the settings still saved")
        XCTAssertEqual(try store.loadDevelopSettings()["photo"], settings(exposure: 1, contrast: 20))
        XCTAssertEqual(app.developHistory(for: "photo").map(\.name), ["调整曝光度"], "no step that isn't stored")

        undo.undo()

        XCTAssertEqual(app.developSettings["photo"], settings(exposure: 1))
        XCTAssertEqual(try store.loadDevelopHistory("photo").map(\.name), ["调整曝光度"],
                       "the earlier step is still in the catalog")
        XCTAssertEqual(app.developHistory(for: "photo").map(\.name), ["调整曝光度"])
    }

    @MainActor
    func testRedoStoresItsOwnStepAndUndoTakesItAway() throws {
        let (app, store) = try makeApp()
        step { app.commitDevelop(["photo": settings(exposure: 1)], undoName: "调整曝光度") }
        _ = app.developHistory(for: "photo")
        try failing("INSERT", on: "develop_history", in: store)
        step { app.commitDevelop(["photo": settings(exposure: 2)], undoName: "调整曝光度") }
        undo.undo()
        try store.db.run("DROP TRIGGER test_fail_develop_history_insert;")

        undo.redo()

        XCTAssertEqual(app.developSettings["photo"], settings(exposure: 2))
        XCTAssertEqual(try store.loadDevelopHistory("photo").count, 2, "the redo stored its step this time")
        XCTAssertEqual(app.developHistory(for: "photo").count, 2)

        undo.undo()

        XCTAssertEqual(app.developSettings["photo"], settings(exposure: 1))
        XCTAssertEqual(try store.loadDevelopHistory("photo").count, 1, "undo takes away the step the redo stored")
        XCTAssertEqual(app.developHistory(for: "photo").count, 1)
    }

    @MainActor
    func testAFailedUndoOfAStepKeepsItInMemory() throws {
        let (app, store) = try makeApp()
        step { app.commitDevelop(["photo": settings(exposure: 1)], undoName: "调整曝光度") }
        XCTAssertEqual(app.developHistory(for: "photo").count, 1)
        try failing("DELETE", on: "develop_history", in: store)

        undo.undo()

        XCTAssertEqual(app.toastCenter.toasts.last?.message, "更新历史记录失败")
        XCTAssertEqual(app.toastCenter.toasts.last?.icon, "warning")
        XCTAssertEqual(try store.loadDevelopHistory("photo").count, 1)
        XCTAssertEqual(app.developHistory(for: "photo").count, 1, "memory lists what the catalog still has")
    }

    @MainActor
    func testAFailedClearLeavesTheHistory() throws {
        let (app, store) = try makeApp()
        step { app.commitDevelop(["photo": settings(exposure: 1)], undoName: "调整曝光度") }
        XCTAssertEqual(app.developHistory(for: "photo").count, 1)
        try failing("DELETE", on: "develop_history", in: store)
        let version = app.developRecordsVersion

        app.clearDevelopHistory(for: "photo")

        XCTAssertEqual(app.toastCenter.toasts.last?.message, "清除历史记录失败")
        XCTAssertEqual(app.toastCenter.toasts.last?.icon, "warning")
        XCTAssertEqual(app.developHistory(for: "photo").map(\.name), ["调整曝光度"])
        XCTAssertEqual(try store.loadDevelopHistory("photo").count, 1)
        XCTAssertEqual(app.developRecordsVersion, version, "nothing changed to show")
    }

    @MainActor
    func testAFailedSnapshotDeleteKeepsTheSnapshot() throws {
        let (app, store) = try makeApp()
        step { app.commitDevelop(["photo": settings(exposure: 1)], undoName: "调整曝光度") }
        app.createDevelopSnapshot(for: "photo")
        let snapshot = try XCTUnwrap(app.developSnapshots(for: "photo").first)
        try failing("DELETE", on: "develop_snapshots", in: store)

        app.deleteDevelopSnapshot(snapshot.id, for: "photo")

        XCTAssertEqual(app.toastCenter.toasts.last?.message, "删除快照失败")
        XCTAssertEqual(app.toastCenter.toasts.last?.icon, "warning")
        XCTAssertEqual(app.developSnapshots(for: "photo").map(\.id), [snapshot.id])
        XCTAssertEqual(try store.loadDevelopSnapshots("photo").map(\.id), [snapshot.id])
    }

    @MainActor
    func testWithoutACatalogEveryStepCountsAsStored() throws {
        let app = AppState.selfCheckFixture()
        XCTAssertNil(app.store)
        undo = UndoManager()
        undo.groupsByEvent = false
        app.undoManager = undo
        _ = app.developHistory(for: "photo")   // without a catalog, steps are kept for photos shown
        step { app.commitDevelop(["photo": settings(exposure: 1)], undoName: "调整曝光度") }
        step { app.commitDevelop(["photo": settings(exposure: 2)], undoName: "调整曝光度") }
        XCTAssertEqual(app.developHistory(for: "photo").count, 2)

        undo.undo()

        XCTAssertEqual(app.developHistory(for: "photo").count, 1, "undo still takes its step away")
        XCTAssertFalse(app.toastCenter.toasts.contains { $0.icon == "warning" })
    }
}
