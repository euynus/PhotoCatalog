import XCTest
import AppKit
import UniformTypeIdentifiers
@preconcurrency @testable import PhotoCatalog

/// Catalogs opened from the Finder. A `.photolibrary` package has Apple's type
/// (`com.apple.photo.library`, which Photos opens); the app declares it as a document type so
/// Finder offers PhotoCatalog in Open With, and a catalog handed over that way opens.
final class CatalogDocumentTypeTests: CatalogTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    override func setUp() {
        super.setUp()
        // never the real library, even on a fallback path
        UserDefaults.app.set(scratch.appendingPathComponent("Fallback.photolibrary"), forKey: "pc_catalogURL")
    }

    /// The Info.plist script/build_and_run.sh writes into the app bundle.
    private func infoPlist() throws -> [String: Any] {
        let (status, data) = try writeInfoPlist()
        XCTAssertEqual(status, 0, "script/info_plist.sh failed")
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String: Any], "script/info_plist.sh wrote no dictionary")
    }

    /// Runs script/info_plist.sh's write_info_plist with `environment` added (or replacing the
    /// defaults): its exit status and what it printed.
    private func writeInfoPlist(_ environment: [String: String] = [:]) throws -> (Int32, Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "source \"$1\" && write_info_plist", "bash",
                             Self.repoRoot.appendingPathComponent("script/info_plist.sh").path]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "APP_NAME": "PhotoCatalog",
                               "BUNDLE_ID": "com.photocatalog.app", "APP_VERSION": "1.0", "BUILD_NUMBER": "1",
                               "MIN_SYSTEM_VERSION": "14.0", "COPYRIGHT": "Copyright © 2026 euynus"]
            .merging(environment) { _, added in added }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }

    /// App Store Connect wants the Xcode and SDK an upload was built with: an App Store build
    /// whose toolchain can't be read stops, rather than going out without them.
    func testAppStoreInfoPlistNeedsTheToolchain() throws {
        let bin = scratch.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let xcodebuild = bin.appendingPathComponent("xcodebuild")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: xcodebuild)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: xcodebuild.path)
        let path = bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin"

        let (failing, _) = try writeInfoPlist(["PATH": path, "APPSTORE": "1", "SDK_PATH": "/nonexistent.sdk"])
        XCTAssertNotEqual(failing, 0, "an App Store Info.plist went out without DTXcode and DTSDKBuild")
        let (unset, _) = try writeInfoPlist(["APPSTORE": "1"])
        XCTAssertNotEqual(unset, 0, "an App Store Info.plist went out without knowing its SDK")
        // a developer's build without Xcode still gets its Info.plist
        let (developer, data) = try writeInfoPlist(["PATH": path, "SDK_PATH": "/nonexistent.sdk"])
        XCTAssertEqual(developer, 0)
        XCTAssertNotNil(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
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
        let first = scratch.appendingPathComponent("First.photolibrary")
        delegate.application(NSApplication.shared, open: [first, scratch.appendingPathComponent("IMG_0001.JPG")])

        var opened: [URL] = []
        delegate.openCatalogURL = { opened.append($0) }
        XCTAssertEqual(opened, [first], "a catalog opened at launch is lost, or another file is taken for one")

        let second = scratch.appendingPathComponent("Second.photolibrary")
        delegate.application(NSApplication.shared, open: [second])
        XCTAssertEqual(opened, [first, second])
    }

    @MainActor
    func testCatalogOpenedFromFinderOpensFromTheWelcomeScreen() async throws {
        // a catalog this Mac has never opened, with the Welcome screen showing
        let url = scratch.appendingPathComponent("Holiday.photolibrary")
        let source = scratch.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        var asset = DemoData.assets[3]
        let original = source.appendingPathComponent(asset.filename)
        try Data("image".utf8).write(to: original)
        asset.localPath = original.path
        asset.status = .ready
        asset.isDemo = false
        asset.deleted = false
        try CatalogStore(packageURL: url).upsert([asset])
        UserDefaults.app.set("0", forKey: "pc_onboarded")
        UserDefaults.app.set([String](), forKey: "pc_recentCatalogs")

        let app = AppState()
        app.runsBackgroundMaintenance = false
        XCTAssertFalse(app.onboarded)
        XCTAssertFalse(app.hasOpenCatalog)

        // as PhotoCatalogApp wires it: the open event can arrive before the window does
        let delegate = AppDelegate()
        delegate.application(NSApplication.shared, open: [url])
        delegate.openCatalogURL = { app.openCatalogFromSystem($0) }
        try await waitUntil("Timed out waiting for the catalog to load", timeout: 3) { !app.isLoadingCatalog }

        XCTAssertTrue(app.hasOpenCatalog)
        XCTAssertEqual(app.catalogPath, url.path)
        XCTAssertEqual(app.assets.map(\.id), [asset.id])
        XCTAssertTrue(app.onboarded, "the Welcome screen stays over the opened catalog")
        XCTAssertEqual(app.recentCatalogs.first?.path, url.path)
    }
}
