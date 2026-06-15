// ============================================================
//  ImportPostActionService — applies configured metadata defaults
//  to newly imported assets.
// ============================================================
import Foundation

struct ImportPostActions: Sendable {
    let keywords: [String]
    let colorLabel: ColorLabel?
}

enum ImportPostActionService {
    static func normalizeKeywords(_ raw: String) -> [String] {
        KeywordService.normalize(raw)
    }

    static func apply(to assets: [Asset], actions: ImportPostActions) -> [Asset] {
        guard !actions.keywords.isEmpty || actions.colorLabel != nil else { return assets }
        return assets.map { asset in
            var updated = asset
            for keyword in actions.keywords where !updated.keywords.contains(keyword) {
                updated.keywords.append(keyword)
            }
            if let colorLabel = actions.colorLabel {
                updated.colorLabel = colorLabel
            }
            return updated
        }
    }
}
