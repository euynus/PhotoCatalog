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
