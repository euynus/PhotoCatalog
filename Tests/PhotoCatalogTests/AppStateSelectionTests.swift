import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoCatalog

final class AppStateSelectionTests: XCTestCase {
    private var previousOpenLast: Any?
    private var previousCatalogURL: Any?
    private var previousOnboarded: Any?
    private var previousPinnedSidebarItems: Any?
    private var previousRecentCatalogs: Any?
    private var previousRenameTemplate: Any?

    override func setUp() {
        super.setUp()
        previousOpenLast = UserDefaults.app.object(forKey: "pc_openLast")
        previousCatalogURL = UserDefaults.app.object(forKey: "pc_catalogURL")
        previousOnboarded = UserDefaults.app.object(forKey: "pc_onboarded")
        previousPinnedSidebarItems = UserDefaults.app.object(forKey: "pc_pinnedSidebarItems")
        previousRecentCatalogs = UserDefaults.app.object(forKey: "pc_recentCatalogs")
        previousRenameTemplate = UserDefaults.app.object(forKey: "pc_renameTemplate")
        UserDefaults.app.set(false, forKey: "pc_openLast")
        UserDefaults.app.removeObject(forKey: "pc_pinnedSidebarItems")
    }

    override func tearDown() {
        if let previousOpenLast {
            UserDefaults.app.set(previousOpenLast, forKey: "pc_openLast")
        } else {
            UserDefaults.app.removeObject(forKey: "pc_openLast")
        }
        if let previousCatalogURL {
            UserDefaults.app.set(previousCatalogURL, forKey: "pc_catalogURL")
        } else {
            UserDefaults.app.removeObject(forKey: "pc_catalogURL")
        }
        if let previousOnboarded {
            UserDefaults.app.set(previousOnboarded, forKey: "pc_onboarded")
        } else {
            UserDefaults.app.removeObject(forKey: "pc_onboarded")
        }
        if let previousPinnedSidebarItems {
            UserDefaults.app.set(previousPinnedSidebarItems, forKey: "pc_pinnedSidebarItems")
        } else {
            UserDefaults.app.removeObject(forKey: "pc_pinnedSidebarItems")
        }
        if let previousRecentCatalogs {
            UserDefaults.app.set(previousRecentCatalogs, forKey: "pc_recentCatalogs")
        } else {
            UserDefaults.app.removeObject(forKey: "pc_recentCatalogs")
        }
        if let previousRenameTemplate {
            UserDefaults.app.set(previousRenameTemplate, forKey: "pc_renameTemplate")
        } else {
            UserDefaults.app.removeObject(forKey: "pc_renameTemplate")
        }
        super.tearDown()
    }

    @MainActor
    @nonobjc
    func waitUntil(_ message: String, timeout: TimeInterval = 1,
                   condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail(message)
        throw NSError(domain: "PhotoCatalogTests.Wait", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: message])
    }

    func makeCatalogWithOneAsset(at package: URL, assetIndex: Int) throws -> CatalogStore {
        let source = package.deletingLastPathComponent().appendingPathComponent("Source-\(assetIndex)")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let store = try CatalogStore(packageURL: package)
        var asset = DemoData.assets[assetIndex]
        let original = source.appendingPathComponent(asset.filename)
        try Data("image \(assetIndex)".utf8).write(to: original)
        asset.localPath = original.path
        asset.status = .ready
        asset.isDemo = false
        asset.deleted = false
        try store.upsert([asset])
        return store
    }

    func writeTestJPEG(to url: URL, black: Bool, gps: [CFString: Any]? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil,
                                      width: 80,
                                      height: 60,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw NSError(domain: "PhotoCatalogTests", code: 1)
        }
        context.setFillColor(black ? CGColor.black : CGColor(red: 0.7, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        if !black {
            context.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 30))
        }
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                                UTType.jpeg.identifier as CFString,
                                                                1,
                                                                nil) else {
            throw NSError(domain: "PhotoCatalogTests", code: 2)
        }
        var properties: [CFString: Any] = [:]
        if let gps { properties[kCGImagePropertyGPSDictionary] = gps }
        CGImageDestinationAddImage(destination, image, properties.isEmpty ? nil : properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "PhotoCatalogTests", code: 3)
        }
    }
}
