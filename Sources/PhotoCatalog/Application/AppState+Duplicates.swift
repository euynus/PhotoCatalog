import AppKit
import Foundation

@MainActor
extension AppState {
    // ---------- duplicate groups (§6.10): exact (content) + similar (perceptual) ----------
    /// The groups as last found, each photo as it is now: a rename or a capture-time change
    /// since then shows at once (the groups are found again only as photos come and go).
    var duplicateGroups: [DuplicateGroup] {
        let found = duplicateGroupsCache
        let version = structureVersion   // both read even on a cache hit, to register them
        if let cache = currentDuplicateGroupsCache, cache.version == version { return cache.groups }
        guard !found.isEmpty else { return [] }   // without building the id index
        let index = assetIndex
        let current = found.map { group in
            DuplicateGroup(id: group.id, method: group.method, score: group.score,
                           items: group.items.map { index[$0.id].map { assets[$0] } ?? $0 })
        }
        currentDuplicateGroupsCache = (version, current)
        return current
    }
    var isAutomaticSimilarityAnalysisLimited: Bool {
        let liveCount = assets.lazy.filter { !$0.isDemo && !$0.deleted }.count
        return !PerceptualHash.canRunAutomaticAnalysis(assetCount: liveCount)
    }

    /// Recompute duplicates off the main thread (dHash reads thumbnails from disk).
    func recomputeDuplicates() {
        guard runsBackgroundMaintenance else { return }
        duplicateRecomputeGeneration &+= 1
        let generation = duplicateRecomputeGeneration
        // a virtual copy shares its master's file: an exact duplicate by definition, never a problem
        let live = assets.filter { !$0.isDemo && !$0.deleted && !$0.isVirtualCopy }
        guard !live.isEmpty else {
            let demoLiveIds = Set(assets.filter { $0.isDemo && !$0.deleted }.map(\.id))
            duplicateGroupsCache = DemoData.duplicateGroups.filter { group in
                group.items.contains { demoLiveIds.contains($0.id) }
            }
            // edited copies' stacks count too: collapsing one survives a duplicate recompute
            collapsedStackIds.formIntersection(Set(photoStacks.map(\.id)))
            return
        }
        Task { [weak self, live] in
            let groups = await Task.detached(priority: .utility) {
                var groups = HashService.exactDuplicateGroups(live)
                    + HashService.suspectedDuplicateGroups(live)
                if PerceptualHash.canRunAutomaticAnalysis(assetCount: live.count) {
                    groups += PerceptualHash.similarGroups(live)
                }
                return groups
            }.value
            guard let self else { return }
            guard self.duplicateRecomputeGeneration == generation else { return }
            self.duplicateGroupsCache = groups
            self.collapsedStackIds.formIntersection(Set(self.photoStacks.map(\.id)))
        }
    }

    @discardableResult
    func resolveDuplicateGroup(_ group: DuplicateGroup, keepId: String?,
                               action: DuplicateResolutionAction) -> Bool {
        let resolvedKeepId = keepId ?? group.items.first?.id
        guard let resolvedKeepId, group.items.contains(where: { $0.id == resolvedKeepId }) else {
            push("重复文件处理失败", "warning")
            return false
        }
        guard group.items.contains(where: { !$0.isDemo }) else {
            push("演示重复组不可处理", "warning")
            return false
        }
        let count = group.items.filter { $0.id != resolvedKeepId && !$0.isDemo }.count
        switch action {
        case .removeFromCatalog:
            guard confirmDestructiveAction(
                L("从目录库移除？"),
                L("将从目录库移除 \(count) 个重复照片记录，磁盘原件会保留。"),
                L("移除")
            ) else { return false }
        case .moveToTrash:
            guard confirmDestructiveAction(
                L("移到废纸篓？"),
                L("将把 \(count) 个重复照片的磁盘原件移到废纸篓，并从目录库移除对应记录。"),
                L("移到废纸篓")
            ) else { return false }
        }

        var updated = assets
        let report = DuplicateResolutionService.resolve(group, keepId: resolvedKeepId, in: &updated, action: action)
        guard !report.removedIds.isEmpty else {
            push(report.failedCount > 0 ? "重复文件处理失败" : "没有可处理的重复文件", "warning")
            return false
        }

        // the removed duplicates' virtual copies go with them
        let copies = virtualCopyIds(of: Set(report.removedIds))
        for index in updated.indices where copies.contains(updated[index].id) { updated[index].deleted = true }
        let removedIds = Set(report.removedIds).union(copies)
        guard persist(removedIds, in: updated) else {
            if action == .moveToTrash {
                let rolledBack = OriginalFileOperationService.rollBackTrash(report.trashedLocations)
                push(verbatim: L("重复文件处理未完成")
                     + (rolledBack > 0 ? L(" · 已回滚 \(rolledBack) 个原件") : L(" · 回滚失败"))
                     + L(" · 目录库保存失败"),
                     "warning")
            }
            return false
        }
        replaceAssetsForMutation(updated)
        if action == .moveToTrash { trashedOriginalIds.formUnion(report.removedIds) }
        purgeCacheFiles(forAssetIds: removedIds)
        duplicateGroupsCache.removeAll { $0.id == group.id }
        recomputeDuplicates()
        ensurePrimaryValid()

        let done = action == .moveToTrash ? L("已移到废纸篓 \(report.affectedCount) 张重复照片")
                                          : L("已从目录库移除 \(report.affectedCount) 张重复照片")
        let failedText = report.failedCount > 0 ? L(" · \(report.failedCount) 失败") : ""
        push(verbatim: done + failedText, "check")
        return report.failedCount == 0
    }

    @discardableResult
    private func persist(_ ids: Set<String>, in sourceAssets: [Asset]? = nil) -> Bool {
        let snapshot = sourceAssets ?? assets
        return persistChanged(snapshot.filter { ids.contains($0.id) })
    }

    /// Saves these photos (demo photos are never persisted) and queues their XMP sidecars.
    func persistChanged(_ edited: [Asset], writingSidecars: Bool = true) -> Bool {
        let changed = edited.filter { !$0.isDemo }
        guard let store else { return true }
        if !changed.isEmpty {
            // this is the single funnel for every metadata edit and the soft-delete-on-trash;
            // a swallowed failure here desyncs the catalog from disk, so surface it (§16.2).
            do {
                try store.upsert(changed)
            } catch {
                push("保存失败，更改未写入目录库", "warning")
                return false
            }
        }
        if writingSidecars { enqueueAutomaticXMPWrite(changed) }
        return true
    }

    func enqueueAutomaticXMPWrite(_ changed: [Asset]) {
        guard autoWriteXMPSidecar, !changed.isEmpty else { return }
        automaticXMPWriteSequence &+= 1
        let sequence = automaticXMPWriteSequence
        let writer = automaticXMPWriter
        let baselines = Dictionary(changed.compactMap { asset in xmpSyncTimes[asset.id].map { (asset.id, $0) } },
                                   uniquingKeysWith: { $1 })
        let catalogURL = store?.packageURL
        Task { [weak self, writer, changed, sequence, baselines, catalogURL] in
            let result = await writer.write(changed, sequence: sequence, baselines: baselines)
            self?.applyAutomaticXMPWrite(result, catalogURL: catalogURL)
        }
    }

    /// Takes in what an automatic write did, once it's done: our write is the newest a sidecar
    /// has been, unless pairing was switched since and the sidecar is no longer the photo's.
    func applyAutomaticXMPWrite(_ result: AutomaticXMPWriter.Result, catalogURL: URL?) {
        let swapped = recordWrittenSidecars(result)
        // another app's change waits to be read rather than being written over
        noteChangedElsewhere(result.changedElsewhere.subtracting(swapped))
        // an original on a drive that's away gets its sidecar once it's back
        if store?.packageURL == catalogURL {
            pendingXMPWriteIds.subtract(result.written.keys)
            pendingXMPWriteIds.subtract(result.changedElsewhere)
            pendingXMPWriteIds.formUnion(result.unavailable)
        }
        guard result.failures > 0 else { return }
        push("\(result.failures) 个 XMP 附属文件写入失败", "warning")
    }

    /// Remembers the sidecars a write wrote as they are now, but not one pairing has swapped
    /// since (a RAW's JPEG, the RAW): it's no longer that photo's. Returns those swapped.
    @discardableResult
    func recordWrittenSidecars(_ result: AutomaticXMPWriter.Result) -> Set<String> {
        let swapped = result.pairing == pairRawAndJpeg ? [] : result.pairingDependent
        recordXMPSync(result.written.filter { !swapped.contains($0.key) })
        return swapped
    }

    /// Writes the sidecars held back while their originals were out of reach, for those back now.
    func flushPendingXMPWrites() {
        guard autoWriteXMPSidecar, !pendingXMPWriteIds.isEmpty else { return }
        let fm = FileManager.default
        var back: [Asset] = []
        for id in pendingXMPWriteIds {
            // a photo removed from the catalog meanwhile has nothing left to write
            guard let index = assetIndex[id], !assets[index].deleted else {
                pendingXMPWriteIds.remove(id)
                continue
            }
            guard let path = assets[index].localPath, fm.fileExists(atPath: path) else { continue }
            pendingXMPWriteIds.remove(id)
            back.append(assets[index])
        }
        enqueueAutomaticXMPWrite(back)
    }

    /// For checks: whether a photo's sidecar waits for its original to be back.
    func xmpWriteIsPending(for id: String) -> Bool { pendingXMPWriteIds.contains(id) }

    /// For checks: how many sidecar writes have been queued (each takes the next sequence).
    var xmpWriteSequence: UInt64 { automaticXMPWriteSequence }
}
