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
