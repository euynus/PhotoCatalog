// ============================================================
//  DuplicateResolutionService - works out a keep-one duplicate action:
//  which photos go and, when requested, their original files trashed.
//  The caller marks the photos removed in the catalog.
// ============================================================
import Foundation

struct DuplicateResolutionReport {
    let keptId: String?
    var removedIds: Set<String> = []
    var trashedCount = 0
    var trashedLocations: [String: OriginalTrashLocation] = [:]
    var failedCount = 0
    var skippedCount = 0

    var affectedCount: Int { removedIds.count }
}

enum DuplicateResolutionService {
    /// `current`: the group's photos as the catalog has them now. A photo of the group not among
    /// them is skipped.
    static func resolve(_ group: DuplicateGroup, current: [Asset], keepId: String?,
                        action: DuplicateResolutionAction) -> DuplicateResolutionReport {
        let groupIds = Set(group.items.map(\.id))
        let keptId = keepId ?? group.items.first?.id
        var report = DuplicateResolutionReport(keptId: keptId)
        guard let keptId else { return report }
        guard groupIds.contains(keptId) else {
            report.failedCount = 1
            return report
        }

        let removeIds = groupIds.subtracting([keptId])
        guard !removeIds.isEmpty else { return report }
        let photos = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for id in removeIds {
            guard let asset = photos[id] else {
                report.skippedCount += 1
                continue
            }

            if action == .moveToTrash {
                guard !asset.isDemo else {
                    report.failedCount += 1
                    continue
                }
                do {
                    report.trashedLocations[id] = try OriginalFileOperationService.trashOriginal(asset)
                    report.trashedCount += 1
                } catch {
                    report.failedCount += 1
                    continue
                }
            }

            report.removedIds.insert(id)
        }

        return report
    }
}
