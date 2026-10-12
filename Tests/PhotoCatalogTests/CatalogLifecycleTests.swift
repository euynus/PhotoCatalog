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
}
