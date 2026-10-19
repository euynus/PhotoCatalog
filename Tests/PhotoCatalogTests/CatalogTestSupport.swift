import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoCatalog

/// A test case that opens scratch catalogs in an `AppState`: the launch preferences it reads
/// are put back afterwards, and each test gets its own folder under the temporary directory.
class CatalogTestCase: XCTestCase {
    private static let isolatedKeys = ["pc_openLast", "pc_catalogURL", "pc_onboarded", "pc_recentCatalogs",
                                       "pc_pairRawJpeg", "pc_readXMP", "pc_vision", "pc_importMode"]
    private var savedDefaults: [String: Any] = [:]
    private(set) var scratch: URL!

    override func setUp() {
        super.setUp()
        for key in Self.isolatedKeys {
            if let value = UserDefaults.app.object(forKey: key) { savedDefaults[key] = value }
        }
        UserDefaults.app.set(false, forKey: "pc_openLast")
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-\(type(of: self))-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // canonical, as the folder scanner reports paths: /var/folders is a link to /private/var/folders
        scratch = ((try? folder.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath)
            .map { URL(fileURLWithPath: $0, isDirectory: true) }) ?? folder
    }

    override func tearDown() {
        for key in Self.isolatedKeys {
            if let value = savedDefaults[key] {
                UserDefaults.app.set(value, forKey: key)
            } else {
                UserDefaults.app.removeObject(forKey: key)
            }
        }
        savedDefaults = [:]
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

    /// Runs a rescan of the watched folders to its end (including any it queued behind it).
    @MainActor
    func rescanToCompletion(_ app: AppState) async throws {
        app.rescanCurrentSource()
        XCTAssertTrue(app.isIncrementalRescanning, "a rescan started")
        try await waitUntil("rescan finished") { !app.isIncrementalRescanning }
    }
}
