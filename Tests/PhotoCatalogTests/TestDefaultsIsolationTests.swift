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

    /// The headless checks (`--selfcheck`, `--pipeline`, …) change settings as they go; they keep a
    /// suite of their own per checkout and mode, so they never touch what an app run reads.
    func testHeadlessChecksKeepASuiteOfTheirOwn() {
        let binary = "/work/a/.build/debug/PhotoCatalog"
        XCTAssertNil(UserDefaults.headlessCheckSuiteName(arguments: [binary], executablePath: binary),
                     "an app run keeps its own preferences")
        XCTAssertNil(UserDefaults.headlessCheckSuiteName(arguments: [binary, "/x/Library.photolibrary"],
                                                         executablePath: binary))
        let modes = ["--selfcheck", "--pipeline", "--scale", "--import-memory-check", "--full-backup-check",
                     "--task-center-check", "--description-review-check"]
        let names = modes.map {
            UserDefaults.headlessCheckSuiteName(arguments: [binary, $0, "-pc_pairRawJpeg", "YES"], executablePath: binary)
        }
        XCTAssertFalse(names.contains(nil), "every headless mode keeps its own suite")
        XCTAssertEqual(Set(names).count, modes.count, "one per mode, so two modes at once don't meet")
        XCTAssertEqual(UserDefaults.headlessCheckSuiteName(arguments: [binary, "--selfcheck", "--benchmark"],
                                                           executablePath: binary), names[0])
        XCTAssertNotEqual(UserDefaults.headlessCheckSuiteName(arguments: ["x", "--selfcheck"],
                                                              executablePath: "/work/b/.build/debug/PhotoCatalog"),
                          names[0], "nor do two checkouts")
    }

    /// Two runs of one check in one checkout at once (two `--selfcheck`s) each take a suite: the
    /// second takes the next one while the first holds its own, and it's free again once let go.
    func testTwoRunsOfOneCheckAtOnceTakeASuiteEach() throws {
        let locks = FileManager.default.temporaryDirectory.appendingPathComponent("SuiteLocks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: locks) }
        let base = "PhotoCatalogChecks.test.selfcheck"
        let first = try XCTUnwrap(UserDefaults.claimHeadlessSuite(base, lockDirectory: locks))
        let second = try XCTUnwrap(UserDefaults.claimHeadlessSuite(base, lockDirectory: locks))
        XCTAssertEqual(first.name, base)
        XCTAssertEqual(second.name, base + ".2")
        close(first.lock)
        let third = try XCTUnwrap(UserDefaults.claimHeadlessSuite(base, lockDirectory: locks))
        XCTAssertEqual(third.name, base, "the first suite is free again")
        close(second.lock)
        close(third.lock)
    }
}
