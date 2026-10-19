import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@preconcurrency @testable import PhotoCatalog

/// Stands in for a tethered camera: each shot "downloads" by copying a local file.
@MainActor
private final class FakeTetherSource: TetherSource {
    let fixture: URL
    var name: String { "Fake Camera" }
    var canCapture: Bool { true }
    private(set) var stopped = false
    private var onShot: (@MainActor (TetherShot) -> Void)?
    private var counter = 100

    init(fixture: URL) { self.fixture = fixture }

    func start(onShot: @escaping @MainActor (TetherShot) -> Void, onEnd: @escaping @MainActor (String) -> Void) -> Bool {
        self.onShot = onShot
        return true
    }

    func stop() { stopped = true }

    func capture() { shoot() }

    func shoot() {
        counter += 1
        let fixture = fixture
        onShot?(TetherShot(originalName: "IMG_\(counter).JPG") { try FileManager.default.copyItem(at: fixture, to: $0) })
    }
}

/// Holds a catalog load between reading the full catalog and installing it.
@MainActor
private final class HydrationGate {
    private(set) var reached = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        reached = true
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

/// Opening, switching, creating and closing catalogs: nothing of the previous catalog — undo
/// steps, a tethered session, sidecar changes, demo photos — carries over into the next.
final class CatalogLifecycleTests: XCTestCase {
    private static let defaultsKeys = ["pc_openLast", "pc_catalogURL", "pc_onboarded", "pc_recentCatalogs",
                                       "pc_tether", "pc_pairRawJpeg"]
    private var previousDefaults: [String: Any] = [:]
    private var root: URL!

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        for key in Self.defaultsKeys {
            if let value = defaults.object(forKey: key) { previousDefaults[key] = value }
        }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pc-lifecycle-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults.set(false, forKey: "pc_openLast")
        // never the real library, even on a fallback path
        defaults.set(root.appendingPathComponent("Fallback.photolibrary"), forKey: "pc_catalogURL")
    }

    override func tearDown() {
        let defaults = UserDefaults.standard
        for key in Self.defaultsKeys {
            if let value = previousDefaults[key] {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        previousDefaults = [:]
        if let root { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    // MARK: - helpers

    @MainActor
    private func makeCatalog(_ name: String, assets indices: [Int]) throws -> (url: URL, store: CatalogStore) {
        let url = root.appendingPathComponent("\(name).photolibrary")
        let source = root.appendingPathComponent("Source-\(name)")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let store = try CatalogStore(packageURL: url)
        let assets = try indices.map { index -> Asset in
            var asset = DemoData.assets[index]
            let original = source.appendingPathComponent(asset.filename)
            try Data("image \(index)".utf8).write(to: original)
            asset.localPath = original.path
            asset.status = .ready
            asset.isDemo = false
            asset.deleted = false
            asset.rating = 0
            return asset
        }
        try store.upsert(assets)
        return (url, store)
    }

    @MainActor
    private func makeApp() -> AppState {
        let app = AppState()
        app.runsBackgroundMaintenance = false
        app.onboarded = true
        return app
    }

    @MainActor
    private func select(_ id: String, in app: AppState) {
        app.primaryId = id
        app.selectedIds = [id]
    }

    @MainActor
    private func waitUntil(_ message: String, timeout: TimeInterval = 3,
                           condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail(message)
        throw NSError(domain: "CatalogLifecycleTests.Wait", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: message])
    }

    @MainActor
    private func quickCollection(in store: CatalogStore) throws -> Set<String> {
        Set(try store.loadAlbums().first { $0.id == AppState.quickCollectionID }?.assetIds ?? [])
    }

    @MainActor
    private func writeJPEG(_ url: URL) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    // MARK: - #3 undo history

    @MainActor
    func testSwitchingCatalogsClearsUndoHistory() async throws {
        let first = try makeCatalog("First", assets: [0])
        let second = try makeCatalog("Second", assets: [1])
        let firstId = DemoData.assets[0].id, secondId = DemoData.assets[1].id
        try second.store.saveAlbum(Album(id: AppState.quickCollectionID, name: "快捷收藏", assetIds: [secondId]),
                                   sortOrder: -1)
        let app = makeApp()
        let undo = UndoManager()
        app.undoManager = undo
        func registerStep() {
            select(firstId, in: app)
            XCTAssertTrue(app.toggleQuickCollection())
            XCTAssertTrue(undo.canUndo)
        }

        XCTAssertTrue(app.openCatalog(at: first.url))
        registerStep()
        XCTAssertTrue(app.openCatalog(at: second.url))
        XCTAssertFalse(undo.canUndo, "undo steps of the previous catalog survive Open Catalog")
        if undo.canUndo { undo.undo() }
        XCTAssertEqual(try quickCollection(in: second.store), [secondId], "an undo emptied the new catalog's Quick Collection")
        XCTAssertEqual(app.quickCollection, [secondId])

        XCTAssertTrue(app.openCatalog(at: first.url))
        registerStep()
        XCTAssertTrue(app.createCatalog(at: root.appendingPathComponent("Third.photolibrary")))
        XCTAssertFalse(undo.canUndo, "undo steps survive New Catalog")

        XCTAssertTrue(app.openCatalog(at: first.url))
        registerStep()
        app.closeCatalog()
        XCTAssertFalse(undo.canUndo, "undo steps survive Close Catalog")
        UserDefaults.standard.set(first.url, forKey: "pc_catalogURL")

        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: first.url))
        registerStep()
        app.openCatalogFromSystem(second.url)
        XCTAssertFalse(undo.canUndo, "undo steps survive a catalog opened in the background")
        try await waitUntil("Timed out waiting for the catalog to load") { !app.isLoadingCatalog }
    }

    // MARK: - #36 tethering

    @MainActor
    func testClosingCatalogEndsTetheredSession() throws {
        let first = try makeCatalog("First", assets: [0])
        let second = try makeCatalog("Second", assets: [1])
        let fixture = root.appendingPathComponent("fixture.jpg")
        try writeJPEG(fixture)
        let app = makeApp()
        XCTAssertTrue(app.openCatalog(at: first.url))
        var settings = TetherSettings()
        settings.sessionName = "Studio"
        settings.destinationPath = root.appendingPathComponent("Sessions").path
        let camera = FakeTetherSource(fixture: fixture)
        XCTAssertTrue(app.startTether(settings, source: camera))

        XCTAssertTrue(app.openCatalog(at: second.url))
        XCTAssertNil(app.tether, "the tethered session outlives its catalog")
        XCTAssertTrue(camera.stopped, "the camera keeps delivering shots after its catalog closed")
    }

    @MainActor
    func testShotInFlightDoesNotLandInNextCatalog() async throws {
        let first = try makeCatalog("First", assets: [0])
        let second = try makeCatalog("Second", assets: [1])
        let fixture = root.appendingPathComponent("fixture.jpg")
        try writeJPEG(fixture)
        let app = makeApp()
        XCTAssertTrue(app.openCatalog(at: first.url))
        var settings = TetherSettings()
        settings.sessionName = "Studio"
        settings.destinationPath = root.appendingPathComponent("Sessions").path
        let session = root.appendingPathComponent("Sessions/Studio").standardizedFileURL.path
        let camera = FakeTetherSource(fixture: fixture)
        XCTAssertTrue(app.startTether(settings, source: camera))

        // a shot is on its way when the catalog is switched
        camera.shoot()
        XCTAssertTrue(app.openCatalog(at: second.url))
        try await waitUntil("The shot was never delivered", timeout: 5) {
            ((try? FileManager.default.contentsOfDirectory(atPath: session)) ?? []).contains { $0.hasSuffix(".JPG") }
        }
        func inSession(_ assets: [Asset]) -> [Asset] { assets.filter { $0.localPath?.hasPrefix(session) == true } }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, inSession(app.assets).isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(inSession(app.assets).isEmpty, "a shot of the previous catalog's session shows in the next")
        XCTAssertTrue(inSession(try second.store.loadAssets()).isEmpty, "a shot of the previous catalog's session is saved in the next")
    }

    /// A shot is saved with the session's folder as a source folder, or not at all: a photo the
    /// catalog kept without its folder would show up at the next launch, unseen until then.
    @MainActor
    func testTetheredShotThatFailsToSaveLeavesNothingInTheCatalog() async throws {
        let first = try makeCatalog("First", assets: [0])
        let fixture = root.appendingPathComponent("fixture.jpg")
        try writeJPEG(fixture)
        let app = makeApp()
        XCTAssertTrue(app.openCatalog(at: first.url))
        var settings = TetherSettings()
        settings.sessionName = "Studio"
        settings.destinationPath = root.appendingPathComponent("Sessions").path
        let session = root.appendingPathComponent("Sessions/Studio").standardizedFileURL.path
        let camera = FakeTetherSource(fixture: fixture)
        XCTAssertTrue(app.startTether(settings, source: camera))
        try first.store.db.execChecked("""
        CREATE TRIGGER fail_session_folder BEFORE INSERT ON source_roots
        BEGIN
          SELECT RAISE(ABORT, 'forced source folder save failure');
        END;
        """)

        camera.shoot()
        try await waitUntil("The shot's save never failed", timeout: 5) {
            app.toastCenter.toasts.contains { $0.message == "联机拍摄的照片未能保存到目录库" }
        }

        func inSession(_ assets: [Asset]) -> [Asset] { assets.filter { $0.localPath?.hasPrefix(session) == true } }
        XCTAssertTrue(inSession(app.assets).isEmpty)
        XCTAssertTrue(inSession(try first.store.loadAssets()).isEmpty, "the shot is in the catalog without its folder")
    }

    /// A shot written where a photo removed in an earlier session was (its file moved to the
    /// Trash) is a new photo: it doesn't take the removed photo's id, albums or edits, and the
    /// removed photo stays as it was removed — even when the two files are the same bytes.
    @MainActor
    func testTetheredShotAtARemovedPhotosPathIsANewPhoto() async throws {
        let catalog = try makeCatalog("First", assets: [0])
        let fixture = root.appendingPathComponent("fixture.jpg")
        try writeJPEG(fixture)
        let sessionFolder = root.appendingPathComponent("Sessions/Studio").standardizedFileURL
        let earlier = sessionFolder.appendingPathComponent("Studio-0001.JPG")
        try FileManager.default.createDirectory(at: sessionFolder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: earlier)
        var removed = try XCTUnwrap(ImportCoordinator(store: catalog.store).importFiles([earlier], from: sessionFolder).first)
        removed.rating = 5
        removed.title = "Removed earlier"
        removed.deleted = true
        try catalog.store.upsert([removed])
        try catalog.store.saveAlbum(Album(id: "al-earlier", name: "Earlier", assetIds: [removed.id]))
        var edits = DevelopSettings()
        edits.exposure = 1
        try catalog.store.saveDevelopSettings([removed.id: edits])
        // Move to Trash took the file
        try FileManager.default.removeItem(at: earlier)

        let app = makeApp()
        XCTAssertTrue(app.openCatalog(at: catalog.url))
        var settings = TetherSettings()
        settings.sessionName = "Studio"
        settings.destinationPath = root.appendingPathComponent("Sessions").path
        let camera = FakeTetherSource(fixture: fixture)
        XCTAssertTrue(app.startTether(settings, source: camera))
        camera.shoot()
        try await waitUntil("The shot never joined the catalog", timeout: 10) {
            app.tether?.shots == 1 && app.tether?.working == false
        }

        let shot = try XCTUnwrap(app.assets.first { !$0.deleted && $0.localPath == earlier.path })
        XCTAssertNotEqual(shot.id, removed.id, "the shot took the removed photo's id")
        XCTAssertEqual(shot.rating, 0)
        XCTAssertNil(app.developSettings[shot.id])
        XCTAssertFalse(app.albums.first { $0.id == "al-earlier" }?.assetIds.contains(shot.id) ?? false)
        let row = try catalog.store.db.query("SELECT deleted, rating, title FROM assets WHERE id=?;",
                                             [.text(removed.id)]).first
        XCTAssertEqual(row?.bool("deleted"), true, "the removed photo came back as the shot")
        XCTAssertEqual(row?.int("rating"), 5)
        XCTAssertEqual(row?.text("title"), "Removed earlier")
        XCTAssertEqual(try catalog.store.loadDevelopSettings()[removed.id], edits)
        XCTAssertTrue(try catalog.store.loadAssets().contains { $0.id == shot.id }, "the shot is saved")
    }

    // MARK: - catalogs that can't be read

    /// A catalog with a photo in an album, whose albums table can't be read.
    @MainActor
    private func makeUnreadableCatalog() throws -> (url: URL, store: CatalogStore) {
        let broken = try makeCatalog("Broken", assets: [0])
        try broken.store.saveAlbum(Album(id: "al-kept", name: "Kept", assetIds: [DemoData.assets[0].id]))
        try broken.store.db.execChecked("ALTER TABLE albums RENAME TO albums_unreadable;")
        return broken
    }

    /// A catalog part of which can't be read is refused rather than opened as one without
    /// albums, where later edits would build on what's missing.
    @MainActor
    func testCatalogWhoseAlbumsCantBeReadIsRefused() throws {
        let first = try makeCatalog("First", assets: [1])
        let broken = try makeUnreadableCatalog()
        let app = makeApp()
        XCTAssertTrue(app.openCatalog(at: first.url))

        XCTAssertFalse(app.openCatalog(at: broken.url), "a catalog that can't be read opens")

        XCTAssertEqual(app.catalogPath, first.url.path, "the catalog that was open opens again")
        XCTAssertFalse(app.assets.contains { $0.id == DemoData.assets[0].id })
        XCTAssertEqual(app.toastCenter.toasts.last?.message, "打开目录库失败")
    }

    /// The same, opened as the Finder and the recent catalogs open one: in the background.
    @MainActor
    func testCatalogWhoseAlbumsCantBeReadIsRefusedWhenLoadedInTheBackground() async throws {
        let first = try makeCatalog("First", assets: [1])
        let broken = try makeUnreadableCatalog()
        let app = makeApp()
        XCTAssertTrue(app.openCatalog(at: first.url))

        app.openCatalogFromSystem(broken.url)
        try await waitUntil("Timed out waiting for the catalog to load") { !app.isLoadingCatalog }

        XCTAssertEqual(app.catalogPath, first.url.path, "a catalog that can't be read opens")
        XCTAssertFalse(app.assets.contains { $0.id == DemoData.assets[0].id })
        XCTAssertTrue(app.toastCenter.toasts.contains { $0.message == "打开目录库失败" })
    }

    /// Search falls back to the photos in memory when the catalog's search index can't be read,
    /// rather than finding nothing.
    @MainActor
    func testSearchFindsPhotoWhenTheIndexCantBeRead() throws {
        let first = try makeCatalog("First", assets: [0])
        let photo = DemoData.assets[0]
        let app = makeApp()
        XCTAssertTrue(app.openCatalog(at: first.url))
        try first.store.db.execChecked("DROP TABLE asset_search;")

        app.search = photo.filename

        XCTAssertTrue(app.list.contains { $0.id == photo.id }, "the search finds nothing")
    }

    // MARK: - #61 sidecars changed elsewhere

    @MainActor
    func testNewOrClosedCatalogForgetsSidecarChanges() throws {
        let first = try makeCatalog("First", assets: [0])
        let id = DemoData.assets[0].id
        let app = makeApp()

        XCTAssertTrue(app.openCatalog(at: first.url))
        app.applyExternalXMPCheck(seeded: [id: 100], changed: [:])
        app.externallyChangedXMPIds = [id]
        XCTAssertTrue(app.createCatalog(at: root.appendingPathComponent("New.photolibrary")))
        XCTAssertTrue(app.externallyChangedXMPIds.isEmpty, "New Catalog still lists the previous catalog's changed sidecars")
        XCTAssertNil(app.xmpSyncTime(for: id), "New Catalog keeps the previous catalog's sidecar baselines")

        XCTAssertTrue(app.openCatalog(at: first.url))
        app.externallyChangedXMPIds = [id]
        app.closeCatalog()
        XCTAssertTrue(app.externallyChangedXMPIds.isEmpty, "Close Catalog still lists the catalog's changed sidecars")
        XCTAssertNil(app.xmpSyncTime(for: id), "Close Catalog keeps the catalog's sidecar baselines")
    }

    // MARK: - #55 restore snapshot

    @MainActor
    func testRestoringSnapshotThatWontOpenReportsFailureAndKeepsCatalog() throws {
        let first = try makeCatalog("First", assets: [0])
        let id = DemoData.assets[0].id
        let app = makeApp()
        XCTAssertTrue(app.openCatalog(at: first.url))
        // a snapshot from a newer version: a valid backup, but this version can't open it
        let snapshot = root.appendingPathComponent("catalog-newer.sqlite")
        do {
            // closed before it's restored, so its tables are in the file rather than the WAL
            let db = try Database(path: snapshot.path)
            try db.execChecked("CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT);")
            try db.execChecked("CREATE TABLE assets (id TEXT PRIMARY KEY);")
            try db.execChecked("INSERT INTO schema_migrations (version, applied_at) VALUES (\(CatalogStore.latestSchemaVersion + 1), 'x');")
        }

        app.restoreBackup(from: snapshot)

        let toast = try XCTUnwrap(app.toastCenter.toasts.last)
        XCTAssertFalse(toast.message.hasPrefix("已恢复备份"), "says restored: \(toast.message)")
        XCTAssertEqual(toast.icon, "warning")
        XCTAssertTrue(app.hasOpenCatalog, "the catalog is left closed")
        XCTAssertEqual(app.assets.map(\.id), [id], "the catalog as it was before the restore is gone")
    }

    // MARK: - #4 Welcome → Add Photo Folder

    @MainActor
    func testWelcomeImportLoadsCatalogInsteadOfKeepingDemoSet() async throws {
        let catalog = try makeCatalog("Default", assets: [0, 1])
        let firstId = DemoData.assets[0].id, secondId = DemoData.assets[1].id
        try catalog.store.saveAlbum(Album(id: AppState.quickCollectionID, name: "快捷收藏", assetIds: [firstId]),
                                    sortOrder: -1)
        try catalog.store.saveAlbum(Album(id: "al-keep", name: "Keep", assetIds: [firstId, secondId]), sortOrder: 0)
        let app = makeApp()
        XCTAssertTrue(app.openCatalog(at: catalog.url))
        app.closeCatalog()
        // the configured catalog after Close Catalog (the default library) is this scratch one
        UserDefaults.standard.set(catalog.url, forKey: "pc_catalogURL")
        XCTAssertTrue(app.assets.contains { $0.isDemo })

        // Welcome → Add Photo Folder: enters the app, then imports a folder
        app.onboarded = true
        let folder = root.appendingPathComponent("Empty Folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        app.importFolder(folder)
        try await waitUntil("Timed out waiting for the import") { !app.importing }

        XCTAssertTrue(app.hasOpenCatalog)
        XCTAssertFalse(app.assets.contains { $0.isDemo }, "the demo photos stay beside the catalog's")
        XCTAssertEqual(Set(app.assets.map(\.id)), [firstId, secondId])
        XCTAssertEqual(app.quickCollection, [firstId])
        XCTAssertEqual(app.albums.first { $0.id == "al-keep" }?.assetIds, [firstId, secondId])

        select(secondId, in: app)
        XCTAssertTrue(app.toggleQuickCollection())
        XCTAssertEqual(try quickCollection(in: catalog.store), [firstId, secondId],
                       "Quick Collection overwritten")
        XCTAssertEqual(try catalog.store.loadAlbums().first { $0.id == "al-keep" }?.assetIds, [firstId, secondId])
    }

    @MainActor
    func testFirstRunImportCreatesCatalogWithoutDemoSet() async throws {
        let url = root.appendingPathComponent("First Run.photolibrary")
        UserDefaults.standard.set(url, forKey: "pc_catalogURL")
        let app = makeApp()
        XCTAssertFalse(app.hasOpenCatalog)
        XCTAssertTrue(app.assets.contains { $0.isDemo })

        let folder = root.appendingPathComponent("Empty Folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        app.importFolder(folder)
        try await waitUntil("Timed out waiting for the import") { !app.importing }

        XCTAssertTrue(app.hasOpenCatalog)
        XCTAssertEqual(app.catalogPath, url.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("catalog.sqlite").path))
        XCTAssertFalse(app.assets.contains { $0.isDemo }, "the demo photos stay in the new catalog")
        XCTAssertTrue(app.albums.isEmpty, "the demo albums stay in the new catalog")
    }

    // MARK: - #42 while a catalog loads

    @MainActor
    func testImportWaitsForCatalogBeingOpened() async throws {
        let first = try makeCatalog("First", assets: [0])
        let second = try makeCatalog("Second", assets: [1])
        let folder = root.appendingPathComponent("Empty Folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let app = makeApp()
        XCTAssertTrue(app.openCatalog(at: first.url))

        app.openCatalogFromSystem(second.url)
        XCTAssertTrue(app.isLoadingCatalog)
        app.importFolder(folder)
        let refused = !app.importing
        XCTAssertTrue(refused, "an import starts while the catalog is still loading")
        XCTAssertEqual(app.toastCenter.toasts.last?.message, "目录库仍在载入，载入完成后再导入")

        try await waitUntil("Timed out waiting for the catalog to load") { !app.isLoadingCatalog && !app.importing }
        XCTAssertEqual(app.catalogPath, second.url.path)
    }

    @MainActor
    func testEditMadeWhileCatalogLoadsSurvives() async throws {
        let first = try makeCatalog("First", assets: [0])
        let second = try makeCatalog("Second", assets: [2])
        let id = DemoData.assets[2].id
        let app = makeApp()
        XCTAssertTrue(app.openCatalog(at: first.url))
        let gate = HydrationGate()
        defer { gate.open() }
        app.catalogHydrationGate = { await gate.wait() }

        app.openCatalogFromSystem(second.url)
        try await waitUntil("The load never read the full catalog") { gate.reached }
        XCTAssertTrue(app.isLoadingCatalog)
        XCTAssertTrue(app.hasCatalogPreview)
        // the first photos are on screen, and the menus still edit them
        select(id, in: app)
        XCTAssertTrue(app.setRating(4))
        gate.open()
        try await waitUntil("Timed out waiting for the catalog to load") { !app.isLoadingCatalog }

        XCTAssertEqual(try second.store.loadAssets().first { $0.id == id }?.rating, 4)
        XCTAssertEqual(app.assets.first { $0.id == id }?.rating, 4, "the rating made while the catalog loaded is gone")
    }

    @MainActor
    func testLoadedCatalogTakesPhotosEditedMeanwhile() throws {
        var kept = DemoData.assets[0], edited = DemoData.assets[1], removed = DemoData.assets[2]
        let made = DemoData.assets[3]
        kept.rating = 1
        edited.rating = 1
        removed.rating = 1
        var newer = edited
        newer.rating = 5
        var gone = removed
        gone.deleted = true

        let merged = AppState.overlaying([newer, gone, made], onto: [kept, edited, removed])

        XCTAssertEqual(merged.map(\.id), [kept.id, edited.id, made.id])
        XCTAssertEqual(merged.map(\.rating), [1, 5, made.rating])
    }

    @MainActor
    func testPairingChangedWhileCatalogLoadsIsHonored() async throws {
        let first = try makeCatalog("First", assets: [0])
        let url = root.appendingPathComponent("Pairs.photolibrary")
        let store = try CatalogStore(packageURL: url)
        let folder = root.appendingPathComponent("Pair")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var raw = try XCTUnwrap(DemoData.assets.first { $0.isRaw })
        // the RAW's own JPEG: one shot, by its camera at its moment
        var jpeg = PairingCheck.sameShot(try XCTUnwrap(DemoData.assets.first { !$0.isRaw && !$0.isVideo }), as: raw)
        raw.localPath = folder.appendingPathComponent("IMG_0001.CR3").path
        jpeg.localPath = folder.appendingPathComponent("IMG_0001.JPG").path
        for asset in [raw, jpeg] { try Data("x".utf8).write(to: URL(fileURLWithPath: asset.localPath ?? "")) }
        raw.isDemo = false; raw.deleted = false; raw.status = .ready
        jpeg.isDemo = false; jpeg.deleted = false; jpeg.status = .ready
        try store.upsert([raw, jpeg])
        let app = makeApp()
        app.pairRawAndJpeg = true
        XCTAssertTrue(app.openCatalog(at: first.url))
        let gate = HydrationGate()
        defer { gate.open() }
        app.catalogHydrationGate = { await gate.wait() }

        app.openCatalogFromSystem(url)
        try await waitUntil("The load never read the full catalog") { gate.reached }
        app.pairRawAndJpeg = false
        gate.open()
        try await waitUntil("Timed out waiting for the catalog to load") { !app.isLoadingCatalog }

        XCTAssertEqual(app.libraryCounts.all, 2, "counts still pair the RAW and its JPEG")
    }
}
