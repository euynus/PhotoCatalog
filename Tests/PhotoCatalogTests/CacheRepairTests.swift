import XCTest
@testable import PhotoCatalog

/// A cached thumbnail or preview that goes missing is made again from the original whenever the
/// photo is shown, however often that happens in a session; only a repair that failed isn't tried
/// again.
final class CacheRepairTests: CatalogTestCase {
    private var savedLimit: Any?

    override func setUp() {
        super.setUp()
        savedLimit = UserDefaults.standard.object(forKey: "pc_cacheLimitMB")
    }

    override func tearDown() {
        if let savedLimit { UserDefaults.standard.set(savedLimit, forKey: "pc_cacheLimitMB") }
        else { UserDefaults.standard.removeObject(forKey: "pc_cacheLimitMB") }
        super.tearDown()
    }

    /// A catalog with one imported photo, `a.jpg`, opened without background maintenance (which
    /// would make missing cache files itself).
    @MainActor
    private func openCatalogWithPhoto() throws -> (AppState, Asset, CatalogStore) {
        let source = scratch.appendingPathComponent("Source")
        let package = scratch.appendingPathComponent("Library.photolibrary")
        let photo = source.appendingPathComponent("a.jpg")
        try makeTestJPEG(at: photo, shade: 3)
        let store = try CatalogStore(packageURL: package)
        try store.addSourceRoot(id: "source-1", displayName: "Source", path: source.path, bookmark: nil)
        let asset = try XCTUnwrap(ImportCoordinator(store: store)
            .importFiles([photo], from: source, sourceRootId: "source-1", folderName: "Source").first)
        try store.upsert([asset])
        let app = AppState()
        app.onboarded = true
        app.runsBackgroundMaintenance = false
        XCTAssertTrue(app.openCatalog(at: package))
        let opened = try XCTUnwrap(app.assets.first { $0.id == asset.id })
        XCTAssertTrue(exists(opened.thumb) && exists(opened.preview))
        return (app, opened, store)
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    @MainActor
    func testPreviewPrunedAfterARepairIsMadeAgain() async throws {
        let (app, asset, store) = try openCatalogWithPhoto()
        let preview = asset.preview
        try FileManager.default.removeItem(atPath: preview)
        let repaired = await app.visibleImageSource(for: asset, requestedSource: preview, kind: .preview2048)
        XCTAssertEqual(repaired, preview)
        XCTAssertTrue(exists(preview), "showing the photo makes its missing preview")

        // a prune takes it again: previews go first, the older first, and a newer filler goes too
        let filler = store.preview2048URL.appendingPathComponent("filler.jpg")
        try Data(repeating: 1, count: 2 * 1_048_576).write(to: filler)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)],
                                              ofItemAtPath: filler.path)
        app.cacheLimitMB = 1
        app.pruneCacheToLimit()
        try await waitUntil("the prune finished") { app.toastCenter.toasts.last?.icon == "trash" }
        XCTAssertFalse(exists(preview), "the prune deleted the repaired preview")

        let shown = await app.visibleImageSource(for: asset, requestedSource: preview, kind: .preview2048)
        XCTAssertEqual(shown, preview)
        XCTAssertTrue(exists(preview), "the pruned preview is made again")
    }

    @MainActor
    func testThumbnailDeletedByRemoveIsMadeAgainAfterUndo() async throws {
        let (app, asset, _) = try openCatalogWithPhoto()
        let undo = UndoManager()
        undo.groupsByEvent = false   // no run loop here to close event groups
        app.undoManager = undo
        let thumb = asset.thumb
        let shown = await app.visibleImageSource(for: asset, requestedSource: thumb, kind: .thumb512)
        XCTAssertEqual(shown, thumb)

        app.primaryId = asset.id
        app.selectedIds = [asset.id]
        undo.beginUndoGrouping()
        app.removeSelected()
        undo.endUndoGrouping()
        XCTAssertFalse(exists(thumb), "Remove from Catalog deletes the photo's cache files")
        undo.undo()

        let restored = try XCTUnwrap(app.assets.first { $0.id == asset.id })
        XCTAssertFalse(restored.deleted)
        let again = await app.visibleImageSource(for: restored, requestedSource: restored.thumb, kind: .thumb512)
        XCTAssertEqual(again, thumb)
        XCTAssertTrue(exists(thumb), "the thumbnail of the photo brought back is made again")
    }
}
