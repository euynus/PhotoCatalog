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
                try checkBatches(in: directory)
                try checkConcurrentEdits(in: directory)
                try checkInitialEdits(in: directory)
                try checkRetryOptions(in: directory)
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
                             store: store, mode: .managed, runId: run.id)
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
                             mode: .managed, runId: run.id)
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
                             store: store, mode: .managed, runId: run.id)
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
                assert(roots.isEmpty == ["assets", "source_roots"].contains(table),
                       "source roots commit with each saved batch, before terminal task state")
                assert(app.importRun?.errorMessage?.contains("blocked \(table)") == true)
            }
            let savedCount = ["assets", "source_roots"].contains(table) ? 0 : 1
            assert(store.assetCount() == savedCount && app.assets.count == savedCount,
                   "the UI must reflect only complete asset/source/checkpoint transactions")
            assert(app.importRun?.imported == savedCount,
                   "a failed asset transaction must not retain a nonzero imported count")
            if table != "success" && savedCount > 0 {
                assert(app.importRun?.errorMessage?.contains("已保存") == true,
                       "partial persistence must explicitly disclose already-saved assets")
            }
            if table != "success" {
                let configuration = try app.savedImportConfiguration(for: run, store: store)
                let recovered = try app.restoredImportRun(job: configuration.job, payload: configuration.payload,
                    folder: directory, mode: .managed, phase: .importing, store: store, allowFailed: true)
                assert(recovered.id == run.id && recovered.saved == savedCount && recovered.failures.isEmpty,
                       "a persistence-only failure can resume its original checkpoints without file failures")
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

    @MainActor
    private static func checkBatches(in directory: URL) throws {
        let store = try catalog("batches", in: directory)
        let app = AppState.selfCheckFixture(store: store)
        app.assets = []
        let previousStrategy = app.importDuplicateStrategy
        defer { app.importDuplicateStrategy = previousStrategy }
        app.importDuplicateStrategy = .skipExact
        let run = ImportRun(source: directory, mode: .managed)
        assert(app.startPersistedImport(run, store: store))
        var first = asset(in: directory)
        first.contentHash = "same-photo"
        first.localPath = directory.appendingPathComponent("first.jpg").path
        let firstURL = URL(fileURLWithPath: first.localPath!)
        try Data("checkpoint fixture, intentionally not an image".utf8).write(to: firstURL)
        app.recordImportProgress(ImportProgress(total: 3, processed: 1, latestAsset: first,
                                               latestSource: ImportSourceFile(url: firstURL)), for: run.id, store: store)
        assert(store.assetCount() == 1 && app.importRun?.saved == 1 && app.assets.count == 1,
               "the first photo is committed and browsable before the import ends")
        app.selectedIds = [first.id]
        app.primaryId = first.id
        assert(app.setRating(5), "saved photos can be rated during import")
        let edited = app.assets.first { $0.id == first.id }!
        let checkpoints = try store.loadImportCheckpoints(sessionId: run.id.uuidString)
        assert(checkpoints.count == 1 && checkpoints.first?.outcome == .saved)
        let loaded = try CatalogStore(packageURL: store.packageURL)
        let reloadedAssets = try loaded.loadAssets()
        assert(reloadedAssets.first?.rating == 5, "committed edits survive a reopened catalog")
        let resumed = ImportCoordinator(store: loaded).importFiles(
            [firstURL], from: directory, mode: .managed, knownAssetsById: [first.id: edited],
            checkpoints: Dictionary(checkpoints.map { ($0.source.path, $0) }, uniquingKeysWith: { a, _ in a }))
        assert(resumed.count == 1 && resumed.first?.rating == 5,
               "managed recovery reuses the checkpoint without decoding or recopying the source")

        var duplicate = asset(in: directory, index: 1)
        duplicate.contentHash = first.contentHash
        duplicate.fileMB = first.fileMB
        duplicate.localPath = directory.appendingPathComponent("duplicate.jpg").path
        let duplicateURL = URL(fileURLWithPath: duplicate.localPath!)
        try Data("duplicate".utf8).write(to: duplicateURL)
        app.recordImportProgress(ImportProgress(total: 3, processed: 2, latestAsset: duplicate,
                                               latestSource: ImportSourceFile(url: duplicateURL)), for: run.id, store: store)
        assert(app.flushImportBatch(store: store))
        assert(app.importRun?.saved == 1 && app.importRun?.skipped == 1 && store.assetCount() == 1,
               "exact duplicate checks span batches, not just one batch")
        try block(store, table: "import_files", operation: "INSERT")
        var third = asset(in: directory, index: 2)
        third.contentHash = "another-photo"
        third.localPath = directory.appendingPathComponent("third.jpg").path
        let thirdURL = URL(fileURLWithPath: third.localPath!)
        try Data("third".utf8).write(to: thirdURL)
        app.recordImportProgress(ImportProgress(total: 3, processed: 3, latestAsset: third,
                                               latestSource: ImportSourceFile(url: thirdURL)), for: run.id, store: store)
        assert(app.importRun?.phase == .failed && app.importRun?.saved == 1 && store.assetCount() == 1,
               "failed checkpoint transactions roll back only their batch and preserve earlier saves")
        app.finishImport(folder: directory, imported: [first, duplicate, third], existingIds: [],
                         store: store, mode: .managed, runId: run.id)
        assert(app.assets.first?.rating == 5 && !app.importing,
               "late completion cannot overwrite an edit made while importing")
    }

    @MainActor
    private static func checkInitialEdits(in directory: URL) throws {
        for table in ["develop_settings", "album_assets", "success"] {
            let store = try catalog("initial-edits-\(table)", in: directory)
            let app = AppState.selfCheckFixture(store: store)
            app.assets = []
            let old = (app.importAuthor, app.importPostKeywords, app.importPostAlbumName, app.importDevelopPresetId)
            defer {
                app.importAuthor = old.0; app.importPostKeywords = old.1
                app.importPostAlbumName = old.2; app.importDevelopPresetId = old.3
            }
            app.importAuthor = "Captured author"
            app.importPostKeywords = "batch-test"
            app.importPostAlbumName = "Import check"
            app.importDevelopPresetId = DevelopPreset.builtIns[0].id
            let run = ImportRun(source: directory, mode: .referenced)
            assert(app.startPersistedImport(run, store: store))
            app.importAuthor = "Changed after start"
            if table != "success" { try block(store, table: table, operation: "INSERT") }
            app.finishImport(folder: directory, imported: [asset(in: directory)], existingIds: [],
                             store: store, mode: .referenced, runId: run.id)
            let saved = try store.loadAssets()
            let files = try store.loadImportCheckpoints(sessionId: run.id.uuidString)
            if table == "success" {
                assert(saved.count == 1 && saved[0].author == "Captured author" && saved[0].keywords.contains("batch-test"))
                let settings = try store.loadDevelopSettings()
                let albums = try store.loadAlbums()
                assert(settings.count == 1)
                assert(albums.contains { $0.name == "Import check" && $0.assetIds == saved.map(\.id) })
                assert(files.count == 1 && app.importRun?.saved == 1)
            } else {
                assert(saved.isEmpty && files.isEmpty && app.assets.isEmpty && app.importRun?.phase == .failed,
                       "initial edits and album membership must commit with the photo checkpoint")
            }
        }
    }

    @MainActor
    private static func checkConcurrentEdits(in directory: URL) throws {
        let store = try catalog("concurrent", in: directory)
        let app = AppState.selfCheckFixture(store: store)
        app.assets = []
        let oldStrategy = app.importDuplicateStrategy
        defer { app.importDuplicateStrategy = oldStrategy }
        app.importDuplicateStrategy = .skipExact
        let run = ImportRun(source: directory, mode: .referenced)
        assert(app.startPersistedImport(run, store: store))
        var original = asset(in: directory)
        original.contentHash = "concurrent-hash"
        original.localPath = directory.appendingPathComponent("concurrent-first.jpg").path
        let firstURL = URL(fileURLWithPath: original.localPath!)
        try Data("fixture".utf8).write(to: firstURL)
        var inserted = original
        inserted.rating = 5
        inserted.title = "Edited after another worker inserted it"
        try store.upsert([inserted])
        app.assets = [inserted]
        app.recordImportProgress(ImportProgress(total: 2, processed: 1, latestAsset: original,
                                               latestSource: ImportSourceFile(url: firstURL)), for: run.id, store: store)
        assert(app.assets.count == 1 && app.assets[0].rating == 5 && app.assets[0].title == inserted.title,
               "an import batch never appends or overwrites a concurrently inserted and edited photo")
        assert(try! store.loadAssets().first?.rating == 5, "the concurrent edit remains durable")
        assert(app.mutate([inserted.id], writingSidecars: false) { $0.deleted = true })
        var replacement = asset(in: directory, index: 1)
        replacement.contentHash = original.contentHash
        replacement.fileMB = original.fileMB
        replacement.localPath = directory.appendingPathComponent("concurrent-replacement.jpg").path
        let nextURL = URL(fileURLWithPath: replacement.localPath!)
        try Data("fixture".utf8).write(to: nextURL)
        app.recordImportProgress(ImportProgress(total: 2, processed: 2, latestAsset: replacement,
                                               latestSource: ImportSourceFile(url: nextURL)), for: run.id, store: store)
        assert(app.importRun?.saved == 1 && app.importRun?.skipped == 1,
               "a photo deleted between batches is no longer a live exact-duplicate candidate")
        let saved = try store.loadAssets()
        assert(saved.count == 1 && saved[0].id == replacement.id)
        app.finishImport(folder: directory, imported: [original, replacement], existingIds: [],
                         store: store, mode: .referenced, runId: run.id)
    }

    @MainActor
    private static func checkRetryOptions(in directory: URL) throws {
        let store = try catalog("retry-options", in: directory)
        let app = AppState.selfCheckFixture(store: store)
        app.assets = []
        let old = (app.importAuthor, app.importPostKeywords, app.importDevelopPresetId, app.visionEnabled,
                   app.readXMPSidecar, app.previewMaxPixel, app.managedArchiveRule)
        defer {
            app.importAuthor = old.0; app.importPostKeywords = old.1; app.importDevelopPresetId = old.2
            app.visionEnabled = old.3; app.readXMPSidecar = old.4; app.previewMaxPixel = old.5
            app.managedArchiveRule = old.6
        }
        app.importAuthor = "Original author"
        app.importPostKeywords = "original-keyword"
        app.importDevelopPresetId = DevelopPreset.builtIns[0].id
        app.visionEnabled = false
        app.readXMPSidecar = false
        app.previewMaxPixel = 1600
        let run = ImportRun(source: directory, mode: .managed)
        assert(app.startPersistedImport(run, store: store))
        let original = try app.savedImportConfiguration(for: run, store: store).payload
        app.finishImport(folder: directory, imported: [], existingIds: [], store: store, mode: .managed, runId: run.id)
        app.importAuthor = "Later author"
        app.importPostKeywords = "later-keyword"
        app.importDevelopPresetId = ""
        app.visionEnabled = true
        app.readXMPSidecar = true
        app.previewMaxPixel = 2048
        let retry = ImportRun(source: directory, mode: .managed)
        assert(app.startPersistedImport(retry, store: store, configuration: original))
        let saved = try app.savedImportConfiguration(for: retry, store: store).payload
        assert(saved.options == original.options && saved.autoTag == original.autoTag
               && saved.readSidecar == original.readSidecar && saved.previewMaxPixel == original.previewMaxPixel
               && saved.archiveRule == original.archiveRule,
               "a retry keeps its original metadata, preset, image processing and archive settings")
        app.finishImport(folder: directory, imported: [], existingIds: [], store: store, mode: .managed, runId: retry.id)
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
        let files = (0..<8).map { directory.appendingPathComponent("invalid-\($0).jpg") }
        for file in files { try Data("invalid image".utf8).write(to: file) }
        let control = ImportControl()
        var failures = 0
        let imported = ImportCoordinator(store: store).importFiles(files, from: directory, control: control) {
            failures = $0.failed
            if $0.failed == 1 { control.cancel() }
        }
        // files already being imported alongside finish; no file starts after the cancel
        assert(imported.isEmpty && failures >= 1 && failures <= ImportCoordinator.parallelism,
               "cancelled import must not start another file")
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

    private static func asset(in directory: URL, index: Int = 0) -> Asset {
        var asset = DemoData.assets[index]
        asset.folderId = "persistence-source"
        asset.folderName = "Source"
        asset.isDemo = false
        asset.deleted = false
        asset.localPath = directory.appendingPathComponent("synthetic.jpg").path
        asset.contentHash = nil
        return asset
    }
}
