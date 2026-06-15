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

        var seenKeys = Set(existingAssets.compactMap(HashService.exactDuplicateKey))
        var fresh: [Asset] = []
        var exactSkipped = 0
        for asset in pathFresh {
            guard let key = HashService.exactDuplicateKey(asset) else {
                fresh.append(asset)
                continue
            }
            if seenKeys.contains(key) {
                exactSkipped += 1
            } else {
                seenKeys.insert(key)
                fresh.append(asset)
            }
        }
        return ImportDeduplicationResult(fresh: fresh, skipped: pathSkipped + exactSkipped)
    }
}
