import XCTest
@testable import PhotoCatalog

/// A develop commit encodes each changed photo's settings once and stores the same text in the
/// settings and the history tables.
final class DevelopEncodeOnceTests: CatalogTestCase {
    @MainActor
    private func makeApp() throws -> (AppState, CatalogStore) {
        let store = try CatalogStore(packageURL: scratch.appendingPathComponent("Encode.photolibrary"))
        return (AppState.selfCheckFixture(store: store), store)
    }

    private func settingsRows(_ store: CatalogStore) throws -> [String: String] {
        var rows: [String: String] = [:]
        for row in try store.db.query("SELECT asset_id, settings FROM develop_settings;") {
            if let id = row.text("asset_id"), let json = row.text("settings") { rows[id] = json }
        }
        return rows
    }

    private func newestHistoryText(_ store: CatalogStore, _ id: String) throws -> String? {
        try store.db.query("SELECT settings FROM develop_history WHERE asset_id=? ORDER BY seq DESC LIMIT 1;",
                           [.text(id)]).first?.text("settings")
    }

    @MainActor
    func testHistoryStoresTheSameTextAsTheSettings() throws {
        let (app, store) = try makeApp()
        var warm = DevelopSettings()
        warm.temperature = 800
        warm.crop = DevelopCrop(x: 0.1, y: 0.1, width: 0.8, height: 0.7)
        var bright = DevelopSettings()
        bright.exposure = 0.7
        bright.masks = [LocalAdjustment(kind: .radial)]

        app.commitDevelop(["a": warm, "b": bright], undoName: "粘贴设置")

        let rows = try settingsRows(store)
        XCTAssertEqual(Set(rows.keys), ["a", "b"])
        for id in ["a", "b"] {
            XCTAssertEqual(try newestHistoryText(store, id), rows[id], "one text for both tables")
            XCTAssertEqual(rows[id], DevelopHistoryStep.json(id == "a" ? warm : bright), "the stored form, as before")
        }

        // a photo the commit leaves as it was keeps its row; only the changed one gets a step
        var brighter = bright
        brighter.exposure = 1.2
        app.commitDevelop(["a": warm, "b": brighter], undoName: "粘贴设置")
        let after = try settingsRows(store)
        XCTAssertEqual(after["a"], rows["a"])
        XCTAssertEqual(try newestHistoryText(store, "b"), after["b"])
        XCTAssertEqual(try store.loadDevelopHistory("a").count, 1)
        XCTAssertEqual(try store.loadDevelopHistory("b").count, 2)
    }

    @MainActor
    func testANeutralCommitDeletesTheRowAndStillRecordsAStep() throws {
        let (app, store) = try makeApp()
        var edited = DevelopSettings()
        edited.contrast = 25
        app.commitDevelop(["a": edited], undoName: "调整对比度")
        XCTAssertNotNil(try settingsRows(store)["a"])

        app.commitDevelop(["a": .neutral], undoName: "复位修图调整")

        XCTAssertNil(try settingsRows(store)["a"], "as shot has no settings row")
        XCTAssertNil(app.developSettings["a"])
        let history = try store.loadDevelopHistory("a")
        XCTAssertEqual(history.map(\.name), ["调整对比度", "复位修图调整"])
        XCTAssertEqual(history.last?.json, DevelopHistoryStep.json(.neutral))
        XCTAssertEqual(history.last?.settings, .neutral)
    }

    @MainActor
    func testAValueThatCannotBeEncodedSavesNothing() throws {
        let (app, store) = try makeApp()
        var broken = DevelopSettings()
        broken.exposure = .infinity

        app.commitDevelop(["a": broken], undoName: "调整曝光度")

        XCTAssertEqual(app.toastCenter.toasts.last?.message, "保存调整失败，更改未写入目录库")
        XCTAssertEqual(app.toastCenter.toasts.last?.icon, "warning")
        XCTAssertNil(app.developSettings["a"], "memory keeps what the catalog has")
        XCTAssertTrue(try settingsRows(store).isEmpty)
        XCTAssertTrue(try store.loadDevelopHistory("a").isEmpty, "no step for a change that wasn't saved")
        XCTAssertThrowsError(try DevelopHistoryStep.json(["a": broken]), "never stored as {}")
    }
}
