import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoCatalog

/// A test case that opens scratch catalogs in an `AppState`: the preferences are put back as
/// they were afterwards, and each test gets its own folder under the temporary directory.
class CatalogTestCase: XCTestCase {
    private(set) var scratch: URL!

    override func setUp() {
        super.setUp()
        preservingAllPreferences()
        UserDefaults.app.set(false, forKey: "pc_openLast")
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-\(type(of: self))-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // canonical, as the folder scanner reports paths: /var/folders is a link to /private/var/folders
        scratch = ((try? folder.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath)
            .map { URL(fileURLWithPath: $0, isDirectory: true) }) ?? folder
    }

    override func tearDown() {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        super.tearDown()
    }

    /// An 80×60 JPEG whose pixels differ with `shade`, so two shades are two different files.
    func makeTestJPEG(at url: URL, shade: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let context = CGContext(data: nil, width: 80, height: 60, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw NSError(domain: "CatalogTestSupport", code: 1)
        }
        let level = CGFloat(shade % 16) / 16
        context.setFillColor(CGColor(red: level, green: 1 - level, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        context.setFillColor(CGColor(red: 0.1, green: 0.4, blue: level, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 10 + shade % 40))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString,
                                                                1, nil) else {
            throw NSError(domain: "CatalogTestSupport", code: 2)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "CatalogTestSupport", code: 3) }
    }

    /// A catalog in the scratch folder, `Library.photolibrary`, holding one photo imported from
    /// its source folder `Source`: `name`, an 80×60 JPEG of `shade`.
    func importPhoto(_ name: String, shade: Int) throws
        -> (store: CatalogStore, package: URL, asset: Asset, original: URL) {
        let source = scratch.appendingPathComponent("Source")
        let original = source.appendingPathComponent(name)
        try makeTestJPEG(at: original, shade: shade)
        let package = scratch.appendingPathComponent("Library.photolibrary")
        let store = try CatalogStore(packageURL: package)
        try store.addSourceRoot(id: "source-1", displayName: "Source", path: source.path, bookmark: nil)
        let asset = try XCTUnwrap(ImportCoordinator(store: store)
            .importFiles([original], from: source, sourceRootId: "source-1", folderName: "Source").first)
        try store.upsert([asset])
        return (store, package, asset, original)
    }

    /// `package` opened in a new, onboarded app, which runs no background maintenance unless asked to.
    @MainActor
    func openCatalog(_ package: URL, backgroundMaintenance: Bool = false,
                     file: StaticString = #filePath, line: UInt = #line) -> AppState {
        let app = AppState()
        app.onboarded = true
        app.runsBackgroundMaintenance = backgroundMaintenance
        XCTAssertTrue(app.openCatalog(at: package), file: file, line: line)
        return app
    }

    /// Runs a rescan of the watched folders to its end (including any it queued behind it).
    @MainActor
    func rescanToCompletion(_ app: AppState) async throws {
        app.rescanCurrentSource()
        XCTAssertTrue(app.isIncrementalRescanning, "a rescan started")
        try await waitUntil("rescan finished") { !app.isIncrementalRescanning }
    }
}

extension XCTestCase {
    /// Puts these preferences back as they are now when the test ends: a key that has a value gets
    /// it back, and a key that has none is removed. It's a teardown block, so it runs after the
    /// test method has returned (its defers included) and before `tearDown()`. Teardown blocks run
    /// last registered first: a test's run before those its class registered in `setUp()`, and a
    /// subclass's before its superclass's.
    func preservingPreferences(_ keys: [String]) {
        let saved = PreferenceSnapshot(keys: keys)
        addTeardownBlock { saved.restore() }
    }

    /// Puts every preference back as it is now when the test ends, as `preservingPreferences`
    /// does: for a test that opens catalogs, which writes more than the settings it changes (each
    /// catalog and folder is remembered, a catalog backed up automatically gets its date).
    func preservingAllPreferences() {
        let saved = PreferenceSnapshot(keys: nil)
        addTeardownBlock { saved.restore() }
    }

    /// Has an `AppState()` made in the test open no catalog at launch, so it starts on the demo
    /// photos however the launch settings are left (onboarded, set by another test or for every
    /// app in the global domain, opened the default catalog).
    func openingNoCatalogAtLaunch() {
        preservingAllPreferences()
        UserDefaults.app.set(false, forKey: "pc_openLast")
    }

    /// Waits for `condition`, failing the test after `timeout`.
    @MainActor
    func waitUntil(_ message: String, timeout: TimeInterval = 10,
                   condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail(message)
        throw NSError(domain: "CatalogTestSupport.Wait", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
