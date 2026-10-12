import XCTest
import AppKit
import UniformTypeIdentifiers
@preconcurrency @testable import PhotoCatalog

/// Catalogs opened from the Finder. A `.photolibrary` package has Apple's type
/// (`com.apple.photo.library`, which Photos opens); the app declares it as a document type so
/// Finder offers PhotoCatalog in Open With, and a catalog handed over that way opens.
final class CatalogDocumentTypeTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let defaultsKeys = ["pc_openLast", "pc_catalogURL", "pc_onboarded", "pc_recentCatalogs"]
    private var previousDefaults: [String: Any] = [:]
    private var root: URL!

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        for key in Self.defaultsKeys {
            if let value = defaults.object(forKey: key) { previousDefaults[key] = value }
        }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pc-document-type-\(UUID().uuidString)")
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

    /// The Info.plist script/build_and_run.sh writes into the app bundle.
    private func infoPlist() throws -> [String: Any] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "source \"$1\" && write_info_plist", "bash",
                             Self.repoRoot.appendingPathComponent("script/info_plist.sh").path]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "APP_NAME": "PhotoCatalog",
                               "BUNDLE_ID": "com.photocatalog.app", "APP_VERSION": "1.0", "BUILD_NUMBER": "1",
                               "MIN_SYSTEM_VERSION": "14.0", "COPYRIGHT": "Copyright © 2026 euynus"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "script/info_plist.sh failed")
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String: Any], "script/info_plist.sh wrote no dictionary")
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
        throw NSError(domain: "CatalogDocumentTypeTests.Wait", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: message])
    }

    func testInfoPlistOffersTheAppForCatalogPackages() throws {
        // the type the system gives a catalog package, whose default app is Photos
        XCTAssertEqual(UTType(filenameExtension: "photolibrary", conformingTo: .directory)?.identifier,
                       "com.apple.photo.library")

        let plist = try infoPlist()
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "com.photocatalog.app")
        let types = plist["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
        let catalog = types.first { ($0["LSItemContentTypes"] as? [String])?.contains("com.apple.photo.library") == true }
        XCTAssertNotNil(catalog, "no document type for com.apple.photo.library: Finder never offers the app for a catalog")
        XCTAssertEqual(catalog?["CFBundleTypeRole"] as? String, "Editor")
        // Photos keeps double-click until the user picks PhotoCatalog: the type is Apple's
        XCTAssertEqual(catalog?["LSHandlerRank"] as? String, "Alternate")
        XCTAssertEqual(catalog?["LSTypeIsPackage"] as? Bool, true)
        XCTAssertNil(plist["UTImportedTypeDeclarations"], "the app must not redeclare Apple's type")
    }

    @MainActor
    func testCatalogsOpenedBeforeTheWindowAppearsAreHandedOnOnce() {
        let delegate = AppDelegate()
        let first = root.appendingPathComponent("First.photolibrary")
        delegate.application(NSApplication.shared, open: [first, root.appendingPathComponent("IMG_0001.JPG")])

        var opened: [URL] = []
        delegate.openCatalogURL = { opened.append($0) }
        XCTAssertEqual(opened, [first], "a catalog opened at launch is lost, or another file is taken for one")

        let second = root.appendingPathComponent("Second.photolibrary")
        delegate.application(NSApplication.shared, open: [second])
        XCTAssertEqual(opened, [first, second])
    }

    @MainActor
    func testCatalogOpenedFromFinderOpensFromTheWelcomeScreen() async throws {
        // a catalog this Mac has never opened, with the Welcome screen showing
        let url = root.appendingPathComponent("Holiday.photolibrary")
        let source = root.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        var asset = DemoData.assets[3]
        let original = source.appendingPathComponent(asset.filename)
        try Data("image".utf8).write(to: original)
        asset.localPath = original.path
        asset.status = .ready
        asset.isDemo = false
        asset.deleted = false
        try CatalogStore(packageURL: url).upsert([asset])
        UserDefaults.standard.set("0", forKey: "pc_onboarded")
        UserDefaults.standard.set([String](), forKey: "pc_recentCatalogs")

        let app = AppState()
        app.runsBackgroundMaintenance = false
        XCTAssertFalse(app.onboarded)
        XCTAssertFalse(app.hasOpenCatalog)

        // as PhotoCatalogApp wires it: the open event can arrive before the window does
        let delegate = AppDelegate()
        delegate.application(NSApplication.shared, open: [url])
        delegate.openCatalogURL = { app.openCatalogFromSystem($0) }
        try await waitUntil("Timed out waiting for the catalog to load") { !app.isLoadingCatalog }

        XCTAssertTrue(app.hasOpenCatalog)
        XCTAssertEqual(app.catalogPath, url.path)
        XCTAssertEqual(app.assets.map(\.id), [asset.id])
        XCTAssertTrue(app.onboarded, "the Welcome screen stays over the opened catalog")
        XCTAssertEqual(app.recentCatalogs.first?.path, url.path)
    }
}
