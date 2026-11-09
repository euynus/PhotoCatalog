import AppKit
import Foundation

@MainActor
extension AppState {
    /// Rebuilt only on structural edits: pairing depends on paths and deletion, never on ratings.
    var assetPairing: AssetPairing {
        guard pairRawAndJpeg else { return .empty }
        let version = structureVersion
        if let cache = assetPairingCache, cache.version == version { return cache.pairing }
        let pairing = AssetPairing.rawJpeg(assets)
        assetPairingCache = (version, pairing)
        return pairing
    }

    /// `ids` plus their paired JPEG/HEIC files, for edits that must reach both.
    func withCompanions(_ ids: Set<String>) -> Set<String> { assetPairing.withCompanions(ids) }

    /// Companion files presented behind this asset's tile (e.g. its JPEG).
    func companions(of asset: Asset) -> [Asset] {
        (assetPairing.companionsByPrimary[asset.id] ?? []).compactMap { id in
            assetIndex[id].map { assets[$0] }
        }
    }

    /// Live assets as the library presents them: companions are folded into their RAW.
    func presentedAssets() -> [Asset] {
        let pairing = assetPairing
        return assets.filter(pairing.shows)
    }

    /// Pairing changes what every count and list shows.
    func invalidatePresentationCaches() {
        captureTimeGroupsCache = nil
        photoStacksCache = nil
        stackByAssetCache = nil
        stackInputsVersion &+= 1
        folderTreeCountCache = nil
        captureDateGroupsCache = nil
        keywordCountsCache = nil
        keywordListCache = nil
        keywordSuggestionPoolCache = nil
        gearCountsCache = nil
        projectCountsCache = nil
        clientCountsCache = nil
        libraryCountsCache = nil
        sidebarCountIndexCache = nil
        pinnedSidebarFavoritesCache = nil
        listInputsVersion &+= 1
        if pairRawAndJpeg, !(selection.type == .lib && selection.id == "missing") {
            let primaries = assetPairing.primaryByCompanion
            func presentedID(_ id: String) -> String { primaries[id] ?? id }
            func presentedIDs(_ ids: [String]) -> [String] {
                var seen = Set<String>()
                return ids.map(presentedID).filter { seen.insert($0).inserted }
            }
            selectedIds = Set(selectedIds.map(presentedID))
            primaryId = primaryId.map(presentedID)
            anchorId = anchorId.map(presentedID)
            compareIds = presentedIDs(compareIds)
            winner = winner.map(presentedID)
            surveyIds = presentedIDs(surveyIds)
        }
        // Survey owns a fixed set of photos, including ones no longer matching the filter.
        if view != .survey { ensurePrimaryValid() }
        if view == .compare { syncCompareSelection() }
    }

    var photoStacks: [PhotoStack] {
        _ = stackInputsVersion   // register the dependency even on a cache hit
        if let cache = photoStacksCache { return cache }
        // edited copies first: a TIFF made for an editor stacks with its original before anything else
        let edits: [DuplicateGroup]
        if let cached = editGroupsCache, cached.version == structureVersion {
            edits = cached.groups
        } else {
            let index = EditedVersions.Index(assets)
            edits = index.groups(of: assets)
            editGroupsCache = (structureVersion, index, edits)
            stackSourceDerivations += 1
        }
        let stacks = PhotoStackService.stacks(from: edits + duplicateGroupsCache, captureTimeGroups: captureTimeGroups())
        photoStacksCache = stacks
        return stacks
    }

    /// The capture-time groups for `autoStackSeconds` (none when it's off), kept per structure change.
    private func captureTimeGroups(seconds: Double? = nil) -> [[String]] {
        guard let seconds = seconds ?? autoStackSeconds else { return [] }
        if let cached = captureTimeGroupsCache, cached.version == structureVersion, cached.seconds == seconds {
            return cached.groups
        }
        let groups = PhotoStackService.groups(inCaptureOrder: captureOrder.keys, of: assets, within: seconds)
        if seconds == autoStackSeconds { captureTimeGroupsCache = (structureVersion, seconds, groups) }
        return groups
    }

    private var captureOrder: PhotoStackService.CaptureOrder {
        if let cache = captureOrderCache, cache.version == structureVersion, cache.pairs == pairRawAndJpeg {
            return cache.order
        }
        let order = Self.captureOrder(of: assets, pairing: assetPairing)
        captureOrderCache = (structureVersion, pairRawAndJpeg, assets.count, order)
        stackSourceDerivations += 1
        return order
    }

    /// The photos `pairing` shows that name a camera, in capture order (as
    /// `PhotoStackService.captureTimeGroups` orders them): their keys read in chunks side by
    /// side, then sorted in runs side by side and merged.
    nonisolated static func captureOrder(of assets: [Asset], pairing: AssetPairing, chunk: Int = 8_192,
                                         run: Int = 16_384) -> PhotoStackService.CaptureOrder {
        typealias Key = PhotoStackService.CaptureKey
        // the photos through a pointer: threads reading one array retained its buffer by turns
        return assets.withUnsafeBufferPointer { photos in
            // each chunk's keys, its cameras numbered as it comes to them
            func keys(_ range: Range<Int>) -> (keys: [Key], cameras: [String]) {
                var numbers: [String: Int32] = [:]
                var cameras: [String] = []
                var keys: [Key] = []
                for position in range where pairing.isShown(photos[position], at: position) {
                    let camera = photos[position].camera
                    guard !camera.isEmpty else { continue }
                    let number: Int32
                    if let known = numbers[camera] {
                        number = known
                    } else {
                        number = Int32(cameras.count)
                        numbers[camera] = number
                        cameras.append(camera)
                    }
                    keys.append(Key(camera: number, position: Int32(position),
                                    time: photos[position].date.timeIntervalSinceReferenceDate))
                }
                return (keys, cameras)
            }
            let parts = Chunks.map(photos.count, chunk: chunk, keys)
            // the numbers then become the cameras' ranks
            let ranks = PhotoStackService.cameraRanks(parts.lazy.flatMap(\.cameras))
            var order: [Key] = []
            order.reserveCapacity(parts.reduce(0) { $0 + $1.keys.count })
            for part in parts {
                let rank = part.cameras.map { ranks[$0] ?? 0 }
                for key in part.keys {
                    order.append(Key(camera: rank[Int(key.camera)], position: key.position, time: key.time))
                }
            }
            concurrentSort(&order, run: run) { PhotoStackService.precedes($0, $1, in: photos) }
            return PhotoStackService.CaptureOrder(keys: order, ranks: ranks)
        }
    }

    /// `order`, the capture order of `assets` up to `start`, carried on to all of them: the
    /// photos from `start` on and those of `flipped` that `pairing` now shows put in where they
    /// sort, those of `flipped` it now hides taken out. Nil when a new photo names a camera no
    /// photo did, which moves the ranks.
    nonisolated static func captureOrder(_ order: PhotoStackService.CaptureOrder, of assets: [Asset],
                                         pairing: AssetPairing, appendedFrom start: Int,
                                         flipped: [Int]) -> PhotoStackService.CaptureOrder? {
        typealias Key = PhotoStackService.CaptureKey
        var added: [Key] = [], removed: [Key] = []
        for position in Set(flipped.filter { $0 < start }).sorted() + Array(start ..< assets.count) {
            let asset = assets[position]
            let shown = pairing.isShown(asset, at: position)
            guard !asset.camera.isEmpty, shown || position < start else { continue }
            guard let rank = order.ranks[asset.camera] else { return nil }
            let key = Key(camera: rank, position: Int32(position), time: asset.date.timeIntervalSinceReferenceDate)
            if shown { added.append(key) } else { removed.append(key) }
        }
        guard !added.isEmpty || !removed.isEmpty else { return order }
        let keys = order.keys
        let merged = assets.withUnsafeBufferPointer { photos -> [Key] in
            // where a key goes among the keys: after each one before it (found by bisection)
            func place(_ key: Key) -> Int {
                var (lower, upper) = (0, keys.count)
                while lower < upper {
                    let middle = (lower + upper) / 2
                    if PhotoStackService.precedes(keys[middle], key, in: photos) { lower = middle + 1 } else { upper = middle }
                }
                return lower
            }
            // (an earlier photo goes in only if not there yet, and comes out only if there)
            let inserts = added.sorted { PhotoStackService.precedes($0, $1, in: photos) }
                .map { (at: place($0), key: $0) }
                .filter { $0.at == keys.count || keys[$0.at] != $0.key }
            let removals = removed.map { (at: place($0), key: $0) }
                .filter { $0.at < keys.count && keys[$0.at] == $0.key }.map(\.at).sorted()
            var merged: [Key] = []
            merged.reserveCapacity(keys.count + inserts.count - removals.count)
            // the keys copied run by run between the places where one goes in or comes out
            var (from, insert, removal) = (0, 0, 0)
            while insert < inserts.count || removal < removals.count {
                if insert < inserts.count, removal == removals.count || inserts[insert].at <= removals[removal] {
                    merged.append(contentsOf: keys[from ..< inserts[insert].at])
                    merged.append(inserts[insert].key)
                    from = inserts[insert].at
                    insert += 1
                } else {
                    merged.append(contentsOf: keys[from ..< removals[removal]])
                    from = removals[removal] + 1
                    removal += 1
                }
            }
            merged.append(contentsOf: keys[from...])
            return merged
        }
        return PhotoStackService.CaptureOrder(keys: merged, ranks: order.ranks)
    }

    /// What stacks are worked out from, carried on to photos just added after the others (an
    /// import batch, a tethered shot) instead of worked out again from every photo when next
    /// read: the edited copies and originals among the photos from `start` on, and the capture
    /// order with them put in, and with the earlier photos the pairing now hides or shows again
    /// (`flipped`, as `AssetPairing.append` gives them) taken out or put back. For `appendAssets`
    /// to call once it has carried the pairing on; what can't be carried exactly is worked out
    /// again when read.
    func carryStacks(appendedFrom start: Int, flipped: [Int]) {
        // what was worked out from the photos before them, just before they were added
        let before = structureVersion &- 1
        if let cache = editGroupsCache, cache.version == before, cache.index.count == start,
           let carried = cache.index.adding(assets) {
            editGroupsCache = (structureVersion, carried.index,
                               carried.changed ? carried.index.groups(of: assets) : cache.groups)
        }
        if let cache = captureOrderCache, cache.version == before, cache.pairs == pairRawAndJpeg, cache.count == start,
           let order = Self.captureOrder(cache.order, of: assets, pairing: assetPairing, appendedFrom: start,
                                         flipped: flipped) {
            captureOrderCache = (structureVersion, pairRawAndJpeg, assets.count, order)
        }
        assertStackSourcesCurrent()
    }

    /// In debug builds, for a catalog small enough: that what stacks are worked out from, as
    /// carried on through a change, is what working it out again gives.
    private func assertStackSourcesCurrent() {
        guard assets.count <= 20_000 else { return }
        if let cache = editGroupsCache, cache.version == structureVersion {
            assert(cache.groups.map { $0.items.map(\.id) } == EditedVersions.groups(assets).map { $0.items.map(\.id) },
                   "carried on, the edited copies are those found again")
        }
        if let cache = captureOrderCache, cache.version == structureVersion, cache.pairs == pairRawAndJpeg {
            assert(cache.order.keys == Self.captureOrder(of: assets, pairing: assetPairing).keys,
                   "carried on, the capture order is the one sorted again")
        }
    }

    /// How many stacks, of how many photos, auto-stacking with `seconds` makes.
    func autoStackPreview(seconds: Double) -> (stacks: Int, photos: Int) {
        let groups = captureTimeGroups(seconds: seconds)
        return (groups.count, groups.reduce(0) { $0 + $1.count })
    }

    /// Turns auto-stacking on with `seconds` (folding the new stacks shut) or off, undoably.
    func setAutoStack(seconds: Double?) {
        let previous = autoStackSeconds
        guard previous != seconds else { return }
        autoStackSeconds = seconds
        if seconds != nil {
            let made = photoStacks.filter { $0.method == "captureTime" }
            collapsedStackIds.formUnion(made.map(\.id))
            push("已按拍摄时间叠放为 \(made.count) 个堆栈", "square.stack.3d.down.right")
        } else {
            push("已取消按拍摄时间自动叠放", "square.stack.3d.up.slash")
        }
        collapsedStackIds.formIntersection(Set(photoStacks.map(\.id)))
        normalizeSelectionToVisibleList()
        if let undoManager {
            UndoSteps.register(on: undoManager) {
                undoManager.registerUndo(withTarget: self) { app in
                    MainActor.assumeIsolated { app.setAutoStack(seconds: previous) }
                }
                undoManager.setActionName(L("自动叠放"))
            }
        }
    }

    /// Folds every stack shut, or opens every one.
    func setAllStacksCollapsed(_ collapsed: Bool) {
        collapsedStackIds = collapsed ? Set(photoStacks.map(\.id)) : []
        normalizeSelectionToVisibleList()
    }

    var hasStacks: Bool { !photoStacks.isEmpty }

    /// O(1) asset → stack lookup (its place among `photoStacks`), rebuilt only when the stacks
    /// change (invalidated in didSet).
    private var stackByAsset: [String: Int] {
        _ = stackInputsVersion   // register the dependency even on a cache hit
        if let cache = stackByAssetCache { return cache }
        let stacks = photoStacks
        var map = [String: Int](minimumCapacity: stacks.reduce(0) { $0 + $1.count })
        for (index, stack) in stacks.enumerated() { for id in stack.assetIds { map[id] = index } }
        stackByAssetCache = map
        return map
    }

    /// The stack `assetId` is in.
    private func stack(containing assetId: String) -> PhotoStack? {
        stackByAsset[assetId].map { photoStacks[$0] }
    }

    func stackInfo(for asset: Asset) -> (count: Int, collapsed: Bool)? {
        guard let stack = stack(containing: asset.id) else { return nil }
        return (stack.count, collapsedStackIds.contains(stack.id))
    }

    func toggleStack(containing assetId: String) {
        guard let stack = stack(containing: assetId) else { return }
        if collapsedStackIds.contains(stack.id) {
            collapsedStackIds.remove(stack.id)
            push("已展开堆栈")
        } else {
            collapsedStackIds.insert(stack.id)
            push("已折叠 \(stack.count) 张照片为堆栈")
        }
        normalizeSelectionToVisibleList()
    }

    func toggleStackForPrimary() {
        guard let primaryId else { return }
        toggleStack(containing: primaryId)
    }
}
