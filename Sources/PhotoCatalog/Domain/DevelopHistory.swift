// ============================================================
//  Develop history and snapshots — Lightroom's History and Snapshots panels
// ============================================================
import Foundation

/// One saved edit of a photo: what it was called and the settings it left.
struct DevelopHistoryStep: Equatable, Sendable, Identifiable {
    let seq: Int
    let name: String
    let date: Date
    /// The settings as stored (sorted-keys JSON). They're decoded only when the step is applied
    /// and compared as text to find the current step: a history of brush-heavy edits would
    /// otherwise decode megabytes whenever the panel shows the photo.
    let json: String

    var id: Int { seq }

    var settings: DevelopSettings {
        (try? JSONDecoder().decode(DevelopSettings.self, from: Data(json.utf8))) ?? .neutral
    }

    init(seq: Int, name: String, date: Date, json: String) {
        self.seq = seq
        self.name = name
        self.date = date
        self.json = json
    }

    init(seq: Int, name: String, date: Date, settings: DevelopSettings) {
        self.init(seq: seq, name: name, date: date, json: Self.json(settings))
    }

    /// The stored form of `settings`, the same text for the same settings.
    static func json(_ settings: DevelopSettings) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(settings)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

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
