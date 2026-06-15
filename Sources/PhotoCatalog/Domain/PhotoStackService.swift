// ============================================================
//  PhotoStackService - derive collapsible stacks from duplicate/similar groups
//  (PRD §6.8 ORGZ-005)
// ============================================================
import Foundation

enum PhotoStackService {
    static func stacks(from groups: [DuplicateGroup]) -> [PhotoStack] {
        var used = Set<String>()
        var result: [PhotoStack] = []
        for group in groups {
            let ids = group.items.map(\.id).filter { used.insert($0).inserted }
            guard ids.count > 1 else { continue }
            result.append(PhotoStack(id: stableId(method: group.method, assetIds: ids),
                                     method: group.method,
                                     assetIds: ids))
        }
        return result
    }

    static func stack(containing assetId: String, in stacks: [PhotoStack]) -> PhotoStack? {
        stacks.first { $0.assetIds.contains(assetId) }
    }

    static func visibleAssets(_ assets: [Asset], stacks: [PhotoStack],
                              collapsedStackIds: Set<String>) -> [Asset] {
        guard !collapsedStackIds.isEmpty else { return assets }
        var stackByAsset: [String: PhotoStack] = [:]
        for stack in stacks where collapsedStackIds.contains(stack.id) {
            for id in stack.assetIds { stackByAsset[id] = stack }
        }

        var seenStacks = Set<String>()
        return assets.filter { asset in
            guard let stack = stackByAsset[asset.id] else { return true }
            return seenStacks.insert(stack.id).inserted
        }
    }

    private static func stableId(method: String, assetIds: [String]) -> String {
        "stack-\(method)-" + assetIds.sorted().joined(separator: "-")
    }
}
