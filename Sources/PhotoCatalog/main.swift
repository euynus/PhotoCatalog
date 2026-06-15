// ============================================================
//  Entry point. `--selfcheck` runs a headless dataset sanity check
//  (used in CI / verification); otherwise the SwiftUI app launches.
// ============================================================
import Foundation

if CommandLine.arguments.contains("--selfcheck") {
    SelfCheck.run()
    exit(0)
}

if CommandLine.arguments.contains("--pipeline") {
    PipelineCheck.run()   // calls exit() itself
}

PhotoCatalogApp.main()
