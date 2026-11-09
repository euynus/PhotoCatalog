// ============================================================
//  The binary's command-line options: the headless modes main.swift runs, and what it does
//  with an option it doesn't know.
// ============================================================
import Foundation

enum LaunchOptions {
    /// Every `--` option the binary takes (`--benchmark` goes with `--selfcheck`).
    static let known: Set<String> = [
        "--selfcheck", "--benchmark", "--pipeline", "--scale", "--import-memory-check",
        "--full-backup-check", "--task-center-check", "--description-review-check",
    ]

    /// The first `--` option that isn't one of `known` (a typo, `--help`), if any. Opened from the
    /// Finder or `open`, the app gets none; a catalog path or `-pc_…` setting is not an option.
    static func unknownOption(in arguments: [String]) -> String? {
        arguments.dropFirst().first { $0.hasPrefix("--") && !known.contains($0) }
    }

    static let usage = """
        Usage: PhotoCatalog [catalog.photolibrary]
               PhotoCatalog --selfcheck [--benchmark] | --pipeline | --full-backup-check
                            | --task-center-check | --description-review-check
               PhotoCatalog --scale <photos> [catalog.photolibrary]
               PhotoCatalog --import-memory-check <image> [20...1000]

        """
}
