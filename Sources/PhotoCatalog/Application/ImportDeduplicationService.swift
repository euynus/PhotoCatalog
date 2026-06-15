// ============================================================
//  ImportDeduplicationService — applies user-selected import
//  duplicate handling before assets are persisted.
// ============================================================
import Foundation

struct ImportDeduplicationResult {
    let fresh: [Asset]
    let skipped: Int
}

enum ImportDeduplicationService {
    static func apply(imported: [Asset], existingAssets: [Asset], existingIds: Set<String>,
                      strategy: ImportDuplicateStrategy) -> ImportDeduplicationResult {
        let pathFresh = imported.filter { !existingIds.contains($0.id) }
        let pathSkipped = imported.count - pathFresh.count
        guard strategy == .skipExact else {
            return ImportDeduplicationResult(fresh: pathFresh, skipped: pathSkipped)
        }

        var seenHashes = Set(existingAssets.compactMap(\.contentHash))
        var fresh: [Asset] = []
        var exactSkipped = 0
        for asset in pathFresh {
            guard let hash = asset.contentHash else {
                fresh.append(asset)
                continue
            }
            if seenHashes.contains(hash) {
                exactSkipped += 1
            } else {
                seenHashes.insert(hash)
                fresh.append(asset)
            }
        }
        return ImportDeduplicationResult(fresh: fresh, skipped: pathSkipped + exactSkipped)
    }
}
