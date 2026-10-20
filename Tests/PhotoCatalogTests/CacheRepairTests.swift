import XCTest
@testable import PhotoCatalog

/// A cached thumbnail or preview that goes missing is made again from the original whenever the
/// photo is shown, however often that happens in a session; only a repair that failed isn't tried
/// again.
final class CacheRepairTests: CatalogTestCase {
    private var savedLimit: Any?

    override func setUp() {
        super.setUp()
        savedLimit = UserDefaults.app.object(forKey: "pc_cacheLimitMB")
    }

    override func tearDown() {
        if let savedLimit { UserDefaults.app.set(savedLimit, forKey: "pc_cacheLimitMB") }
        else { UserDefaults.app.removeObject(forKey: "pc_cacheLimitMB") }
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

    private func modified(_ path: String) -> Date? {
        try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// A virtual copy shows its master's preview; with that pruned, the copy's own is made, and
    /// that's the one shown from then on.
    @MainActor
    func testVirtualCopyKeepsThePreviewMadeForIt() async throws {
        let (app, master, _) = try openCatalogWithPhoto()
        let copy = master.virtualCopy(id: "copy-1", name: "Copy 1")
        XCTAssertEqual(copy.preview, master.preview)
        try FileManager.default.removeItem(atPath: master.preview)

        let shown = await app.visibleImageSource(for: copy, requestedSource: copy.preview, kind: .preview2048)
        XCTAssertTrue(exists(shown), "the copy's preview is made")
        let madeAt = modified(shown)
        XCTAssertEqual(app.verifiedImageSource(for: copy, requestedSource: copy.preview, kind: .preview2048), shown,
                       "the next arrow key finds it without a look at the disk")

        let again = await app.visibleImageSource(for: copy, requestedSource: copy.preview, kind: .preview2048)
        XCTAssertEqual(again, shown, "shown again, not the placeholder")
        XCTAssertEqual(modified(again), madeAt, "and not made a second time")
    }

    /// A catalog moved since its photos' cache paths were stored finds the files in its own cache.
    @MainActor
    func testMovedCatalogFindsPreviewsInItsOwnCache() async throws {
        let (app, asset, _) = try openCatalogWithPhoto()
        // the path stored before the move
        let stored = asset.preview.replacingOccurrences(of: "/Library.photolibrary/", with: "/Old.photolibrary/")
        XCTAssertNotEqual(stored, asset.preview)
        let madeAt = modified(asset.preview)

        let shown = await app.visibleImageSource(for: asset, requestedSource: stored, kind: .preview2048)
        XCTAssertEqual(shown, asset.preview)
        XCTAssertEqual(app.verifiedImageSource(for: asset, requestedSource: stored, kind: .preview2048),
                       asset.preview)
        let again = await app.visibleImageSource(for: asset, requestedSource: stored, kind: .preview2048)
        XCTAssertEqual(again, asset.preview, "shown again, not the placeholder")
        XCTAssertEqual(modified(asset.preview), madeAt, "the preview there is used, not made again")
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
        app.waitForCachePurges()
        XCTAssertFalse(exists(thumb), "Remove from Catalog deletes the photo's cache files")
        undo.undo()

        let restored = try XCTUnwrap(app.assets.first { $0.id == asset.id })
        XCTAssertFalse(restored.deleted)
        let again = await app.visibleImageSource(for: restored, requestedSource: restored.thumb, kind: .thumb512)
        XCTAssertEqual(again, thumb)
        XCTAssertTrue(exists(thumb), "the thumbnail of the photo brought back is made again")
    }

    /// Removed photos' cache files are deleted in the background; a photo brought back (undo) before
    /// that happens keeps them rather than losing its thumbnail just after it shows again.
    @MainActor
    func testPhotoBroughtBackBeforeItsCacheIsDeletedKeepsIt() async throws {
        let (app, asset, _) = try openCatalogWithPhoto()
        let undo = UndoManager()
        undo.groupsByEvent = false
        app.undoManager = undo
        let thumb = asset.thumb
        _ = await app.visibleImageSource(for: asset, requestedSource: thumb, kind: .thumb512)
        XCTAssertTrue(exists(thumb))

        app.primaryId = asset.id
        app.selectedIds = [asset.id]
        app.holdingCachePurges {
            undo.beginUndoGrouping()
            app.removeSelected()
            undo.endUndoGrouping()
            undo.undo()
        }
        app.waitForCachePurges()
        XCTAssertFalse(try XCTUnwrap(app.assets.first { $0.id == asset.id }).deleted)
        XCTAssertTrue(exists(thumb), "the photo back in the catalog keeps its thumbnail")
    }
}
