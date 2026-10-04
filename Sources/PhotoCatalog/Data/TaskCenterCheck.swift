import Foundation

enum TaskCenterCheck {
    static func run() {
        MainActor.assumeIsolated {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("pc-task-center-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            do {
                try checkPersistence(in: directory)
                try checkRetention(in: directory)
                try checkSharedWriters(in: directory)
                try checkErrors(in: directory)
                checkActionsAndSelection()
                print("--- task center assertions passed ---")
            } catch {
                fatalError("Task center check failed: \(error)")
            }
        }
    }

    @MainActor
    private static func checkPersistence(in directory: URL) throws {
        let catalog = try makeCatalog("recovery", in: directory)
        let history = try BackgroundTaskHistory(catalogURL: catalog)
        assert(history.tasks.isEmpty, "a new catalog has no task history")
        let start = Date(timeIntervalSince1970: 1_000)
        var running = BackgroundTask(kind: .exportPhotos, title: "Export", state: .running,
                                     createdAt: start, totalCount: 4,
                                     destination: catalog.appendingPathComponent("Export"))
        running.completedCount = 2
        running.succeededCount = 1
        running.failedCount = 1
        running.failures = [.init(item: "image.raw", message: "Offline", assetID: "a", path: "/photos/image.raw")]
        let queued = BackgroundTask(kind: .preview, title: "Preview", createdAt: start)
        let paused = BackgroundTask(kind: .importPhotos, title: "Import", state: .paused, createdAt: start)
        var completed = BackgroundTask(kind: .backup, title: "Backup", state: .completed, createdAt: start)
        completed.finishedAt = start.addingTimeInterval(1)
        completed.updatedAt = completed.finishedAt!
        for task in [running, queued, paused, completed] { try history.upsert(task) }

        let live = try BackgroundTaskHistory(catalogURL: catalog, liveTaskIDs: [running.id, queued.id, paused.id])
        assert(live.tasks == history.tasks, "reattached worker snapshots round-trip without losing progress or details")
        let recoveryDate = start.addingTimeInterval(100)
        let reopened = try BackgroundTaskHistory(catalogURL: catalog, now: recoveryDate)
        let interrupted = reopened.tasks.filter { $0.state == .interrupted }
        assert(interrupted.count == 3 && !reopened.tasks.contains { $0.state.isActive },
               "orphaned queued, running and paused tasks become interrupted")
        assert(interrupted.allSatisfy { $0.availableActions(.init()).retry == nil },
               "persisted history alone never restores a retry capability")
        assert(interrupted.allSatisfy { $0.finishedAt == nil && $0.updatedAt == recoveryDate },
               "recovery records discovery time, not a fabricated completion time")
        let restored = reopened.tasks.first { $0.id == running.id }
        assert(restored?.completedCount == 2 && restored?.failures == running.failures
               && restored?.destination == running.destination && restored?.fractionCompleted == 0.5,
               "interruption retains actual progress, failure details and destination")
        assert(reopened.tasks.first { $0.id == completed.id } == completed,
               "an already completed task is unchanged by recovery")
        let reopenedAgain = try BackgroundTaskHistory(catalogURL: catalog, now: recoveryDate.addingTimeInterval(10))
        assert(reopenedAgain.tasks == reopened.tasks, "interruption is persisted once and reopen is idempotent")
        let other = try BackgroundTaskHistory(catalogURL: makeCatalog("other", in: directory))
        assert(other.tasks.isEmpty, "task history is scoped to its catalog")
    }

    @MainActor
    private static func checkRetention(in directory: URL) throws {
        let catalog = try makeCatalog("retention", in: directory)
        let history = try BackgroundTaskHistory(catalogURL: catalog, retentionLimit: 2)
        var terminalIDs: [UUID] = []
        for index in 0..<6 {
            let task = BackgroundTask(kind: .ai, title: "AI \(index)", state: .completed,
                                      createdAt: Date(timeIntervalSince1970: Double(index)))
            terminalIDs.append(task.id)
            try history.upsert(task)
        }
        assert(Set(history.tasks.map(\.id)) == Set(terminalIDs.suffix(2)),
               "only the newest terminal records are retained")
        var activeIDs = Set<UUID>()
        for state in [BackgroundTask.State.queued, .running, .paused] {
            let task = BackgroundTask(kind: .enhance, title: "Enhance", state: state)
            activeIDs.insert(task.id)
            try history.upsert(task)
        }
        assert(history.tasks.count == 5 && history.tasks.filter { $0.state.isActive }.count == 3,
               "terminal retention never evicts active workers")
        var failed = BackgroundTask(kind: .exportPhotos, title: "Many failures", state: .failed)
        failed.failures = (0..<(BackgroundTaskHistory.failureDetailLimit + 5)).map {
            .init(item: "image-\($0)", message: "Offline", assetID: "asset-\($0)")
        }
        failed.failedCount = failed.failures.count + 10
        try history.upsert(failed)
        let bounded = history.tasks.first { $0.id == failed.id }
        assert(bounded?.failures.count == BackgroundTaskHistory.failureDetailLimit
               && bounded?.failureCount == failed.failedCount && bounded?.omittedFailureCount == 15,
               "bounded failure details retain the full failure count")
        let reopened = try BackgroundTaskHistory(catalogURL: catalog, retentionLimit: 2, liveTaskIDs: activeIDs)
        assert(reopened.tasks == history.tasks, "retention is stable on disk as well as in memory")
        try reopened.removeFinished()
        assert(Set(reopened.tasks.map(\.id)) == activeIDs, "clearing history keeps live work")
        let empty = try BackgroundTaskHistory(catalogURL: catalog, retentionLimit: 0)
        assert(empty.tasks.isEmpty, "zero retention removes terminal and newly interrupted history")

        var active = BackgroundTask(kind: .preview, title: "Preview", state: .running)
        try empty.upsert(active)
        assert(empty.tasks.map(\.id) == [active.id], "zero terminal retention still retains active work")
        active.state = .completed
        try empty.upsert(active)
        let zeroReopened = try BackgroundTaskHistory(catalogURL: catalog, retentionLimit: 0)
        assert(empty.currentTasks.isEmpty && zeroReopened.tasks.isEmpty,
               "a terminal transition is persisted even when its record is immediately evicted")
    }

    @MainActor
    private static func checkSharedWriters(in directory: URL) throws {
        let catalog = try makeCatalog("shared-writers", in: directory)
        let original = try BackgroundTaskHistory(catalogURL: catalog)
        var export = BackgroundTask(kind: .exportPhotos, title: "Export", state: .running, totalCount: 3)
        try original.upsert(export)
        let reopened = try BackgroundTaskHistory(catalogURL: catalog, liveTaskIDs: [export.id])
        let preview = BackgroundTask(kind: .preview, title: "Preview", state: .running)
        try reopened.upsert(preview)

        export.completedCount = 1
        original.stage(export)
        assert(original.tasks.first { $0.id == export.id }?.completedCount == 0
               && original.currentTasks.first { $0.id == export.id }?.completedCount == 1,
               "staged progress is visible without claiming it has reached disk")
        export.state = .completed
        export.completedCount = 3
        export.succeededCount = 3
        try original.upsert(export)
        assert(original.tasks.first { $0.id == preview.id } == preview,
               "an old worker finishing does not erase a same-path session's new task")
        let backup = BackgroundTask(kind: .backup, title: "Backup", state: .completed)
        try reopened.upsert(backup)
        assert(reopened.tasks.first { $0.id == export.id } == export,
               "a stale writer merges its changed IDs without restoring old running snapshots")
        assert(Set(reopened.tasks.map(\.id)) == [export.id, preview.id, backup.id],
               "all writers' independent task outcomes are retained")

        try original.removeFinished()
        assert(original.tasks == [preview], "clear history reads other writers before preserving active work")
        try reopened.refresh()
        assert(reopened.currentTasks == [preview], "refresh sees external completion and removal without executing work")

        let unreadableCatalog = try makeCatalog("unloaded", in: directory)
        let unloaded = BackgroundTaskHistory(unloadedCatalogURL: unreadableCatalog)
        try FileManager.default.createDirectory(at: unloaded.fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let invalid = Data("{".utf8)
        try invalid.write(to: unloaded.fileURL)
        expectFailure("an unloaded context retains its identity when the stored file is corrupt") {
            try unloaded.load()
        }
        unloaded.stage(preview)
        expectFailure("staged live work must not replace unreadable saved history") { try unloaded.savePending() }
        let preserved = try Data(contentsOf: unloaded.fileURL)
        assert(unloaded.currentTasks == [preview] && unloaded.hasPendingChanges && preserved == invalid,
               "live state survives an initial load error without destroying the corrupt file")
        try FileManager.default.removeItem(at: unloaded.fileURL)
        try unloaded.savePending()
        assert(unloaded.tasks == [preview] && !unloaded.hasPendingChanges && unloaded.lastWriteError == nil,
               "a later successful save flushes work staged while history was unavailable")
    }

    @MainActor
    private static func checkErrors(in directory: URL) throws {
        let catalog = try makeCatalog("errors", in: directory)
        let history = try BackgroundTaskHistory(catalogURL: catalog)
        let task = BackgroundTask(kind: .backup, title: "Backup", state: .completed)
        try history.upsert(task)
        let original = try Data(contentsOf: history.fileURL)
        for invalid in [Data("{".utf8), try JSONSerialization.data(withJSONObject: ["version": 2, "tasks": []])] {
            try invalid.write(to: history.fileURL)
            expectFailure("corrupt or newer history must not silently become an empty history") {
                _ = try BackgroundTaskHistory(catalogURL: catalog)
            }
            let preserved = try Data(contentsOf: history.fileURL)
            assert(preserved == invalid, "unreadable history remains untouched")
        }
        try original.write(to: history.fileURL)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(task))
        let duplicate = try JSONSerialization.data(withJSONObject: ["version": 1, "tasks": [object, object]])
        try duplicate.write(to: history.fileURL)
        expectFailure("duplicate record IDs must be surfaced before SwiftUI receives them") {
            _ = try BackgroundTaskHistory(catalogURL: catalog)
        }
        try original.write(to: history.fileURL)

        let writeCatalog = try makeCatalog("blocked-write", in: directory)
        let writer = try BackgroundTaskHistory(catalogURL: writeCatalog)
        let config = writer.fileURL.deletingLastPathComponent()
        let blocker = Data("not a directory".utf8)
        try blocker.write(to: config)
        expectFailure("write errors must propagate to the caller") { try writer.upsert(task) }
        let unchanged = try Data(contentsOf: config)
        assert(writer.tasks.isEmpty && unchanged == blocker, "failed saves do not publish or overwrite data")
        assert(writer.currentTasks == [task] && writer.hasPendingChanges && writer.lastWriteError != nil,
               "a failed save preserves live task state and exposes its persistence error")
        try FileManager.default.removeItem(at: config)
        try writer.savePending()
        assert(writer.tasks == [task] && !writer.hasPendingChanges && writer.lastWriteError == nil,
               "pending records are saved after the filesystem becomes available")

        let blockedRecovery = try makeCatalog("blocked-recovery", in: directory)
        let recovering = try BackgroundTaskHistory(catalogURL: blockedRecovery)
        try recovering.upsert(BackgroundTask(kind: .preview, title: "Preview", state: .running))
        let saved = recovering.fileURL.appendingPathExtension("saved")
        try FileManager.default.moveItem(at: recovering.fileURL, to: saved)
        try FileManager.default.createDirectory(at: recovering.fileURL, withIntermediateDirectories: false)
        expectFailure("a directory or unreadable history file must not be treated as absent") {
            _ = try BackgroundTaskHistory(catalogURL: blockedRecovery)
        }
        let before = recovering.tasks
        expectFailure("an invalid history destination must propagate its error") { try recovering.upsert(task) }
        assert(recovering.tasks == before, "failed replacement leaves the last published snapshot intact")

        try FileManager.default.removeItem(at: catalog)
        let newTask = BackgroundTask(kind: .backup, title: "Another backup", state: .queued)
        expectFailure("a removed catalog is not recreated while writing history") { try history.upsert(newTask) }
        assert(!FileManager.default.fileExists(atPath: catalog.path) && history.tasks == [task],
               "an unavailable catalog preserves in-memory history without recreating its path")
        _ = try makeCatalog("errors", in: directory)
        expectFailure("an old worker cannot write into a replacement catalog at the same path") {
            try history.upsert(newTask)
        }
        let replacement = try BackgroundTaskHistory(catalogURL: catalog)
        assert(replacement.tasks.isEmpty && !history.belongsToSameCatalog(as: replacement),
               "same-path replacement does not inherit another catalog's task identity")
    }

    @MainActor
    private static func checkActionsAndSelection() {
        var task = BackgroundTask(kind: .ai, title: "AI", state: .failed, totalCount: 10)
        task.completedCount = 6
        task.succeededCount = 1
        task.failures = [
            .init(item: "B", message: "Failure", assetID: "b"),
            .init(item: "A", message: "Failure", assetID: "a"),
            .init(item: "B again", message: "Failure", assetID: "b"),
            .init(item: "Removed", message: "Failure", assetID: "removed"),
            .init(item: "Path only", message: "Failure")
        ]
        let targets = task.failureAssetIDs(availableAssetIDs: ["a", "b", "current-selection"])
        assert(targets == ["b", "a"], "failure selection is deduplicated and excludes missing or unrelated assets")
        assert(task.failureAssetIDs(availableAssetIDs: []).isEmpty, "missing retry data never falls back to library selection")
        assert(task.availableActions(.init()).retry == nil, "failed state alone does not create a retry capability")
        assert(task.availableActions(.init()).review == nil, "saved task state alone cannot restore review results")
        var retried: [String] = []
        var reviewCount = 0
        let offered = BackgroundTask.Actions(cancel: {}, retry: { retried = targets },
                                             revealDestination: {}, selectFailures: {}, review: { reviewCount += 1 })
        let available = task.availableActions(offered)
        assert(available.cancel == nil && available.retry != nil && available.revealDestination == nil,
               "finished tasks cannot be cancelled and absent destinations cannot be revealed")
        available.retry?()
        assert(retried == ["b", "a"], "retry dispatch uses the offered original input snapshot")
        assert(task.hasPartialFailure && task.needsAttention, "partial results are not an unqualified success")
        task.state = .running
        assert(task.availableActions(offered).cancel != nil && task.availableActions(offered).retry == nil,
               "active tasks expose cancellation, not duplicate retries")
        task.state = .completed
        task.failedCount = 0
        task.failures = []
        assert(task.availableActions(offered).retry == nil && task.availableActions(offered).selectFailures == nil,
               "successful tasks do not expose retry or failure selection")
        task.availableActions(offered).review?()
        assert(reviewCount == 1 && retried == ["b", "a"],
               "successful results can be reviewed without invoking retry")
        for state in [BackgroundTask.State.queued, .running, .paused, .completed, .failed, .cancelled, .interrupted] {
            task.state = state
            assert(task.availableActions(offered).review != nil,
                   "review capability depends on retained results, not a retry state")
        }
        task.state = .failed
        assert(task.availableActions(offered).retry != nil,
               "a failed checkpoint can expose an explicit resume action without per-file failures")
        task.state = .interrupted
        assert(task.availableActions(offered).retry != nil, "interrupted retry requires an explicitly supplied callback")
        task.destination = URL(fileURLWithPath: "/tmp/export")
        assert(task.availableActions(offered).revealDestination != nil, "a local destination can use an offered reveal action")
        task.destination = URL(string: "https://example.invalid/export")
        assert(task.availableActions(offered).revealDestination == nil, "history cannot turn an arbitrary remote URL into a reveal action")
        task.completedCount = 20
        assert(task.fractionCompleted == 1, "progress is bounded above")
        task.completedCount = -1
        assert(task.fractionCompleted == 0, "progress is bounded below")
        task.totalCount = nil
        assert(task.fractionCompleted == nil, "unknown totals do not invent a completion percentage")

        let pauseResume = BackgroundTask.Actions(pause: {}, resume: {})
        task.state = .running
        assert(task.availableActions(pauseResume).pause != nil && task.availableActions(pauseResume).resume == nil,
               "only a running task exposes its offered pause action")
        task.state = .paused
        assert(task.availableActions(pauseResume).pause == nil && task.availableActions(pauseResume).resume != nil,
               "only a paused task exposes its offered resume action")
        task.state = .failed
        assert(task.availableActions(pauseResume).pause == nil && task.availableActions(pauseResume).resume == nil,
               "terminal tasks cannot use live pause or resume actions")

        let active = BackgroundTask(kind: .importPhotos, title: "Import", state: .running)
        assert(BackgroundTask.selected(in: [task, active], id: task.id)?.id == task.id,
               "task detail preserves an explicit selection")
        assert(BackgroundTask.selected(in: [task, active], id: UUID())?.id == active.id,
               "removed selection falls back to active work")
        assert(BackgroundTask.selected(in: [], id: task.id) == nil, "empty history has no stale detail selection")
    }

    private static func makeCatalog(_ name: String, in directory: URL) throws -> URL {
        let catalog = directory.appendingPathComponent("\(name).photolibrary")
        try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["uuid": UUID().uuidString])
            .write(to: catalog.appendingPathComponent("manifest.json"))
        return catalog
    }

    private static func expectFailure(_ message: String, _ action: () throws -> Void) {
        do {
            try action()
            assertionFailure(message)
        } catch {}
    }
}
