import XCTest
@testable import PhotoCatalog

/// What a batch of folder-watching events starts: a rescan, or for sidecars and hidden files
/// only the rescan's tail (the originals' availability and the sidecar check).
final class WatchedFilesChangedTests: CatalogTestCase {
    /// A catalog with one photo in a watched folder, its launch checks done and its own watcher
    /// stopped, so only the events a test hands in reach it.
    @MainActor
    private func openWatchedCatalog() async throws -> (app: AppState, source: URL) {
        let source = scratch.appendingPathComponent("Source")
        let photo = source.appendingPathComponent("a.jpg")
        try makeTestJPEG(at: photo, shade: 3)
        let package = scratch.appendingPathComponent("Library.photolibrary")
        let store = try CatalogStore(packageURL: package)
        try store.addSourceRoot(id: "source-1", displayName: "Source", path: source.path, bookmark: nil)
        let imported = ImportCoordinator(store: store)
            .importFiles([photo], from: source, sourceRootId: "source-1", folderName: "Source")
        XCTAssertEqual(imported.count, 1)
        try store.upsert(imported)

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))
        app.watcher?.stop()
        try await waitUntil("launch checks finished") {
            !app.isCheckingOriginals && !app.isCheckingXMP && !app.isIncrementalRescanning
        }
        return (app, source)
    }

    @MainActor
    func testSidecarAndHiddenFileBatchRunsOnlyTheRescansTail() async throws {
        let (app, source) = try await openWatchedCatalog()
        app.lastXMPCheck = nil

        app.watchedFilesChanged([source.appendingPathComponent("a.xmp").path,
                                 source.appendingPathComponent(".DS_Store").path,
                                 source.appendingPathComponent(".a.jpg.tmp").path])

        XCTAssertFalse(app.isIncrementalRescanning, "no rescan for files the scan never takes")
        XCTAssertTrue(app.isCheckingOriginals, "the originals' availability is checked")
        XCTAssertTrue(app.isCheckingXMP, "the sidecars are checked")
        try await waitUntil("checks finished") { !app.isCheckingOriginals && !app.isCheckingXMP }
    }

    @MainActor
    func testPhotoInTheBatchStartsARescan() async throws {
        let (app, source) = try await openWatchedCatalog()

        app.watchedFilesChanged([source.appendingPathComponent("a.xmp").path,
                                 source.appendingPathComponent("a.jpg").path])

        XCTAssertTrue(app.isIncrementalRescanning, "a photo's event starts a rescan")
        try await waitUntil("rescan finished") { !app.isIncrementalRescanning }
    }

    func testCannotHoldPhotosLooksAtTheNameOnly() {
        XCTAssertTrue(AppState.cannotHoldPhotos("/Photos/IMG_0001.xmp"))
        XCTAssertTrue(AppState.cannotHoldPhotos("/Photos/IMG_0001.XMP"))
        XCTAssertTrue(AppState.cannotHoldPhotos("/Photos/.DS_Store"))
        XCTAssertTrue(AppState.cannotHoldPhotos("/Photos/.IMG_0001.CR3.partial"))
        XCTAssertFalse(AppState.cannotHoldPhotos("/Photos/IMG_0001.CR3"))
        XCTAssertFalse(AppState.cannotHoldPhotos("/Photos/IMG_0001.xmp.jpg"))
        XCTAssertFalse(AppState.cannotHoldPhotos("/Users/me/.hidden/Photos/IMG_0001.jpg"),
                       "a watched folder under a hidden one still holds photos")
        XCTAssertFalse(AppState.cannotHoldPhotos("/Users/me/.hidden/Photos"))
    }
}
