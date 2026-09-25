// ============================================================
//  ImportPostActionService — applies configured metadata defaults
//  to newly imported assets.
// ============================================================
import Foundation

struct ImportPostActions: Sendable {
    let keywords: [String]
    let colorLabel: ColorLabel?
    /// Metadata template: set on every imported photo when not empty. `{year}` becomes the
    /// capture year, so "© {year} Name" stays right across old and new photos.
    var author = ""
    var copyright = ""
}

enum ImportPostActionService {
    static func normalizeKeywords(_ raw: String) -> [String] {
        KeywordService.normalize(raw)
    }

    static func apply(to assets: [Asset], actions: ImportPostActions) -> [Asset] {
        let author = actions.author.trimmingCharacters(in: .whitespacesAndNewlines)
        let copyright = actions.copyright.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !actions.keywords.isEmpty || actions.colorLabel != nil || !author.isEmpty || !copyright.isEmpty
        else { return assets }
        return assets.map { asset in
            var updated = asset
            for keyword in actions.keywords where !updated.keywords.contains(keyword) {
                updated.keywords.append(keyword)
            }
            if let colorLabel = actions.colorLabel {
                updated.colorLabel = colorLabel
            }
            if !author.isEmpty { updated.author = author }
            if !copyright.isEmpty {
                let year = Calendar.captureWallClock.component(.year, from: asset.date)
                updated.copyright = copyright.replacingOccurrences(of: "{year}", with: String(year))
            }
            return updated
        }
    }
}
