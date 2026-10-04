import Foundation

enum TaskCenterWorkflowCheck {
    static func run() {
        MainActor.assumeIsolated {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("pc-task-workflow-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            do {
                try checkCatalogIdentity(in: directory)
                try checkImportAndSelection(in: directory)
                try checkPersistenceFailure(in: directory)
                try checkBackupHistory(in: directory)
                print("--- task center workflow assertions passed ---")
            } catch {
                fatalError("Task center workflow check failed: \(error)")
            }
        }
    }

    @MainActor
    private static func fixture(_ name: String, in directory: URL) throws -> AppState {
        let store = try CatalogStore(packageURL: directory.appendingPathComponent(name + ".photolibrary"))
        let app = AppState.selfCheckFixture(store: store)
        app.runsBackgroundMaintenance = false
        return app
    }

    @MainActor
    private static func checkCatalogIdentity(in directory: URL) throws {
        let app = try fixture("origin", in: directory)
        let origin = app.taskHistory!
        var task = BackgroundTask(kind: .exportPhotos, title: "Export", state: .running, totalCount: 2)
        var cancels = 0
        app.recordBackgroundTask(task, originHistory: origin, actions: .init(cancel: { cancels += 1 }))
        let oldCancel = app.taskCenterActions(task).cancel
        oldCancel?()
        assert(cancels == 1, "a live task exposes its engine callback")

        app.configureTaskHistory()
        assert(app.taskHistory !== origin && app.backgroundTasks.first?.state == .running,
               "same-path reopening reattaches only tracked live worker IDs")
        oldCancel?()
        assert(cancels == 1, "callbacks from the previous panel cannot operate after reopening")
        app.taskCenterActions(task).cancel?()
        assert(cancels == 2, "the reattached task supplies a fresh guarded callback")

        task.state = .completed
        task.completedCount = 2
        task.succeededCount = 2
        app.recordBackgroundTask(task, originHistory: origin)
        assert(app.backgroundTasks.first?.state == .completed,
               "the original worker's terminal outcome appears in the reopened library")
        var late = task
        late.state = .running
        late.completedCount = 1
        app.recordBackgroundTask(late, originHistory: origin)
        assert(app.backgroundTasks.first?.state == .completed && origin.currentTasks.first?.completedCount == 2,
               "late progress cannot revive a completed task")
        assert(app.taskCenterActions(task).cancel == nil, "terminal tasks cannot cancel a different worker")

        let other = try fixture("other", in: directory)
        task.detail = "Final outcome from original worker"
        other.recordBackgroundTask(task, originHistory: origin)
        assert(other.backgroundTasks.isEmpty, "a foreign catalog worker does not populate current history")
        let saved = try BackgroundTaskHistory(catalogURL: origin.catalogURL)
        assert(saved.tasks.first?.detail == task.detail, "foreign worker outcomes still reach their original catalog")
        let otherSaved = try BackgroundTaskHistory(catalogURL: other.store!.packageURL)
        assert(otherSaved.tasks.isEmpty, "foreign outcomes never reach the new catalog on disk")
    }

    @MainActor
    private static func checkImportAndSelection(in directory: URL) throws {
        let app = try fixture("actions", in: directory)
        var run = ImportRun(source: directory, mode: .referenced)
        run.phase = .failed
        run.total = 3
        run.processed = 1
        run.saved = 1
        run.errorMessage = "Catalog write failed"
        app.importRun = run
        let importTask = app.backgroundTasks.first { $0.id == run.id }!
        assert(importTask.succeededCount == 1 && importTask.completedCount == 1,
               "import task reports durable saves separately from unfinished work")
        assert(app.taskCenterActions(importTask).retry != nil && importTask.failures.isEmpty,
               "a database-only import failure still offers explicit continuation")
        assert(app.taskCenterActions(importTask).cancel == nil, "import does not invent a cancel capability")

        var kept = DemoData.assets[0], removed = DemoData.assets[1]
        kept.deleted = false
        removed.deleted = true
        app.assets = [kept, removed]
        var failed = BackgroundTask(kind: .enhance, title: "Enhance", state: .failed)
        failed.failures = [
            .init(item: kept.filename, message: "Failed", assetID: kept.id),
            .init(item: removed.filename, message: "Failed", assetID: removed.id),
            .init(item: kept.filename, message: "Failed again", assetID: kept.id),
        ]
        app.recordBackgroundTask(failed, originHistory: app.taskHistory!)
        app.taskCenterActions(failed).selectFailures?()
        assert(app.selectedIds == [kept.id] && app.primaryId == kept.id,
               "select failures excludes removed assets and deduplicates IDs")
    }

    @MainActor
    private static func checkPersistenceFailure(in directory: URL) throws {
        let app = try fixture("write-error", in: directory)
        let history = app.taskHistory!
        let config = history.fileURL.deletingLastPathComponent()
        try FileManager.default.removeItem(at: config)
        try Data("blocked".utf8).write(to: config)
        var task = BackgroundTask(kind: .preview, title: "Preview", state: .running, totalCount: 2)
        let start = Date(timeIntervalSince1970: 1_000)
        app.recordBackgroundTask(task, originHistory: history, now: start)
        assert(app.backgroundTasks.first?.id == task.id && app.taskHistoryError != nil && history.hasPendingChanges,
               "history write failure remains visible without dropping the live task")
        task.completedCount = 1
        app.recordBackgroundTask(task, originHistory: history, now: start.addingTimeInterval(0.1))
        assert(history.lastWriteAttempt == start && app.backgroundTasks.first?.completedCount == 1,
               "failed writes are throttled while current progress remains visible")
        try FileManager.default.removeItem(at: config)
        task.state = .completed
        task.completedCount = 2
        task.succeededCount = 2
        app.recordBackgroundTask(task, originHistory: history, now: start.addingTimeInterval(0.2))
        assert(!history.hasPendingChanges && app.taskHistoryError == nil,
               "terminal outcomes retry immediately and clear a resolved persistence error")
        let reopened = try BackgroundTaskHistory(catalogURL: history.catalogURL)
        assert(reopened.tasks.first?.state == .completed, "recovered history writes preserve the actual terminal outcome")
    }

    @MainActor
    private static func checkBackupHistory(in directory: URL) throws {
        let app = try fixture("backup-history", in: directory)
        let history = app.taskHistory!
        var task = BackgroundTask(kind: .backup, title: "Backup", state: .running)
        app.recordBackgroundTask(task, originHistory: history)
        let backup = directory.appendingPathComponent("with-live-history.photobackup")
        try FullBackupService.backup(app.store!, to: backup) { progress in
            task.completedCount = progress.completedFiles
            app.recordBackgroundTask(task, originHistory: history, forcePersist: true)
        }
        assert(!FileManager.default.fileExists(atPath: backup.appendingPathComponent("Library/Logs/TaskHistory.json").path),
               "a backup's own live task history is excluded from the snapshot and cannot invalidate its file copy")
    }
}
