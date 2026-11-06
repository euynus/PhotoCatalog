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
    /// suite of their own per mode, so they never touch what an app run reads, nor each other's.
    func testHeadlessChecksKeepASuiteOfTheirOwn() {
        let binary = "/work/a/.build/debug/PhotoCatalog"
        XCTAssertNil(IsolatedRun.suiteBase(arguments: [binary], testing: false), "an app run keeps its own preferences")
        XCTAssertNil(IsolatedRun.suiteBase(arguments: [binary, "/x/Library.photolibrary"], testing: false))
        let modes = ["--selfcheck", "--pipeline", "--scale", "--import-memory-check", "--full-backup-check",
                     "--task-center-check", "--description-review-check"]
        let names = modes.map { IsolatedRun.suiteBase(arguments: [binary, $0, "-pc_pairRawJpeg", "YES"], testing: false) }
        XCTAssertFalse(names.contains(nil), "every headless mode keeps its own suite")
        XCTAssertEqual(Set(names).count, modes.count, "one per mode, so two modes at once don't meet")
        XCTAssertEqual(IsolatedRun.suiteBase(arguments: [binary, "--selfcheck", "--benchmark"], testing: false), names[0])
        XCTAssertFalse(names.contains(IsolatedRun.suiteBase(arguments: [binary], testing: true)), "nor the tests'")
    }

    /// Two runs at once (two `--selfcheck`s, or test runs in two checkouts) each take a suite: the
    /// second takes the next one while the first holds its own, and it's free again once let go.
    func testTwoRunsAtOnceTakeASuiteEach() throws {
        let locks = FileManager.default.temporaryDirectory.appendingPathComponent("SuiteLocks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: locks) }
        let base = "PhotoCatalogChecks.test.selfcheck"
        let first = try XCTUnwrap(IsolatedRun.claimSuite(base, lockDirectory: locks))
        let second = try XCTUnwrap(IsolatedRun.claimSuite(base, lockDirectory: locks))
        XCTAssertEqual(first.name, base)
        XCTAssertEqual(second.name, base + ".2")
        close(first.lock)
        let third = try XCTUnwrap(IsolatedRun.claimSuite(base, lockDirectory: locks))
        XCTAssertEqual(third.name, base, "the first suite is free again")
        close(second.lock)
        close(third.lock)
    }

    /// A run starts from nothing a run before left: its suite is emptied, and so is its Pictures
    /// folder. Settings left behind piled up run after run (remembered folders, a backup date for
    /// every catalog a test made), and one a test left set had later tests open a catalog.
    func testARunStartsWithNothingTheRunBeforeLeft() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("IsolatedRun-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // held while the test runs, so a run at the same time takes another
        let held = try XCTUnwrap(IsolatedRun.claimSuite("PhotoCatalogTests.probe",
                                                        lockDirectory: FileManager.default.temporaryDirectory))
        defer { close(held.lock) }
        let name = held.name
        let leftover = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { leftover.removePersistentDomain(forName: name) }
        leftover.set("1", forKey: "pc_onboarded")
        let library = directory.appendingPathComponent(name + ".Pictures/PhotoCatalog Library.photolibrary")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)

        let run = IsolatedRun.fresh(name, in: directory)
        XCTAssertEqual(run.suiteName, name)
        // the suite's own: a key set for every app (in the global domain) still reads through
        XCTAssertEqual(UserDefaults(suiteName: name)?.persistentDomain(forName: name)?.count ?? 0, 0,
                       "the suite starts empty")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: run.picturesFolder.path), [],
                       "and so does the Pictures folder")
        XCTAssertEqual(run.picturesFolder.lastPathComponent, name + ".Pictures")
    }

    /// The default catalog, export, card-copy and tether locations are in the Pictures folder: a
    /// test run's are in its own, never in the user's, where the user's library is.
    func testDefaultLocationsAreTheRunsOwn() throws {
        let run = try XCTUnwrap(IsolatedRun.current, "a test run keeps apart")
        UserDefaults.app.set("this run", forKey: "pc_isolationProbe")
        defer { UserDefaults.app.removeObject(forKey: "pc_isolationProbe") }
        XCTAssertEqual(UserDefaults(suiteName: run.suiteName)?.string(forKey: "pc_isolationProbe"), "this run",
                       "the app's preferences are the run's suite")
        let users = try XCTUnwrap(FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first)
            .resolvingSymlinksInPath().path + "/"
        XCTAssertEqual(FileAccessService.picturesFolder, run.picturesFolder)
        for path in [CatalogStore.defaultURL.path, CardImportOptions.standard.destination.path,
                     TetherSettings.defaultDestination] {
            XCTAssertTrue(path.hasPrefix(run.picturesFolder.path + "/"), path)
            XCTAssertFalse(path.hasPrefix(users), path)
        }
    }

    /// An `AppState` made with the launch settings as another test left them (onboarded, opening
    /// the last catalog, none named) falls back on the default catalog: the run's own, never the
    /// user's library, which tests opened and backed up before.
    @MainActor
    func testAnAppStateFallingBackOnTheDefaultCatalogNeverOpensTheUsers() throws {
        preservingAllPreferences()
        let defaults = UserDefaults.app
        defaults.set("1", forKey: "pc_onboarded")
        for key in ["pc_openLast", "pc_catalogURL", "pc_renderedExportFolder"] { defaults.removeObject(forKey: key) }
        let run = try XCTUnwrap(IsolatedRun.current)

        let app = AppState()
        if let store = app.store {
            XCTAssertTrue(store.packageURL.path.hasPrefix(run.picturesFolder.path + "/"), store.packageURL.path)
        }
        XCTAssertTrue(app.renderedExportFolder.hasPrefix(run.picturesFolder.path + "/"), app.renderedExportFolder)
    }
}
