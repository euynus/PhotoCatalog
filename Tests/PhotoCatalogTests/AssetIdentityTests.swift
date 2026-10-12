import XCTest
@testable import PhotoCatalog

/// A photo's id is made from the path it was imported at, but stays with the photo when its
/// file is renamed or moved: the old path is free for a new photo, and the renamed one is
/// still found by where it is now.
final class AssetIdentityTests: CatalogTestCase {
    private struct Fixture {
        let source: URL
        let package: URL
        let store: CatalogStore
        let renamed: Asset
        let oldPath: URL
        let newPath: URL
    }

    /// A watched source with one photo imported as `a.jpg` and then renamed to `b.jpg`, as
    /// Rename Photos leaves it: same id, new filename and path.
    private func renamedPhotoFixture() throws -> Fixture {
        let source = scratch.appendingPathComponent("Source")
        let package = scratch.appendingPathComponent("Library.photolibrary")
        let oldPath = source.appendingPathComponent("a.jpg")
        let newPath = source.appendingPathComponent("b.jpg")
        try makeTestJPEG(at: oldPath, shade: 1)
        let store = try CatalogStore(packageURL: package)
        try store.addSourceRoot(id: "source-1", displayName: "Source", path: source.path, bookmark: nil)
        var asset = try XCTUnwrap(ImportCoordinator(store: store)
            .importFiles([oldPath], from: source, sourceRootId: "source-1", folderName: "Source").first)
        asset.rating = 4
        try FileManager.default.moveItem(at: oldPath, to: newPath)
        asset.filename = newPath.lastPathComponent
        asset.localPath = newPath.path
        try store.upsert([asset])
        return Fixture(source: source, package: package, store: store, renamed: asset, oldPath: oldPath, newPath: newPath)
    }

    @MainActor
    func testRescanCatalogsNewFileAtRenamedPhotosOldPath() async throws {
        let fixture = try renamedPhotoFixture()
        let thumbBefore = try Data(contentsOf: URL(fileURLWithPath: fixture.renamed.thumb))
        try makeTestJPEG(at: fixture.oldPath, shade: 9)

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: fixture.package))
        try await rescanToCompletion(app)

        let live = app.assets.filter { !$0.deleted && !$0.isDemo }
        XCTAssertEqual(live.count, 2, "the new file at the old path joins the catalog")
        let newcomer = try XCTUnwrap(live.first { $0.localPath == fixture.oldPath.path })
        XCTAssertNotEqual(newcomer.id, fixture.renamed.id)
        XCTAssertNotEqual(newcomer.thumb, fixture.renamed.thumb)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: fixture.renamed.thumb)), thumbBefore,
                       "the renamed photo's thumbnail is not overwritten")
        let renamed = try XCTUnwrap(app.assets.first { $0.id == fixture.renamed.id })
        XCTAssertEqual(renamed.localPath, fixture.newPath.path)
        XCTAssertEqual(renamed.rating, 4)
        XCTAssertEqual(Set(try fixture.store.loadAssets().map(\.id)), Set([fixture.renamed.id, newcomer.id]))
    }

    @MainActor
    func testRescanRefreshesRenamedPhotoWhenItsFileChanges() async throws {
        let fixture = try renamedPhotoFixture()
        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: fixture.package))

        try makeTestJPEG(at: fixture.newPath, shade: 7)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_900_000_000)],
                                              ofItemAtPath: fixture.newPath.path)
        try await rescanToCompletion(app)

        let refreshed = try XCTUnwrap(app.assets.first { $0.id == fixture.renamed.id })
        XCTAssertNotEqual(refreshed.quickHash, fixture.renamed.quickHash, "the edit to the renamed file is picked up")
        XCTAssertEqual(refreshed.rating, 4)
        XCTAssertEqual(refreshed.localPath, fixture.newPath.path)
        XCTAssertEqual(app.assets.filter { !$0.deleted && !$0.isDemo }.count, 1)
    }

    func testImportGivesFileAtTakenPathItsOwnId() throws {
        let fixture = try renamedPhotoFixture()
        try makeTestJPEG(at: fixture.oldPath, shade: 9)

        let coordinator = ImportCoordinator(store: fixture.store)
        let imported = try XCTUnwrap(coordinator.importFiles([fixture.oldPath], from: fixture.source).first)

        XCTAssertNotEqual(imported.id, fixture.renamed.id)
        XCTAssertNotEqual(imported.thumb, fixture.renamed.thumb)
        // the same file imported again keeps the id it got
        try fixture.store.upsert([imported])
        let again = try XCTUnwrap(coordinator.importFiles([fixture.oldPath], from: fixture.source).first)
        XCTAssertEqual(again.id, imported.id)
    }

    func testImportOfRemovedPhotoAtItsPathKeepsItsId() throws {
        let source = scratch.appendingPathComponent("Source")
        let photo = source.appendingPathComponent("removed.jpg")
        try makeTestJPEG(at: photo, shade: 3)
        let store = try CatalogStore(packageURL: scratch.appendingPathComponent("Library.photolibrary"))
        let coordinator = ImportCoordinator(store: store)
        var removed = try XCTUnwrap(coordinator.importFiles([photo], from: source).first)
        removed.deleted = true
        try store.upsert([removed])

        // so an import of its folder can bring it back in place
        let again = try XCTUnwrap(coordinator.importFiles([photo], from: source).first)
        XCTAssertEqual(again.id, removed.id)
    }
}
