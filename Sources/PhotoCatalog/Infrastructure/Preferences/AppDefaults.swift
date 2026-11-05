// ============================================================
//  The app's preferences store
// ============================================================
import CryptoKit
import Darwin
import Foundation

extension UserDefaults {
    /// The app's preferences: the standard ones, except under XCTest and in the headless checks.
    /// Under XCTest every `swift test` on this Mac shares the test runner's domain, so two runs at
    /// once (in two checkouts) changed each other's open catalog and settings; each checkout's test
    /// runs keep a suite of their own. The headless checks change settings as they go (and don't
    /// all put them back), in the domain a `swift run` of the app reads; see `headlessCheckSuiteName`.
    static let app: UserDefaults = {
        if NSClassFromString("XCTestCase") != nil {
            let tests = Bundle.allBundles.first { $0.bundleURL.pathExtension == "xctest" }?.bundlePath
                ?? FileManager.default.currentDirectoryPath
            return UserDefaults(suiteName: "PhotoCatalogTests.\(digest(tests))") ?? .standard
        }
        // resolved: `.build/debug` is a link to the build's own folder, and the build script runs that
        let executable = Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments.first ?? ""
        guard let base = headlessCheckSuiteName(arguments: CommandLine.arguments, executablePath: executable) else {
            return .standard
        }
        // held until the run ends: another run of the same check takes the next suite
        let name = claimHeadlessSuite(base, lockDirectory: FileManager.default.temporaryDirectory)?.name ?? base
        guard let suite = UserDefaults(suiteName: name) else { return .standard }
        // each run starts from the app's defaults (and any `-pc_…` arguments, which every suite reads)
        suite.removePersistentDomain(forName: name)
        return suite
    }()

    /// The suite a headless check mode (`--selfcheck`, `--pipeline`, `--scale`, the `--…-check`
    /// modes) keeps its settings in: one per checkout (its binary) and mode, so a check never
    /// changes what an app run reads, and checks in two checkouts, or two modes at once, don't
    /// change each other's settings mid-run. Nil for an app run.
    static func headlessCheckSuiteName(arguments: [String], executablePath: String) -> String? {
        let modes: Set<String> = ["--selfcheck", "--pipeline", "--scale"]
        guard let mode = arguments.dropFirst().first(where: {
            modes.contains($0) || ($0.hasPrefix("--") && $0.hasSuffix("-check"))
        }) else { return nil }
        return "PhotoCatalogChecks.\(digest(executablePath)).\(mode.dropFirst(2))"
    }

    /// The suite `base`, or `base.2`, `base.3`… while other runs of the same check hold the ones
    /// before: each run holds its suite's lock (a file in `lockDirectory`, open for as long as
    /// `lock` is) until it ends. Nil when no lock can be taken.
    static func claimHeadlessSuite(_ base: String, lockDirectory: URL) -> (name: String, lock: Int32)? {
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

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}
