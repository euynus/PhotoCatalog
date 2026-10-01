// ============================================================
//  PhotoStackService - derive collapsible stacks from duplicate/similar groups
//  (PRD §6.8 ORGZ-005)
// ============================================================
import Foundation

enum PhotoStackService {
    /// Stacks from `groups` first, then from `captureTimeGroups` (see `captureTimeGroups(_:within:)`);
    /// a photo already in a stack isn't taken again.
    static func stacks(from groups: [DuplicateGroup], captureTimeGroups: [[String]] = []) -> [PhotoStack] {
        var used = Set<String>()
        var result: [PhotoStack] = []
        for group in groups {
            let ids = group.items.map(\.id).filter { used.insert($0).inserted }
            guard ids.count > 1 else { continue }
            result.append(PhotoStack(id: stableId(method: group.method, assetIds: ids),
                                     method: group.method,
                                     assetIds: ids))
        }
        for group in captureTimeGroups {
            let ids = group.filter { used.insert($0).inserted }
            guard ids.count > 1 else { continue }
            result.append(PhotoStack(id: stableId(method: "captureTime", assetIds: ids), method: "captureTime", assetIds: ids))
        }
        return result
    }

    /// Bursts and brackets: photos from one camera each taken within `seconds` of the one before,
    /// as groups of ids in capture order. Photos without a camera (scans, screenshots) and
    /// lone photos stay out.
    static func captureTimeGroups(_ assets: [Asset], within seconds: TimeInterval) -> [[String]] {
        let sorted = assets.filter { !$0.camera.isEmpty }
            .sorted { ($0.camera, $0.date, $0.id) < ($1.camera, $1.date, $1.id) }
        var groups: [[String]] = []
        var current: [String] = []
        var previous: Asset?
        for asset in sorted {
            if let previous, previous.camera == asset.camera, asset.date.timeIntervalSince(previous.date) <= seconds {
                current.append(asset.id)
            } else {
                if current.count > 1 { groups.append(current) }
                current = [asset.id]
            }
            previous = asset
        }
        if current.count > 1 { groups.append(current) }
        return groups
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
