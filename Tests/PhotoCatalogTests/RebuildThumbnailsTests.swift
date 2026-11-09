import XCTest
@testable import PhotoCatalog

/// Rebuild Thumbnails makes each photo's thumbnails and preview again, the preview at the size
/// the photo's was.
final class RebuildThumbnailsTests: CatalogTestCase {
    /// A catalog of two photos, one with a 1600 px preview and one with a 2048 px one, open in an
    /// app that runs no background maintenance, so only the rebuild makes cache files.
    @MainActor
    private func openCatalogWithTwoPreviewSizes() throws -> (app: AppState, small: Asset, large: Asset) {
        let source = scratch.appendingPathComponent("Source")
        let smallPhoto = source.appendingPathComponent("small.jpg")
        let largePhoto = source.appendingPathComponent("large.jpg")
        try makeTestJPEG(at: smallPhoto, shade: 3)
        try makeTestJPEG(at: largePhoto, shade: 9)
        let package = scratch.appendingPathComponent("Library.photolibrary")
        let store = try CatalogStore(packageURL: package)
        try store.addSourceRoot(id: "source-1", displayName: "Source", path: source.path, bookmark: nil)
        let coordinator = ImportCoordinator(store: store)
        let small = try XCTUnwrap(coordinator.importFiles([smallPhoto], from: source, previewMaxPixel: 1600,
                                                          sourceRootId: "source-1", folderName: "Source").first)
        let large = try XCTUnwrap(coordinator.importFiles([largePhoto], from: source, previewMaxPixel: 2048,
                                                          sourceRootId: "source-1", folderName: "Source").first)
        XCTAssertTrue(small.preview.contains("/Previews/1600/"))
        XCTAssertTrue(large.preview.contains("/Previews/2048/"))
        try store.upsert([small, large])

        let app = AppState()
        app.onboarded = true
        app.runsBackgroundMaintenance = false
        XCTAssertTrue(app.openCatalog(at: package))
        return (app, small, large)
    }

    private static let kinds: [ThumbnailService.Kind] = [.thumb256, .thumb512, .preview1600, .preview2048]

    @MainActor
    private func waitForRebuild(_ app: AppState, since generation: Int) async throws {
        try await waitUntil("rebuild finished", timeout: 30) { app.thumbnailCacheGeneration != generation }
    }

    @MainActor
    func testRebuildMakesThumbnailsAndThePreviewAtItsOwnSize() async throws {
        let (app, small, large) = try openCatalogWithTwoPreviewSizes()
        let service = try XCTUnwrap(app.coordinator?.thumbnails)
        let fm = FileManager.default
        for asset in [small, large] {
            for kind in Self.kinds { try? fm.removeItem(at: service.cachePath(assetId: asset.id, kind: kind)) }
        }

        let generation = app.thumbnailCacheGeneration
        app.rebuildThumbnails()
        try await waitForRebuild(app, since: generation)

        for (asset, preview, other) in [(small, ThumbnailService.Kind.preview1600, ThumbnailService.Kind.preview2048),
                                        (large, .preview2048, .preview1600)] {
            for kind in [ThumbnailService.Kind.thumb256, .thumb512, preview] {
                XCTAssertTrue(fm.fileExists(atPath: service.cachePath(assetId: asset.id, kind: kind).path),
                              "\(asset.filename): no \(kind)")
            }
            XCTAssertFalse(fm.fileExists(atPath: service.cachePath(assetId: asset.id, kind: other).path),
                           "\(asset.filename): a preview of the other size")
        }
    }

    /// The rebuild runs on the backfill's lane: a backfill under way is stopped, not left to take
    /// turns with it.
    @MainActor
    func testRebuildStopsARunningBackfill() async throws {
        let (app, _, _) = try openCatalogWithTwoPreviewSizes()
        app.runsBackgroundMaintenance = true
        app.backfillThumbnails()
        app.runsBackgroundMaintenance = false
        XCTAssertTrue(app.isBackfilling)

        let generation = app.thumbnailCacheGeneration
        app.rebuildThumbnails()

        XCTAssertFalse(app.isBackfilling, "the backfill runs on beside the rebuild")
        try await waitForRebuild(app, since: generation)
    }
}
