import XCTest
@testable import PhotoCatalog

/// What a rescan saves when an original changed on disk: the photo and its virtual copies, in
/// one save that either keeps them all or none.
final class RescanSaveTests: CatalogTestCase {
    /// A photo with a virtual copy, cataloged in a watched folder, whose original then changes.
    @MainActor
    private func openCatalogWithCopy() throws -> (app: AppState, store: CatalogStore,
                                                  original: Asset, copy: Asset, photo: URL) {
        let source = scratch.appendingPathComponent("Source")
        let photo = source.appendingPathComponent("edited.jpg")
        try makeTestJPEG(at: photo, shade: 1)
        let package = scratch.appendingPathComponent("Library.photolibrary")
        let store = try CatalogStore(packageURL: package)
        try store.addSourceRoot(id: "source-1", displayName: "Source", path: source.path, bookmark: nil)
        let original = try XCTUnwrap(ImportCoordinator(store: store)
            .importFiles([photo], from: source, sourceRootId: "source-1", folderName: "Source").first)
        let copy = original.virtualCopy(id: "v-copy-1", name: "副本 1")
        try store.upsert([original, copy])

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))
        // an editor's save: other pixels, a later time
        try makeTestJPEG(at: photo, shade: 11)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_900_000_000)],
                                              ofItemAtPath: photo.path)
        return (app, store, original, copy, photo)
    }

    @MainActor
    func testVirtualCopyOfChangedOriginalIsSavedWithItsNewFileState() async throws {
        let (app, store, original, copy, _) = try openCatalogWithCopy()
        try await rescanToCompletion(app)

        let refreshed = try XCTUnwrap(app.assets.first { $0.id == original.id })
        XCTAssertNotEqual(refreshed.quickHash, original.quickHash, "the changed file was read again")
        let saved = try store.loadAssets()
        let savedCopy = try XCTUnwrap(saved.first { $0.id == copy.id })
        XCTAssertEqual(savedCopy.quickHash, refreshed.quickHash, "the copy's row has the new quick hash")
        XCTAssertEqual(savedCopy.fileBytes, refreshed.fileBytes, "and the new file size")
        XCTAssertEqual(savedCopy.contentHash, refreshed.contentHash)
        XCTAssertEqual(saved.first { $0.id == original.id }?.quickHash, refreshed.quickHash)
        XCTAssertEqual(app.assets.first { $0.id == copy.id }?.quickHash, refreshed.quickHash)
    }

    /// The copy's row can't be written: the rescan warns and applies nothing, the original's
    /// refreshed row included, rather than showing a copy the catalog never saved.
    @MainActor
    func testRescanThatCannotSaveACopyAppliesNothing() async throws {
        let (app, store, original, copy, _) = try openCatalogWithCopy()
        try await waitUntil("launch checks finished") { !app.isCheckingOriginals }
        try store.db.execChecked("""
        CREATE TRIGGER fail_copy_update BEFORE UPDATE ON assets WHEN OLD.id = '\(copy.id)'
        BEGIN
          SELECT RAISE(ABORT, 'forced copy save failure');
        END;
        """)

        try await rescanToCompletion(app)

        XCTAssertEqual(app.toastCenter.toasts.last?.message, "重新扫描保存失败")
        XCTAssertEqual(app.assets.first { $0.id == original.id }?.quickHash, original.quickHash)
        XCTAssertEqual(app.assets.first { $0.id == copy.id }?.quickHash, original.quickHash)
        let saved = try store.loadAssets()
        XCTAssertEqual(saved.first { $0.id == original.id }?.quickHash, original.quickHash,
                       "the original's row is left as it was")
        XCTAssertEqual(saved.first { $0.id == copy.id }?.quickHash, original.quickHash)
    }
}
