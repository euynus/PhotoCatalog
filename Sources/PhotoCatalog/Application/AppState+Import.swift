import AppKit
import Foundation

@MainActor
extension AppState {
    // ---------- real folder import (§6.3) ----------
    /// Refuses (true) an import asked for while a catalog opens: it would go into the catalog
    /// the load is about to replace, or open another before the first photos are in.
    func refusesImportWhileCatalogLoads() -> Bool {
        guard isLoadingCatalog else { return false }
        push("目录库仍在载入，载入完成后再导入", "warning")
        return true
    }

    func addFolder() {
        guard !importing else {
            sheet = "import"
            push("已有导入任务正在运行", "warning")
            return
        }
        guard !refusesImportWhileCatalogLoads() else { return }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("导入")
        let mode = importMode
        panel.message = mode == .managed ? L("选择要复制到目录库的文件夹")
                                         : L("选择要原位添加的文件夹（原件保持不动）")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        importFolder(folder)
    }

    /// Imports one folder with the current mode — from the open panel or a Finder drop.
    func importFolder(_ folder: URL) {
        guard !importing else {
            sheet = "import"
            push("已有导入任务正在运行", "warning")
            return
        }
        guard !refusesImportWhileCatalogLoads() else { return }
        let mode = importMode
        openOrCreateCatalog()
        guard let coordinator, let store else { return }
        let sourceId = coordinator.sourceId(forFolder: folder)
        // referenced assets already in this source folder can be reused on a re-import instead
        // of being re-read/re-thumbnailed/re-Vision'd (process() skips by id)
        let knownAssetsById = Dictionary(
            assets.filter { !$0.deleted && !$0.isDemo && $0.folderId == sourceId }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        let run = ImportRun(source: folder, mode: mode)
        guard startPersistedImport(run, store: store), let control = importControl else { return }
        let vision = visionEnabled
        let previewSize = previewMaxPixel
        let archiveRule = managedArchiveRule
        let readXMP = readXMPSidecar
        cancelBackfill()  // let the import generate thumbnails without a background pass contending
        push("正在导入「\(folder.lastPathComponent)」…", "importIcon")
        Task { [weak self, coordinator, store, folder, mode, vision, previewSize, archiveRule, readXMP, sourceId, run, control, knownAssetsById] in
            guard let self else { return }
            let imported = await self.runImportWorker(run, store: store) { progress in
                coordinator.importFolder(folder, mode: mode, autoTag: vision, archiveRule: archiveRule,
                                         readSidecar: readXMP, previewMaxPixel: previewSize, control: control,
                                         knownAssetsById: knownAssetsById, progress: progress)
            }
            self.finishImport(folder: folder, imported: imported,
                              store: store, mode: mode, runId: run.id, sourceId: sourceId)
        }
    }

    // ---------- memory-card import ----------
    func refreshCardVolumes() {
        let detected = CardImportService.detectCards()
        guard detected != cardVolumes else { return }
        let added = detected.filter { !cardVolumes.contains($0) }
        cardVolumes = detected
        if let card = added.first { push("检测到存储卡「\(card.name)」· 可从侧边栏“设备”导入", "sdcard") }
    }

    func ejectCard(_ card: CardVolume) {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: card.url)
        } catch {
            push("无法推出「\(card.name)」：\(error.localizedDescription)", "warning")
        }
    }

    func showCardImport(_ card: CardVolume? = nil) {
        guard !importing else {
            sheet = "import"
            push("已有导入任务正在运行", "warning")
            return
        }
        cardImportVolume = card ?? cardVolumes.first
        cardImportDevice = card == nil && cardImportVolume == nil ? cameraDevices.first : nil
        sheet = "cardImport"
    }

    /// Copies the chosen card photos into the destination (organized, renamed, backed up) and
    /// catalogs the copies as a referenced source. The card itself is never referenced.
    func importFromCard(_ card: CardVolume?, files: [CardFile], options: CardImportOptions) {
        guard let root = prepareCopyImport(files: files, options: options) else { return }
        runCopyImport(from: card?.name ?? L("存储卡"), urls: files.map(\.url), root: root,
                      preparer: CardCopier(options: options, files: files), retriesThroughPreparer: true) { [weak self] failed in
            guard let self, options.ejectAfter, let card, failed == 0 else { return }
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: card.url)
                self.push("已推出「\(card.name)」", "eject")
            } catch {
                self.push("无法推出「\(card.name)」：\(error.localizedDescription)", "warning")
            }
        }
    }

    // ---------- camera / phone import ----------
    /// Starts watching for cameras and phones. Only the app calls this; checks never touch devices.
    func startDeviceBrowsing() {
        guard deviceBrowsingStarted == nil else { return }
        deviceBrowsingStarted = .now
        let browser = CameraDeviceBrowser.shared
        browser.onChange = { [weak self] devices in
            guard let self else { return }
            let added = devices.filter { !self.cameraDevices.contains($0) }
            self.cameraDevices = devices
            // devices already connected at launch are listed, not announced
            let settled = self.deviceBrowsingStarted.map { Date().timeIntervalSince($0) > 3 } ?? true
            if settled, let device = added.first {
                self.push("检测到「\(device.name)」· 可从侧边栏“设备”导入", device.isPhone ? "iphone" : "camera")
            }
        }
        browser.start()
    }

    func showDeviceImport(_ device: CameraDevice) {
        guard !importing else {
            sheet = "import"
            push("已有导入任务正在运行", "warning")
            return
        }
        cardImportDevice = device
        cardImportVolume = nil
        sheet = "cardImport"
    }

    /// Downloads the chosen photos from a camera or phone and copies them into the destination
    /// like card photos. Each download is staged on the destination's volume — so placing it is
    /// a clone rather than a second copy — and removed once it is in place.
    func importFromDevice(_ device: CameraDevice, files: [CardFile], options: CardImportOptions) {
        guard let root = prepareCopyImport(files: files, options: options) else { return }
        let staging: URL
        do {
            staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                  appropriateFor: root, create: true)
        } catch {
            push("无法创建目标文件夹：\(error.localizedDescription)", "warning")
            return
        }
        let staged = files.map { $0.staged(in: staging) }
        let sources = CameraDeviceBrowser.shared.sources(for: files) { CameraDevicePaths.staged($0.url, in: staging).path }
        let fetcher = DeviceFileFetcher(sources: sources, copier: CardCopier(options: options, files: staged))
        runCopyImport(from: device.name, urls: staged.map(\.url), root: root, preparer: fetcher) { failed in
            try? FileManager.default.removeItem(at: staging)
            if options.ejectAfter, failed == 0 { CameraDeviceBrowser.shared.eject(device) }
            CameraDeviceBrowser.shared.close(device)
        }
    }


    /// The common start of a copy import: nothing else importing, a catalog, the destination.
    private func prepareCopyImport(files: [CardFile], options: CardImportOptions) -> URL? {
        guard !importing else {
            sheet = "import"
            push("已有导入任务正在运行", "warning")
            return nil
        }
        guard !refusesImportWhileCatalogLoads() else { return nil }
        guard !files.isEmpty else { return nil }
        cardImportOptions = options
        openOrCreateCatalog()
        guard coordinator != nil, store != nil else { return nil }
        FileAccessService.reach(options.destination)
        if options.backupEnabled, let backup = options.backup { FileAccessService.reach(backup) }
        do {
            try FileManager.default.createDirectory(at: options.destination, withIntermediateDirectories: true)
        } catch {
            push("无法创建目标文件夹：\(error.localizedDescription)", "warning")
            return nil
        }
        return options.destination
    }

    /// Imports files that `preparer` copies into `root`, cataloging the copies as a referenced
    /// source; `finished` gets the number of files that failed. `retriesThroughPreparer`: Retry
    /// Failed can copy the failed files with `preparer` again (a card's can; a camera's session
    /// ends with the import).
    private func runCopyImport(from sourceName: String, urls: [URL], root: URL, preparer: any ImportFilePreparer,
                               retriesThroughPreparer: Bool = false,
                               finished: @escaping @MainActor (Int) -> Void) {
        guard let coordinator, let store else { return }
        let sourceId = coordinator.sourceId(forFolder: root)
        // an interrupted import resumes from the copies, never from a card or camera that may be gone
        let run = ImportRun(source: root, mode: .referenced)
        guard startPersistedImport(run, store: store), let control = importControl else { return }
        copyImportRetry = retriesThroughPreparer ? (run.id, preparer) : nil
        let vision = visionEnabled
        let previewSize = previewMaxPixel
        let readXMP = readXMPSidecar
        cancelBackfill()
        push("正在从「\(sourceName)」导入 \(urls.count) 张照片…", "importIcon")
        Task { [weak self, coordinator, store, root, vision, previewSize, readXMP, sourceId, run,
                control, preparer, urls] in
            guard let self else { return }
            let imported = await self.runImportWorker(run, store: store) { progress in
                coordinator.importFiles(urls, from: root, mode: .referenced, autoTag: vision, readSidecar: readXMP,
                                        previewMaxPixel: previewSize, control: control,
                                        preparer: preparer, progress: progress)
            }
            self.finishImport(folder: root, imported: imported,
                              store: store, mode: .referenced, runId: run.id, sourceId: sourceId)
            let completed = self.importRun?.phase == .complete
            finished(completed ? (self.importRun?.failed ?? 0) : max(1, self.importRun?.failed ?? 0))
        }
    }

    private func importOptionsSnapshot(for folder: URL, mode: ImportMode) -> ImportOptionsSnapshot {
        let presets = Dictionary(allDevelopPresets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let albumName = importPostAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)
        // a managed import's photos are its copies in Originals, which an import again finds there
        let photosFolder = mode == .managed ? store?.originalsURL ?? folder : folder
        return ImportOptionsSnapshot(
            duplicateStrategy: importDuplicateStrategy.rawValue,
            keywords: ImportPostActionService.normalizeKeywords(importPostKeywords),
            colorLabel: ColorLabel(rawValue: importPostColorLabel)?.rawValue,
            author: importAuthor, copyright: importCopyright, albumName: albumName,
            albumId: albumName.isEmpty ? nil : (albums.first { $0.name == albumName }?.id ?? "al-" + UUID().uuidString),
            preset: importDevelopPreset, rawDefaults: rawDefaultPresetIds.compactMapValues { presets[$0] },
            rawDefaultOptOuts: Set(rawDefaultPresetIds.filter { $0.value == "none" }.map(\.key)),
            bookmark: FileAccessService.createBookmark(for: folder),
            // taken as the import begins: photos removed later, while it runs, stay removed
            revivableIds: try? store?.removedAssetIds(under: photosFolder))
    }

    private func prepareImportBatches(options: ImportOptionsSnapshot,
                                      checkpoints: [ImportFileCheckpoint] = []) {
        importOptions = options
        importCheckpoints = Dictionary(checkpoints.map { ($0.source.path, $0) }, uniquingKeysWith: { _, last in last })
        pendingImportFiles = []
        lastImportBatchWrite = nil
        pendingImportRun = nil
        lastImportRunFlush = nil
    }

    private func runImportWorker(_ run: ImportRun, store: CatalogStore,
                                 operation: @escaping @Sendable (@escaping (ImportProgress) -> Void) -> [Asset]) async -> [Asset] {
        let (events, continuation) = AsyncStream<ImportProgress>.makeStream()
        let worker = Task.detached(priority: .userInitiated) {
            defer { continuation.finish() }
            return operation { continuation.yield($0) }
        }
        // Drain every progress event before completion; unstructured MainActor tasks can arrive late.
        for await progress in events { recordImportProgress(progress, for: run.id, store: store) }
        return await worker.value
    }

    @discardableResult
    func flushImportBatch(store: CatalogStore) -> Bool {
        guard !pendingImportFiles.isEmpty else { return true }
        guard let live = importRun, live.phase.isActive, let options = importOptions else { return false }
        var run = pendingImportRun ?? live
        run.phase = live.phase == .paused ? .paused : .importing
        let committed: CommittedImportBatch
        do {
            committed = try store.saveImportBatch(pendingImportFiles, run: run, options: options)
        } catch {
            failImportPersistence(error, run: live, store: store)
            return false
        }
        for checkpoint in committed.checkpoints { importCheckpoints[checkpoint.source.path] = checkpoint }
        pendingImportFiles = []
        lastImportBatchWrite = .now
        run = committed.run
        let fresh = committed.assets
        if !fresh.isEmpty {
            developSettings.merge(committed.developSettings) { _, latest in latest }
            addImportBatch(fresh, revivedIds: committed.revivedIds,
                           album: options.albumId.map { ($0, options.albumName) })
            recordSidecarBaselines(fresh, returning: committed.revivedIds)
            clearDevelopRecordCaches()
        }
        if let source = committed.source {
            if sourceManagementModesById[source.id] != source.managementMode {
                sourceManagementModesById[source.id] = source.managementMode
            }
            setSourceFolder(id: source.id, name: source.displayName, path: source.pathHint, status: source.status)
            if live.saved == 0, run.saved > 0, sheet == "import" {
                select(Selection(type: .folder, id: source.id, name: source.displayName))
            }
        }
        pendingImportRun = run
        flushPendingImportRun()
        return true
    }

    func showImportedPhotos() {
        guard let run = importRun, let rootId = run.sourceId, run.saved > 0 else { return }
        select(Selection(type: .folder, id: rootId, name: run.sourceName))
        sheet = nil
    }

    func recordImportProgress(_ progress: ImportProgress, for runId: UUID, store: CatalogStore) {
        guard let live = importRun, live.id == runId, live.phase.isActive else { return }
        var run = (pendingImportRun?.id == runId ? pendingImportRun : nil) ?? live
        if failureSeenIds.runId != run.id {
            failureSeenIds = (run.id, Set(run.failures.map(\.id)))
        }
        run.total = max(run.total, progress.total)
        run.processed = max(run.processed, progress.processed)
        if let latest = progress.latestAsset {
            run.recentAssets.removeAll { $0.id == latest.id }
            run.recentAssets.insert(latest, at: 0)
            if run.recentAssets.count > 28 {
                run.recentAssets.removeLast(run.recentAssets.count - 28)
            }
        }
        if let failure = progress.latestFailure {
            if failureSeenIds.ids.insert(failure.id).inserted {
                run.failures.append(failure)
            }
        }
        if let source = progress.latestSource {
            if progress.latestFailure == nil, failureSeenIds.ids.remove(source.path) != nil {
                run.failures.removeAll { $0.path == source.path }
            }
            pendingImportFiles.append(ImportFileResult(source: source, asset: progress.latestAsset,
                                                      reason: progress.latestFailure?.reason))
        }
        pendingImportRun = run
        let final = progress.total > 0 && progress.processed + progress.failed >= progress.total
        let saveDue = lastImportBatchWrite.map { ContinuousClock.now - $0 >= .seconds(1) } ?? true
        if pendingImportFiles.count >= 32 || saveDue || final {
            guard flushImportBatch(store: store) else { return }
            run = pendingImportRun ?? importRun ?? run
        }
        guard persistImportSessionProgress(run, store: store) else { return }
        let due = lastImportRunFlush.map { ContinuousClock.now - $0 >= .milliseconds(100) } ?? true
        if due || final { flushPendingImportRun() }
    }

    /// Publish the accumulated progress. The pending copy never owns the phase:
    /// pause/resume writes phase straight into importRun, so adopt the live one.
    private func flushPendingImportRun() {
        guard var flush = pendingImportRun else { return }
        pendingImportRun = nil
        guard let live = importRun, live.id == flush.id, live.phase.isActive else { return }
        flush.phase = live.phase == .paused ? .paused : .importing
        lastImportRunFlush = ContinuousClock.now
        importRun = flush
    }

    func finishImport(folder: URL, imported: [Asset], store: CatalogStore,
                      mode: ImportMode, runId: UUID, sourceId: String? = nil) {
        guard importRun?.id == runId else { return }
        defer {
            importing = false
            importControl = nil
            activeImportJobId = nil
        }
        guard importRun?.phase.isActive == true else { return }
        let checkpointIds = Set(importCheckpoints.values.compactMap(\.assetId))
        let pendingIds = Set(pendingImportFiles.compactMap { $0.asset?.id })
        // Also supports callers delivering a completed batch without progress events.
        for asset in imported where !checkpointIds.contains(asset.id) && !pendingIds.contains(asset.id) {
            let url = asset.localPath.map { URL(fileURLWithPath: $0) } ?? folder.appendingPathComponent(asset.filename)
            pendingImportFiles.append(ImportFileResult(source: ImportSourceFile(url: url), asset: asset, reason: nil))
        }
        guard flushImportBatch(store: store) else { return }
        flushPendingImportRun()
        guard var run = importRun, run.phase.isActive else { return }
        let rootId = run.sourceId ?? imported.first?.folderId ?? sourceId
        run.sourceId = rootId
        run.total = max(run.total, imported.count + run.failed)
        run.processed = max(run.processed, imported.count)
        run.finishedAt = .now
        run.errorMessage = importFailureSummary(run.failures)
        let unfinished = run.pending
        if unfinished > 0 {
            run.errorMessage = L("还有 \(unfinished) 个源文件未处理；已保存的照片可以继续使用。请重新连接来源后再次导入。")
        }
        do {
            guard let activeImportJobId else { throw DBError.step("Missing active import job") }
            try store.db.transaction {
                try store.updateImportSession(id: run.id.uuidString, rootId: rootId,
                                              state: unfinished > 0 ? "failed" : "completed", totalCount: run.total,
                                              importedCount: run.imported, skippedCount: run.skipped,
                                              failedCount: run.failed, finishedAt: run.finishedAt,
                                              errorMessage: run.errorMessage)
                try store.updateJob(id: activeImportJobId, state: unfinished > 0 ? "failed" : "succeeded", lockedAt: nil,
                                    lastError: run.errorMessage)
            }
        } catch {
            let detail = run.saved > 0
                ? L("\(run.saved) 张照片已写入，但导入状态未保存")
                : L("本次导入未完成")
            failImportPersistence(error, run: run, store: store, detail: detail,
                                  hasSavedAssets: run.saved > 0)
            return
        }
        if mode == .referenced, (run.saved > 0 || run.skipped > 0), !watchedRoots.contains(folder) {
            watchedRoots.append(folder)
            refreshWatcher()
        }
        run.phase = unfinished > 0 ? .failed : .complete
        importRun = run
        lastImportSessionPersistedCount = run.processed + run.failed
        importing = false
        recomputeDuplicates()
        enforceCacheLimitIfNeeded()
        backfillThumbnails()
        let failedCount = importRun?.failed ?? 0
        let message: String
        let icon: String
        if unfinished > 0 {
            message = run.errorMessage ?? L("本次导入未完成")
            icon = "warning"
        } else if run.saved == 0, run.skipped > 0 {
            message = L("已跳过 \(run.skipped) 张重复照片") + (failedCount > 0 ? L(" · \(failedCount) 失败") : "")
            icon = "warning"
        } else if run.saved == 0 {
            message = failedCount > 0 ? L("导入失败 \(failedCount) 个文件") : L("未发现可导入的照片")
            icon = "warning"
        } else {
            message = L("已导入 \(run.saved) 张照片") + (failedCount > 0 ? L(" · \(failedCount) 失败") : "")
            icon = failedCount > 0 ? "warning" : "check"
        }
        push(verbatim: message, icon)
    }

    func toggleImportPaused() {
        if let store, !flushImportBatch(store: store) { return }
        flushPendingImportRun()  // pause/resume must act on current counts
        guard var run = importRun, run.phase.isActive else { return }
        guard let importControl else {
            if run.phase == .paused {
                resumeRecoveredImport(run)
            }
            return
        }
        guard let store else { return }
        let resuming = run.phase == .paused
        run.phase = resuming ? .importing : .paused
        guard persistImportState(run, state: resuming ? "running" : "paused", store: store) else { return }
        importRun = run
        if resuming {
            importControl.resume()
            push("导入已继续", "play")
        } else {
            importControl.pause()
            push("导入已暂停", "pause")
        }
    }

    func recoverInterruptedImportJobs() {
        guard !importing, let store else { return }
        do {
            let jobs = try store.loadJobs(type: "scan", states: ["running", "paused", "failed"])
            guard let job = jobs.first(where: { $0.state != "failed" })
                ?? jobs.last(where: { $0.state == "failed" }) else { return }
            do {
                guard let payload = importJobPayload(from: job), payload.kind == "importFolder",
                      let mode = ImportMode(rawValue: payload.mode) else {
                    throw DBError.step(L("无法解析导入任务"))
                }
                let folder = URL(fileURLWithPath: payload.sourcePath)
                reachImportSource(payload)
                if job.state == "failed" {
                    importRun = try restoredImportRun(job: job, payload: payload, folder: folder,
                                                      mode: mode, phase: .failed, store: store, allowFailed: true)
                    sheet = "import"
                    return
                }
                let phase: ImportPhase = job.state == "paused" ? .paused : .importing
                let run = try restoredImportRun(job: job, payload: payload, folder: folder,
                                                mode: mode, phase: phase, store: store)
                guard FileManager.default.fileExists(atPath: folder.path) else {
                    throw DBError.step(L("源文件夹不可访问"))
                }
                if phase == .paused {
                    importRun = run
                    activeImportJobId = job.id
                    lastImportSessionPersistedCount = run.processed + run.failed
                    importing = true
                    sheet = "import"
                    push("发现暂停的导入任务", "pause")
                    return
                }
                restartRecoveredImport(jobId: job.id, run: run, folder: folder, mode: mode,
                                       autoTag: payload.autoTag,
                                       archiveRule: recoveredArchiveRule(payload),
                                       readSidecar: payload.readSidecar ?? readXMPSidecar,
                                       previewMaxPixel: payload.previewMaxPixel ?? previewMaxPixel, options: payload.options)
            } catch {
                var message = L("未能恢复导入：\(String(describing: error))")
                do {
                    try store.updateJob(id: job.id, state: "failed", lockedAt: nil, lastError: message)
                } catch { message += L(" · 任务失败状态也未保存：\(String(describing: error))") }
                push(verbatim: message, "warning")
            }
        } catch {
            push("读取导入任务失败：\(String(describing: error))", "warning")
        }
    }

    /// Opens the folder of an import interrupted in an earlier launch through the bookmark taken
    /// when it began (a sandboxed copy can't read it otherwise), for resuming or retrying it.
    private func reachImportSource(_ payload: ImportJobPayload) {
        guard let bookmark = payload.options?.bookmark,
              let resolved = FileAccessService.resolveBookmark(bookmark),
              resolved.url.standardizedFileURL.path == URL(fileURLWithPath: payload.sourcePath).standardizedFileURL.path,
              resolved.url.startAccessingSecurityScopedResource() else { return }
        securityScopedRoots.append(resolved.url)
    }

    private func resumeRecoveredImport(_ run: ImportRun) {
        guard let store else { return }
        do {
            guard let activeImportJobId,
                  let job = try store.loadJobs(type: "scan", states: ["running", "paused"])
                    .first(where: { $0.id == activeImportJobId }),
                  let payload = importJobPayload(from: job), payload.kind == "importFolder",
                  let mode = ImportMode(rawValue: payload.mode) else {
                throw DBError.step(L("导入任务缺失或无法解析"))
            }
            let folder = URL(fileURLWithPath: payload.sourcePath)
            _ = try restoredImportRun(job: job, payload: payload, folder: folder,
                                       mode: mode, phase: .paused, store: store)
            guard FileManager.default.fileExists(atPath: folder.path) else {
                throw DBError.step(L("源文件夹不可访问"))
            }
            restartRecoveredImport(jobId: job.id, run: run, folder: folder, mode: mode,
                                   autoTag: payload.autoTag,
                                   archiveRule: recoveredArchiveRule(payload),
                                   readSidecar: payload.readSidecar ?? readXMPSidecar,
                                   previewMaxPixel: payload.previewMaxPixel ?? previewMaxPixel, options: payload.options)
        } catch {
            failImportPersistence(error, run: run, store: store, detail: L("未能恢复导入"))
            importControl = nil
            self.activeImportJobId = nil
            importing = false
        }
    }

    private func restartRecoveredImport(jobId: String, run: ImportRun, folder: URL, mode: ImportMode,
                                        autoTag: Bool, archiveRule: ManagedArchiveRule,
                                        readSidecar: Bool, previewMaxPixel: Int,
                                        options: ImportOptionsSnapshot?) {
        guard let coordinator, let store else { return }
        do {
            let checkpoints = try store.loadImportCheckpoints(sessionId: run.id.uuidString)
            prepareImportBatches(options: options ?? importOptionsSnapshot(for: folder, mode: mode), checkpoints: checkpoints)
        } catch {
            failImportPersistence(error, run: run, store: store, detail: L("未能恢复导入"))
            return
        }
        var runningRun = run
        runningRun.phase = .importing
        runningRun.finishedAt = nil
        runningRun.errorMessage = nil
        activeImportJobId = jobId
        guard persistImportState(runningRun, state: "running", store: store) else {
            activeImportJobId = nil
            importing = false
            return
        }
        let control = ImportControl()
        importRun = runningRun
        importControl = control
        lastImportSessionPersistedCount = runningRun.processed + runningRun.failed
        let sourceId = coordinator.sourceId(forFolder: folder)
        // skip re-processing originals already cataloged before the crash (referenced mode)
        let knownAssetsById = Dictionary(
            assets.filter { !$0.deleted && !$0.isDemo && $0.folderId == sourceId }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        let checkpoints = importCheckpoints
        importing = true
        sheet = "import"
        push("正在恢复导入「\(folder.lastPathComponent)」…", "refresh")

        Task { [weak self, coordinator, store, folder, mode, autoTag, archiveRule, readSidecar, previewMaxPixel, sourceId, runningRun, control, knownAssetsById, checkpoints] in
            guard let self else { return }
            let imported = await self.runImportWorker(runningRun, store: store) { progress in
                coordinator.importFolder(folder, mode: mode, autoTag: autoTag,
                                         archiveRule: archiveRule, readSidecar: readSidecar,
                                         previewMaxPixel: previewMaxPixel, control: control,
                                         knownAssetsById: knownAssetsById, checkpoints: checkpoints, progress: progress)
            }
            self.finishImport(folder: folder, imported: imported,
                              store: store, mode: mode, runId: runningRun.id, sourceId: sourceId)
        }
    }

    func restoredImportRun(job: JobRecord, payload: ImportJobPayload, folder: URL,
                           mode: ImportMode, phase: ImportPhase, store: CatalogStore,
                           allowFailed: Bool = false) throws -> ImportRun {
        guard let runId = UUID(uuidString: payload.sessionId),
              let session = try store.loadImportSessions().first(where: { $0.id == payload.sessionId }) else {
            throw DBError.step(L("导入会话缺失或状态不一致，不能自动恢复"))
        }
        let resumable = ["running", "paused"].contains(session.state) && session.state == job.state
        let explicitRetry = allowFailed && ["running", "paused", "failed"].contains(job.state)
            && ["running", "paused", "failed", "completed"].contains(session.state)
        guard resumable || explicitRetry else {
            throw DBError.step(L("导入会话缺失或状态不一致，不能自动恢复"))
        }
        var run = ImportRun(id: runId, source: folder, mode: mode,
                            startedAt: session.startedAt)
        run.phase = phase
        run.sourceId = session.rootId
        run.total = session.totalCount
        let checkpoints = try store.loadImportCheckpoints(sessionId: run.id.uuidString)
        run.saved = checkpoints.filter { $0.outcome == .saved }.count
        run.skipped = checkpoints.filter { $0.outcome == .skipped }.count
        run.failed = checkpoints.filter { $0.outcome == .failed }.count
        run.failures = checkpoints.compactMap { checkpoint in
            guard checkpoint.outcome == .failed, let reason = checkpoint.reason else { return nil }
            return ImportFailure(url: URL(fileURLWithPath: checkpoint.source.path), reason: reason)
        }
        run.processed = run.saved + run.skipped
        run.finishedAt = session.finishedAt
        run.errorMessage = session.errorMessage
        return run
    }

    private func importJobPayload(from job: JobRecord) -> ImportJobPayload? {
        guard let data = job.payloadJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ImportJobPayload.self, from: data)
    }

    private func recoveredArchiveRule(_ payload: ImportJobPayload) -> ManagedArchiveRule {
        payload.archiveRule.flatMap(ManagedArchiveRule.init(rawValue:)) ?? managedArchiveRule
    }

    func savedImportConfiguration(for run: ImportRun, store: CatalogStore) throws
        -> (job: JobRecord, payload: ImportJobPayload) {
        for job in try store.loadJobs(type: "scan") {
            if let payload = importJobPayload(from: job), payload.sessionId == run.id.uuidString,
               payload.sourcePath == run.sourcePath, payload.mode == run.mode.rawValue {
                return (job, payload)
            }
        }
        throw DBError.step(L("无法读取原导入设置"))
    }

    func retryFailedImport() {
        guard !importing, let run = importRun, run.phase.isFinished,
              run.phase == .failed || !run.failures.isEmpty else { return }
        guard let coordinator, let store else {
            push("无可用目录库", "warning")
            return
        }
        let folder = URL(fileURLWithPath: run.sourcePath)
        guard FileManager.default.fileExists(atPath: folder.path) else {
            push("源文件夹不可访问", "warning")
            return
        }
        let configuration: (job: JobRecord, payload: ImportJobPayload)
        do {
            configuration = try savedImportConfiguration(for: run, store: store)
            if run.phase == .failed {
                let restored = try restoredImportRun(job: configuration.job, payload: configuration.payload,
                    folder: folder, mode: run.mode, phase: .importing, store: store, allowFailed: true)
                let payload = configuration.payload
                restartRecoveredImport(jobId: configuration.job.id, run: restored, folder: folder, mode: run.mode,
                    autoTag: payload.autoTag, archiveRule: recoveredArchiveRule(payload),
                    readSidecar: payload.readSidecar ?? readXMPSidecar,
                    previewMaxPixel: payload.previewMaxPixel ?? previewMaxPixel, options: payload.options)
                return
            }
        } catch {
            push("无法继续导入：\(String(describing: error))", "warning")
            return
        }
        let files = run.failures.map { URL(fileURLWithPath: $0.path) }
        // a card import's failures are the card's files: copied off it again, as the import would have
        let preparer = copyImportRetry?.runId == run.id ? copyImportRetry?.preparer : nil
        let retry = ImportRun(source: folder, mode: run.mode)
        guard startPersistedImport(retry, store: store, configuration: configuration.payload), let control = importControl else {
            importRun?.failures = run.failures
            return
        }
        copyImportRetry = preparer.map { (retry.id, $0) }
        let vision = configuration.payload.autoTag
        let previewSize = configuration.payload.previewMaxPixel ?? previewMaxPixel
        let archiveRule = recoveredArchiveRule(configuration.payload)
        let readXMP = configuration.payload.readSidecar ?? readXMPSidecar
        push("正在重试 \(files.count) 个失败文件…", "refresh")
        Task { [weak self, coordinator, store, folder, files, retry, vision, archiveRule, readXMP, previewSize, control,
                preparer] in
            guard let self else { return }
            let imported = await self.runImportWorker(retry, store: store) { progress in
                coordinator.importFiles(files, from: folder, mode: retry.mode, autoTag: vision,
                                        archiveRule: archiveRule, readSidecar: readXMP,
                                        previewMaxPixel: previewSize, control: control,
                                        preparer: preparer, progress: progress)
            }
            self.finishImport(folder: folder, imported: imported,
                              store: store, mode: retry.mode, runId: retry.id)
        }
    }

    private func importFailureSummary(_ failures: [ImportFailure]) -> String? {
        guard !failures.isEmpty else { return nil }
        return failures.map { "\($0.filename): \($0.reason)" }.joined(separator: "\n")
    }

    func startPersistedImport(_ run: ImportRun, store: CatalogStore, configuration: ImportJobPayload? = nil) -> Bool {
        guard !importing else { return false }
        sheet = "import"
        let jobId = "job-" + run.id.uuidString
        let options = configuration?.options
            ?? importOptionsSnapshot(for: URL(fileURLWithPath: run.sourcePath), mode: run.mode)
        do {
            try store.db.transaction {
                try store.startImportSession(id: run.id.uuidString, startedAt: run.startedAt)
                try store.startImportJob(id: jobId, sessionId: run.id.uuidString,
                                         sourcePath: run.sourcePath, mode: run.mode,
                                         autoTag: configuration?.autoTag ?? visionEnabled,
                                         archiveRule: configuration.map(recoveredArchiveRule) ?? managedArchiveRule,
                                         readSidecar: configuration?.readSidecar ?? readXMPSidecar,
                                         previewMaxPixel: configuration?.previewMaxPixel ?? previewMaxPixel, options: options)
            }
        } catch {
            failImportPersistence(error, run: run, store: store)
            return false
        }
        importRun = run
        prepareImportBatches(options: options)
        importControl = ImportControl()
        activeImportJobId = jobId
        lastImportSessionPersistedCount = 0
        importing = true
        return true
    }

    private func persistImportSessionProgress(_ run: ImportRun, store: CatalogStore) -> Bool {
        let completedCount = run.processed + run.failed
        let stride = max(1, run.total / 100)
        guard completedCount == 0 || completedCount == run.total ||
                completedCount - lastImportSessionPersistedCount >= stride else { return true }
        do {
            try store.updateImportSession(id: run.id.uuidString,
                                          state: run.phase == .paused ? "paused" : "running",
                                          totalCount: run.total, importedCount: run.imported,
                                          skippedCount: run.skipped, failedCount: run.failed)
            lastImportSessionPersistedCount = completedCount
            return true
        } catch {
            failImportPersistence(error, run: run, store: store)
            return false
        }
    }

    func persistImportState(_ run: ImportRun, state: String, store: CatalogStore) -> Bool {
        do {
            guard let activeImportJobId else { throw DBError.step("Missing active import job") }
            try store.db.transaction {
                try store.updateImportSession(id: run.id.uuidString, state: state,
                                              totalCount: run.total, importedCount: run.imported,
                                              skippedCount: run.skipped, failedCount: run.failed)
                try store.updateJob(id: activeImportJobId, state: state)
            }
            return true
        } catch {
            failImportPersistence(error, run: run, store: store)
            return false
        }
    }

    private func failImportPersistence(_ error: Error, run: ImportRun, store: CatalogStore,
                                       detail: String = L("本次处理结果未保存"), hasSavedAssets: Bool = false) {
        var failed = run
        failed.phase = .failed
        failed.finishedAt = .now
        if !hasSavedAssets && failed.saved == 0 {
            failed.processed = 0
            failed.skipped = 0
            failed.recentAssets = []
        }
        var messages = [L("写入目录库失败：\(String(describing: error))"), detail]
        if failed.saved > 0 { messages.append(L("已保存 \(failed.saved) 张照片，仍可浏览和编辑")) }
        if let summary = importFailureSummary(run.failures) { messages.append(summary) }
        if let activeImportJobId {
            // Attempt both independently: a broken session must not leave a resumable job.
            do {
                try store.updateJob(id: activeImportJobId, state: "failed", lockedAt: nil,
                                    lastError: messages.joined(separator: " · "))
            } catch { messages.append(L("任务失败状态也未保存：\(String(describing: error))")) }
            do {
                try store.updateImportSession(id: run.id.uuidString, state: "failed",
                                              totalCount: failed.total, importedCount: failed.imported,
                                              skippedCount: failed.skipped, failedCount: failed.failed,
                                              finishedAt: failed.finishedAt,
                                              errorMessage: messages.joined(separator: " · "))
            } catch { messages.append(L("会话失败状态也未保存：\(String(describing: error))")) }
        }
        failed.errorMessage = messages.joined(separator: " · ")
        pendingImportRun = nil
        importRun = failed
        // ponytail: cancellation takes effect between files; keep the lock until the current file exits.
        importControl?.cancel()
        push(verbatim: failed.errorMessage ?? L("导入失败"), "warning")
    }
}
