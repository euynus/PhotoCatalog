import XCTest
@testable import PhotoCatalog

/// Folder watching and the rescan behind it (⌘R): what a rescan adds, refreshes and leaves alone.
final class FolderWatchTests: CatalogTestCase {
    /// A folder imported as a source, and one of its subfolders imported as a second source:
    /// both are watched.
    @MainActor
    func testNestedWatchedFoldersAddANewFileOnce() async throws {
        let parent = scratch.appendingPathComponent("Parent")
        let child = parent.appendingPathComponent("Child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let package = scratch.appendingPathComponent("Library.photolibrary")
        let store = try CatalogStore(packageURL: package)
        try store.addSourceRoot(id: "source-parent", displayName: "Parent", path: parent.path, bookmark: nil)
        try store.addSourceRoot(id: "source-child", displayName: "Child", path: child.path, bookmark: nil)

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))
        let photo = child.appendingPathComponent("new.jpg")
        try makeTestJPEG(at: photo, shade: 2)
        try await rescanToCompletion(app)

        XCTAssertEqual(app.assets.filter { $0.localPath == photo.path }.count, 1, "the new file is added once")
        XCTAssertEqual(try store.loadAssets().filter { $0.localPath == photo.path }.count, 1)
    }

    /// A photo removed from the catalog in an earlier session: its file is still in the watched
    /// folder, and the next launch's rescan leaves it out.
    @MainActor
    func testRescanAfterRelaunchLeavesRemovedPhotoOut() async throws {
        let source = scratch.appendingPathComponent("Source")
        let photo = source.appendingPathComponent("removed.jpg")
        try makeTestJPEG(at: photo, shade: 5)
        let package = scratch.appendingPathComponent("Library.photolibrary")
        let store = try CatalogStore(packageURL: package)
        try store.addSourceRoot(id: "source-1", displayName: "Source", path: source.path, bookmark: nil)
        var removed = try XCTUnwrap(ImportCoordinator(store: store)
            .importFiles([photo], from: source, sourceRootId: "source-1", folderName: "Source").first)
        removed.rating = 3
        removed.deleted = true
        try store.upsert([removed])

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))
        try await rescanToCompletion(app)

        XCTAssertFalse(app.assets.contains { !$0.deleted && $0.localPath == photo.path }, "the removed photo stays out")
        let row = try store.db.query("SELECT deleted, rating FROM assets WHERE id=?;", [.text(removed.id)]).first
        XCTAssertEqual(row?.bool("deleted"), true)
        XCTAssertEqual(row?.int("rating"), 3)
        XCTAssertEqual(try store.db.query("SELECT id FROM assets;").count, 1)
    }

    /// Import Photo Folder… under Skip Exact Duplicates leaves out a byte-identical copy of a
    /// photo it imports; the watched folder's rescan leaves it out too.
    @MainActor
    func testRescanLeavesOutDuplicateTheImportSkipped() async throws {
        let key = "pc_importDuplicateStrategy"
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let source = scratch.appendingPathComponent("Source")
        let photo = source.appendingPathComponent("a.jpg")
        try makeTestJPEG(at: photo, shade: 3)
        try FileManager.default.copyItem(at: photo, to: source.appendingPathComponent("b.jpg"))
        let package = scratch.appendingPathComponent("Library.photolibrary")
        _ = try CatalogStore(packageURL: package)

        let app = AppState()
        app.onboarded = true
        app.importDuplicateStrategy = .skipExact
        XCTAssertTrue(app.openCatalog(at: package))
        app.importFolder(source)
        try await waitUntil("import finished") { !app.importing }
        XCTAssertEqual(app.assets.filter { !$0.isDemo && !$0.deleted }.count, 1, "the duplicate is skipped")
        XCTAssertEqual(app.importRun?.skipped, 1)

        try await rescanToCompletion(app)

        XCTAssertEqual(app.assets.filter { !$0.isDemo && !$0.deleted }.count, 1,
                       "the rescan leaves the skipped duplicate out")
        XCTAssertEqual(try CatalogStore(packageURL: package).loadAssets().count, 1)
    }

    /// An original changed on disk (an editor's save) is read again for what the file holds —
    /// size, pixels, hashes — while what the catalog says about the photo stays, a sidecar
    /// from before the catalog's edits included.
    @MainActor
    func testRescanOfChangedOriginalKeepsCatalogMetadata() async throws {
        let source = scratch.appendingPathComponent("Source")
        let photo = source.appendingPathComponent("edited.jpg")
        try makeTestJPEG(at: photo, shade: 1)
        let package = scratch.appendingPathComponent("Library.photolibrary")
        let store = try CatalogStore(packageURL: package)
        try store.addSourceRoot(id: "source-1", displayName: "Source", path: source.path, bookmark: nil)
        var asset = try XCTUnwrap(ImportCoordinator(store: store)
            .importFiles([photo], from: source, sourceRootId: "source-1", folderName: "Source").first)
        let shotAt = Date(timeIntervalSince1970: 1_600_000_000)
        asset.rating = 5
        asset.keywords = ["kept"]
        asset.title = "Kept title"
        asset.date = shotAt
        asset.captureDateSource = "手动设置"
        asset.gps = (31.2304, 121.4737)
        asset.gpsAltitude = 12
        asset.location = Asset.locationLabel(asset.gps)
        asset.author = "Catalog Author"
        asset.copyright = "© Catalog"
        try store.upsert([asset])
        // a sidecar another app left before those edits: rating, keywords and title only
        try """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/"
          xmlns:dc="http://purl.org/dc/elements/1.1/" xmp:Rating="1">
        <dc:subject><rdf:Bag><rdf:li>stale</rdf:li></rdf:Bag></dc:subject>
        <dc:title><rdf:Alt><rdf:li xml:lang="x-default">Stale title</rdf:li></rdf:Alt></dc:title>
        </rdf:Description></rdf:RDF></x:xmpmeta>
        """.write(to: XMPSidecar.sidecarURL(for: photo), atomically: true, encoding: .utf8)

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))
        try makeTestJPEG(at: photo, shade: 11)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_900_000_000)],
                                              ofItemAtPath: photo.path)
        try await rescanToCompletion(app)

        let refreshed = try XCTUnwrap(app.assets.first { $0.id == asset.id })
        XCTAssertNotEqual(refreshed.quickHash, asset.quickHash, "the changed file was read again")
        for saved in [refreshed, try XCTUnwrap(try store.loadAssets().first { $0.id == asset.id })] {
            XCTAssertEqual(saved.rating, 5)
            XCTAssertEqual(saved.keywords, ["kept"])
            XCTAssertEqual(saved.title, "Kept title")
            XCTAssertEqual(saved.date, shotAt)
            XCTAssertEqual(saved.captureDateSource, "手动设置")
            XCTAssertEqual(saved.gps.0, 31.2304)
            XCTAssertEqual(saved.gps.1, 121.4737)
            XCTAssertEqual(saved.gpsAltitude, 12)
            XCTAssertEqual(saved.location, asset.location)
            XCTAssertEqual(saved.author, "Catalog Author")
            XCTAssertEqual(saved.copyright, "© Catalog")
        }
    }

    /// A rating and a removal made while a rescan runs, on photos whose originals it reads again,
    /// outlast the rescan.
    @MainActor
    func testEditsMadeDuringRescanSurviveIt() async throws {
        let source = scratch.appendingPathComponent("Source")
        let rated = source.appendingPathComponent("rated.jpg")
        let removed = source.appendingPathComponent("removed.jpg")
        try makeTestJPEG(at: rated, shade: 1)
        try makeTestJPEG(at: removed, shade: 2)
        let package = scratch.appendingPathComponent("Library.photolibrary")
        let store = try CatalogStore(packageURL: package)
        try store.addSourceRoot(id: "source-1", displayName: "Source", path: source.path, bookmark: nil)
        let imported = ImportCoordinator(store: store)
            .importFiles([rated, removed], from: source, sourceRootId: "source-1", folderName: "Source")
        try store.upsert(imported)
        let ratedId = try XCTUnwrap(imported.first { $0.localPath == rated.path }).id
        let removedId = try XCTUnwrap(imported.first { $0.localPath == removed.path }).id

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))
        for (index, url) in [rated, removed].enumerated() {
            try makeTestJPEG(at: url, shade: 12 + index)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_900_000_000)],
                                                  ofItemAtPath: url.path)
        }

        app.rescanCurrentSource()
        XCTAssertTrue(app.isIncrementalRescanning)
        // while the rescan reads the changed files
        XCTAssertTrue(app.mutateAsset(ratedId) { $0.rating = 5 })
        XCTAssertTrue(app.mutate([removedId], writingSidecars: false) { $0.deleted = true })
        try await waitUntil("rescan finished") { !app.isIncrementalRescanning }

        let ratedNow = try XCTUnwrap(app.assets.first { $0.id == ratedId })
        XCTAssertNotEqual(ratedNow.quickHash, imported.first { $0.id == ratedId }?.quickHash, "the file was read again")
        XCTAssertEqual(ratedNow.rating, 5)
        XCTAssertEqual(app.assets.first { $0.id == removedId }?.deleted, true)
        let rows = try store.db.query("SELECT id, rating, deleted FROM assets;")
        XCTAssertEqual(rows.first { $0.text("id") == ratedId }?.int("rating"), 5)
        XCTAssertEqual(rows.first { $0.text("id") == removedId }?.bool("deleted"), true)
    }

    /// A watcher reports a change in its folder; dropped, it's gone: the stream doesn't keep it
    /// alive, and a change after that calls nobody.
    @MainActor
    func testDroppedWatcherIsReleasedAndCallsNoMore() async throws {
        let folder = scratch.appendingPathComponent("Watched")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var calls = 0
        var watcher: FileWatcher? = FileWatcher(paths: [folder.path], latency: 0.05) { _ in calls += 1 }
        weak var released = watcher
        watcher?.start()
        try Data("a".utf8).write(to: folder.appendingPathComponent("a.txt"))
        try await waitUntil("the change is reported") { calls > 0 }

        watcher = nil
        XCTAssertNil(released, "the stream doesn't keep the watcher alive")
        let reported = calls
        try Data("b".utf8).write(to: folder.appendingPathComponent("b.txt"))
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(calls, reported, "a dropped watcher calls nobody")
    }

    /// A photo listed twice (as the nested-folder rescan used to leave it) whose original goes
    /// missing is flagged, not a crash.
    @MainActor
    func testMissingDetectionToleratesAPhotoListedTwice() async throws {
        let source = scratch.appendingPathComponent("Source")
        let photo = source.appendingPathComponent("twice.jpg")
        try makeTestJPEG(at: photo, shade: 4)
        let package = scratch.appendingPathComponent("Library.photolibrary")
        let store = try CatalogStore(packageURL: package)
        let asset = try XCTUnwrap(ImportCoordinator(store: store).importFiles([photo], from: source).first)
        try store.upsert([asset])

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))
        try await waitUntil("launch check finished") { !app.isCheckingOriginals }
        app.assets = app.assets + [asset]
        try FileManager.default.removeItem(at: photo)

        app.detectMissingRealAssets()
        try await waitUntil("missing check finished") { !app.isCheckingOriginals }

        XCTAssertTrue(app.assets.filter { $0.id == asset.id }.allSatisfy { $0.status == .missing })
        XCTAssertEqual(try store.loadAssets().first { $0.id == asset.id }?.status, .missing)
    }
}
