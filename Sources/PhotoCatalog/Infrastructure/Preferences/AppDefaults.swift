// ============================================================
//  The app's preferences store
// ============================================================
import CryptoKit
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
        let executable = Bundle.main.executableURL?.path ?? CommandLine.arguments.first ?? ""
        guard let name = headlessCheckSuiteName(arguments: CommandLine.arguments, executablePath: executable),
              let suite = UserDefaults(suiteName: name) else { return .standard }
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

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}
