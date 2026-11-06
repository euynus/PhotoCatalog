import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
extension AppState {
    // ---------- catalog health / cache (§6.1, §17.3) ----------
    func runHealthCheck() {
        guard !importing else { push("导入中无法运行健康检查", "warning"); return }
        guard let store else { push("无目录库", "warning"); return }
        let packageURL = store.packageURL
        let snapshot = assets
        Task { [weak self, store, packageURL, snapshot] in
            let report = await Task.detached(priority: .utility) {
                CatalogHealth.check(store, assets: snapshot)
            }.value
            guard let self, self.store?.packageURL == packageURL else { return }
            self.applyHealthReport(report)
            self.push(verbatim: report.summary, report.isHealthy ? "check" : "warning")
        }
    }

    private func applyHealthReport(_ report: HealthReport) {
        healthReport = report
        statusMetrics = StatusMetrics(cacheBytes: report.cacheBytes,
                                      lastBackupDate: statusMetrics.lastBackupDate,
                                      backupCount: report.backupCount)
    }

    func refreshStatusMetrics() {
        guard let store else {
            statusMetrics = StatusMetrics()
            return
        }
        let packageURL = store.packageURL
        Task { [weak self, store, packageURL] in
            let metrics = await Task.detached(priority: .utility) {
                let backups = BackupService.listBackups(store)
                return StatusMetrics(cacheBytes: CatalogHealth.directorySize(store.cacheURL),
                                     lastBackupDate: backups.first.flatMap(BackupService.date(of:)),
                                     backupCount: backups.count)
            }.value
            guard let self, self.store?.packageURL == packageURL else { return }
            self.statusMetrics = metrics
            if var report = self.healthReport {
                report.cacheBytes = metrics.cacheBytes ?? report.cacheBytes
                report.backupCount = metrics.backupCount
                self.healthReport = report
            }
        }
    }

    func rebuildThumbnails() {
        guard let coordinator, let packageURL = store?.packageURL else { push("无已导入照片", "warning"); return }
        let real = thumbnailMaintenanceAssets
        guard !real.isEmpty else { push("无已导入照片", "warning"); return }
        push("正在重建缩略图…", "refresh")
        let previewSize = previewMaxPixel
        Task { [weak self, coordinator, real, previewSize, packageURL] in
            await Task.detached(priority: .utility) {
                for a in real {
                    if let path = a.localPath {
                        let original = URL(fileURLWithPath: path)
                        _ = coordinator.thumbnails.generate(from: original, assetId: a.id, kind: .thumb256)
                        _ = coordinator.thumbnails.generate(from: original, assetId: a.id, kind: .thumb512)
                        _ = coordinator.thumbnails.generate(
                            from: original,
                            assetId: a.id,
                            kind: ThumbnailService.previewKind(forCachePath: a.preview,
                                                               fallbackMaxPixel: previewSize))
                    }
                }
            }.value
            self?.finishThumbnailRebuild(expectedCatalogURL: packageURL)
        }
    }

    @discardableResult
    func finishThumbnailRebuild(expectedCatalogURL: URL? = nil) -> Bool {
        if let expectedCatalogURL, store?.packageURL != expectedCatalogURL { return false }
        invalidateThumbnailCache()
        enforceCacheLimitIfNeeded()
        push("缩略图已重建", "check")
        return true
    }

    /// Stop any in-flight thumbnail backfill (e.g. when a fresh import is about to
    /// generate its own thumbnails, or the catalog is closing) so the two passes
    /// don't contend for disk I/O. Resets state eagerly so a subsequent
    /// backfillThumbnails() isn't blocked by the cancelled run's lingering flag, and
    /// bumps the generation so the orphaned task's cleanup can't clobber a newer run.
    func cancelBackfill() {
        backfillCancellation?.set()
        backfillTask?.cancel()
        backfillTask = nil
        backfillCancellation = nil
        isBackfilling = false
        backfillGeneration &+= 1
    }

    /// Low-priority background pass that fills in any missing/stale thumbnails for
    /// imported photos (visible-first generation is handled per-cell). PRD §6.6 THM-003.
    ///
    /// Every thumbnail first (the grid needs them), while the thumbnails alone fit under the
    /// cache limit — a prune takes previews first to make room for them — then previews,
    /// newest photos first, while everything fits. Previews past the limit would be pruned
    /// when the pass ends and made again at the next launch, which kept a 14,000-photo
    /// library (6.7 GB of cache against the 2 GB default) decoding RAWs for the best part of
    /// an hour on every launch.
    ///
    /// Processed in small chunks so the pass stays cooperative: it yields between
    /// chunks, honors cancellation, and re-checks Low Power Mode mid-run rather than
    /// only once at the start.
    func backfillThumbnails() {
        guard runsBackgroundMaintenance, let coordinator, let store, !isBackfilling else { return }
        // battery saver: skip background work under Low Power Mode (§17.5)
        if reduceBackgroundOnLowPower, ProcessInfo.processInfo.isLowPowerModeEnabled { return }
        let real = thumbnailMaintenanceAssets
        guard !real.isEmpty else { return }
        isBackfilling = true
        backfillGeneration &+= 1
        let generation = backfillGeneration
        let previewSize = previewMaxPixel
        let lowPowerSensitive = reduceBackgroundOnLowPower
        let limit = cacheLimit
        let cacheURL = store.cacheURL, thumbnailsURL = store.thumb512URL.deletingLastPathComponent()
        let thumbnails: [(Asset, ThumbnailService.Kind)] = real.map { ($0, .thumb512) }
        let previews: [(Asset, ThumbnailService.Kind)] = real.sorted { $0.date > $1.date }.map {
            ($0, ThumbnailService.previewKind(forCachePath: $0.preview, fallbackMaxPixel: previewSize))
        }
        let cancellation = CancellationFlag()
        backfillCancellation = cancellation
        let originHistory = taskHistory
        let initial = BackgroundTask(kind: .preview, title: L("生成缩略图和预览"), state: .queued,
                                     totalCount: thumbnails.count + previews.count, destination: cacheURL)
        if let originHistory {
            recordBackgroundTask(initial, originHistory: originHistory, actions: .init(cancel: { [weak self] in
                guard let self, self.backfillGeneration == generation,
                      self.backfillCancellation === cancellation else { return }
                self.cancelBackfill()
            }))
        }
        backfillTask = Task { [weak self, coordinator, thumbnails, previews, originHistory, initial] in
            var task = initial
            var passLimit: Int64?
            defer {
                if cancellation.isSet || Task.isCancelled {
                    task.state = .cancelled
                    task.detail = L("预览生成已取消")
                    task.errorMessage = nil
                } else if task.state.isActive {
                    task.state = task.failedCount > 0 ? .failed : .completed
                    task.detail = L("缓存检查与生成已结束")
                }
                if let originHistory {
                    self?.recordBackgroundTask(task, originHistory: originHistory, actions: .init())
                }
                // Terminal history belongs to this worker even if a newer generation now
                // owns the shared UI flags. Never let the old cleanup clear the new run.
                if let self, self.backfillGeneration == generation {
                    self.isBackfilling = false
                    self.backfillTask = nil
                    self.backfillCancellation = nil
                    self.enforceCacheLimitIfNeeded(automaticLimitBytes: passLimit)
                }
            }
            // Let the initial window and visible thumbnails settle before
            // maintenance starts competing for disk and Image I/O.
            do { try await Task.sleep(for: .milliseconds(750)) } catch { return }
            guard !cancellation.isSet, !Task.isCancelled else { return }
            task.state = .running
            if let originHistory { self?.recordBackgroundTask(task, originHistory: originHistory) }
            let measured = await ThumbnailRepairQueue.run(.background) {
                () -> (used: Int64, thumbnails: Int64, limit: Int64) in
                let used = CatalogHealth.directorySize(cacheURL)
                return (used, CatalogHealth.directorySize(thumbnailsURL), limit.bytes(cacheBytes: used))
            }
            guard let measured else {
                task.state = .interrupted
                task.errorMessage = L("预览任务未能开始")
                return
            }
            var (used, thumbnailsUsed) = (measured.used, measured.thumbnails)
            // the pass ends by pruning to the automatic limit it started with
            let limitBytes = measured.limit
            if limit.chosenMB <= 0 { passLimit = limitBytes }
            // stopping a twentieth short of the limit leaves the end-of-pass prune nothing to take
            // back, so the next launch finds the cache full and makes nothing
            let budget = limitBytes - limitBytes / 20
            let chunkSize = 8
            passes: for (work, isThumbnail) in [(thumbnails, true), (previews, false)] {
                task.detail = isThumbnail ? L("正在生成缩略图") : L("正在生成预览")
                var index = 0
                while index < work.count, (isThumbnail ? thumbnailsUsed : used) < budget {
                    if cancellation.isSet || Task.isCancelled { break passes }
                    // re-check Low Power Mode between chunks — it can be toggled mid-run
                    if lowPowerSensitive, ProcessInfo.processInfo.isLowPowerModeEnabled {
                        task.state = .interrupted
                        task.detail = L("低电量模式已停止预览生成")
                        break passes
                    }
                    let chunk = Array(work[index..<min(index + chunkSize, work.count)])
                    let room = budget - (isThumbnail ? thumbnailsUsed : used)
                    // off the cooperative pool, one at a time at background QoS, so a large
                    // backfill never competes with visible repairs or the UI
                    let outcome = await ThumbnailRepairQueue.run(.background) {
                        () -> (bytes: Int64, processed: Int, ready: Int, failures: [BackgroundTask.Failure]) in
                        var added: Int64 = 0
                        var processed = 0, ready = 0
                        var failures: [BackgroundTask.Failure] = []
                        for (a, kind) in chunk where added < room {
                            guard !cancellation.isSet else { break }
                            processed += 1
                            guard let path = a.localPath,
                                  FileManager.default.fileExists(atPath: path) else {
                                failures.append(.init(item: a.filename, message: L("原件不可访问"),
                                                      assetID: a.id, path: a.localPath))
                                continue
                            }
                            let cached = coordinator.thumbnails.cachePath(assetId: a.id, kind: kind)
                            let existed = FileManager.default.fileExists(atPath: cached.path)
                            let made = coordinator.thumbnails.ensureCached(
                                from: URL(fileURLWithPath: path), fallbackPreview: nil,
                                catalogModificationDate: a.fileModifiedAt, assetId: a.id, kind: kind)
                            if made != nil {
                                ready += 1
                            } else {
                                failures.append(.init(item: a.filename, message: L("无法生成缓存图像"),
                                                      assetID: a.id, path: path))
                            }
                            if !existed, let made {
                                added += Int64((try? made.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                            }
                        }
                        return (added, processed, ready, failures)
                    }
                    guard let outcome else { break passes }
                    used += outcome.bytes
                    if isThumbnail { thumbnailsUsed += outcome.bytes }
                    index += outcome.processed
                    task.completedCount += outcome.processed
                    task.succeededCount += outcome.ready
                    task.failedCount += outcome.failures.count
                    task.failures = Array((task.failures + outcome.failures).suffix(BackgroundTaskHistory.failureDetailLimit))
                    if let originHistory { self?.recordBackgroundTask(task, originHistory: originHistory) }
                    do { try await Task.sleep(for: .milliseconds(10)) } catch { break passes }
                }
            }
            if task.state.isActive, task.completedCount < (task.totalCount ?? 0) {
                task.state = .interrupted
                task.detail = L("达到缓存预算，预览生成已停止")
            }
        }
    }

    var thumbnailMaintenanceAssets: [Asset] {
        assets.filter {
            !$0.deleted && !$0.isDemo && $0.status == .ready && $0.localPath != nil
        }
    }

    /// Privacy: delete catalog log files (§17.6).
    func confirmClearLogs() {
        guard confirmDestructiveAction(L("清除日志？"), L("将删除当前目录库中的本地日志文件。"), L("清除")) else { return }
        clearLogs()
    }

    func clearLogs() {
        guard let store else { push("无目录库", "warning"); return }
        let fm = FileManager.default
        let logs = (try? fm.contentsOfDirectory(at: store.logsURL, includingPropertiesForKeys: nil)) ?? []
        var failed = 0
        for url in logs {
            do {
                try fm.removeItem(at: url)
            } catch {
                failed += 1
            }
        }
        guard failed == 0 else {
            push("清除日志失败", "warning")
            return
        }
        push("已清除日志", "trash")
    }

    /// Privacy: drop stored security-scoped bookmarks; sources need re-authorization (§17.6).
    func confirmClearSecurityBookmarks() {
        guard confirmDestructiveAction(L("清除安全书签？"), L("当前目录库的源文件夹下次访问时需要重新授权。"), L("清除")) else { return }
        clearSecurityBookmarks()
    }

    func clearSecurityBookmarks() {
        guard let store else { push("无目录库", "warning"); return }
        do {
            try store.clearSourceBookmarks()
        } catch {
            push("清除安全书签失败", "warning")
            return
        }
        let sourceIds = Set(((try? store.loadSourceRoots()) ?? []).map(\.id))
        for url in securityScopedRoots {
            url.stopAccessingSecurityScopedResource()
        }
        securityScopedRoots = []
        watchedRoots = []
        for i in folders.indices where sourceIds.contains(folders[i].id) {
            folders[i] = Folder(id: folders[i].id, name: folders[i].name, status: "permissionLost")
        }
        refreshWatcher()
        push("已清除安全书签，下次访问需重新授权", "trash")
    }

    func confirmClearCache() {
        guard confirmDestructiveAction(L("清理缓存？"), L("将删除当前目录库的缩略图和预览缓存，可稍后重新生成。"), L("清理")) else { return }
        clearCache()
    }

    func clearCache() {
        guard let store else { push("无目录库", "warning"); return }
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: store.cacheURL.path) {
                try fm.removeItem(at: store.cacheURL)
            }
            for dir in [store.thumb256URL, store.thumb512URL, store.preview1600URL, store.preview2048URL] {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        } catch {
            push("清理缓存失败", "warning")
            return
        }
        invalidateThumbnailCache()
        refreshStatusMetrics()
        push("已清理缩略图缓存", "trash")
    }

    private func invalidateThumbnailCache() {
        ThumbLoader.clearCache()
        failedCacheRepairs.removeAll()
        verifiedCacheSources.removeAll()
        thumbnailCacheGeneration &+= 1
    }

    private func isVerified(_ source: String, for assetId: String) -> Bool {
        verifiedCacheSources[assetId]?.contains(source) == true
    }

    private func markVerified(_ source: String, for assetId: String) {
        verifiedCacheSources[assetId, default: []].insert(source)
    }

    static func confirmDestructiveAction(title: String, message: String, confirmTitle: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: L("取消"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    func visibleImageSource(for asset: Asset, requestedSource: String,
                            kind: ThumbnailService.Kind) async -> String {
        if requestedSource.hasPrefix("http") || asset.isDemo {
            return requestedSource
        }

        guard let coordinator,
              let localPath = asset.localPath else {
            return requestedSource
        }

        let original = URL(fileURLWithPath: localPath)
        let fallbackPreview = asset.preview.isEmpty ? nil : URL(fileURLWithPath: asset.preview)

        let assetId = asset.id
        let thumbnails = coordinator.thumbnails
        let resolvedKind = kind.isPreview
            ? ThumbnailService.previewKind(forCachePath: requestedSource, fallbackMaxPixel: previewMaxPixel)
            : kind
        if let settings = developSettings[assetId], !settings.isNeutral {
            let edited = thumbnails.editedCachePath(assetId: assetId, kind: resolvedKind, settings: settings).path
            if isVerified(Self.cacheCheckKey(edited, asset), for: assetId) { return edited }
            // Rotation and crop alone start from the ordinary cached image, not a full RAW render.
            let base = settings.withoutGeometry.isNeutral
                ? await cachedImageSource(for: asset, requestedSource: requestedSource, kind: resolvedKind,
                                          original: original, fallbackPreview: fallbackPreview, thumbnails: thumbnails)
                : nil
            return await editedImageSource(for: asset, settings: settings, kind: resolvedKind,
                                           thumbnails: thumbnails, base: base) ?? requestedSource
        }
        return await cachedImageSource(for: asset, requestedSource: requestedSource, kind: resolvedKind,
                                       original: original, fallbackPreview: fallbackPreview,
                                       thumbnails: thumbnails) ?? requestedSource
    }

    /// What `visibleImageSource` returns, when that is already known without touching the disk
    /// (the cache file was verified earlier this session); nil when it would have to check or
    /// render. Lets the loupe show a prefetched neighbor in the same frame as the arrow key.
    func verifiedImageSource(for asset: Asset, requestedSource: String, kind: ThumbnailService.Kind) -> String? {
        if requestedSource.hasPrefix("http") || asset.isDemo { return requestedSource }
        guard let coordinator, asset.localPath != nil else { return requestedSource }
        let resolvedKind = kind.isPreview
            ? ThumbnailService.previewKind(forCachePath: requestedSource, fallbackMaxPixel: previewMaxPixel)
            : kind
        if let settings = developSettings[asset.id], !settings.isNeutral {
            let edited = coordinator.thumbnails.editedCachePath(assetId: asset.id, kind: resolvedKind, settings: settings).path
            return isVerified(Self.cacheCheckKey(edited, asset), for: asset.id) ? edited : nil
        }
        if isVerified(Self.cacheCheckKey(requestedSource, asset), for: asset.id) { return requestedSource }
        let own = coordinator.thumbnails.cachePath(assetId: asset.id, kind: resolvedKind).path
        return isVerified(Self.cacheCheckKey(own, asset), for: asset.id) ? own : nil
    }

    /// A checked cache file, as of the original's modification date: one the original has
    /// changed since is checked again.
    private static func cacheCheckKey(_ source: String, _ asset: Asset) -> String {
        "\(source)|\(asset.fileModifiedAt?.timeIntervalSince1970 ?? 0)"
    }

    /// The ordinary (unadjusted) cached image, repaired from the original when missing or damaged.
    private func cachedImageSource(for asset: Asset, requestedSource: String, kind resolvedKind: ThumbnailService.Kind,
                                   original: URL, fallbackPreview: URL?,
                                   thumbnails: ThumbnailService) async -> String? {
        let assetId = asset.id
        let localPath = original.path
        // A cache file already checked this session (exists, fresh, not a black RAW render)
        // skips the stat + decode hops every time its cell scrolls back into view.
        if isVerified(Self.cacheCheckKey(requestedSource, asset), for: assetId) { return requestedSource }
        // The photo's own cache file, where a repair writes. The stored path can be another: a
        // virtual copy's is its master's, and a catalog moved since keeps the old place. With that
        // gone, the photo's own file is the one to look for, or a remade one would show once
        // and then the placeholder.
        let own = thumbnails.cachePath(assetId: assetId, kind: resolvedKind).path
        if own != requestedSource, isVerified(Self.cacheCheckKey(own, asset), for: assetId) { return own }
        let candidates = own == requestedSource ? [own] : [requestedSource, own]
        let usable = await Task.detached(priority: .userInitiated) { () -> String? in
            candidates.first { source in
                guard !source.isEmpty, FileManager.default.fileExists(atPath: source) else { return false }
                let cached = URL(fileURLWithPath: source)
                return !ThumbnailService.cacheIsStale(cache: cached, originalModificationDate: asset.fileModifiedAt)
                    && !thumbnails.cachedRepresentationNeedsRegeneration(at: cached, original: original, kind: resolvedKind)
            }
        }.value
        if let usable {
            markVerified(Self.cacheCheckKey(usable, asset), for: assetId)
            return usable
        }
        // Only touch a referenced original after the local cache is missing, stale, or damaged.
        let (originalExists, previewExists) = await Task.detached(priority: .userInitiated) {
            [localPath, preview = asset.preview] in
            let fm = FileManager.default
            return (fm.fileExists(atPath: localPath),
                    !preview.isEmpty && fm.fileExists(atPath: preview))
        }.value
        guard originalExists || previewExists else {
            return nil
        }
        // A repair that failed isn't tried again this session: a RAW that decodes black again
        // must not cost another multi-second decode every time its cell reappears. One that
        // worked is remembered as a checked file instead, until a prune or a removal from the
        // catalog drops that (it may have deleted the file), and then the file is made again.
        let repairKey = "\(assetId)|\(resolvedKind)"
        if repairsInFlight[repairKey] != nil {
            await withCheckedContinuation { repairsInFlight[repairKey, default: []].append($0) }
            // that repair is done (or was cancelled before it started): look again
            return await cachedImageSource(for: asset, requestedSource: requestedSource, kind: resolvedKind,
                                           original: original, fallbackPreview: fallbackPreview, thumbnails: thumbnails)
        }
        guard !failedCacheRepairs.contains(repairKey) else { return nil }
        repairsInFlight[repairKey] = []
        defer { repairsInFlight.removeValue(forKey: repairKey)?.forEach { $0.resume() } }
        guard let restored = await ThumbnailRepairQueue.run(.visible, { () -> (url: URL?, usable: Bool) in
            let made = thumbnails.ensureCached(from: original,
                                               fallbackPreview: fallbackPreview,
                                               catalogModificationDate: asset.fileModifiedAt,
                                               assetId: assetId,
                                               kind: resolvedKind)
            return (made, made.map {
                !thumbnails.cachedRepresentationNeedsRegeneration(at: $0, original: original, kind: resolvedKind)
            } ?? false)
        }) else {
            return nil   // cancelled while queued; retry when shown again
        }
        // a remade file is as good as a checked one: the loupe can then show a prefetched
        // neighbor in the same frame as the arrow key instead of checking the disk first
        if restored.usable, let path = restored.url?.path {
            markVerified(Self.cacheCheckKey(path, asset), for: assetId)
        } else {
            failedCacheRepairs.insert(repairKey)
        }
        return restored.url?.path
    }

    /// Developed rendering for an adjusted photo, rendered off the cooperative pool when missing.
    /// `base` (an already-rendered image) replaces the original; an unavailable original falls
    /// back to adjusting the cached preview.
    private func editedImageSource(for asset: Asset, settings: DevelopSettings, kind: ThumbnailService.Kind,
                                   thumbnails: ThumbnailService, base: String? = nil) async -> String? {
        let edited = thumbnails.editedCachePath(assetId: asset.id, kind: kind, settings: settings)
        let key = edited.path
        if isVerified(Self.cacheCheckKey(key, asset), for: asset.id) { return key }
        let preview = asset.preview
        let source: (url: URL, isRaw: Bool)?
        if let base {
            source = (URL(fileURLWithPath: base), false)
        } else if asset.status == .ready, let path = asset.localPath {
            source = (URL(fileURLWithPath: path), asset.isRaw)
        } else if !preview.isEmpty, !preview.hasPrefix("http") {
            source = (URL(fileURLWithPath: preview), false)
        } else {
            source = nil
        }
        guard let source else { return nil }
        let assetId = asset.id
        guard let rendered = await ThumbnailRepairQueue.run(.visible, {
            thumbnails.ensureEdited(from: source.url, isRaw: source.isRaw, settings: settings,
                                    assetId: assetId, kind: kind, originalModificationDate: asset.fileModifiedAt)
        }), let rendered else { return nil }
        markVerified(Self.cacheCheckKey(rendered.path, asset), for: assetId)
        return rendered.path
    }

    func pruneCacheToLimit() {
        guard let store else { push("无目录库", "warning"); return }
        let packageURL = store.packageURL
        let snapshot = assets
        let limit = cacheLimit
        Task { [weak self, store, packageURL, snapshot, limit] in
            let result = await Task.detached(priority: .utility) {
                let report = CacheService.prune(store.cacheURL) { limit.bytes(cacheBytes: $0) }
                return (report, CatalogHealth.check(store, assets: snapshot))
            }.value
            guard let self, self.store?.packageURL == packageURL else { return }
            if result.0.removedFiles > 0 { self.verifiedCacheSources.removeAll() }
            self.applyHealthReport(result.1)
            if result.0.removedFiles == 0 {
                let limitMB = Int(result.0.maxBytes / 1_048_576)
                self.push("缓存已在 \(limitMB) MB 上限内", "check")
            } else {
                self.push("已清理缓存 \(self.formatCacheMB(result.0.removedBytes)) · \(result.0.removedFiles) 个文件", "trash")
            }
        }
    }

    /// Prunes the cache to its limit. A background pass that just ended passes the automatic limit
    /// it started with: worked out again, the limit could come out lower than the one the pass
    /// filled the cache to, and the prune would take back what it made.
    func enforceCacheLimitIfNeeded(automaticLimitBytes: Int64? = nil) {
        guard let store else { return }
        let packageURL = store.packageURL
        let snapshot = assets
        let limit = cacheLimit
        let passLimit = limit.chosenMB > 0 ? nil : automaticLimitBytes
        Task { [weak self, store, packageURL, snapshot, limit, passLimit] in
            let result = await Task.detached(priority: .utility) {
                let report = CacheService.prune(store.cacheURL) { passLimit ?? limit.bytes(cacheBytes: $0) }
                let health = report.removedFiles > 0 ? CatalogHealth.check(store, assets: snapshot) : nil
                let cacheBytes = health?.cacheBytes ?? CatalogHealth.directorySize(store.cacheURL)
                return (health, cacheBytes)
            }.value
            guard let self, self.store?.packageURL == packageURL else { return }
            if let report = result.0 {
                self.verifiedCacheSources.removeAll()   // pruning removed cache files
                self.applyHealthReport(report)
            } else {
                self.statusMetrics.cacheBytes = result.1
            }
        }
    }

    private func formatCacheMB(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    /// Best-effort removal of an asset's cached thumbnails/previews when it leaves the catalog,
    /// so deleting photos reclaims their cache instead of leaving orphans behind. A photo brought
    /// back (undo) has its files made again when shown: the checked files dropped here are
    /// looked for on disk then.
    func purgeCacheFiles<S: Sequence>(forAssetIds ids: S) where S.Element == String {
        guard let thumbnails = coordinator?.thumbnails else { return }
        let ids = Array(ids)
        for id in ids { verifiedCacheSources[id] = nil }
        // Their thumbnails and previews go off the main thread: four files a photo, each path a
        // hash of its id, took Move to Trash of 1,000 photos a quarter of a second. A photo back in
        // the catalog before they're gone keeps them (`applyAssetEdits` takes it off the list).
        let purges = cachePurges
        purges.add(ids)
        Self.cachePurgeQueue.async {
            let fm = FileManager.default
            let kinds: [ThumbnailService.Kind] = [.thumb256, .thumb512, .preview1600, .preview2048]
            for id in ids where purges.take(id) {
                for kind in kinds { try? fm.removeItem(at: thumbnails.cachePath(assetId: id, kind: kind)) }
            }
        }
    }

    /// The photos whose cache files wait to be deleted, shared with the queue deleting them.
    final class CachePurges: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: Set<String> = []
        func add(_ ids: [String]) { lock.withLock { waiting.formUnion(ids) } }
        func cancel(_ ids: [String]) { lock.withLock { waiting.subtract(ids) } }
        /// Whether `id`'s files are still to go; they're no longer waiting after this.
        func take(_ id: String) -> Bool { lock.withLock { waiting.remove(id) != nil } }
    }
    private static let cachePurgeQueue = DispatchQueue(label: "PhotoCatalog.cachePurge", qos: .utility)

    /// For checks: runs `body` with cache files held back from deletion, then lets them go.
    func holdingCachePurges(_ body: () -> Void) {
        Self.cachePurgeQueue.suspend()
        defer { Self.cachePurgeQueue.resume() }
        body()
    }

    /// For checks: waits until the cache files of photos removed so far are deleted.
    func waitForCachePurges() { Self.cachePurgeQueue.sync {} }

    // ---------- backup (§6.12) ----------
    func runBackup() {
        guard !importing else { push("导入中无法备份目录库", "warning"); return }
        guard let store else { push("无目录库可备份", "warning"); return }
        backUpCatalog(store, title: L("目录库快照（不含原件）")) { app, url, error in
            if let url {
                app.push("已备份目录库 · \(url.lastPathComponent)", "check")
            } else {
                app.push("备份失败：\(error ?? L("未知错误"))", "warning")
            }
        }
    }

    func runAutomaticBackupIfNeeded(now: Date = .now) {
        guard !importing, let store else { return }
        let interval: TimeInterval
        switch automaticBackupFrequency {
        case "daily":
            interval = 24 * 60 * 60
        case "weekly":
            interval = 7 * 24 * 60 * 60
        default:
            return
        }

        let backupKey = Self.lastAutoBackupKey(for: store.packageURL)
        let last = UserDefaults.app.object(forKey: backupKey) as? Date
        if let last, now.timeIntervalSince(last) < interval {
            return
        }

        backUpCatalog(store, title: L("自动目录库快照（不含原件）"), at: now,
                      saved: { _ in UserDefaults.app.set(now, forKey: backupKey) }) { app, url, error in
            if let url {
                app.push("已自动备份目录库 · \(url.lastPathComponent)", "check")
            } else {
                app.push("自动备份失败：\(error ?? L("未知错误"))", "warning")
            }
        }
    }

    /// Snapshots `store` off the main thread as a background task titled `title`, named for
    /// `date` (when it's taken, if nil). `saved` runs on success; `finished` runs only while the
    /// same catalog is still open, after the status bar's metrics are refreshed on success.
    private func backUpCatalog(_ store: CatalogStore, title: String, at date: Date? = nil,
                               saved: @escaping (URL) -> Void = { _ in },
                               finished: @escaping (AppState, _ url: URL?, _ error: String?) -> Void) {
        let packageURL = store.packageURL
        let originHistory = taskHistory
        let initial = BackgroundTask(kind: .backup, title: title, state: .running,
                                     totalCount: 1, destination: store.backupsURL)
        if let originHistory { recordBackgroundTask(initial, originHistory: originHistory) }
        Task { [weak self, store, packageURL, originHistory, initial, date] in
            let result = await Task.detached(priority: .utility) { () -> (url: URL?, error: String?) in
                do {
                    return (try date.map { try BackupService.backup(store, at: $0) } ?? BackupService.backup(store), nil)
                } catch {
                    return (nil, error.localizedDescription)
                }
            }.value
            guard let self else { return }
            var task = initial
            task.state = result.url == nil ? .failed : .completed
            task.completedCount = 1
            task.succeededCount = result.url == nil ? 0 : 1
            task.destination = result.url ?? initial.destination
            task.errorMessage = result.error
            if let error = result.error {
                task.failures = [.init(item: packageURL.lastPathComponent, message: error, path: packageURL.path)]
            }
            if let originHistory { self.recordBackgroundTask(task, originHistory: originHistory) }
            if let url = result.url { saved(url) }
            guard self.store === store else { return }
            if result.url != nil { self.refreshStatusMetrics() }
            finished(self, result.url, result.error)
        }
    }

    private static func lastAutoBackupKey(for packageURL: URL) -> String {
        lastAutoBackupKey + "." + packageURL.standardizedFileURL.path
    }

    func restoreBackup() {
        // never replace the catalog file while an import task still holds the live connection
        guard !importing else { push("导入中无法恢复备份", "warning"); return }
        guard let backupsURL = store?.backupsURL else {
            push("无目录库可恢复", "warning")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = backupsURL
        panel.prompt = L("恢复")
        panel.message = L("选择一个目录库 SQLite 备份文件")
        if let sqliteType = UTType(filenameExtension: "sqlite") {
            panel.allowedContentTypes = [sqliteType]
        }
        guard panel.runModal() == .OK, let backup = panel.url else { return }

        guard confirmDestructiveAction(L("恢复目录库备份？"),
                                       L("当前目录库数据库会被所选备份替换。应用会先尝试创建一次当前状态备份。"),
                                       L("恢复")) else { return }
        restoreBackup(from: backup)
    }

    /// Puts `backup` in place of the open catalog's database, once chosen and confirmed.
    func restoreBackup(from backup: URL) {
        guard !importing else { push("导入中无法恢复备份", "warning"); return }
        guard let packageURL = store?.packageURL else {
            push("无目录库可恢复", "warning")
            return
        }
        do {
            // scoped, so the live connection closes with the catalog below
            var current: URL?
            if let store {
                try store.upsert(assets.filter { !$0.isDemo })
                current = try BackupService.backup(store)
            }
            closeCurrentCatalog()
            resetCatalog(toDemo: true)
            try BackupService.restore(backup, intoPackageAt: packageURL)
            let error = loadExistingCatalog()
            guard store == nil else {
                push("已恢复备份 · \(backup.lastPathComponent)", "check")
                return
            }
            // in place, but it won't open (a newer version's, say): the catalog goes back to how
            // it was, from the backup just made
            if let current { try? BackupService.restore(current, intoPackageAt: packageURL) }
            resetCatalog(toDemo: true)
            loadExistingCatalog()
            push(verbatim: catalogOpenFailureMessage(error, fallback: L("恢复备份失败")), "warning")
        } catch {
            resetCatalog(toDemo: true)
            loadExistingCatalog()
            push(verbatim: catalogOpenFailureMessage(error, fallback: L("恢复备份失败")), "warning")
        }
    }

    func closeCurrentCatalog() {
        // a session imports into the catalog it started in; ended first, so the folder it hands
        // to the watcher goes with the rest below
        endTether()
        invalidateDescriptionReview()
        captureStatisticsTask?.cancel()
        captureStatisticsTask = nil
        captureStatisticsGeneration &+= 1
        captureStatisticsCache = nil
        catalogLoadTask?.cancel()
        catalogLoadTask = nil
        catalogLoadGeneration &+= 1
        deferredCatalogArguments = nil
        isLoadingCatalog = false
        hasCatalogPreview = false
        loadingCatalogTotalCount = nil
        loadingCatalogURL = nil
        cancelBackfill()
        availabilityScanTask?.cancel()
        availabilityScanTask = nil
        availabilityScanGeneration &+= 1
        isCheckingOriginals = false
        incrementalRescanGeneration &+= 1
        isIncrementalRescanning = false
        needsIncrementalRescan = false
        watcher?.stop()
        watcher = nil
        for url in securityScopedRoots {
            url.stopAccessingSecurityScopedResource()
        }
        securityScopedRoots = []
        watchedRoots = []
        sourceRootPathsById = [:]
        sourceManagementModesById = [:]
        importControl = nil
        activeImportJobId = nil
        pendingImportFiles = []
        importOptions = nil
        importCheckpoints = [:]
        importing = false
        store = nil
        coordinator = nil
        statusMetrics = StatusMetrics()
    }

    /// The demo catalog, or an empty one, its first photo (if any) selected.
    func resetCatalog(toDemo demo: Bool) {
        // the steps put back photos and albums of the catalog being replaced: ⌘Z must not
        // replay them into the next one (text fields' own steps stay)
        undoManager?.removeAllActions(withTarget: self)
        removedSourceIds = []
        trashedOriginalIds = []
        duplicateRecomputeGeneration &+= 1
        let a = demo ? DemoData.assets : []
        assets = a
        albums = demo ? DemoData.initialAlbums(a) : []
        quickCollection = []
        smartAlbums = demo ? DemoData.initialSmartAlbums(a) : []
        albumSets = []
        folders = demo ? DemoData.folders : []
        developSettings = [:]
        clearDevelopRecordCaches()
        clearFaces()
        // sidecar state is the catalog's (a loaded one reads its own)
        xmpSyncTimes = [:]
        xmpSyncRecordedAt = [:]
        externallyChangedXMPIds = []
        pendingXMPWriteIds = []
        sourceRootPathsById = [:]
        sourceManagementModesById = [:]
        duplicateGroupsCache = demo ? DemoData.duplicateGroups : []
        selection = Selection(type: .lib, id: "all", name: L("全部照片"))
        primaryId = list.first?.id
        selectedIds = primaryId.map { Set([$0]) } ?? []
        anchorId = primaryId
        compareIds = []
        winner = nil
        importRun = nil
        healthReport = nil
    }
}
