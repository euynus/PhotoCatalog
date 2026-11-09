import XCTest
@testable import PhotoCatalog

/// As a catalog opens, its develop settings are decoded with its photos, off the main thread, and
/// taken as they are unless develop settings were written between that read and the open's end:
/// then they're read again, so settings older than a write made meanwhile never win over it.
final class DevelopSettingsHydrationTests: CatalogTestCase {
    /// The settings read with the photos are the ones the open uses. The probe: a change made to
    /// the row behind the catalog's back (another connection, which no count sees) after that read
    /// isn't picked up, as it would be if the open read the settings again on main.
    @MainActor
    func testSettingsReadWithThePhotosAreUsed() async throws {
        let (url, id) = try makeCatalog(exposure: 1)
        let app = try makeApp()
        app.catalogHydrationGate = {
            try? Self.overwriteBehindTheCatalog(url, id: id, exposure: 2)
        }

        try await open(url, in: app)
        XCTAssertEqual(app.developSettings[id]?.exposure, 1, "the settings were read again on main")
    }

    /// The race: the user develops the photo after the settings were read with the photos and
    /// before the open ends. The open reads them again, and the edit is what the app holds.
    @MainActor
    func testADevelopEditMadeWhileTheCatalogOpensWins() async throws {
        let (url, id) = try makeCatalog(exposure: 1)
        let app = try makeApp()
        app.catalogHydrationGate = { [unowned app] in
            app.commitDevelop(id, undoName: "test") { $0.exposure = 3 }
        }

        try await open(url, in: app)
        XCTAssertEqual(app.developSettings[id]?.exposure, 3, "settings read before the edit won over it")
        XCTAssertEqual(try CatalogStore(packageURL: url).loadDevelopSettings()[id]?.exposure, 3)
    }

    /// The same race straight on the store, for each kind of write: settings saved, settings reset
    /// (their row deleted) and virtual copies saved with theirs.
    func testAnyDevelopWriteAfterTheReadIsReadAgain() throws {
        let (url, id) = try makeCatalog(exposure: 1)
        let store = try CatalogStore(packageURL: url)
        var two = DevelopSettings()
        two.exposure = 2
        var copy = DemoData.assets[2]
        copy.isDemo = false
        copy.deleted = false
        copy.masterId = id
        let writes: [(String, () throws -> Void, Double?)] = [
            ("save", { try store.saveDevelopSettings([id: two]) }, 2),
            ("reset", { try store.saveDevelopSettings([id: .neutral]) }, nil),
            ("copy", { try store.saveVirtualCopies([copy], developSettings: [id: two, copy.id: two]) }, 2),
        ]
        for (name, write, exposure) in writes {
            let read = try store.loadDevelopSettingsCounted()
            XCTAssertEqual(try store.loadCatalogCollections(developSettings: read).developSettings, read.settings,
                           "\(name): nothing written, the settings read are used")
            try write()
            let collections = try store.loadCatalogCollections(developSettings: read)
            XCTAssertEqual(collections.developSettings[id]?.exposure, exposure, name)
            XCTAssertEqual(collections.developSettings, try store.loadDevelopSettings(), name)
        }
    }

    // MARK: - helpers

    /// A catalog of one photo developed to `exposure`, and that photo's id.
    private func makeCatalog(exposure: Double) throws -> (url: URL, id: String) {
        let url = scratch.appendingPathComponent("Developed.photolibrary")
        let store = try CatalogStore(packageURL: url)
        var asset = DemoData.assets[0]
        let original = scratch.appendingPathComponent(asset.filename)
        try Data("image".utf8).write(to: original)
        asset.localPath = original.path
        asset.status = .ready
        asset.isDemo = false
        asset.deleted = false
        try store.upsert([asset])
        var settings = DevelopSettings()
        settings.exposure = exposure
        try store.saveDevelopSettings([asset.id: settings])
        return (url, asset.id)
    }

    /// A new app with another catalog open, so the one under test opens as the user opens one.
    @MainActor
    private func makeApp() throws -> AppState {
        let first = scratch.appendingPathComponent("First.photolibrary")
        var asset = DemoData.assets[1]
        asset.isDemo = false
        asset.deleted = false
        try CatalogStore(packageURL: first).upsert([asset])
        let app = AppState()
        app.runsBackgroundMaintenance = false
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: first))
        return app
    }

    @MainActor
    private func open(_ url: URL, in app: AppState) async throws {
        app.openCatalogFromSystem(url)
        XCTAssertTrue(app.isLoadingCatalog)
        try await waitUntil("Timed out waiting for the catalog to load", timeout: 10) { !app.isLoadingCatalog }
        XCTAssertEqual(app.catalogPath, url.path)
    }

    private static func overwriteBehindTheCatalog(_ url: URL, id: String, exposure: Double) throws {
        var settings = DevelopSettings()
        settings.exposure = exposure
        let db = try Database(path: url.appendingPathComponent("catalog.sqlite").path)
        try db.run("UPDATE develop_settings SET settings=? WHERE asset_id=?;",
                   [.text(DevelopHistoryStep.json(settings)), .text(id)])
    }
}
