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
                try checkCommittedDuplicates(in: directory)
                try checkCommittedReplay(in: directory)
                try checkCommittedRetries(in: directory)
                try checkCommittedRollback(in: directory)
                try checkCommittedCatalogChanges(in: directory)
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
            app.finishImport(folder: directory, imported: [asset(in: directory)],
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
            app.finishImport(folder: directory, imported: [], store: store,
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
            app.finishImport(folder: directory, imported: [asset(in: directory)],
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

    private static func checkCommittedDuplicates(in directory: URL) throws {
        let store = try catalog("committed-duplicates", in: directory)
        var run = ImportRun(source: directory, mode: .referenced)
        run.total = 12
        try store.startImportSession(id: run.id.uuidString)
        var options = batchOptions()
        var photos = (0..<5).map { asset(in: directory, index: $0) }
        for index in 0..<3 { photos[index].contentHash = "rounded-size" }
        photos[0].fileMB = 1024.1 / (1024 * 1024)
        photos[1].fileMB = 1024.4 / (1024 * 1024)
        photos[2].fileMB = 1024.6 / (1024 * 1024)
        let files = photos.map { fileResult($0, in: directory) }
        let first = try store.saveImportBatch(files + [files[0]], run: run, options: options)
        assert(first.assets.map(\.id) == [photos[0], photos[2], photos[3], photos[4]].map(\.id),
               "dedup uses rounded bytes plus hash, while files without hashes remain distinct")
        assert(first.run.saved == 4 && first.run.skipped == 1 && first.checkpoints.count == 5,
               "same-batch duplicates and repeated successful events count only once")
        var duplicate = asset(in: directory, index: 5)
        duplicate.contentHash = photos[0].contentHash
        duplicate.fileMB = 1024.49 / (1024 * 1024)
        let nextFile = fileResult(duplicate, in: directory)
        let next = try store.saveImportBatch([nextFile, nextFile], run: run, options: options)
        assert(next.assets.isEmpty && next.developSettings.isEmpty && next.checkpoints.count == 1)
        assert(next.run.saved == 4 && next.run.skipped == 2,
               "persisted hashes and counts are used even when the caller supplies its original run")
        let replay = try store.saveImportBatch([nextFile], run: run, options: options)
        assert(replay.checkpoints.isEmpty && replay.run.saved == 4 && replay.run.skipped == 2,
               "a skipped checkpoint is also a successful replay")
        for (index, strategy) in [ImportDuplicateStrategy.keep, .groupExact].enumerated() {
            options.duplicateStrategy = strategy.rawValue
            var copy = asset(in: directory, index: index + 6)
            copy.contentHash = duplicate.contentHash
            copy.fileMB = duplicate.fileMB
            let alias = ImportFileResult(source: ImportSourceFile(path: directory.appendingPathComponent("alias-\(index)").path,
                                                                 byteCount: 4096, modifiedAt: 1), asset: copy, reason: nil)
            let kept = try store.saveImportBatch([fileResult(copy, in: directory), alias], run: run, options: options)
            assert(kept.assets.map(\.id) == [copy.id] && kept.checkpoints.count == 2,
                   "keep/groupExact retain matching content but collapse repeated IDs within a batch")
            let repeatedId = try store.saveImportBatch([alias], run: run, options: options)
            assert(repeatedId.assets.isEmpty && repeatedId.checkpoints.isEmpty,
                   "keep/groupExact also preserve already skipped checkpoints")
        }
        assert(store.assetCount() == 6)
    }

    private static func checkCommittedReplay(in directory: URL) throws {
        let store = try catalog("committed-replay", in: directory)
        var photo = asset(in: directory, raw: true)
        photo.localPath = store.originalsURL.appendingPathComponent("managed.CR3").path
        let file = fileResult(photo, in: directory)
        var run = ImportRun(source: directory, mode: .managed)
        run.sourceId = "explicit-source"
        run.phase = .paused
        run.total = 10
        run.processed = 3
        run.saved = 99
        run.skipped = 98
        run.failed = 97
        run.recentAssets = [photo]
        run.failures = [ImportFailure(url: directory.appendingPathComponent("other.CR3"), reason: "Unreadable")]
        run.errorMessage = "Preserve progress details"
        try store.startImportSession(id: run.id.uuidString)
        let bookmark = Data("prior source permission".utf8)
        try store.addSourceRoot(id: run.sourceId!, displayName: "Old name", path: directory.path,
                                bookmark: bookmark, mode: .managed)
        var options = batchOptions()
        options.author = "Frozen author"
        options.copyright = "Copyright {year}"
        options.keywords = ["frozen-keyword"]
        options.colorLabel = ColorLabel.red.rawValue
        options.albumId = "frozen-album"
        options.albumName = "Frozen album"
        options.bookmark = Data("new source permission".utf8)
        var rawSettings = DevelopSettings.neutral
        rawSettings.exposure = 1.25
        options.rawDefaults[photo.camera] = DevelopPreset(id: "raw-default", name: "Camera default",
            transfer: DevelopTransfer(settings: rawSettings, fields: [.exposure], sourceIsRaw: true))
        var presetSettings = DevelopSettings.neutral
        presetSettings.contrast = 17
        options.preset = DevelopPreset(id: "import-preset", name: "Import preset",
            transfer: DevelopTransfer(settings: presetSettings, fields: [.contrast], sourceIsRaw: true))
        var expectedSettings = rawSettings
        expectedSettings.contrast = 17
        let first = try store.saveImportBatch([file], run: run, options: options)
        var expectedRun = run
        expectedRun.saved = 1
        expectedRun.skipped = 0
        expectedRun.failed = 0
        assert(first.run == expectedRun, "committed counters must not replace UI progress, failures or paused phase")
        assert(first.assets[0].author == options.author && first.assets[0].keywords.contains("frozen-keyword")
               && first.assets[0].colorLabel == .red)
        let year = Calendar.captureWallClock.component(.year, from: photo.date)
        assert(first.assets[0].copyright == "Copyright \(year)")
        assert(first.source?.id == run.sourceId && first.source?.pathHint == run.sourcePath
               && first.source?.bookmarkData == bookmark && first.source?.managementMode == "managed"
               && first.source?.volumeIdentifier == VolumeMonitor.volumeIdentifier(for: directory))
        assert(first.checkpoints.first?.source == file.source && first.checkpoints.first?.source.path != photo.localPath,
               "managed destination paths never replace the original source identity")
        let persistedSettings = try store.loadDevelopSettings()
        let initialHistory = try store.loadDevelopHistory(photo.id)
        assert(first.developSettings == [photo.id: expectedSettings] && first.developSettings == persistedSettings)
        assert(initialHistory.map(\.settings) == [rawSettings, expectedSettings],
               "RAW defaults precede the frozen import preset")
        let albums = try store.loadAlbums()
        let session = try store.loadImportSessions().first
        assert(albums.first?.assetIds == [photo.id] && albums.first?.name == options.albumName)
        assert(session?.state == "paused")

        var edited = first.assets[0]
        edited.rating = 5
        edited.title = "User title after import"
        edited.keywords = ["user-keyword"]
        try store.updateAsset(edited)
        var userSettings = expectedSettings
        userSettings.exposure = -0.5
        try store.saveDevelopSettings([photo.id: userSettings])
        _ = try store.appendDevelopHistory([photo.id: (name: "User edit", settings: userSettings)])
        let history = try store.loadDevelopHistory(photo.id)
        let lateFailure = ImportFileResult(source: file.source, asset: nil, reason: "Late duplicate event")
        let replay = try store.saveImportBatch([file, lateFailure], run: run, options: options)
        assert(replay.assets.isEmpty && replay.checkpoints.isEmpty && replay.developSettings.isEmpty)
        assert(replay.run == expectedRun, "a replay must not double-count or downgrade an already saved source")
        let saved = try store.loadAssets()
        let settings = try store.loadDevelopSettings()
        let replayHistory = try store.loadDevelopHistory(photo.id)
        let replayAlbums = try store.loadAlbums()
        assert(saved.first?.rating == 5 && saved.first?.title == edited.title && saved.first?.keywords == edited.keywords)
        assert(settings == [photo.id: userSettings] && replayHistory == history && replayAlbums == albums,
               "replays must not reapply initial metadata, settings, history or album membership")
    }

    private static func checkCommittedRetries(in directory: URL) throws {
        let store = try catalog("committed-retries", in: directory)
        let run = ImportRun(source: directory, mode: .referenced)
        try store.startImportSession(id: run.id.uuidString)
        let options = batchOptions()
        let firstFile = fileResult(asset(in: directory), in: directory)
        let failedFile = ImportFileResult(source: firstFile.source, asset: nil, reason: "Decoder failed")
        let failed = try store.saveImportBatch([failedFile, failedFile], run: run, options: options)
        assert(failed.run.failed == 1 && failed.run.saved == 0 && failed.checkpoints.count == 1 && failed.source == nil)
        let retried = try store.saveImportBatch([firstFile], run: run, options: options)
        assert(retried.run.saved == 1 && retried.run.failed == 0 && retried.checkpoints.first?.reason == nil,
               "successful retry replaces, rather than adds to, a failed checkpoint")
        let changedSource = ImportSourceFile(path: firstFile.source.path, byteCount: 8192, modifiedAt: 2)
        let changed = ImportFileResult(source: changedSource, asset: asset(in: directory, index: 1), reason: nil)
        let replaced = try store.saveImportBatch([changed], run: run, options: options)
        assert(replaced.assets.count == 1 && replaced.run.saved == 1 && store.assetCount() == 2,
               "a changed fingerprint is processed and counts still describe one checkpoint per source path")
        let sameId = ImportFileResult(source: ImportSourceFile(path: changedSource.path, byteCount: 8192, modifiedAt: 3),
                                      asset: changed.asset, reason: nil)
        let skipped = try store.saveImportBatch([sameId], run: run, options: options)
        assert(skipped.run.saved == 0 && skipped.run.skipped == 1 && skipped.assets.isEmpty,
               "changed source fingerprints cannot overwrite already cataloged IDs")
        let failedAgain = ImportFileResult(source: ImportSourceFile(path: changedSource.path, byteCount: 8192, modifiedAt: 4),
                                           asset: nil, reason: "Changed file is unreadable")
        let failure = try store.saveImportBatch([failedAgain], run: run, options: options)
        assert(failure.run.saved == 0 && failure.run.skipped == 0 && failure.run.failed == 1)
        let recovered = ImportFileResult(source: failedAgain.source, asset: asset(in: directory, index: 2), reason: nil)
        let final = try store.saveImportBatch([failedAgain, recovered, recovered], run: run, options: options)
        let session = try store.loadImportSessions().first
        let checkpoints = try store.loadImportCheckpoints(sessionId: run.id.uuidString)
        assert(final.run.saved == 1 && final.run.failed == 0 && final.run.skipped == 0 && final.assets.count == 1)
        assert(session?.importedCount == 1 && session?.failedCount == 0 && session?.skippedCount == 0)
        assert(checkpoints.count == 1 && checkpoints[0].source == recovered.source && checkpoints[0].outcome == .saved)
    }

    private static func checkCommittedRollback(in directory: URL) throws {
        for table in ["assets", "source_roots", "develop_settings", "develop_history", "albums",
                      "album_assets", "import_files", "import_sessions"] {
            let store = try catalog("committed-rollback-\(table)", in: directory)
            var run = ImportRun(source: directory, mode: .referenced)
            run.total = 3
            try store.startImportSession(id: run.id.uuidString)
            var options = batchOptions()
            options.author = "Atomic author"
            options.keywords = ["atomic-keyword"]
            options.albumId = "atomic-album"
            options.albumName = "Atomic album"
            options.preset = DevelopPreset.builtIns[0]
            let photos = (0..<3).map { asset(in: directory, index: $0, raw: false) }
            let files = photos.map { fileResult($0, in: directory) }
            let first = try store.saveImportBatch([files[0]], run: run, options: options)
            var edited = first.assets[0]
            edited.rating = 5
            try store.updateAsset(edited)
            try store.addSourceRoot(id: edited.folderId, displayName: "Before rejected batch", path: directory.path,
                                    bookmark: Data("preserved access".utf8))
            let beforeSession = try store.loadImportSessions()
            let beforeAssets = try store.loadAssets()
            let beforeSettings = try store.loadDevelopSettings()
            let beforeHistory = try store.loadDevelopHistory(edited.id)
            let beforeAlbums = try store.loadAlbums()
            let beforeSource = try store.loadSourceRoots().first
            // Reject the second new asset so an earlier row in the same batch also has to roll back.
            let condition = table == "assets" ? "WHEN NEW.id='\(photos[2].id)'" : ""
            try block(store, table: table, operation: table == "import_sessions" ? "UPDATE" : "INSERT",
                      condition: condition)
            expectFailure {
                _ = try store.saveImportBatch(Array(files.dropFirst()), run: run, options: options)
            }
            let saved = try store.loadAssets()
            let settings = try store.loadDevelopSettings()
            let history = try store.loadDevelopHistory(edited.id)
            let albums = try store.loadAlbums()
            let sessions = try store.loadImportSessions()
            let checkpoints = try store.loadImportCheckpoints(sessionId: run.id.uuidString)
            let source = try store.loadSourceRoots().first
            assert(saved == beforeAssets && settings == beforeSettings && history == beforeHistory,
                   "\(table) rejection must preserve earlier assets/edits and roll back the whole new batch")
            assert(albums == beforeAlbums && sessions == beforeSession,
                   "\(table) rejection must not publish membership or committed counts")
            assert(checkpoints.count == 1 && checkpoints[0].source == files[0].source && checkpoints[0].outcome == .saved)
            assert(source?.displayName == beforeSource?.displayName && source?.bookmarkData == beforeSource?.bookmarkData)
            assert(store.db.scalarInt("SELECT COUNT(*) FROM asset_search;") == 1)
            for photo in photos.dropFirst() {
                let newHistory = try store.loadDevelopHistory(photo.id)
                assert(newHistory.isEmpty, "initial develop history rolls back with its asset")
            }
            try store.db.execChecked("DROP TRIGGER block_\(table);")
            let retry = try store.saveImportBatch(Array(files.dropFirst()), run: run, options: options)
            assert(retry.assets.count == 2 && retry.run.saved == 3 && retry.developSettings.count == 2,
                   "a rejected batch can retry without losing earlier commits or counting attempted writes")
            let afterRetrySettings = try store.loadDevelopSettings()
            for photo in retry.assets {
                assert(photo.author == options.author && photo.keywords.contains("atomic-keyword"))
                assert(retry.developSettings[photo.id] == afterRetrySettings[photo.id])
            }
        }
        let store = try catalog("committed-missing-session", in: directory)
        expectFailure {
            _ = try store.saveImportBatch([fileResult(asset(in: directory), in: directory)],
                                         run: ImportRun(source: directory, mode: .referenced), options: batchOptions())
        }
        let sources = try store.loadSourceRoots()
        assert(store.assetCount() == 0 && sources.isEmpty, "missing sessions fail before any batch is published")
    }

    private static func checkCommittedCatalogChanges(in directory: URL) throws {
        let store = try catalog("committed-catalog-changes", in: directory)
        let run = ImportRun(source: directory, mode: .referenced)
        try store.startImportSession(id: run.id.uuidString)
        var options = batchOptions()
        options.author = "Import author"
        let peer = try CatalogStore(packageURL: store.packageURL)
        var original = asset(in: directory)
        original.contentHash = "current-content"
        original.fileMB = 1
        var edited = original
        edited.rating = 5
        edited.title = "Inserted and edited by another catalog writer"
        var demo = asset(in: directory, index: 1)
        demo.contentHash = original.contentHash
        demo.fileMB = original.fileMB
        demo.isDemo = true
        try peer.upsert([edited, demo])
        var duplicate = asset(in: directory, index: 2)
        duplicate.contentHash = original.contentHash
        duplicate.fileMB = original.fileMB
        let first = try store.saveImportBatch([fileResult(original, in: directory), fileResult(duplicate, in: directory)],
                                             run: run, options: options)
        assert(first.assets.isEmpty && first.run.skipped == 2 && first.source?.id == original.folderId,
               "current persisted IDs/content win over worker snapshots; all-skipped batches still retain source metadata")
        let current = try peer.loadAssets().first { $0.id == original.id }
        assert(current?.rating == 5 && current?.title == edited.title && current?.author == edited.author,
               "a concurrent insert is never overwritten or given import defaults")

        edited.deleted = true
        try peer.updateAsset(edited)
        let deletedId = ImportFileResult(source: ImportSourceFile(path: directory.appendingPathComponent("deleted-id.jpg").path,
                                                                 byteCount: 4096, modifiedAt: 1), asset: original, reason: nil)
        var replacement = asset(in: directory, index: 3)
        replacement.contentHash = original.contentHash
        replacement.fileMB = original.fileMB
        replacement.folderId = "fresh-source"
        options.bookmark = Data("snapshot permission".utf8)
        let replacementFile = fileResult(replacement, in: directory)
        let next = try store.saveImportBatch([deletedId, replacementFile], run: run, options: options)
        assert(next.assets.map(\.id) == [replacement.id] && next.run.saved == 1 && next.run.skipped == 3,
               "deleted IDs are reserved, but deleted and demo rows are excluded from content duplication")
        assert(next.source?.id == replacement.folderId && next.source?.bookmarkData == options.bookmark,
               "the first fresh folder takes precedence over skipped result folders and uses frozen access")
        let deleted = try store.db.query("SELECT deleted,rating,title FROM assets WHERE id=?;", [.text(original.id)]).first
        assert(deleted?.bool("deleted") == true && deleted?.int("rating") == 5 && deleted?.text("title") == edited.title)

        var removed = next.assets[0]
        removed.deleted = true
        try peer.updateAsset(removed)
        let replay = try store.saveImportBatch([replacementFile], run: run, options: options)
        assert(replay.assets.isEmpty && replay.checkpoints.isEmpty && replay.run.saved == 1 && replay.run.skipped == 3,
               "successful replay cannot resurrect a photo the user deleted after import")
        var demoResult = asset(in: directory, index: 4)
        demoResult.isDemo = true
        let ignored = try store.saveImportBatch([fileResult(demoResult, in: directory)], run: run, options: options)
        assert(ignored.assets.isEmpty && ignored.checkpoints.first?.outcome == .skipped,
               "demo results never become persisted imports")
        let count = try store.db.query("SELECT COUNT(*) AS n FROM assets WHERE id=?;", [.text(demoResult.id)]).first?.int("n")
        assert(count == 0)
    }

    private static func fileResult(_ asset: Asset, in directory: URL) -> ImportFileResult {
        ImportFileResult(source: ImportSourceFile(path: directory.appendingPathComponent(asset.id + ".jpg").path,
                                                  byteCount: 4096, modifiedAt: 1), asset: asset, reason: nil)
    }

    private static func batchOptions() -> ImportOptionsSnapshot {
        ImportOptionsSnapshot(duplicateStrategy: ImportDuplicateStrategy.skipExact.rawValue,
                              keywords: [], colorLabel: nil, author: "", copyright: "", albumName: "", albumId: nil,
                              preset: nil, rawDefaults: [:], rawDefaultOptOuts: [], bookmark: nil)
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
        app.finishImport(folder: directory, imported: [first, duplicate, third],
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
            app.finishImport(folder: directory, imported: [asset(in: directory)],
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
        app.finishImport(folder: directory, imported: [original, replacement],
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
        app.finishImport(folder: directory, imported: [], store: store, mode: .managed, runId: run.id)
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
        app.finishImport(folder: directory, imported: [], store: store, mode: .managed, runId: retry.id)
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

    private static func asset(in directory: URL, index: Int = 0, raw: Bool? = nil) -> Asset {
        let candidates = raw.map { isRaw in DemoData.assets.filter { $0.isRaw == isRaw } } ?? DemoData.assets
        var asset = candidates[index]
        asset.folderId = "persistence-source"
        asset.folderName = "Source"
        asset.isDemo = false
        asset.deleted = false
        asset.localPath = directory.appendingPathComponent("synthetic.jpg").path
        asset.contentHash = nil
        return asset
    }
}
