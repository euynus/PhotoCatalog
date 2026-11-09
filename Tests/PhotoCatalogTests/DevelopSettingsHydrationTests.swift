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
        XCTAssertEqual(try CatalogStore(packageURL: url).loadDevelopSettings()[id]?.exposure, 2, "the probe didn't land")
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
            var read = try store.loadDevelopSettingsCounted()
            // marked, so settings read again can't pass for them
            read.settings[id, default: DevelopSettings()].exposure = 9
            XCTAssertEqual(try store.loadCatalogCollections(developSettings: read).developSettings[id]?.exposure, 9,
                           "\(name): with nothing written, the settings were read again")
            try write()
            let collections = try store.loadCatalogCollections(developSettings: read)
            XCTAssertEqual(collections.developSettings[id]?.exposure, exposure, name)
            XCTAssertEqual(collections.developSettings, try store.loadDevelopSettings(), name)
        }
    }

    /// An import batch that gives its photos settings (an import preset here) counts as a develop
    /// write: settings read before it are read again, with the new photo's. One that gives none
    /// doesn't, so the open keeps the settings it read.
    func testAnImportBatchThatDevelopsCountsAsAWrite() throws {
        let (url, id) = try makeCatalog(exposure: 1)
        let store = try CatalogStore(packageURL: url)
        let punch = try XCTUnwrap(DevelopPreset.builtIns.first { $0.id == "builtin.punch" })
        for (number, preset) in [nil, punch].enumerated() {
            let run = ImportRun(source: scratch, mode: .referenced)
            try store.startImportSession(id: run.id.uuidString)
            var photo = DemoData.assets[3 + number]
            photo.isDemo = false
            photo.deleted = false
            let file = ImportFileResult(source: ImportSourceFile(path: scratch.appendingPathComponent("\(photo.id).jpg").path,
                                                                 byteCount: 4096, modifiedAt: 1),
                                        asset: photo, reason: nil)
            let options = ImportOptionsSnapshot(duplicateStrategy: ImportDuplicateStrategy.keep.rawValue, keywords: [],
                                                colorLabel: nil, author: "", copyright: "", albumName: "", albumId: nil,
                                                preset: preset, rawDefaults: [:], rawDefaultOptOuts: [], bookmark: nil)
            var read = try store.loadDevelopSettingsCounted()
            read.settings[id]?.exposure = 9   // marked, as above

            let batch = try store.saveImportBatch([file], run: run, options: options)
            XCTAssertEqual(batch.assets.map(\.id), [photo.id])
            let collections = try store.loadCatalogCollections(developSettings: read)
            if preset == nil {
                XCTAssertTrue(batch.developSettings.isEmpty)
                XCTAssertEqual(collections.developSettings[id]?.exposure, 9, "an import that developed nothing counted as a write")
            } else {
                XCTAssertNotNil(batch.developSettings[photo.id], "the probe: the import preset gave the photo settings")
                XCTAssertEqual(collections.developSettings, try store.loadDevelopSettings(),
                               "settings read before an import batch won over its photo's")
                XCTAssertEqual(collections.developSettings[photo.id], batch.developSettings[photo.id])
            }
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
