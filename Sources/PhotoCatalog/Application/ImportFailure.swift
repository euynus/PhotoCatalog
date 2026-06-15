// ============================================================
//  ImportFailure — per-file import error shown in the import UI
// ============================================================
import Foundation

struct ImportFailure: Identifiable, Equatable, Sendable {
    let path: String
    let filename: String
    let reason: String

    var id: String { path }

    init(url: URL, reason: String) {
        path = url.path
        filename = url.lastPathComponent
        self.reason = reason
    }
}
