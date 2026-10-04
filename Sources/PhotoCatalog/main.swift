// ============================================================
//  Entry point. `--selfcheck` runs a headless dataset sanity check
//  (used in CI / verification); otherwise the SwiftUI app launches.
// ============================================================
import Foundation

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
    FullBackupCheck.run()
    exit(0)
}

if CommandLine.arguments.contains("--task-center-check") {
    TaskCenterCheck.run()
    TaskCenterWorkflowCheck.run()
    exit(0)
}

if CommandLine.arguments.contains("--description-review-check") {
    DescriptionReviewCheck.run()
    DescriptionReviewRequestCheck.run()
    exit(0)
}

if CommandLine.arguments.contains("--selfcheck") {
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
