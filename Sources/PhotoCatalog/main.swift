// ============================================================
//  Entry point. `--selfcheck` runs a headless dataset sanity check
//  (used in CI / verification); otherwise the SwiftUI app launches.
// ============================================================
import Foundation

/// Stops a check that verifies with `assert` when this build compiles assertions out (Release):
/// `--selfcheck` and the other `--…-check` modes below would check nothing there and still say they
/// passed. It exits with status 2. `--pipeline`, `--scale` and `--import-memory-check` judge their own
/// results and run in any build.
func requireAssertions(for flag: String) {
    var assertionsRun = false
    assert({ assertionsRun = true; return true }())
    guard !assertionsRun else { return }
    let message = """
        PhotoCatalog \(flag): this optimized build compiles out the assert() calls the check relies on, \
        so it would check nothing. Build Debug (script/build_and_run.sh build, or CONFIGURATION=debug) \
        and run ./.build/debug/PhotoCatalog \(flag).

        """
    FileHandle.standardError.write(Data(message.utf8))
    exit(2)
}

if let index = CommandLine.arguments.firstIndex(of: "--import-memory-check") {
    let arguments = Array(CommandLine.arguments.dropFirst(index + 1))
    Task.detached { exit(ImportMemoryCheck.run(arguments: arguments)) }
    dispatchMain()
}

if let index = CommandLine.arguments.firstIndex(of: "--scale") {
    let arguments = Array(CommandLine.arguments.dropFirst(index + 1))
    exit(MainActor.assumeIsolated { ScaleCheck.run(arguments: arguments) })
}

if CommandLine.arguments.contains("--full-backup-check") {
    requireAssertions(for: "--full-backup-check")
    FullBackupCheck.run()
    exit(0)
}

if CommandLine.arguments.contains("--task-center-check") {
    requireAssertions(for: "--task-center-check")
    TaskCenterCheck.run()
    TaskCenterWorkflowCheck.run()
    exit(0)
}

if CommandLine.arguments.contains("--description-review-check") {
    requireAssertions(for: "--description-review-check")
    DescriptionReviewCheck.run()
    DescriptionReviewRequestCheck.run()
    exit(0)
}

if CommandLine.arguments.contains("--selfcheck") {
    requireAssertions(for: "--selfcheck")
    SelfCheck.run()
    Task { @MainActor in
        await CaptureAnalysisCheck.runAsync()
        exit(0)
    }
    dispatchMain()
}

if CommandLine.arguments.contains("--pipeline") {
    PipelineCheck.run()   // calls exit() itself
}

PhotoCatalogApp.main()
