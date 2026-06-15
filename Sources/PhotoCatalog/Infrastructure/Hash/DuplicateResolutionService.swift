// ============================================================
//  DuplicateResolutionService - apply keep-one duplicate actions
//  to the catalog model and, when requested, the original files.
// ============================================================
import Foundation

struct DuplicateResolutionReport {
    let keptId: String?
    var removedIds: Set<String> = []
    var trashedCount = 0
    var failedCount = 0
    var skippedCount = 0

    var affectedCount: Int { removedIds.count }
}

enum DuplicateResolutionService {
    static func resolve(_ group: DuplicateGroup, keepId: String?, in assets: inout [Asset],
                        action: DuplicateResolutionAction) -> DuplicateResolutionReport {
        let keptId = keepId ?? group.items.first?.id
        var report = DuplicateResolutionReport(keptId: keptId)
        guard let keptId else { return report }

        let removeIds = Set(group.items.map(\.id).filter { $0 != keptId })
        guard !removeIds.isEmpty else { return report }

        for id in removeIds {
            guard let index = assets.firstIndex(where: { $0.id == id }) else {
                report.skippedCount += 1
                continue
            }

            if action == .moveToTrash {
                guard let path = assets[index].localPath, !assets[index].isDemo else {
                    report.failedCount += 1
                    continue
                }
                let url = URL(fileURLWithPath: path)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    report.failedCount += 1
                    continue
                }
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    report.trashedCount += 1
                } catch {
                    report.failedCount += 1
                    continue
                }
            }

            assets[index].deleted = true
            report.removedIds.insert(id)
        }

        return report
    }
}
