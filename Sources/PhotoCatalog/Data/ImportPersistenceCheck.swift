import Foundation

enum ImportPersistenceCheck {
    static func run() {
        MainActor.assumeIsolated {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("pc-import-persistence-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try checkStart(in: directory)
                try checkProgress(in: directory)
                try checkState(in: directory)
                try checkFinish(in: directory)
                try checkRecovery(in: directory)
                try checkCancellation(in: directory)
                print("--- import persistence assertions passed ---")
            } catch {
                fatalError("Import persistence check failed: \(error)")
            }
        }
    }

    @MainActor
    private static func checkStart(in directory: URL) throws {
        for table in ["import_sessions", "jobs"] {
            let store = try catalog("start-\(table)", in: directory)
            try block(store, table: table, operation: "INSERT")
            let app = AppState.selfCheckFixture()
            let run = ImportRun(source: directory, mode: .managed)
            assert(!app.startPersistedImport(run, store: store), "a failed start must not launch a worker")
            let sessions = try store.loadImportSessions()
            let jobs = try store.loadJobs()
            assert(sessions.isEmpty && jobs.isEmpty, "session/job creation must roll back together")
            assert(app.importRun?.phase == .failed && !app.importing,
                   "failed start must be visible and release the import lock")
            assert(app.importRun?.errorMessage?.contains("blocked \(table)") == true,
                   "the original database error must be retained")
        }
    }

    @MainActor
    private static func checkProgress(in directory: URL) throws {
        for blockFailureState in [false, true] {
            let store = try catalog("progress-\(blockFailureState)", in: directory)
            let app = AppState.selfCheckFixture()
            let run = ImportRun(source: directory, mode: .managed)
            assert(app.startPersistedImport(run, store: store))
            try block(store, table: "import_sessions", operation: "UPDATE",
                      condition: blockFailureState ? "" : "WHEN NEW.state='running'")
            if blockFailureState { try block(store, table: "jobs", operation: "UPDATE") }
            app.recordImportProgress(ImportProgress(total: 2, processed: 1), for: run.id, store: store)
            assert(app.importRun?.phase == .failed && app.importRun?.imported == 0,
                   "failed progress writes must not leave a successful or resumable live run")
            assert(app.importing && !app.startPersistedImport(ImportRun(source: directory, mode: .managed), store: store),
                   "keep the import lock until the cancelled worker exits")
            if blockFailureState {
                let message = app.importRun?.errorMessage ?? ""
                assert(message.contains("blocked import_sessions") && message.contains("blocked jobs"),
                       "failures to persist the failed state must also be surfaced")
            } else {
                let sessions = try store.loadImportSessions()
                let jobs = try store.loadJobs()
                assert(sessions.first?.state == "failed" && jobs.first?.state == "failed")
            }
            app.recordImportProgress(ImportProgress(total: 2, processed: 2), for: run.id, store: store)
            app.finishImport(folder: directory, imported: [asset(in: directory)], existingIds: [],
                             store: store, bookmark: nil, mode: .managed, runId: run.id,
                             persistSourceRoot: true)
            assert(app.importRun?.phase == .failed && !app.importing && store.assetCount() == 0,
                   "late progress and completion must not turn a checkpoint failure into success")
        }
    }

    @MainActor
    private static func checkState(in directory: URL) throws {
        for state in ["paused", "running"] {
            let store = try catalog("state-\(state)", in: directory)
            let app = AppState.selfCheckFixture()
            var run = ImportRun(source: directory, mode: .managed)
            assert(app.startPersistedImport(run, store: store))
            run.total = 10
            run.processed = 3
            assert(app.persistImportState(run, state: "paused", store: store))
            let sessions = try store.loadImportSessions()
            let jobs = try store.loadJobs()
            assert(sessions.first?.state == "paused" && jobs.first?.state == "paused")
            try block(store, table: "jobs", operation: "UPDATE", condition: "WHEN NEW.state='\(state)'")
            run.processed = 4
            assert(!app.persistImportState(run, state: state, store: store))
            let failedSession = try store.loadImportSessions().first
            let failedJob = try store.loadJobs().first
            assert(app.importRun?.phase == .failed && failedSession?.state == "failed" && failedJob?.state == "failed",
                   "failed pause/resume writes must not publish a successful transition")
            app.finishImport(folder: directory, imported: [], existingIds: [], store: store,
                             bookmark: nil, mode: .managed, runId: run.id, persistSourceRoot: true)
        }
    }

    @MainActor
    private static func checkFinish(in directory: URL) throws {
        for table in ["assets", "source_roots", "import_sessions", "jobs", "success"] {
            let store = try catalog("finish-\(table)", in: directory)
            let app = AppState.selfCheckFixture()
            app.assets = []
            let run = ImportRun(source: directory, mode: .managed)
            assert(app.startPersistedImport(run, store: store))
            switch table {
            case "assets", "source_roots": try block(store, table: table, operation: "INSERT")
            case "import_sessions":
                try block(store, table: table, operation: "UPDATE", condition: "WHEN NEW.state='completed'")
            case "jobs":
                try block(store, table: table, operation: "UPDATE", condition: "WHEN NEW.state='succeeded'")
            default:
                try store.addSourceRoot(id: "persistence-source", displayName: "Source", path: directory.path,
                                        bookmark: Data("preserved bookmark".utf8), mode: .managed)
            }
            app.finishImport(folder: directory, imported: [asset(in: directory)], existingIds: [],
                             store: store, bookmark: nil, mode: .managed, runId: run.id,
                             persistSourceRoot: true)
            let session = try store.loadImportSessions().first
            let job = try store.loadJobs().first
            let roots = try store.loadSourceRoots()
            assert(!app.importing, "completion releases the worker lock")
            if table == "success" {
                assert(app.importRun?.phase == .complete && session?.state == "completed" && job?.state == "succeeded")
                assert(roots.first?.bookmarkData == Data("preserved bookmark".utf8),
                       "retry/recovery must not erase an existing source bookmark")
            } else {
                assert(app.importRun?.phase == .failed && session?.state == "failed" && job?.state == "failed",
                       "no persistence failure may be reported as successful completion")
                assert(roots.isEmpty, "source/session/job finalization must roll back together")
                assert(app.importRun?.errorMessage?.contains("blocked \(table)") == true)
            }
            let savedCount = table == "assets" ? 0 : 1
            assert(store.assetCount() == savedCount && app.assets.count == savedCount,
                   "the UI must reflect only assets committed by the separate upsert transaction")
            assert(app.importRun?.imported == savedCount,
                   "a failed asset transaction must not retain a nonzero imported count")
            if table != "success" && savedCount > 0 {
                assert(app.importRun?.errorMessage?.contains("\u{5DF2}\u{5199}\u{5165}") == true,
                       "partial persistence must explicitly disclose already-saved assets")
            }
        }
    }

    @MainActor
    private static func checkRecovery(in directory: URL) throws {
        let store = try catalog("recovery", in: directory)
        let app = AppState.selfCheckFixture()
        let run = ImportRun(source: directory, mode: .managed)
        assert(app.startPersistedImport(run, store: store))
        guard let job = try store.loadJobs().first else { fatalError("Missing recovery fixture job") }
        let payload = try JSONDecoder().decode(ImportJobPayload.self, from: Data(job.payloadJSON.utf8))
        let restored = try app.restoredImportRun(job: job, payload: payload, folder: directory,
                                                 mode: .managed, phase: .importing, store: store)
        assert(restored.id == run.id)
        for state in ["failed", "completed", "paused"] {
            try store.updateImportSession(id: run.id.uuidString, state: state, totalCount: 0,
                                          importedCount: 0, skippedCount: 0, failedCount: 0)
            expectFailure {
                _ = try app.restoredImportRun(job: job, payload: payload, folder: directory,
                                               mode: .managed, phase: .importing, store: store)
            }
        }
        try store.db.run("DELETE FROM import_sessions;")
        expectFailure {
            _ = try app.restoredImportRun(job: job, payload: payload, folder: directory,
                                           mode: .managed, phase: .importing, store: store)
        }
        expectFailure {
            try store.updateImportSession(id: run.id.uuidString, state: "running", totalCount: 0,
                                          importedCount: 0, skippedCount: 0, failedCount: 0)
        }
        expectFailure { try store.updateJob(id: "missing", state: "running") }
        try store.db.execChecked("DROP TABLE import_sessions;")
        expectFailure {
            _ = try app.restoredImportRun(job: job, payload: payload, folder: directory,
                                           mode: .managed, phase: .importing, store: store)
        }
    }

    private static func catalog(_ name: String, in directory: URL) throws -> CatalogStore {
        try CatalogStore(packageURL: directory.appendingPathComponent(name + ".photolibrary"))
    }

    private static func checkCancellation(in directory: URL) throws {
        let paused = ImportControl()
        let entered = DispatchSemaphore(value: 0)
        let exited = DispatchSemaphore(value: 0)
        paused.pause()
        DispatchQueue.global().async {
            entered.signal()
            precondition(!paused.waitIfPaused(), "cancellation must release a paused worker without processing")
            exited.signal()
        }
        precondition(entered.wait(timeout: .now() + 5) == .success)
        paused.cancel()
        precondition(exited.wait(timeout: .now() + 5) == .success)
        paused.resume()
        paused.pause()
        assert(!paused.waitIfPaused() && !paused.isPaused, "resume must not revive a cancelled import")

        let store = try catalog("cancellation", in: directory)
        let files = [directory.appendingPathComponent("invalid-first.jpg"),
                     directory.appendingPathComponent("invalid-second.jpg")]
        for file in files { try Data("invalid image".utf8).write(to: file) }
        let control = ImportControl()
        var failures = 0
        let imported = ImportCoordinator(store: store).importFiles(files, from: directory, control: control) {
            failures = $0.failed
            if $0.failed == 1 { control.cancel() }
        }
        assert(imported.isEmpty && failures == 1, "cancelled import must not process the next file")
    }

    private static func block(_ store: CatalogStore, table: String, operation: String,
                              condition: String = "") throws {
        try store.db.execChecked("""
        CREATE TRIGGER block_\(table) BEFORE \(operation) ON \(table) \(condition)
        BEGIN SELECT RAISE(ABORT, 'blocked \(table)'); END;
        """)
    }

    private static func expectFailure(_ action: () throws -> Void) {
        var failed = false
        do { try action() } catch { failed = true }
        assert(failed, "missing/inconsistent/unreadable persistence records must fail closed")
    }

    private static func asset(in directory: URL) -> Asset {
        var asset = DemoData.assets[0]
        asset.folderId = "persistence-source"
        asset.folderName = "Source"
        asset.isDemo = false
        asset.deleted = false
        asset.localPath = directory.appendingPathComponent("synthetic.jpg").path
        asset.contentHash = nil
        return asset
    }
}
