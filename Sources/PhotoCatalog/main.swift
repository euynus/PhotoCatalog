// ============================================================
//  Entry point. `--selfcheck` runs a headless dataset sanity check
//  (used in CI / verification); otherwise the SwiftUI app launches.
// ============================================================
import Foundation

if CommandLine.arguments.contains("--selfcheck") {
    SelfCheck.run()
    exit(0)
}

PhotoCatalogApp.main()
