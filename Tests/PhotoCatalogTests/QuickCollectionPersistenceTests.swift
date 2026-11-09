import XCTest
@testable import PhotoCatalog

/// B adds and removes only the photos that change: the catalog's quick collection is the app's
/// after each step, undo and redo included, and the members that stay keep their rows.
final class QuickCollectionPersistenceTests: CatalogTestCase {
    private var undo: UndoManager!

    override func tearDown() {
        undo = nil
        super.tearDown()
    }

    @MainActor
    func testAddRemoveUndoAndRedoAreWhatACatalogOpenedAgainHolds() throws {
        let (app, package, ids) = try openCatalog()

        step(app, selecting: [ids[0], ids[1]])
        XCTAssertEqual(app.quickCollection, [ids[0], ids[1]])
        try assertSavedQuickCollection(of: app, package: package)

        step(app, selecting: [ids[0]])
        XCTAssertEqual(app.quickCollection, [ids[1]])
        try assertSavedQuickCollection(of: app, package: package)

        undo.undo()
        XCTAssertEqual(app.quickCollection, [ids[0], ids[1]])
        try assertSavedQuickCollection(of: app, package: package)

        undo.redo()
        XCTAssertEqual(app.quickCollection, [ids[1]])
        try assertSavedQuickCollection(of: app, package: package)

        let reopened = AppState()
        reopened.onboarded = true
        XCTAssertTrue(reopened.openCatalog(at: package))
        XCTAssertEqual(reopened.quickCollection, app.quickCollection)
    }

    /// Adding a photo writes its own row only: a member already in keeps its row and place.
    @MainActor
    func testAddingAPhotoLeavesTheMembersAlreadyIn() throws {
        let (app, package, ids) = try openCatalog()
        step(app, selecting: [ids[0]])
        let db = try Database(path: package.appendingPathComponent("catalog.sqlite").path)
        try db.execChecked("""
        CREATE TRIGGER keep_first_member BEFORE DELETE ON album_assets
        WHEN OLD.asset_id = '\(ids[0])'
        BEGIN SELECT RAISE(ABORT, 'a member already in was written again'); END;
        """)

        step(app, selecting: [ids[2]])

        XCTAssertNotEqual(app.toastCenter.toasts.last?.message, "快捷收藏保存失败")
        try assertSavedQuickCollection(of: app, package: package)
        let positions = try db.query("""
        SELECT asset_id, position FROM album_assets WHERE album_id=? ORDER BY position;
        """, [.text(AppState.quickCollectionID)]).map { "\($0.text("asset_id") ?? "")@\($0.int("position") ?? -1)" }
        XCTAssertEqual(positions, ["\(ids[0])@0", "\(ids[2])@1"], "the new member goes after the one already in")
    }

    // MARK: - helpers

    /// A scratch catalog of three real JPEGs, opened in a fresh AppState with an undo manager.
    @MainActor
    private func openCatalog() throws -> (AppState, URL, [String]) {
        let package = scratch.appendingPathComponent("Library.photolibrary")
        let store = try CatalogStore(packageURL: package)
        let photos = try (0..<3).map { index -> Asset in
            let file = scratch.appendingPathComponent("Source/photo-\(index).jpg")
            try makeTestJPEG(at: file, shade: index)
            var asset = DemoData.assets[index]
            asset.isDemo = false
            asset.deleted = false
            asset.localPath = file.path
            asset.status = .ready
            return asset
        }
        try store.upsert(photos)
        undo = UndoManager()
        undo.groupsByEvent = false   // no run loop here to close event groups
        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))
        app.autoWriteXMPSidecar = false
        app.undoManager = undo
        return (app, package, photos.map(\.id))
    }

    /// B on these photos, as one undo step.
    @MainActor
    private func step(_ app: AppState, selecting ids: Set<String>) {
        app.selectedIds = ids
        app.primaryId = ids.first
        undo.beginUndoGrouping()
        XCTAssertTrue(app.toggleQuickCollection())
        undo.endUndoGrouping()
    }

    @MainActor
    private func assertSavedQuickCollection(of app: AppState, package: URL,
                                            file: StaticString = #filePath, line: UInt = #line) throws {
        let saved = try CatalogStore(packageURL: package).loadAlbums().first { $0.id == AppState.quickCollectionID }
        XCTAssertEqual(Set(saved?.assetIds ?? []), app.quickCollection, file: file, line: line)
    }
}
