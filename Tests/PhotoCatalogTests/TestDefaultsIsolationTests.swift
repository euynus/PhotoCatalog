import XCTest
@testable import PhotoCatalog

/// Another `swift test` run on this Mac — an agent's, in another checkout — writes the test
/// runner's preferences at the same time; the app's preferences in this run (`UserDefaults.app`)
/// aren't those.
final class TestDefaultsIsolationTests: XCTestCase {
    func testAnotherTestRunsPreferencesDontReachThisOne() throws {
        let key = "pc_isolationProbe"
        let defaults = UserDefaults.app
        XCTAssertFalse(defaults === UserDefaults.standard, "tests keep a suite of their own")
        defaults.set("this run", forKey: key)
        defer { defaults.removeObject(forKey: key) }
        let domain = try XCTUnwrap(Bundle.main.bundleIdentifier)
        // what a test run in another process does to the runner's shared domain
        let other = Process()
        other.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        other.arguments = ["write", domain, key, "-string", "another run"]
        try other.run()
        other.waitUntilExit()
        defer {
            let cleanup = Process()
            cleanup.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            cleanup.arguments = ["delete", domain, key]
            try? cleanup.run()
            cleanup.waitUntilExit()
        }
        XCTAssertEqual(defaults.string(forKey: key), "this run")
    }
}
