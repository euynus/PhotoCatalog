import XCTest
@testable import PhotoCatalog

/// Review and metadata edits write only their own columns: what a catalog opened again loads is
/// the photo as the app holds it, and the search index finds the new words.
final class EditableColumnPersistenceTests: CatalogTestCase {
    private var undo: UndoManager!

    override func tearDown() {
        undo = nil
        super.tearDown()
    }

    @MainActor
    func testKeywordTitleAndGPSEditsLoadAsTheAppHoldsThem() throws {
        let (app, package, ids) = try openCatalog()
        app.selectedIds = [ids[0], ids[1]]
        app.addKeyword("lighthousequay")
        XCTAssertTrue(app.mutate([ids[0]]) { $0.title = "quayside harbourdawn" })
        XCTAssertTrue(app.mutate([ids[1]]) {
            $0.gps = (59.3293, 18.0686)
            $0.gpsAltitude = 28.5
        })

        try assertCatalogLoadsAsTheAppHolds(app, package: package, ids: ids)
        let store = try CatalogStore(packageURL: package)
        XCTAssertEqual(Set(store.search("lighthousequay") ?? []), [ids[0], ids[1]])
        XCTAssertEqual(store.search("harbourdawn"), [ids[0]])
    }

    @MainActor
    func testUndoAndRedoOfAKeywordEditLoadAsTheAppHoldsThem() throws {
        let (app, package, ids) = try openCatalog()
        undo = UndoManager()
        undo.groupsByEvent = false   // no run loop here to close event groups
        app.undoManager = undo
        app.selectedIds = [ids[0]]
        undo.beginUndoGrouping()
        app.addKeyword("tidepoolwalk")
        undo.endUndoGrouping()

        undo.undo()
        XCTAssertFalse(app.asset(id: ids[0])?.keywords.contains("tidepoolwalk") ?? true)
        try assertCatalogLoadsAsTheAppHolds(app, package: package, ids: ids)
        XCTAssertEqual(try CatalogStore(packageURL: package).search("tidepoolwalk"), [])

        undo.redo()
        XCTAssertTrue(app.asset(id: ids[0])?.keywords.contains("tidepoolwalk") ?? false)
        try assertCatalogLoadsAsTheAppHolds(app, package: package, ids: ids)
        XCTAssertEqual(try CatalogStore(packageURL: package).search("tidepoolwalk"), [ids[0]])
    }

    /// A row gone from under the app (another tool, a restore) is written whole again.
    @MainActor
    func testAPhotoWhoseRowIsGoneIsSavedWhole() throws {
        let (app, package, ids) = try openCatalog()
        let db = try Database(path: package.appendingPathComponent("catalog.sqlite").path)
        try db.run("DELETE FROM assets WHERE id=?;", [.text(ids[0])])

        XCTAssertTrue(app.mutate([ids[0]]) { $0.keywords.append("rowcameback") })

        try assertCatalogLoadsAsTheAppHolds(app, package: package, ids: ids)
        XCTAssertEqual(try CatalogStore(packageURL: package).search("rowcameback"), [ids[0]])
    }

    /// An edit that changes nothing has no column to write.
    @MainActor
    func testAnEditThatChangesNothingWritesNoRow() throws {
        let (app, package, ids) = try openCatalog()
        let db = try Database(path: package.appendingPathComponent("catalog.sqlite").path)
        try db.failWrites("no_asset_update", before: "UPDATE", on: "assets", message: "no row may be written")
        try db.failWrites("no_asset_insert", before: "INSERT", on: "assets", message: "no row may be written")
        let title = try XCTUnwrap(app.asset(id: ids[0])?.title)

        XCTAssertTrue(app.mutate([ids[0]]) { $0.title = title })
        XCTAssertNotEqual(app.toastCenter.toasts.last?.message, "保存失败，更改未写入目录库")
    }

    /// A review edit leaves the metadata columns as the catalog has them, and the other way round.
    func testOnlyTheEditedColumnsAreWritten() throws {
        let store = try CatalogStore(packageURL: scratch.appendingPathComponent("Library.photolibrary"))
        var photo = DemoData.assets[0]
        photo.isDemo = false
        photo.title = "saved title"
        photo.rating = 1
        try store.upsert([photo])

        var edited = photo
        edited.rating = 4
        edited.title = "unsaved title"
        try store.updateEditableColumns([edited], review: true, metadata: false)
        var saved = try XCTUnwrap(store.loadAssets().first { $0.id == photo.id })
        XCTAssertEqual(saved.rating, 4)
        XCTAssertEqual(saved.title, "saved title")

        edited.rating = 2
        try store.updateEditableColumns([edited], review: false, metadata: true)
        saved = try XCTUnwrap(store.loadAssets().first { $0.id == photo.id })
        XCTAssertEqual(saved.rating, 4)
        XCTAssertEqual(saved.title, "unsaved title")
        XCTAssertEqual(store.search("unsaved"), [photo.id])
    }

    // MARK: - helpers

    /// A scratch catalog of two real JPEGs, opened in a fresh AppState.
    @MainActor
    private func openCatalog() throws -> (AppState, URL, [String]) {
        let package = scratch.appendingPathComponent("Library.photolibrary")
        let store = try CatalogStore(packageURL: package)
        let photos = try (0..<2).map { index -> Asset in
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
        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))
        app.autoWriteXMPSidecar = false   // nothing beside the scratch photos but the photos
        return (app, package, photos.map(\.id))
    }

    /// Every column of each photo, as the catalog binds them: `Asset ==` compares only ids.
    private func columns(_ asset: Asset?) -> String {
        asset.map { "\(CatalogStore.params($0))" } ?? "no photo"
    }

    @MainActor
    private func assertCatalogLoadsAsTheAppHolds(_ app: AppState, package: URL, ids: [String],
                                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let loaded = try CatalogStore(packageURL: package).loadAssets()
        for id in ids {
            XCTAssertEqual(columns(loaded.first { $0.id == id }), columns(app.asset(id: id)),
                           "photo \(id)", file: file, line: line)
        }
    }
}
