import Foundation

/// History stays separate from `jobs`: import recovery and catalog health already consume
/// that execution table. Mirroring tasks there would double-count live and failed jobs.
@MainActor
final class BackgroundTaskHistory {
    nonisolated static let defaultRetentionLimit = 200
    nonisolated static let failureDetailLimit = 100

    private struct Snapshot: Codable {
        var version = 1
        var tasks: [BackgroundTask]
    }

    enum HistoryError: LocalizedError {
        case invalidCatalog, unsupportedVersion(Int), duplicateIDs

        var errorDescription: String? {
            switch self {
            case .invalidCatalog: return L("任务历史需要可访问的本地目录库。")
            case .unsupportedVersion(let version): return L("无法读取任务历史版本 \(version)。")
            case .duplicateIDs: return L("任务历史包含重复标识，原文件已保留。")
            }
        }
    }

    let fileURL: URL
    let retentionLimit: Int
    let catalogURL: URL
    private let catalogID: String?
    private(set) var tasks: [BackgroundTask] = []
    private(set) var lastWriteAttempt: Date?
    private(set) var lastWriteError: String?
    private var pending: [UUID: BackgroundTask] = [:]
    private var loaded = false
    private var reattachedTaskIDs: Set<UUID> = []

    var hasPendingChanges: Bool { !pending.isEmpty }

    func belongsToSameCatalog(as other: BackgroundTaskHistory) -> Bool {
        catalogID != nil && catalogID == other.catalogID
            && fileURL.standardizedFileURL == other.fileURL.standardizedFileURL
    }

    var currentTasks: [BackgroundTask] {
        Self.retained(mergingPending(into: tasks), limit: retentionLimit)
    }

    /// The identity exists even when loading fails, so workers can keep a catalog-scoped
    /// handle without accidentally falling back to a newly opened catalog.
    init(unloadedCatalogURL: URL, retentionLimit: Int = defaultRetentionLimit) {
        catalogURL = unloadedCatalogURL
        catalogID = try? Self.readCatalogID(at: unloadedCatalogURL)
        self.retentionLimit = max(0, retentionLimit)
        // Runtime history changes during backups; keep it outside the backed-up Config tree.
        fileURL = unloadedCatalogURL.appendingPathComponent("Logs/TaskHistory.json")
    }

    /// Only pass IDs for workers the caller has actually reattached. Everything else that
    /// was queued/running/paused is interrupted, never completed or automatically retried.
    convenience init(catalogURL: URL, retentionLimit: Int = defaultRetentionLimit,
                     liveTaskIDs: Set<UUID> = [], now: Date = .now) throws {
        self.init(unloadedCatalogURL: catalogURL, retentionLimit: retentionLimit)
        try load(liveTaskIDs: liveTaskIDs, now: now)
    }

    func load(liveTaskIDs: Set<UUID> = [], now: Date = .now) throws {
        reattachedTaskIDs = liveTaskIDs
        let snapshot = try readSnapshot()
        let recovered = snapshot.tasks.map { task in
            guard task.state.isActive, !liveTaskIDs.contains(task.id) else { return task }
            var task = task
            task.state = .interrupted
            task.updatedAt = now
            task.finishedAt = nil
            if task.errorMessage == nil { task.errorMessage = L("上次运行未完成。") }
            return task
        }
        let retained = Self.retained(recovered, limit: retentionLimit)
        if retained != snapshot.tasks { try write(retained) }
        tasks = retained
        loaded = true
    }

    /// `tasks` is the last saved snapshot. Live UI state must remain visible if saving fails.
    func upsert(_ task: BackgroundTask) throws {
        stage(task)
        try savePending()
    }

    func stage(_ task: BackgroundTask) {
        pending[task.id] = Self.retained([task], limit: 1).first
        // Keep final updates for previously saved active jobs until they reach disk, even
        // with zero terminal retention; dropping them would leave a permanent running row.
        let retainedIDs = Set(currentTasks.map(\.id)).union(tasks.filter { $0.state.isActive }.map(\.id))
        pending = pending.filter { retainedIDs.contains($0.key) }
    }

    func savePending(now: Date = .now) throws {
        lastWriteAttempt = now
        do {
            try loadIfNeeded(now: now)
            // Old workers and a same-path reopened catalog can hold distinct history objects.
            // Merge only changed IDs against disk, not either object's stale full snapshot.
            try commit(mergingPending(into: readSnapshot().tasks))
            lastWriteError = nil
        } catch {
            lastWriteError = error.localizedDescription
            throw error
        }
    }

    func removeFinished() throws {
        let now = Date.now
        lastWriteAttempt = now
        do {
            try loadIfNeeded(now: now)
            try commit(mergingPending(into: readSnapshot().tasks).filter { $0.state.isActive })
            lastWriteError = nil
        } catch {
            lastWriteError = error.localizedDescription
            throw error
        }
    }

    /// Refreshing a panel does not recover or execute work; it just sees other writers' outcomes.
    func refresh() throws {
        try loadIfNeeded(now: .now)
        tasks = Self.retained(try readSnapshot().tasks, limit: retentionLimit)
    }

    private func loadIfNeeded(now: Date) throws {
        if !loaded {
            try load(liveTaskIDs: reattachedTaskIDs.union(pending.keys), now: now)
        }
    }

    private func mergingPending(into records: [BackgroundTask]) -> [BackgroundTask] {
        var merged = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        merged.merge(pending) { _, latest in latest }
        return Array(merged.values)
    }

    private func commit(_ records: [BackgroundTask]) throws {
        let retained = Self.retained(records, limit: retentionLimit)
        try write(retained)
        tasks = retained
        pending = [:]
    }

    nonisolated static func retained(_ records: [BackgroundTask], limit: Int = defaultRetentionLimit) -> [BackgroundTask] {
        let ordered = BackgroundTask.ordered(records)
        var finished = 0
        return ordered.compactMap { record in
            if !record.state.isActive {
                guard finished < max(0, limit) else { return nil }
                finished += 1
            }
            var record = record
            record.failedCount = record.failureCount
            record.failures = Array(record.failures.suffix(Self.failureDetailLimit))
            return record
        }
    }

    private func requireCatalog() throws {
        guard let catalogID, try Self.readCatalogID(at: catalogURL) == catalogID else {
            throw HistoryError.invalidCatalog
        }
    }

    private static func readCatalogID(at url: URL) throws -> String {
        // Read the manifest afresh: URL resource values can survive removal, and an old
        // worker must not write into a different catalog later created at the same path.
        guard url.isFileURL,
              let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: url.appendingPathComponent("manifest.json"))) as? [String: Any],
              let id = manifest["uuid"] as? String, !id.isEmpty else {
            throw HistoryError.invalidCatalog
        }
        return id
    }

    private func readSnapshot() throws -> Snapshot {
        try requireCatalog()
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileReadNoSuchFileError {
            return Snapshot(tasks: [])
        }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        guard snapshot.version == 1 else { throw HistoryError.unsupportedVersion(snapshot.version) }
        guard Set(snapshot.tasks.map(\.id)).count == snapshot.tasks.count else { throw HistoryError.duplicateIDs }
        return snapshot
    }

    private func write(_ records: [BackgroundTask]) throws {
        try requireCatalog()
        let data = try JSONEncoder().encode(Snapshot(tasks: records))
        let folder = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        }
        try requireCatalog()
        try data.write(to: fileURL, options: .atomic)
    }
}
