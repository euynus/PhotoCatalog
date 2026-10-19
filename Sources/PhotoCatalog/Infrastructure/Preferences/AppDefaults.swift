// ============================================================
//  The app's preferences store
// ============================================================
import CryptoKit
import Foundation

extension UserDefaults {
    /// The app's preferences: the standard ones, except under XCTest. There every `swift test` on
    /// this Mac shares the test runner's domain, so two runs at once (in two checkouts) changed
    /// each other's open catalog and settings; each checkout's test runs keep a suite of their own.
    static let app: UserDefaults = {
        guard NSClassFromString("XCTestCase") != nil else { return .standard }
        let tests = Bundle.allBundles.first { $0.bundleURL.pathExtension == "xctest" }?.bundlePath
            ?? FileManager.default.currentDirectoryPath
        let digest = SHA256.hash(data: Data(tests.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return UserDefaults(suiteName: "PhotoCatalogTests.\(digest)") ?? .standard
    }()
}
