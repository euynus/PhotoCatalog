import XCTest
@testable import PhotoCatalog

/// Rebuild Thumbnails runs on the background lane the backfill shares: it stops when its catalog
/// closes (else it competes with the next catalog's backfill for as long as it runs), and when a
/// rebuild starts again.
final class ThumbnailRebuildCancellationTests: CatalogTestCase {
    private static let rebuiltToast = "缩略图已重建"

    /// What the app's toasts said, kept past their time on screen.
    private final class Heard {
        var messages: [String] = []
    }
    private var heard = Heard()

    /// A catalog of `count` photos, opened with no background work, and each photo's thumbnail
    /// file, removed so a rebuild's work shows.
    @MainActor
    private func appWithPhotos(_ count: Int) throws -> (app: AppState, thumbnails: [URL]) {
        let source = scratch.appendingPathComponent("Source")
        let files = (0..<count).map { source.appendingPathComponent(String(format: "IMG_%04d.jpg", $0)) }
        for (index, file) in files.enumerated() { try makeTestJPEG(at: file, shade: index) }
        let package = scratch.appendingPathComponent("Library.photolibrary")
        let store = try CatalogStore(packageURL: package)
        try store.addSourceRoot(id: "source-1", displayName: "Source", path: source.path, bookmark: nil)
        let imported = ImportCoordinator(store: store)
            .importFiles(files, from: source, sourceRootId: "source-1", folderName: "Source")
        XCTAssertEqual(imported.count, count)
        try store.upsert(imported)
        let app = openCatalog(package)
        let heard = heard
        app.toastCenter.announce = { message, _ in heard.messages.append(message) }
        let service = try XCTUnwrap(app.coordinator?.thumbnails)
        let thumbnails = imported.map { service.cachePath(assetId: $0.id, kind: .thumb512) }
        for thumbnail in thumbnails where FileManager.default.fileExists(atPath: thumbnail.path) {
            try FileManager.default.removeItem(at: thumbnail)
        }
        return (app, thumbnails)
    }

    private func made(_ thumbnails: [URL]) -> Int {
        thumbnails.filter { FileManager.default.fileExists(atPath: $0.path) }.count
    }

    /// A rebuild of the catalog being closed makes nothing more once it's closed.
    @MainActor
    func testClosingTheCatalogStopsTheRebuild() async throws {
        let (app, thumbnails) = try appWithPhotos(10)
        let rebuild = try XCTUnwrap(app.rebuildThumbnails())

        app.closeCatalog()
        await rebuild.value

        XCTAssertEqual(made(thumbnails), 0, "the closed catalog's thumbnails aren't made")
        XCTAssertFalse(heard.messages.contains(Self.rebuiltToast))
    }

    /// A rebuild started while one runs takes its place: the photos are made once, and the
    /// rebuild is reported once.
    @MainActor
    func testRebuildStartedAgainStopsTheFirst() async throws {
        let (app, thumbnails) = try appWithPhotos(3)
        let first = try XCTUnwrap(app.rebuildThumbnails())
        let second = try XCTUnwrap(app.rebuildThumbnails())

        await first.value
        await second.value

        XCTAssertEqual(made(thumbnails), thumbnails.count, "the second rebuild made every photo's")
        XCTAssertEqual(heard.messages.filter { $0 == Self.rebuiltToast }.count, 1, "the first stopped")
    }
}
