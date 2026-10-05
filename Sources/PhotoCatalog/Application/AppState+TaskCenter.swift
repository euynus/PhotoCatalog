import AppKit
import Foundation

@MainActor
extension AppState {
    /// Called after `store` changes, before its workers are recovered. Their original IDs
    /// will replace interrupted snapshots when the engines publish their real state.
    func configureTaskHistory(liveTaskIDs: Set<UUID> = []) {
        pruneWorkerTaskHistories()
        taskHistory = nil
        taskHistoryError = nil
        taskActions = taskActions.filter { workerTaskHistories[$0.key] != nil }
        backgroundTasks = []
        guard let store else { return }
        let history = BackgroundTaskHistory(unloadedCatalogURL: store.packageURL)
        taskHistory = history
        let attachedIDs = Set(workerTaskHistories.compactMap { id, origin -> UUID? in
            guard origin.belongsToSameCatalog(as: history),
                  origin.currentTasks.first(where: { $0.id == id })?.state.isActive == true else { return nil }
            return id
        })
        do {
            try history.load(liveTaskIDs: liveTaskIDs.union(attachedIDs))
        } catch {
            taskHistoryError = L("无法载入任务历史：\(error.localizedDescription)")
        }
        publishTaskHistory()
    }

    func showTaskCenter() {
        guard store != nil, sheet == nil || sheet == "taskCenter" else { return }
        if let history = taskHistory {
            do {
                try flushPendingTaskHistories(for: history)
                try history.refresh()
                if !history.hasPendingChanges, history.lastWriteError == nil { taskHistoryError = nil }
            } catch {
                taskHistoryError = L("无法载入任务历史：\(error.localizedDescription)")
            }
            pruneWorkerTaskHistories()
            publishTaskHistory()
        }
        sheet = "taskCenter"
    }

    /// Each engine passes the history object captured at launch. Old workers still save
    /// their own outcomes after a switch; only tracked same-library workers can reattach.
    /// Ordinary progress saves once per second; new tasks and state changes save immediately.
    func recordBackgroundTask(_ incoming: BackgroundTask, originHistory: BackgroundTaskHistory,
                              actions: BackgroundTask.Actions? = nil, forcePersist: Bool = false,
                              now: Date = .now) {
        let isCurrent = taskHistory === originHistory
        let previous = originHistory.currentTasks.first { $0.id == incoming.id }
        if let previous, !previous.state.isActive, incoming.state.isActive {
            let recoveringImport = isCurrent && (previous.state == .interrupted || previous.state == .failed)
                && incoming.kind == .importPhotos
                && importRun?.id == incoming.id && importRun?.phase.isActive == true
            guard recoveringImport else { return }
        }
        var task = incoming
        task.updatedAt = now
        if !task.state.isActive, task.state != .interrupted, task.finishedAt == nil {
            task.finishedAt = now
        }
        originHistory.stage(task)
        workerTaskHistories[task.id] = originHistory
        if let actions { taskActions[task.id] = actions }
        publishTaskHistory()
        let lastAttempt = originHistory.lastWriteAttempt
        let due = lastAttempt.map { now < $0 || now.timeIntervalSince($0) >= 1 } ?? true
        guard forcePersist || previous?.state != task.state || !task.state.isActive || due else { return }
        // Throttle failed attempts too; a disconnected disk must not trigger per-frame I/O.
        let previousError = originHistory.lastWriteError
        let sharesFile = taskHistory.map { $0.belongsToSameCatalog(as: originHistory) } ?? false
        do {
            try originHistory.savePending(now: now)
            if isCurrent || sharesFile { taskHistoryError = nil }
        } catch {
            if isCurrent || sharesFile {
                taskHistoryError = L("任务历史未保存：\(error.localizedDescription)")
            } else if previousError != error.localizedDescription {
                push("任务历史未保存（\(originHistory.catalogURL.lastPathComponent)）：\(error.localizedDescription)", "warning")
            }
        }
        if sharesFile, !isCurrent, originHistory.lastWriteError == nil {
            do { try taskHistory?.refresh() }
            catch { taskHistoryError = L("无法载入任务历史：\(error.localizedDescription)") }
        }
        pruneWorkerTaskHistories()
        publishTaskHistory()
    }

    func clearFinishedTasks() {
        guard let history = taskHistory else {
            if taskHistoryError == nil { taskHistoryError = L("任务历史不可用，未清除记录。") }
            return
        }
        do {
            try flushPendingTaskHistories(for: history)
            try history.removeFinished()
            pruneWorkerTaskHistories()
            publishTaskHistory()
            taskHistoryError = nil
        } catch {
            taskHistoryError = L("未能清除任务历史：\(error.localizedDescription)")
        }
    }

    func recordImportTask(_ run: ImportRun) {
        guard let store, let history = taskHistory, importRun?.id == run.id else { return }
        let previous = backgroundTasks.first { $0.id == run.id }
        let state: BackgroundTask.State
        switch run.phase {
        case .scanning, .importing: state = .running
        case .paused: state = .paused
        case .complete: state = .completed
        case .failed: state = .failed
        }
        let destination = run.mode == .managed ? store.originalsURL : URL(fileURLWithPath: run.sourcePath)
        var task = BackgroundTask(id: run.id, kind: .importPhotos, title: L("导入 \(run.sourceName)"),
                                  state: state, createdAt: run.startedAt,
                                  totalCount: run.total > 0 || run.phase.isFinished ? run.total : nil,
                                  destination: destination)
        task.completedCount = run.processed + run.failed
        task.succeededCount = run.saved
        task.skippedCount = run.skipped
        task.failedCount = max(run.failed, run.failures.count)
        task.detail = L("已处理 \(task.completedCount) 个文件 · 已保存 \(run.saved) 张照片") + "\n" + run.sourcePath
        task.errorMessage = run.errorMessage
        task.finishedAt = run.finishedAt
        // Keep row identity stable while progress is published, without copying every failure.
        let priorIDs = Dictionary((previous?.failures ?? []).compactMap { failure in
            failure.path.map { ($0, failure.id) }
        }, uniquingKeysWith: { first, _ in first })
        task.failures = run.failures.suffix(BackgroundTaskHistory.failureDetailLimit).map { failure in
            BackgroundTask.Failure(id: priorIDs[failure.path] ?? UUID(), item: failure.filename,
                                   message: failure.reason, path: failure.path)
        }
        recordBackgroundTask(task, originHistory: history)
    }

    func recordFullBackupTask(_ state: FullBackupState, originHistory: BackgroundTaskHistory) {
        guard let id = state.runID, let operation = state.activeOperation,
              let startedAt = state.startedAt else { return }
        let taskState: BackgroundTask.State
        switch state.status {
        case .idle: return
        case .running: taskState = .running
        case .completed: taskState = .completed
        case .failed: taskState = .failed
        case .cancelled: taskState = .cancelled
        }
        let kind: BackgroundTask.Kind
        switch operation {
        case .backup: kind = .backup
        case .verify: kind = .analysis
        case .restore: kind = .restore
        }
        var task = BackgroundTask(id: id, kind: kind, title: operation.title, state: taskState,
                                  createdAt: startedAt, totalCount: state.progress?.totalFiles,
                                  destination: state.report?.url ?? state.destinationURL)
        task.completedCount = state.progress?.completedFiles ?? 0
        // Copied files are not yet a successfully verified backup.
        task.succeededCount = state.status == .completed ? task.completedCount : 0
        task.errorMessage = state.errorMessage
        task.finishedAt = state.finishedAt
        task.detail = state.isCancelRequested && state.isRunning ? L("正在取消…") : state.progressTitle
        if let source = state.sourceURL { task.detail += "\n" + source.path }
        var actions = BackgroundTask.Actions()
        if state.isRunning, !state.isCancelRequested {
            actions.cancel = { [weak self] in self?.cancelFullBackup(runID: id) }
        }
        recordBackgroundTask(task, originHistory: originHistory, actions: actions)
    }

    func recordArtifactExportProgress(_ initial: BackgroundTask, originHistory: BackgroundTaskHistory,
                                      fraction: Double) {
        guard fraction.isFinite, let total = initial.totalCount, total > 0 else { return }
        var task = originHistory.currentTasks.first { $0.id == initial.id } ?? initial
        guard task.state.isActive else { return }
        task.completedCount = max(task.completedCount, Int((min(1, max(0, fraction)) * Double(total)).rounded()))
        recordBackgroundTask(task, originHistory: originHistory)
    }

    /// These exporters report a final artifact, not per-photo rendering success. Count
    /// the file/page they actually returned; never infer successful photos from progress.
    func finishArtifactExportTask(_ initial: BackgroundTask, originHistory: BackgroundTaskHistory,
                                  output: URL?, cancelled: Bool, failureMessage: String) {
        var task = originHistory.currentTasks.first { $0.id == initial.id } ?? initial
        guard task.state.isActive else { return }
        if let output {
            task.state = .completed
            task.destination = output
            task.completedCount = task.totalCount ?? task.completedCount
            task.succeededCount = 1
        } else if cancelled {
            task.state = .cancelled
        } else {
            task.state = .failed
            task.errorMessage = failureMessage
            task.failures = [.init(item: task.title, message: failureMessage, path: task.destination?.path)]
        }
        recordBackgroundTask(task, originHistory: originHistory, actions: .init())
    }

    /// Resolve capabilities from the current engine, not the saved row's old state. Every
    /// returned callback rechecks both the catalog and task at click time.
    func taskCenterActions(_ task: BackgroundTask) -> BackgroundTask.Actions {
        guard let history = taskHistory,
              let current = backgroundTasks.first(where: { $0.id == task.id }) else { return .init() }
        var result = offeredTaskActions(current)
        result.cancel = guardedTaskAction(\.cancel, taskID: task.id, history: history)
        result.retry = guardedTaskAction(\.retry, taskID: task.id, history: history)
        result.review = guardedTaskAction(\.review, taskID: task.id, history: history)
        result.pause = guardedTaskAction(\.pause, taskID: task.id, history: history)
        result.resume = guardedTaskAction(\.resume, taskID: task.id, history: history)
        result.revealDestination = guardedTaskAction(\.revealDestination, taskID: task.id, history: history)
        result.selectFailures = guardedTaskAction(\.selectFailures, taskID: task.id, history: history)
        return result
    }

    private func guardedTaskAction(_ key: KeyPath<BackgroundTask.Actions, BackgroundTask.Actions.Handler?>,
                                   taskID: UUID, history: BackgroundTaskHistory) -> BackgroundTask.Actions.Handler? {
        guard let task = backgroundTasks.first(where: { $0.id == taskID }),
              offeredTaskActions(task)[keyPath: key] != nil else { return nil }
        return { [weak self, weak history] in
            guard let self, let history, self.taskHistory === history,
                  let current = self.backgroundTasks.first(where: { $0.id == taskID }) else { return }
            self.offeredTaskActions(current)[keyPath: key]?()
        }
    }

    private func offeredTaskActions(_ task: BackgroundTask) -> BackgroundTask.Actions {
        var offered = taskActions[task.id] ?? .init()
        if task.kind == .ai, describeProgress != nil || !hasDescriptionReview {
            offered.review = nil
        }
        if task.kind == .importPhotos {
            // Import has pause/resume, not a user cancellation engine. A historical run may
            // never borrow the current run's failed paths or settings for retry.
            offered.cancel = nil
            offered.retry = nil
            offered.pause = nil
            offered.resume = nil
            if let run = importRun, run.id == task.id {
                if run.phase == .scanning || run.phase == .importing {
                    offered.pause = { [weak self] in self?.toggleImportPaused() }
                } else if run.phase == .paused {
                    offered.resume = { [weak self] in self?.toggleImportPaused() }
                } else if !importing, run.phase.isFinished, run.phase == .failed || !run.failures.isEmpty {
                    offered.retry = { [weak self] in
                        guard let self, let current = self.importRun, current.id == task.id, !self.importing,
                              current.phase.isFinished,
                              current.phase == .failed || !current.failures.isEmpty else { return }
                        self.sheet = nil
                        self.retryFailedImport()
                    }
                    offered.retryTitle = run.phase == .failed ? L("继续未完成导入") : L("重试失败文件")
                }
            }
        }
        if offered.revealDestination == nil, let destination = task.destination, destination.isFileURL,
           FileManager.default.fileExists(atPath: destination.path) {
            offered.revealDestination = { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
        }
        if offered.selectFailures == nil, !availableTaskFailureIDs(task).isEmpty {
            offered.selectFailures = { [weak self] in self?.selectTaskFailures(task) }
        }
        return task.availableActions(offered)
    }

    private func availableTaskFailureIDs(_ task: BackgroundTask) -> [String] {
        let available = Set(task.failures.compactMap(\.assetID).filter { asset(id: $0)?.deleted == false })
        return task.failureAssetIDs(availableAssetIDs: available)
    }

    private func selectTaskFailures(_ task: BackgroundTask) {
        let ids = availableTaskFailureIDs(task)
        guard !ids.isEmpty else { return }
        sheet = nil
        filters = Filters()
        search = ""
        switchView(.grid)
        select(Selection(type: .lib, id: "all", name: L("全部照片")))
        let wanted = Set(ids)
        let visible = Set(list.lazy.filter { wanted.contains($0.id) }.map(\.id))
        let selected = ids.filter { visible.contains($0) }
        guard let first = selected.first else {
            selectedIds = []
            primaryId = nil
            push("失败照片当前不可显示", "warning")
            return
        }
        selectCell(first, shift: false, meta: false)
        for id in selected.dropFirst() { selectCell(id, shift: false, meta: true) }
    }

    private func pruneTaskCallbacks() {
        let ids = Set(backgroundTasks.map(\.id)).union(workerTaskHistories.keys)
        taskActions = taskActions.filter { ids.contains($0.key) }
    }

    private func pruneWorkerTaskHistories() {
        workerTaskHistories = workerTaskHistories.filter { id, history in
            guard let task = history.currentTasks.first(where: { $0.id == id }) else { return false }
            if task.state.isActive || history.hasPendingChanges { return true }
            guard let current = taskHistory, current !== history,
                  current.belongsToSameCatalog(as: history) else { return false }
            return current.currentTasks.first(where: { $0.id == id })?.state.isActive == true
        }
    }

    /// Only explicitly tracked worker IDs can reattach to a same-path reopened library.
    /// Their snapshots may be displayed, but writes still use their original history and
    /// old sheet callbacks still fail the current history-object identity check.
    private func publishTaskHistory() {
        guard let history = taskHistory else {
            pruneTaskCallbacks()
            return
        }
        var records = Dictionary(history.currentTasks.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for (id, origin) in workerTaskHistories
        where origin.belongsToSameCatalog(as: history) {
            if let task = origin.currentTasks.first(where: { $0.id == id }) { records[id] = task }
            if origin.hasPendingChanges, let error = origin.lastWriteError {
                taskHistoryError = L("任务历史未保存：\(error)")
            }
        }
        backgroundTasks = BackgroundTaskHistory.retained(Array(records.values), limit: history.retentionLimit)
        pruneTaskCallbacks()
    }

    /// This retries only local history writes, never the engines represented by the rows.
    private func flushPendingTaskHistories(for current: BackgroundTaskHistory) throws {
        var visited = Set<ObjectIdentifier>()
        for history in [current] + Array(workerTaskHistories.values)
        where history.belongsToSameCatalog(as: current) {
            guard visited.insert(ObjectIdentifier(history)).inserted, history.hasPendingChanges else { continue }
            try history.savePending()
        }
    }
}
