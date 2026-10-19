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

    /// Import Photo Folder… in managed mode, Remove from Catalog, the same import again: the
    /// photo comes back, as it does for a referenced import.
    @MainActor
    func testManagedReimportBringsBackRemovedPhoto() async throws {
        let folder = scratch.appendingPathComponent("Card")
        try makeTestJPEG(at: folder.appendingPathComponent("managed.jpg"), shade: 6)
        let package = scratch.appendingPathComponent("Library.photolibrary")
        let store = try CatalogStore(packageURL: package)

        let app = AppState()
        app.onboarded = true
        app.importMode = .managed
        XCTAssertTrue(app.openCatalog(at: package))
        app.importFolder(folder)
        try await waitUntil("first import finished") { !app.importing }
        let imported = try XCTUnwrap(app.assets.first { !$0.isDemo && $0.filename == "managed.jpg" })
        XCTAssertTrue(imported.localPath?.hasPrefix(store.originalsURL.path) == true)
        XCTAssertTrue(app.mutate([imported.id], writingSidecars: false) { $0.rating = 3; $0.title = "Managed title" })
        XCTAssertTrue(app.mutate([imported.id], writingSidecars: false) { $0.deleted = true })

        app.importFolder(folder)
        try await waitUntil("second import finished") { !app.importing }

        XCTAssertEqual(app.assets.filter { $0.id == imported.id }.map(\.deleted), [false], "the removed photo is back")
        XCTAssertEqual(app.assets.filter { !$0.isDemo && !$0.deleted }.count, 1)
        let back = app.assets.first { $0.id == imported.id }
        XCTAssertEqual(back?.rating, 3, "with its rating")
        XCTAssertEqual(back?.title, "Managed title")
        let row = try store.db.query("SELECT deleted, rating, title FROM assets WHERE id=?;", [.text(imported.id)]).first
        XCTAssertEqual(row?.bool("deleted"), false)
        XCTAssertEqual(row?.int("rating"), 3)
        XCTAssertEqual(row?.text("title"), "Managed title")
    }

    /// Import Photo Folder…, edit what the catalog says about a photo, Remove from Catalog, the
    /// same import again: the photo comes back with all of it — over the import's defaults and
    /// over a sidecar left from before the edits — in memory and in the catalog.
    @MainActor
    func testReimportBringsBackRemovedPhotoWithItsMetadata() async throws {
        let folder = scratch.appendingPathComponent("Source")
        let photo = folder.appendingPathComponent("kept.jpg")
        try makeTestJPEG(at: photo, shade: 4)
        let package = scratch.appendingPathComponent("Library.photolibrary")
        _ = try CatalogStore(packageURL: package)

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))
        app.importFolder(folder)
        try await waitUntil("first import finished") { !app.importing }
        let imported = try XCTUnwrap(app.assets.first { !$0.isDemo && $0.localPath == photo.path })
        let shotAt = Date(timeIntervalSince1970: 1_600_000_000)
        XCTAssertTrue(app.mutate([imported.id], writingSidecars: false) {
            $0.rating = 4
            $0.flag = .pick
            $0.colorLabel = .green
            $0.keywords = ["kept", "trip"]
            $0.title = "Kept title"
            $0.caption = "Kept caption"
            $0.author = "Catalog Author"
            $0.copyright = "© Catalog"
            $0.project = "Project K"
            $0.client = "Client K"
            $0.gps = (31.2304, 121.4737)
            $0.gpsAltitude = 12
            $0.location = Asset.locationLabel($0.gps)
            $0.date = shotAt
            $0.captureDateSource = "手动设置"
        })
        let edited = try XCTUnwrap(app.assets.first { $0.id == imported.id })
        XCTAssertTrue(app.mutate([imported.id], writingSidecars: false) { $0.deleted = true })
        // a sidecar another app left before those edits
        try """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/"
          xmlns:dc="http://purl.org/dc/elements/1.1/" xmp:Rating="1">
        <dc:subject><rdf:Bag><rdf:li>stale</rdf:li></rdf:Bag></dc:subject>
        <dc:title><rdf:Alt><rdf:li xml:lang="x-default">Stale title</rdf:li></rdf:Alt></dc:title>
        </rdf:Description></rdf:RDF></x:xmpmeta>
        """.write(to: XMPSidecar.sidecarURL(for: photo), atomically: true, encoding: .utf8)

        app.importFolder(folder)
        try await waitUntil("second import finished") { !app.importing }

        XCTAssertEqual(app.assets.filter { $0.id == imported.id }.map(\.deleted), [false], "the removed photo is back")
        let reloaded = try XCTUnwrap(try CatalogStore(packageURL: package).loadAssets().first { $0.id == imported.id })
        for back in [try XCTUnwrap(app.assets.first { $0.id == imported.id }), reloaded] {
            XCTAssertEqual(back.rating, 4)
            XCTAssertEqual(back.flag, .pick)
            XCTAssertEqual(back.colorLabel, .green)
            XCTAssertEqual(back.keywords, ["kept", "trip"])
            XCTAssertEqual(back.title, "Kept title")
            XCTAssertEqual(back.caption, "Kept caption")
            XCTAssertEqual(back.author, "Catalog Author")
            XCTAssertEqual(back.copyright, "© Catalog")
            XCTAssertEqual(back.project, "Project K")
            XCTAssertEqual(back.client, "Client K")
            XCTAssertEqual(back.gps.0, 31.2304)
            XCTAssertEqual(back.gps.1, 121.4737)
            XCTAssertEqual(back.gpsAltitude, 12)
            XCTAssertEqual(back.location, edited.location)
            XCTAssertEqual(back.date, shotAt)
            XCTAssertEqual(back.captureDateSource, "手动设置")
            XCTAssertFalse(back.deleted)
            XCTAssertEqual(back.localPath, photo.path)
            XCTAssertGreaterThan(back.importedAt, edited.importedAt, "a returning photo is among the recent imports")
        }
    }

    /// Edit In makes `a-Edit.tif`; it's moved to the Trash; Edit In again writes a new
    /// `a-Edit.tif` at the same path, which joins the catalog as a new photo.
    @MainActor
    func testEditAgainAfterTrashingTheResultJoinsTheCatalog() throws {
        let source = scratch.appendingPathComponent("Source")
        let original = source.appendingPathComponent("a.jpg")
        try makeTestJPEG(at: original, shade: 8)
        let package = scratch.appendingPathComponent("Library.photolibrary")
        let store = try CatalogStore(packageURL: package)
        let master = try XCTUnwrap(ImportCoordinator(store: store).importFiles([original], from: source).first)
        try store.upsert([master])

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))
        func editAgain() throws -> (url: URL, ids: Set<String>) {
            let made = AppState.renderEditedCopies(app.externalEditJobs([master]),
                                                   coordinator: ImportCoordinator(store: store), previewMaxPixel: 256)
            let url = try XCTUnwrap(made.first?.url)
            return (url, app.finishExternalEdit(made, editor: nil, expected: 1).importedIDs)
        }
        let first = try editAgain()
        let firstId = try XCTUnwrap(first.ids.first)
        // Move to Trash: the file goes, the photo leaves the catalog
        try FileManager.default.removeItem(at: first.url)
        XCTAssertTrue(app.mutate([firstId], writingSidecars: false) { $0.deleted = true })

        let second = try editAgain()

        XCTAssertEqual(second.url.path, first.url.path, "the new result takes the trashed one's name")
        XCTAssertEqual(second.ids.count, 1, "the new result joins the catalog")
        let added = try XCTUnwrap(app.assets.first { !$0.deleted && $0.localPath == second.url.path })
        XCTAssertNotEqual(added.id, firstId)
        XCTAssertEqual(app.assets.first { $0.id == firstId }?.deleted, true)
        XCTAssertTrue(try store.loadAssets().contains { $0.id == added.id })
    }

    /// A photo removed from the catalog (rated, keyworded, titled, in an album, edited), then a
    /// different photo at its path — the camera's counter come round again — and Import Photo
    /// Folder…: the file is a new photo, and the removed one stays removed with all it had.
    @MainActor
    func testDifferentPhotoAtRemovedPhotosPathIsANewPhoto() async throws {
        let folder = scratch.appendingPathComponent("Source")
        let photo = folder.appendingPathComponent("IMG_0001.JPG")
        try makeShot(at: photo, make: "Canon", model: "Canon EOS R5", taken: "2026:10:12 10:00:00", shade: 1)
        let package = scratch.appendingPathComponent("Library.photolibrary")
        let store = try CatalogStore(packageURL: package)
        var removed = try XCTUnwrap(ImportCoordinator(store: store).importFiles([photo], from: folder).first)
        removed.rating = 4
        removed.keywords = ["old shot"]
        removed.title = "Old shot"
        removed.deleted = true
        try store.upsert([removed])
        try store.saveAlbum(Album(id: "al-old", name: "Old", assetIds: [removed.id]))
        var edits = DevelopSettings()
        edits.exposure = 1
        try store.saveDevelopSettings([removed.id: edits])
        // the counter came round again: another shot by the same name
        try makeShot(at: photo, make: "Canon", model: "Canon EOS R5", taken: "2026:11:02 09:30:00", shade: 9)

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))
        app.importFolder(folder)
        try await waitUntil("import finished") { !app.importing }

        let newcomer = try XCTUnwrap(app.assets.first { !$0.isDemo && !$0.deleted && $0.localPath == photo.path })
        XCTAssertNotEqual(newcomer.id, removed.id, "the new photo took the removed one's place")
        XCTAssertNotEqual(newcomer.rating, 4)
        XCTAssertFalse(newcomer.keywords.contains("old shot"))
        XCTAssertNotEqual(newcomer.title, "Old shot")
        XCTAssertNotEqual(newcomer.date, removed.date, "the new photo has its own capture time")
        XCTAssertNotEqual(newcomer.thumb, removed.thumb)
        XCTAssertNotEqual(app.developSettings[newcomer.id], edits)
        XCTAssertFalse(app.albums.first { $0.id == "al-old" }?.assetIds.contains(newcomer.id) ?? true)
        let row = try store.db.query("SELECT deleted, rating, title FROM assets WHERE id=?;", [.text(removed.id)]).first
        XCTAssertEqual(row?.bool("deleted"), true, "the removed photo came back")
        XCTAssertEqual(row?.int("rating"), 4)
        XCTAssertEqual(row?.text("title"), "Old shot")
        XCTAssertEqual(try store.loadDevelopSettings()[removed.id], edits)
        XCTAssertTrue(try store.loadAssets().contains { $0.id == newcomer.id }, "the new photo is saved")
    }

    /// The same in managed mode: Move to Trash frees the photo's name in Originals, and a new
    /// shot by that name, taken the same day, is copied to it.
    @MainActor
    func testNewShotCopiedToTrashedManagedPhotosNameIsANewPhoto() async throws {
        let card = scratch.appendingPathComponent("Card")
        let shot = card.appendingPathComponent("IMG_0001.JPG")
        try makeShot(at: shot, make: "Canon", model: "Canon EOS R5", taken: "2026:10:12 10:00:00", shade: 1)
        let package = scratch.appendingPathComponent("Library.photolibrary")
        let store = try CatalogStore(packageURL: package)
        let app = AppState()
        app.onboarded = true
        app.importMode = .managed
        XCTAssertTrue(app.openCatalog(at: package))
        app.importFolder(card)
        try await waitUntil("first import finished") { !app.importing }
        let first = try XCTUnwrap(app.assets.first { !$0.isDemo && !$0.deleted && $0.filename == "IMG_0001.JPG" })
        let copy = try XCTUnwrap(first.localPath)
        XCTAssertTrue(copy.hasPrefix(store.originalsURL.path))
        XCTAssertTrue(app.mutate([first.id], writingSidecars: false) { $0.rating = 3; $0.title = "First" })
        // Move to Trash: the copy goes, the photo leaves the catalog
        XCTAssertTrue(app.mutate([first.id], writingSidecars: false) { $0.deleted = true })
        try FileManager.default.removeItem(atPath: copy)
        try makeShot(at: shot, make: "Canon", model: "Canon EOS R5", taken: "2026:10:12 18:00:00", shade: 9)

        app.importFolder(card)
        try await waitUntil("second import finished") { !app.importing }

        let second = try XCTUnwrap(app.assets.first { !$0.isDemo && !$0.deleted && $0.localPath == copy },
                                   "the new shot is copied to the trashed photo's name")
        XCTAssertNotEqual(second.id, first.id, "the new shot took the removed photo's place")
        XCTAssertNotEqual(second.rating, 3)
        XCTAssertEqual(app.assets.first { $0.id == first.id }?.deleted, true)
        let row = try store.db.query("SELECT deleted, rating, title FROM assets WHERE id=?;", [.text(first.id)]).first
        XCTAssertEqual(row?.bool("deleted"), true)
        XCTAssertEqual(row?.int("rating"), 3)
        XCTAssertEqual(row?.text("title"), "First")
    }

    /// A removed photo whose file an editor saved over while it was out of the catalog is still
    /// that photo — other bytes, the same shot — and Import Photo Folder… brings it back.
    @MainActor
    func testRemovedPhotoAnEditorSavedOverComesBack() async throws {
        let folder = scratch.appendingPathComponent("Source")
        let photo = folder.appendingPathComponent("IMG_0001.JPG")
        try makeShot(at: photo, make: "Canon", model: "Canon EOS R5", taken: "2026:10:12 10:00:00", shade: 1)
        let package = scratch.appendingPathComponent("Library.photolibrary")
        let store = try CatalogStore(packageURL: package)
        var removed = try XCTUnwrap(ImportCoordinator(store: store).importFiles([photo], from: folder).first)
        removed.rating = 4
        removed.title = "Kept"
        removed.deleted = true
        try store.upsert([removed])
        try makeShot(at: photo, make: "Canon", model: "Canon EOS R5", taken: "2026:10:12 10:00:00", shade: 9)
        XCTAssertNotEqual(HashService.contentHash(photo), removed.contentHash, "the editor's save changed the bytes")

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))
        app.importFolder(folder)
        try await waitUntil("import finished") { !app.importing }

        XCTAssertEqual(app.assets.filter { !$0.isDemo && !$0.deleted }.map(\.id), [removed.id], "the photo is back, once")
        let back = app.assets.first { $0.id == removed.id }
        XCTAssertEqual(back?.rating, 4)
        XCTAssertEqual(back?.title, "Kept")
        XCTAssertNotEqual(back?.contentHash, removed.contentHash, "with what its file holds now")
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
