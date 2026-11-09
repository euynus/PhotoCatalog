// ============================================================
//  The app's preferences store, and what a test or check run keeps apart
// ============================================================
import Darwin
import Foundation

/// A run that must leave the user's own settings and files alone: XCTest, and the headless checks
/// (`--selfcheck`, `--pipeline`, `--scale`, the `--…-check` modes). Each run holds a preferences
/// suite of its own, emptied as it starts, so nothing a test or check leaves behind reaches the
/// next run, and a stand-in for the Pictures folder in the temporary folder, emptied too. The
/// default catalog, export, card-copy and tether locations are in Pictures, so a test or check
/// that falls back on one never reaches the user's library: tests that made an `AppState` with
/// the launch settings left as they were opened the user's own catalog and backed it up.
struct IsolatedRun: Sendable {
    /// The preferences suite this run holds.
    let suiteName: String
    /// What stands in for the user's Pictures folder: empty as the run starts.
    let picturesFolder: URL

    /// This process's; nil for an app run.
    static let current: IsolatedRun? = {
        let testing = NSClassFromString("XCTestCase") != nil
        guard let base = suiteBase(arguments: CommandLine.arguments, testing: testing) else { return nil }
        return claim(base, in: FileManager.default.temporaryDirectory)
    }()

    /// The suite a run starts from: one for XCTest and one per check mode. Nil for an app run.
    static func suiteBase(arguments: [String], testing: Bool) -> String? {
        if testing { return "PhotoCatalogTests" }
        let modes: Set<String> = ["--selfcheck", "--pipeline", "--scale"]
        guard let mode = arguments.dropFirst().first(where: {
            modes.contains($0) || ($0.hasPrefix("--") && $0.hasSuffix("-check"))
        }) else { return nil }
        return "PhotoCatalogChecks.\(mode.dropFirst(2))"
    }

    /// Takes the suite `base`, or the first of `base.2`, `base.3`… that no other run holds (two
    /// test runs at once, in two checkouts, or two `--selfcheck`s), emptied for this run.
    static func claim(_ base: String, in directory: URL) -> IsolatedRun {
        // with every suite held, one of this process's own rather than another run's
        fresh(claimSuite(base, lockDirectory: directory)?.name ?? "\(base).\(getpid())", in: directory)
    }

    /// The suite `name` and its Pictures folder in `directory`, emptied of what a run before left.
    static func fresh(_ name: String, in directory: URL) -> IsolatedRun {
        // the app's defaults, and any `-pc_…` arguments, which every suite reads
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        let fm = FileManager.default
        let pictures = directory.appendingPathComponent(name + ".Pictures", isDirectory: true)
        try? fm.removeItem(at: pictures)
        try? fm.createDirectory(at: pictures, withIntermediateDirectories: true)
        // canonical, as the folder scanner reports paths: /var/folders is a link to /private/var/folders
        let canonical = (try? pictures.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath)
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        return IsolatedRun(suiteName: name, picturesFolder: canonical ?? pictures)
    }

    /// The suite `base`, or `base.2`, `base.3`… while other runs hold the ones before: each run
    /// holds its suite's lock (a file in `lockDirectory`, open for as long as `lock` is) until it
    /// ends. Nil when no lock can be taken.
    static func claimSuite(_ base: String, lockDirectory: URL) -> (name: String, lock: Int32)? {
        for index in 1...16 {
            let name = index == 1 ? base : "\(base).\(index)"
            let file = lockDirectory.appendingPathComponent(name + ".lock").path
            let lock = open(file, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            guard lock >= 0 else { return nil }
            if flock(lock, LOCK_EX | LOCK_NB) == 0 { return (name, lock) }
            close(lock)
        }
        return nil
    }
}

/// Preferences as a test or check found them in the run's suite (all of them when `keys` is
/// nil), for it to put back when it ends: a key that had a value gets it back, and a key that had
/// none is removed. The suite's own values: one read through from another domain (a key set for
/// every app on the Mac) put back would be the suite's from then on. `Any` isn't `Sendable`, but
/// these are property-list values that nothing changes once they're read.
struct PreferenceSnapshot: @unchecked Sendable {
    private let suiteName: String
    private let keys: [String]?
    private let values: [String: Any]

    init(keys: [String]?) {
        // an app run has no suite of its own: its snapshot would hold nothing, and restoring it
        // would remove the user's settings
        guard let run = IsolatedRun.current else {
            preconditionFailure("preferences are put back only in a test or check run")
        }
        suiteName = run.suiteName
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

extension UserDefaults {
    /// The app's preferences: the standard ones, except in a test or check run, which keeps a
    /// suite of its own (see `IsolatedRun`). Every `swift test` on this Mac shares the test
    /// runner's domain, and a `swift run` of the app reads the one the checks would otherwise use.
    static let app: UserDefaults = IsolatedRun.current.flatMap { UserDefaults(suiteName: $0.suiteName) } ?? .standard
}
