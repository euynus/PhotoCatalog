import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoCatalog

/// A test case that opens scratch catalogs in an `AppState`: the launch preferences it reads
/// are put back afterwards, and each test gets its own folder under the temporary directory.
class CatalogTestCase: XCTestCase {
    private static let isolatedKeys = ["pc_openLast", "pc_catalogURL", "pc_onboarded", "pc_recentCatalogs",
                                       "pc_pairRawJpeg", "pc_readXMP", "pc_vision", "pc_importMode",
                                       "pc_autoStackSeconds"]
    private(set) var scratch: URL!

    override func setUp() {
        super.setUp()
        preservingPreferences(Self.isolatedKeys)
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
        let saved = SavedPreferences(keys: keys)
        addTeardownBlock { saved.restore() }
    }

    /// Puts every preference back as it is now when the test ends, as `preservingPreferences`
    /// does: for a test that opens catalogs, which writes more than the settings it changes (each
    /// catalog and folder is remembered, a catalog backed up automatically gets its date).
    func preservingAllPreferences() {
        let saved = SavedPreferences(keys: nil)
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

/// Preferences as a test found them in the run's suite (all of them when `keys` is nil), for its
/// teardown block to put back. The suite's own values: one read through from another domain (a
/// key set for every app on the Mac) put back would be the suite's from then on. `Any` isn't
/// `Sendable`, but these are property-list values that nothing changes once they're read.
private struct SavedPreferences: @unchecked Sendable {
    private let suiteName = IsolatedRun.current?.suiteName ?? ""
    private let keys: [String]?
    private let values: [String: Any]

    init(keys: [String]?) {
        let suite = UserDefaults.app.persistentDomain(forName: suiteName) ?? [:]
        self.keys = keys
        values = keys.map { keys in suite.filter { keys.contains($0.key) } } ?? suite
    }

    func restore() {
        let defaults = UserDefaults.app
        guard let keys else {
            defaults.setPersistentDomain(values, forName: suiteName)
            return
        }
        for key in keys {
            if let value = values[key] {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }
}
