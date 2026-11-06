import AppKit
import Foundation

@MainActor
extension AppState {
    // ----- develop history and snapshots, loaded per photo when first shown -----
    private static let developRecordCacheLimit = 64
    /// Photos whose history or snapshots are in memory (for tests).
    var cachedDevelopRecordCount: Int { Set(developHistoryCache.keys).union(developSnapshotCache.keys).count }

    /// The photo's develop steps, oldest first.
    func developHistory(for id: String) -> [DevelopHistoryStep] {
        _ = developRecordsVersion
        defer { touchDevelopRecords(id) }
        if let cached = developHistoryCache[id] { return cached }
        let loaded = (try? store?.loadDevelopHistory(id)) ?? []
        developHistoryCache[id] = loaded
        return loaded
    }

    func developSnapshots(for id: String) -> [DevelopSnapshot] {
        _ = developRecordsVersion
        defer { touchDevelopRecords(id) }
        if let cached = developSnapshotCache[id] { return cached }
        let loaded = (try? store?.loadDevelopSnapshots(id)) ?? []
        developSnapshotCache[id] = loaded
        return loaded
    }

    /// Marks the photo's records as just shown and forgets those of the photos shown longest ago,
    /// beyond the limit — never the photo on screen. Without a catalog the records live only in
    /// memory, so none is forgotten.
    private func touchDevelopRecords(_ id: String) {
        guard store != nil else { return }
        if developRecordOrder.last != id {
            developRecordOrder.removeAll { $0 == id }
            developRecordOrder.append(id)
        }
        while developRecordOrder.count > Self.developRecordCacheLimit {
            let current = primaryId
            guard let oldest = developRecordOrder.firstIndex(where: { $0 != id && $0 != current }) else { break }
            let forgotten = developRecordOrder.remove(at: oldest)
            developHistoryCache[forgotten] = nil
            developSnapshotCache[forgotten] = nil
        }
    }

    func recordDevelopHistory(_ changed: [String: DevelopSettings], name: String, change: DevelopHistoryChange) {
        guard !changed.isEmpty else { return }
        switch change {
        case .append:
            let stored = (try? store?.appendDevelopHistory(changed.mapValues { (name: name, settings: $0) })) ?? [:]
            for (id, value) in changed where developHistoryCache[id] != nil {
                // with a catalog, only what was stored is listed, so undo removes the same step from both
                if store != nil, stored[id] == nil { continue }
                let seq = stored[id]?.seq ?? (developHistoryCache[id]?.last?.seq ?? 0) + 1
                developHistoryCache[id]?.append(stored[id] ?? DevelopHistoryStep(seq: seq, name: name, date: .now,
                                                                                 settings: value))
                if let count = developHistoryCache[id]?.count, count > DevelopHistoryStep.limit {
                    developHistoryCache[id]?.removeFirst(count - DevelopHistoryStep.limit)
                }
            }
        case .revert:
            try? store?.removeLastDevelopHistory(Array(changed.keys))
            for id in changed.keys where developHistoryCache[id]?.isEmpty == false {
                developHistoryCache[id]?.removeLast()
            }
        }
        developRecordsVersion &+= 1
    }

    /// Returns the photo to a history step's settings, as a new step (undoable).
    func applyDevelopHistoryStep(_ step: DevelopHistoryStep, to id: String) {
        // returning to "History: X" names the new step after X, not History: History: X
        let prefix = L("历史记录：")
        let name = step.name.hasPrefix(prefix) ? String(step.name.dropFirst(prefix.count)) : step.name
        commitDevelop([id: step.settings], undoName: L("历史记录：\(name)"))
    }

    /// Asks first: the history can't be brought back.
    func confirmClearDevelopHistory(for id: String) {
        guard confirmDestructiveAction(L("清除历史记录？"), L("这张照片的修图步骤将被清除，当前设置和快照保持不变。"),
                                       L("清除")) else { return }
        clearDevelopHistory(for: id)
    }

    func clearDevelopHistory(for id: String) {
        try? store?.clearDevelopHistory(id)
        developHistoryCache[id] = []
        touchDevelopRecords(id)
        developRecordsVersion &+= 1
    }

    /// Keeps the photo's current settings as a new snapshot.
    func createDevelopSnapshot(for id: String) {
        let existing = developSnapshots(for: id)
        let snapshot = DevelopSnapshot(id: UUID().uuidString, name: L("快照 \(existing.count + 1)"), date: .now,
                                       settings: developSettings[id] ?? .neutral)
        saveDevelopSnapshot(snapshot, for: id)
    }

    func renameDevelopSnapshot(_ snapshotId: String, to name: String, for id: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var snapshot = developSnapshots(for: id).first(where: { $0.id == snapshotId }) else { return }
        snapshot.name = trimmed
        saveDevelopSnapshot(snapshot, for: id)
    }

    /// Replaces a snapshot's settings with the photo's current ones.
    func updateDevelopSnapshot(_ snapshotId: String, for id: String) {
        guard var snapshot = developSnapshots(for: id).first(where: { $0.id == snapshotId }) else { return }
        snapshot.settings = developSettings[id] ?? .neutral
        saveDevelopSnapshot(snapshot, for: id)
    }

    func deleteDevelopSnapshot(_ snapshotId: String, for id: String) {
        try? store?.deleteDevelopSnapshot(snapshotId)
        developSnapshotCache[id] = developSnapshots(for: id).filter { $0.id != snapshotId }
        developRecordsVersion &+= 1
    }

    func applyDevelopSnapshot(_ snapshot: DevelopSnapshot, to id: String) {
        commitDevelop([id: snapshot.settings], undoName: L("快照：\(snapshot.name)"))
    }

    private func saveDevelopSnapshot(_ snapshot: DevelopSnapshot, for id: String) {
        do {
            try store?.saveDevelopSnapshot(snapshot, for: id)
        } catch {
            push("保存快照失败", "warning")
            return
        }
        var list = developSnapshots(for: id)
        if let index = list.firstIndex(where: { $0.id == snapshot.id }) { list[index] = snapshot } else { list.append(snapshot) }
        developSnapshotCache[id] = list
        developRecordsVersion &+= 1
    }

    func clearDevelopRecordCaches() {
        developHistoryCache = [:]
        developSnapshotCache = [:]
        developRecordOrder = []
        developRecordsVersion &+= 1
    }
}
