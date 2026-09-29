// ============================================================
//  Develop history and snapshots — Lightroom's History and Snapshots panels
// ============================================================
import Foundation

/// One saved edit of a photo: what it was called and the settings it left.
struct DevelopHistoryStep: Equatable, Sendable, Identifiable {
    let seq: Int
    let name: String
    let date: Date
    let settings: DevelopSettings

    var id: Int { seq }

    /// Steps kept per photo; older ones are dropped.
    static let limit = 100
}

/// A named state of a photo's settings to come back to.
struct DevelopSnapshot: Equatable, Sendable, Identifiable {
    let id: String
    var name: String
    let date: Date
    var settings: DevelopSettings
}

/// What saving an edit does to the photo's history: a new edit adds a step; undoing it takes
/// that step away again, and redoing puts it back.
enum DevelopHistoryChange: Sendable {
    case append
    case revert
}
