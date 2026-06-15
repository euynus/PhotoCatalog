// ============================================================
//  AppState — port of App() state, derived collections & mutations
// ============================================================
import SwiftUI
import Combine
import AppKit

@MainActor
final class AppState: ObservableObject {
    // ----- onboarding -----
    @Published var onboarded: Bool = UserDefaults.standard.string(forKey: "pc_onboarded") == "1"
    @Published var welcomeAnim = false

    // ----- core data -----
    @Published var assets: [Asset]
    @Published var albums: [Album]
    @Published var smartAlbums: [SmartAlbum]
    @Published var folders: [Folder] = DemoData.folders
    @Published var importing = false
    @Published var importRun: ImportRun?
    @Published var duplicateGroupsCache: [DuplicateGroup] = DemoData.duplicateGroups

    // ----- settings (PRD §17) -----
    @Published var importMode: ImportMode =
        ImportMode(rawValue: UserDefaults.standard.string(forKey: "pc_importMode") ?? "") ?? .referenced {
        didSet { UserDefaults.standard.set(importMode.rawValue, forKey: "pc_importMode") }
    }
    @Published var exportWritesXMP = UserDefaults.standard.bool(forKey: "pc_exportXMP") {
        didSet { UserDefaults.standard.set(exportWritesXMP, forKey: "pc_exportXMP") }
    }
    @Published var visionEnabled = UserDefaults.standard.bool(forKey: "pc_vision") {
        didSet { UserDefaults.standard.set(visionEnabled, forKey: "pc_vision") }
    }
    @Published var healthReport: HealthReport?

    // ----- catalog (real persistence / scanning) -----
    private var store: CatalogStore?
    private var coordinator: ImportCoordinator?
    private var watcher: FileWatcher?
    private var watchedRoots: [URL] = []
    private var securityScopedRoots: [URL] = []
    private var volumeMonitor: VolumeMonitor?
    private var lastImportSessionPersistedCount = 0
    private var importControl: ImportControl?
    private var activeImportJobId: String?

    // ----- selection / view -----
    @Published var selection = Selection(type: .lib, id: "all", name: "全部照片")
    @Published var selectedIds: Set<String> = []
    @Published var primaryId: String?
    @Published var view: ViewMode = .grid
    @Published var thumbSize: CGFloat = 168
    @Published var showInspector = true
    @Published var showInfo = true
    @Published var insTab = "org"
    private var anchorId: String?

    // ----- filters / sort -----
    @Published var filters = Filters()
    @Published var filterOpen = false
    @Published var search = ""
    @Published var sort = Sort()

    // ----- compare -----
    @Published var compareIds: [String] = []
    @Published var winner: String?

    // ----- sheets / toasts -----
    @Published var sheet: String?
    @Published var toasts: [Toast] = []

    // ----- search focus signal (Cmd+F) -----
    @Published var searchFocusToken = 0
    func focusSearch() { searchFocusToken += 1 }

    init() {
        let a = DemoData.assets
        assets = a
        albums = DemoData.initialAlbums(a)
        smartAlbums = DemoData.initialSmartAlbums(a)
        loadExistingCatalog()
        startVolumeMonitor()
        // seed the initial primary/selection from the first visible photo
        let first = list.first
        primaryId = first?.id
        if let id = first?.id { selectedIds = [id]; anchorId = id }
    }

    deinit {
        for url in securityScopedRoots {
            url.stopAccessingSecurityScopedResource()
        }
    }

    // ---------- catalog open / load ----------
    private func loadExistingCatalog() {
        let url = CatalogStore.defaultURL
        guard FileManager.default.fileExists(atPath: url.path),
              let s = try? CatalogStore(packageURL: url) else { return }
        store = s
        coordinator = ImportCoordinator(store: s)
        let real = ((try? s.loadAssets()) ?? []).filter { !$0.isDemo && !$0.deleted }
        guard !real.isEmpty else {
            restoreSourceRoots(from: s)
            return
        }

        assets = []
        albums = []
        smartAlbums = []
        folders = []
        restoreSourceRoots(from: s)

        // missing-file detection (§6.4 ORG-003)
        let checked = real.map { a -> Asset in
            guard let p = a.localPath, !FileManager.default.fileExists(atPath: p) else { return a }
            var m = a; m.status = .missing; return m
        }
        assets = checked
        for (fid, items) in Dictionary(grouping: checked, by: { $0.folderId }) where
            !folders.contains(where: { $0.id == fid }) {
            folders.append(Folder(id: fid, name: items.first?.folderName ?? fid))
        }
        recomputeDuplicates()
    }

    private func restoreSourceRoots(from store: CatalogStore) {
        guard let roots = try? store.loadSourceRoots() else { return }
        for root in roots {
            let resolved = resolveSourceRoot(root)
            try? store.updateSourceRootStatus(id: root.id, status: resolved.status)

            if !folders.contains(where: { $0.id == root.id }) {
                folders.append(Folder(id: root.id, name: root.displayName))
            }
            if root.managementMode == "referenced",
               resolved.status == "online",
               let url = resolved.url,
               !watchedRoots.contains(url) {
                watchedRoots.append(url)
            }
        }
        refreshWatcher()
    }

    private func resolveSourceRoot(_ root: SourceRootRecord) -> (url: URL?, status: String) {
        if let bookmark = root.bookmarkData {
            guard let resolved = FileAccessService.resolveBookmark(bookmark) else {
                return fallbackSourceRoot(root, preferredStatus: "permissionLost")
            }
            guard !resolved.isStale else {
                return (resolved.url, "permissionLost")
            }
            let ok = resolved.url.startAccessingSecurityScopedResource()
            if ok { securityScopedRoots.append(resolved.url) }
            guard FileManager.default.fileExists(atPath: resolved.url.path) else {
                return (resolved.url, VolumeMonitor.status(forInaccessible: resolved.url.path).rawValue)
            }
            return (resolved.url, "online")
        }
        return fallbackSourceRoot(root, preferredStatus: nil)
    }

    private func fallbackSourceRoot(_ root: SourceRootRecord, preferredStatus: String?) -> (url: URL?, status: String) {
        let url = URL(fileURLWithPath: root.pathHint)
        if FileManager.default.fileExists(atPath: url.path) {
            return (url, preferredStatus ?? "online")
        }
        return (nil, preferredStatus ?? VolumeMonitor.status(forInaccessible: root.pathHint).rawValue)
    }

    private func openOrCreateCatalog() {
        guard store == nil else { return }
        guard let s = try? CatalogStore(packageURL: CatalogStore.defaultURL) else {
            push("无法创建目录库", "warning"); return
        }
        store = s
        coordinator = ImportCoordinator(store: s)
    }

    // ---------- real folder import (§6.3) ----------
    func addFolder() {
        guard !importing else {
            sheet = "import"
            push("已有导入任务正在运行", "warning")
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "导入"
        let mode = importMode
        panel.message = mode == .managed ? "选择文件夹（托管式：复制原件到目录库）"
                                         : "选择文件夹（引用式：原件保持不动）"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        openOrCreateCatalog()
        guard let coordinator, let store else { return }
        let existingIds = Set(assets.map { $0.id })
        let run = ImportRun(source: folder, mode: mode)
        let control = ImportControl()
        let jobId = "job-" + run.id.uuidString
        importRun = run
        importControl = control
        activeImportJobId = jobId
        lastImportSessionPersistedCount = 0
        let vision = visionEnabled
        importing = true
        sheet = "import"
        try? store.startImportSession(id: run.id.uuidString, startedAt: run.startedAt)
        try? store.startImportJob(id: jobId, sessionId: run.id.uuidString, sourcePath: folder.path,
                                  mode: mode, autoTag: vision)
        push("正在导入「\(folder.lastPathComponent)」…", "importIcon")
        let bookmark = FileAccessService.createBookmark(for: folder)
        Task { [weak self, coordinator, store, folder, mode, vision, bookmark, existingIds, run, control] in
            let imported = await Task.detached(priority: .userInitiated) { [coordinator, folder, mode, vision, control] in
                coordinator.importFolder(folder, mode: mode, autoTag: vision, control: control) { progress in
                    Task { @MainActor [weak self] in
                        self?.recordImportProgress(progress, for: run.id)
                    }
                }
            }.value
            guard let self else { return }
            self.finishImport(folder: folder, imported: imported, existingIds: existingIds,
                              store: store, bookmark: bookmark, mode: mode, runId: run.id,
                              persistSourceRoot: true)
        }
    }

    private func recordImportProgress(_ progress: ImportProgress, for runId: UUID) {
        guard var run = importRun, run.id == runId, run.phase.isActive else { return }
        if run.phase != .paused {
            run.phase = .importing
        }
        run.total = progress.total
        run.processed = progress.processed
        run.failed = progress.failed
        if let latest = progress.latestAsset {
            run.recentAssets.removeAll { $0.id == latest.id }
            run.recentAssets.insert(latest, at: 0)
            if run.recentAssets.count > 28 {
                run.recentAssets.removeLast(run.recentAssets.count - 28)
            }
        }
        if let failure = progress.latestFailure, !run.failures.contains(where: { $0.id == failure.id }) {
            run.failures.append(failure)
        }
        importRun = run
        persistImportSessionProgress(run)
    }

    private func finishImport(folder: URL, imported: [Asset], existingIds: Set<String>, store: CatalogStore,
                              bookmark: Data?, mode: ImportMode, runId: UUID, persistSourceRoot: Bool) {
        let fresh = imported.filter { !existingIds.contains($0.id) }
        let skipped = max(0, imported.count - fresh.count)
        assets.append(contentsOf: fresh)
        try? store.upsert(fresh)
        var rootId: String?
        if let fid = fresh.first?.folderId {
            rootId = fid
            if persistSourceRoot {
                try? store.addSourceRoot(id: fid, displayName: folder.lastPathComponent,
                                         path: folder.path, bookmark: bookmark)
            }
            if !folders.contains(where: { $0.id == fid }) {
                folders.append(Folder(id: fid, name: folder.lastPathComponent))
            }
            select(Selection(type: .folder, id: fid, name: folder.lastPathComponent))
        }
        if mode == .referenced, !watchedRoots.contains(folder) {
            watchedRoots.append(folder)
            refreshWatcher()
        }

        if var run = importRun, run.id == runId {
            run.phase = .complete
            run.total = max(run.total, imported.count + run.failed)
            run.processed = imported.count
            run.skipped = skipped
            run.finishedAt = .now
            let previewAssets = fresh.isEmpty ? imported : fresh
            run.recentAssets = Array(previewAssets.prefix(28))
            run.errorMessage = importFailureSummary(run.failures)
            importRun = run
            lastImportSessionPersistedCount = run.processed + run.failed
            try? store.updateImportSession(id: run.id.uuidString, rootId: rootId, state: "completed",
                                           totalCount: run.total, importedCount: run.imported,
                                           skippedCount: run.skipped, failedCount: run.failed,
                                           finishedAt: run.finishedAt, errorMessage: run.errorMessage)
        }

        importing = false
        importControl = nil
        if let activeImportJobId {
            try? store.updateJob(id: activeImportJobId, state: "succeeded", lockedAt: nil,
                                 lastError: importRun?.errorMessage)
            self.activeImportJobId = nil
        }
        recomputeDuplicates()
        let failedCount = importRun?.failed ?? 0
        let message: String
        let icon: String
        if fresh.isEmpty, skipped > 0 {
            message = "已跳过 \(skipped) 张重复照片" + (failedCount > 0 ? " · \(failedCount) 失败" : "")
            icon = "warning"
        } else if fresh.isEmpty {
            message = failedCount > 0 ? "导入失败 \(failedCount) 个文件" : "未发现可导入的照片"
            icon = "warning"
        } else {
            message = "已导入 \(fresh.count) 张照片" + (failedCount > 0 ? " · \(failedCount) 失败" : "")
            icon = failedCount > 0 ? "warning" : "check"
        }
        push(message, icon)
    }

    func toggleImportPaused() {
        guard var run = importRun, run.phase.isActive, let importControl else { return }
        if run.phase == .paused {
            importControl.resume()
            run.phase = .importing
            importRun = run
            persistImportSessionState(run, state: "running")
            persistImportJobState("running")
            push("导入已继续", "play")
        } else {
            importControl.pause()
            run.phase = .paused
            importRun = run
            persistImportSessionState(run, state: "paused")
            persistImportJobState("paused")
            push("导入已暂停", "pause")
        }
    }

    func retryFailedImport() {
        guard let run = importRun, run.phase.isFinished, !run.failures.isEmpty else { return }
        guard let coordinator, let store else {
            push("无可用目录库", "warning")
            return
        }
        let folder = URL(fileURLWithPath: run.sourcePath)
        guard FileManager.default.fileExists(atPath: folder.path) else {
            push("源文件夹不可访问", "warning")
            return
        }
        let files = run.failures.map { URL(fileURLWithPath: $0.path) }
        let retry = ImportRun(source: folder, mode: run.mode)
        let control = ImportControl()
        let jobId = "job-" + retry.id.uuidString
        let existingIds = Set(assets.map { $0.id })
        importRun = retry
        importControl = control
        activeImportJobId = jobId
        lastImportSessionPersistedCount = 0
        let vision = visionEnabled
        importing = true
        try? store.startImportSession(id: retry.id.uuidString, startedAt: retry.startedAt)
        try? store.startImportJob(id: jobId, sessionId: retry.id.uuidString, sourcePath: folder.path,
                                  mode: retry.mode, autoTag: vision)
        push("正在重试 \(files.count) 个失败文件…", "refresh")
        Task { [weak self, coordinator, store, folder, files, existingIds, retry, vision, control] in
            let imported = await Task.detached(priority: .userInitiated) { [coordinator, folder, files, retry, vision, control] in
                coordinator.importFiles(files, from: folder, mode: retry.mode, autoTag: vision,
                                        control: control) { progress in
                    Task { @MainActor [weak self] in
                        self?.recordImportProgress(progress, for: retry.id)
                    }
                }
            }.value
            guard let self else { return }
            self.finishImport(folder: folder, imported: imported, existingIds: existingIds,
                              store: store, bookmark: nil, mode: retry.mode, runId: retry.id,
                              persistSourceRoot: false)
        }
    }

    private func importFailureSummary(_ failures: [ImportFailure]) -> String? {
        guard !failures.isEmpty else { return nil }
        return failures.map { "\($0.filename): \($0.reason)" }.joined(separator: "\n")
    }

    private func persistImportSessionProgress(_ run: ImportRun) {
        guard let store else { return }
        let completedCount = run.processed + run.failed
        let stride = max(1, run.total / 100)
        guard completedCount == 0 || completedCount == run.total ||
                completedCount - lastImportSessionPersistedCount >= stride else { return }
        lastImportSessionPersistedCount = completedCount
        try? store.updateImportSession(id: run.id.uuidString,
                                       state: run.phase == .paused ? "paused" : "running",
                                       totalCount: run.total, importedCount: run.imported,
                                       skippedCount: run.skipped, failedCount: run.failed)
    }

    private func persistImportSessionState(_ run: ImportRun, state: String) {
        guard let store else { return }
        try? store.updateImportSession(id: run.id.uuidString, state: state,
                                       totalCount: run.total, importedCount: run.imported,
                                       skippedCount: run.skipped, failedCount: run.failed)
    }

    private func persistImportJobState(_ state: String) {
        guard let store, let activeImportJobId else { return }
        try? store.updateJob(id: activeImportJobId, state: state)
    }

    // ---------- FSEvents incremental watch (§12.8) ----------
    private func refreshWatcher() {
        watcher?.stop()
        let paths = watchedRoots.map { $0.path }
        guard !paths.isEmpty else { watcher = nil; return }
        let w = FileWatcher(paths: paths) { [weak self] _ in self?.incrementalRescan() }
        w.start()
        watcher = w
    }

    private func incrementalRescan() {
        guard let coordinator, let store else { return }
        let roots = watchedRoots
        let knownPaths = Set(assets.compactMap { $0.localPath })
        let vision = visionEnabled
        Task { [weak self, coordinator, store, roots, knownPaths, vision] in
            let fresh = await Task.detached(priority: .utility) {
                var fresh: [Asset] = []
                for root in roots {
                    fresh.append(contentsOf: coordinator.scanNew(in: root, knownPaths: knownPaths,
                                                                 mode: .referenced, autoTag: vision))
                }
                return fresh
            }.value
            guard let self else { return }
            let trulyNew = fresh.filter { a in !self.assets.contains { $0.id == a.id } }
            if !trulyNew.isEmpty {
                self.assets.append(contentsOf: trulyNew)
                try? store.upsert(trulyNew)
                self.recomputeDuplicates()
                self.push("检测到 \(trulyNew.count) 张新照片", "importIcon")
            }
            self.detectMissingRealAssets()
        }
    }

    func detectMissingRealAssets() {
        var changed = false
        for i in assets.indices where !assets[i].isDemo {
            guard let p = assets[i].localPath else { continue }
            let target: AssetStatus = FileManager.default.fileExists(atPath: p)
                ? .ready : VolumeMonitor.status(forInaccessible: p)   // offline vs missing (§6.4)
            if assets[i].status != target { assets[i].status = target; changed = true }
        }
        if changed, let store { try? store.upsert(assets.filter { !$0.isDemo }) }
    }

    private func startVolumeMonitor() {
        let m = VolumeMonitor { [weak self] in self?.detectMissingRealAssets() }
        m.start()
        volumeMonitor = m
    }

    // ---------- batch capture-time shift (§4.2 / META-008) ----------
    func shiftCaptureTime(hours: Int) {
        guard hours != 0 else { return }
        let ids = targetIds
        guard !ids.isEmpty else { return }
        mutate(ids) {
            $0.date = $0.date.addingTimeInterval(Double(hours) * 3600)
            $0.captureDateSource = "手动调整"
        }
        push("已调整 \(ids.count) 张拍摄时间 \(hours > 0 ? "+" : "")\(hours) 小时", "clock")
    }

    // ---------- XMP sidecar write (§6.5 META-007) ----------
    func writeXMPForSelection() {
        let real = assets.filter { targetIds.contains($0.id) && !$0.isDemo && $0.localPath != nil }
        guard !real.isEmpty else { push("仅可为已导入照片写入 XMP", "warning"); return }
        var count = 0
        for a in real {
            let url = XMPSidecar.sidecarURL(for: URL(fileURLWithPath: a.localPath!))
            if XMPSidecar.write(a, to: url) { count += 1 }
        }
        push("已写入 \(count) 个 XMP sidecar", "check")
    }

    // ---------- batch rename (§4.2) ----------
    func batchRename(prefix: String) {
        let trimmed = prefix.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let real = list.filter { selectedIds.contains($0.id) && !$0.isDemo && $0.localPath != nil }
        guard !real.isEmpty else { push("仅可重命名已导入照片", "warning"); return }
        let map = RenameService.rename(real, prefix: trimmed)
        for (id, url) in map {
            mutateAsset(id) { $0.filename = url.lastPathComponent; $0.localPath = url.path }
        }
        push("已重命名 \(map.count) 张照片", "check")
    }

    // ---------- catalog health / cache (§6.1, §17.3) ----------
    func runHealthCheck() {
        openOrCreateCatalog()
        guard let store else { push("无目录库", "warning"); return }
        let report = CatalogHealth.check(store, assets: assets)
        healthReport = report
        push(report.summary, report.dbIntegrityOK ? "check" : "warning")
    }

    func rebuildThumbnails() {
        guard let coordinator else { push("无已导入照片", "warning"); return }
        let real = assets.filter { !$0.isDemo && $0.localPath != nil }
        guard !real.isEmpty else { push("无已导入照片", "warning"); return }
        push("正在重建缩略图…", "refresh")
        Task { [weak self, coordinator, real] in
            await Task.detached(priority: .utility) {
                for a in real {
                    if let path = a.localPath {
                        _ = coordinator.thumbnails.generateAll(from: URL(fileURLWithPath: path), assetId: a.id)
                    }
                }
            }.value
            self?.push("缩略图已重建", "check")
        }
    }

    func clearCache() {
        guard let store else { push("无目录库", "warning"); return }
        let fm = FileManager.default
        try? fm.removeItem(at: store.cacheURL)
        for dir in [store.thumb256URL, store.thumb512URL, store.preview2048URL] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        push("已清理缩略图缓存", "trash")
    }

    // ---------- export originals (§6.11) ----------
    func exportSelection() {
        let ids = targetIds
        let selected = assets.filter { ids.contains($0.id) && !$0.deleted }
        let real = selected.filter { !$0.isDemo && $0.localPath != nil }
        guard !real.isEmpty else {
            push("正在导出 \(max(selected.count, 1)) 张原件…（演示照片无本地原件）", "export")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "导出到此处"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let xmp = exportWritesXMP
        Task { [weak self, real, dest, xmp] in
            let report = await Task.detached(priority: .userInitiated) {
                ExportService.copyOriginals(real, to: dest, xmp: xmp)
            }.value
            self?.push("已导出 \(report.copied) 张原件" + (report.failed > 0 ? " · \(report.failed) 失败" : "")
                       + (xmp ? " · 含 XMP" : ""), "export")
        }
    }

    // ---------- backup (§6.12) ----------
    func runBackup() {
        openOrCreateCatalog()
        guard let store else { push("无目录库可备份", "warning"); return }
        try? store.upsert(assets.filter { !$0.isDemo })
        if let url = try? BackupService.backup(store) {
            push("已备份目录库 · \(url.lastPathComponent)", "check")
        } else {
            push("备份失败", "warning")
        }
    }

    // ---------- duplicate groups (§6.10): exact (content) + similar (perceptual) ----------
    var duplicateGroups: [DuplicateGroup] { duplicateGroupsCache }

    /// Recompute duplicates off the main thread (dHash reads thumbnails from disk).
    func recomputeDuplicates() {
        let live = assets.filter { !$0.isDemo && !$0.deleted }
        guard !live.isEmpty else { duplicateGroupsCache = DemoData.duplicateGroups; return }
        Task { [weak self, live] in
            let groups = await Task.detached(priority: .utility) {
                HashService.exactDuplicateGroups(live) + PerceptualHash.similarGroups(live)
            }.value
            self?.duplicateGroupsCache = groups
        }
    }

    @discardableResult
    func resolveDuplicateGroup(_ group: DuplicateGroup, keepId: String?,
                               action: DuplicateResolutionAction) -> Bool {
        guard group.items.contains(where: { !$0.isDemo }) else {
            push("演示重复组不可处理", "warning")
            return false
        }

        var updated = assets
        let report = DuplicateResolutionService.resolve(group, keepId: keepId, in: &updated, action: action)
        guard !report.removedIds.isEmpty else {
            push(report.failedCount > 0 ? "重复文件处理失败" : "没有可处理的重复文件", "warning")
            return false
        }

        assets = updated
        persist(report.removedIds)
        duplicateGroupsCache.removeAll { $0.id == group.id }
        recomputeDuplicates()
        ensurePrimaryValid()

        let actionText = action == .moveToTrash ? "移到废纸篓" : "从目录库移除"
        let failedText = report.failedCount > 0 ? " · \(report.failedCount) 失败" : ""
        push("已\(actionText) \(report.affectedCount) 张重复照片\(failedText)", "check")
        return report.failedCount == 0
    }

    private func persist(_ ids: Set<String>) {
        guard let store else { return }
        let changed = assets.filter { ids.contains($0.id) && !$0.isDemo }
        if !changed.isEmpty { try? store.upsert(changed) }
    }

    // ---------- toasts ----------
    func push(_ message: String, _ icon: String = "check") {
        let toast = Toast(message: message, icon: icon)
        toasts.append(toast)
        Task { [weak self, toast] in
            try? await Task.sleep(for: .seconds(2.2))
            self?.toasts.removeAll { $0.id == toast.id }
        }
    }

    // ---------- keyword sidebar list ----------
    var keywordList: [KeywordCount] {
        // Preserve first-encounter order (like a JS Map) so ties sort stably,
        // matching the prototype's keyword sidebar order.
        var order: [String] = []
        var counts: [String: Int] = [:]
        for a in assets where !a.deleted {
            for k in a.keywords {
                if counts[k] == nil { order.append(k) }
                counts[k, default: 0] += 1
            }
        }
        return order.map { KeywordCount(name: $0, count: counts[$0] ?? 0) }
            .sorted { $0.count > $1.count }   // Swift 5 sort is stable
            .prefix(8)
            .map { $0 }
    }

    // ---------- base collection from sidebar ----------
    var baseList: [Asset] {
        let live = assets.filter { !$0.deleted }
        switch selection.type {
        case .folder:
            return live.filter { $0.folderId == selection.id }
        case .album:
            guard let al = albums.first(where: { $0.id == selection.id }) else { return [] }
            return live.filter { al.assetIds.contains($0.id) }
        case .smart:
            guard let sa = smartAlbums.first(where: { $0.id == selection.id }) else { return [] }
            return SmartMatcher.match(live, sa.rule)
        case .keyword:
            return live.filter { $0.keywords.contains(selection.id) }
        case .lib:
            switch selection.id {
            case "recent":
                let cutoff = Date().addingTimeInterval(-60 * 60 * 24 * 14)
                return live.filter { $0.importedAt > cutoff }
            case "unrated":
                return live.filter { $0.rating == 0 && $0.flag != .reject }
            case "picks":
                return live.filter { $0.flag == .pick }
            case "rejected":
                return live.filter { $0.flag == .reject }
            case "missing":
                return live.filter { $0.status == .missing || $0.status == .offline }
            case "places":
                return live.filter { !($0.gps.0 == 0 && $0.gps.1 == 0) }
            case "people":
                return live.filter { $0.faces > 0 }
            default:
                return live
            }
        }
    }

    // ---------- apply filter bar + search + sort ----------
    var list: [Asset] {
        var l = baseList.filter { a in
            if filters.minRating > 0 && a.rating < filters.minRating { return false }
            if filters.flag != "any" && a.flag.rawValue != filters.flag { return false }
            if filters.color != "any" && a.colorLabel?.rawValue != filters.color { return false }
            if filters.type != "any" {
                if filters.type == "RAW" && !a.isRaw { return false }
                if filters.type != "RAW" && a.type != filters.type { return false }
            }
            let q = search.trimmingCharacters(in: .whitespaces).lowercased()
            if !q.isEmpty {
                let hay = ([a.filename, a.camera, a.lens, a.title, a.caption, a.location]
                    + a.keywords).joined(separator: " ").lowercased()
                if !hay.contains(q) { return false }
            }
            return true
        }
        let dir = sort.descending ? -1 : 1
        l.sort { a, b in
            switch sort.field {
            case .name:
                let cmp = a.filename.localizedCompare(b.filename)
                return dir < 0 ? cmp == .orderedDescending : cmp == .orderedAscending
            case .capture:
                return compare(a.date.timeIntervalSince1970, b.date.timeIntervalSince1970, dir)
            case .imported:
                return compare(a.importedAt.timeIntervalSince1970, b.importedAt.timeIntervalSince1970, dir)
            case .rating:
                return compare(Double(a.rating), Double(b.rating), dir)
            case .size:
                return compare(a.fileMB, b.fileMB, dir)
            }
        }
        return l
    }

    private func compare(_ a: Double, _ b: Double, _ dir: Int) -> Bool {
        if a == b { return false }
        return dir < 0 ? a > b : a < b
    }

    var primary: Asset? { assets.first { $0.id == primaryId } }
    var isDuplicates: Bool { selection.type == .lib && selection.id == "duplicates" }
    var isPlaces: Bool { selection.type == .lib && selection.id == "places" }
    var isPeople: Bool { selection.type == .lib && selection.id == "people" }

    // ---------- navigation ----------
    func select(_ s: Selection) {
        selection = s
        if view == .compare { view = .grid }
        ensurePrimaryValid()
    }

    func setFilters(_ f: Filters) { filters = f; ensurePrimaryValid() }
    func setSearch(_ s: String) { search = s; ensurePrimaryValid() }
    func setSort(_ s: Sort) { sort = s }

    private func ensurePrimaryValid() {
        let ids = list
        guard !ids.isEmpty else { return }
        if primaryId == nil || !ids.contains(where: { $0.id == primaryId }) {
            primaryId = ids[0].id
            selectedIds = [ids[0].id]
            anchorId = ids[0].id
        }
    }

    // ---------- selection ----------
    func selectCell(_ id: String, shift: Bool, meta: Bool) {
        if shift, let anchor = anchorId {
            let ids = list.map { $0.id }
            if let i1 = ids.firstIndex(of: anchor), let i2 = ids.firstIndex(of: id) {
                let lo = min(i1, i2), hi = max(i1, i2)
                selectedIds = Set(ids[lo...hi])
                primaryId = id
                return
            }
        }
        if meta {
            if selectedIds.contains(id) { selectedIds.remove(id) } else { selectedIds.insert(id) }
            primaryId = id
            anchorId = id
            return
        }
        selectedIds = [id]
        primaryId = id
        anchorId = id
    }

    func openLoupe(_ id: String) {
        primaryId = id
        selectedIds = [id]
        view = .loupe
    }

    func setPrimary(_ id: String) {
        primaryId = id
        selectedIds = [id]
        anchorId = id
    }

    // ---------- mutations ----------
    private var targetIds: Set<String> {
        if !selectedIds.isEmpty { return selectedIds }
        if let p = primaryId { return [p] }
        return []
    }

    /// Apply an in-place edit to the current selection (or an explicit set).
    func mutate(_ ids: Set<String>? = nil, _ transform: (inout Asset) -> Void) {
        let target = ids ?? targetIds
        for i in assets.indices where target.contains(assets[i].id) {
            transform(&assets[i])
        }
        persist(target)
    }

    func mutateAsset(_ id: String, _ transform: (inout Asset) -> Void) {
        guard let i = assets.firstIndex(where: { $0.id == id }) else { return }
        transform(&assets[i])
        persist([id])
    }

    func setRating(_ n: Int) { mutate { $0.rating = n } }
    func setFlag(_ f: Flag) { mutate { $0.flag = f } }
    func setColor(_ c: ColorLabel?) { mutate { $0.colorLabel = c } }
    func setTitle(_ t: String) { mutate { $0.title = t } }
    func setCaption(_ c: String) { mutate { $0.caption = c } }

    func revealInFinder(_ id: String) {
        guard let asset = assets.first(where: { $0.id == id }), let path = asset.localPath else {
            push("演示照片没有本地原件", "warning")
            return
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            push("原件不存在，请先重新定位", "warning")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func locate(_ id: String) {
        guard let asset = assets.first(where: { $0.id == id }) else { return }
        guard !asset.isDemo else {
            push("演示照片没有本地原件", "warning")
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "重新定位"
        panel.message = "选择移动后的原件文件，或选择包含该原件的新文件夹。"
        guard panel.runModal() == .OK, let selected = panel.url else { return }

        guard let replacement = RelocationService.replacement(for: asset, selected: selected) else {
            push("未找到匹配的原件", "warning")
            return
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: replacement.path)
        let size = (attrs?[.size] as? Int64) ?? 0
        mutateAsset(id) {
            $0.localPath = replacement.path
            $0.filename = replacement.lastPathComponent
            $0.fileMB = Double(size) / (1024 * 1024)
            $0.quickHash = HashService.quickHash(replacement, fileSize: size)
            $0.contentHash = HashService.contentHash(replacement)
            $0.status = .ready
        }
        recomputeDuplicates()
        push("已重新定位原件", "link")
    }

    func addKeyword(_ kw: String) {
        mutate { if !$0.keywords.contains(kw) { $0.keywords.append(kw) } }
    }
    func removeKeyword(_ kw: String) {
        mutate { $0.keywords.removeAll { $0 == kw } }
    }

    func removeSelected() {
        let ids = targetIds
        guard !ids.isEmpty else { return }
        mutate(ids) { $0.deleted = true }
        push("已从目录库移除 \(ids.count) 张（原件保留）", "trash")
        selectedIds = []
        ensurePrimaryValid()
    }

    // ---------- compare ----------
    func enterCompare() {
        // order by display position so the chosen subset is deterministic
        var ids = list.map { $0.id }.filter { selectedIds.contains($0) }
        if ids.count < 2 { ids = list.prefix(3).map { $0.id } }
        compareIds = Array(ids.prefix(4))
        winner = nil
        view = .compare
    }

    func switchView(_ v: ViewMode) {
        if v == .compare { enterCompare() } else { view = v }
    }

    // ---------- onboarding ----------
    func enterApp(_ action: String) {
        welcomeAnim = true
        Task { [weak self, action] in
            try? await Task.sleep(for: .seconds(0.42))
            guard let self else { return }
            UserDefaults.standard.set("1", forKey: "pc_onboarded")
            self.onboarded = true
            if action == "import" { self.sheet = "import" }
        }
    }

    func saveSmart(name: String, rule: SmartRule, count: Int) {
        let id = "sm-" + UUID().uuidString.prefix(5)
        smartAlbums.append(SmartAlbum(id: id, name: name, rule: rule, count: count))
        sheet = nil
        selection = Selection(type: .smart, id: id, name: name)
        push("已创建智能相册「\(name)」", "sparkles")
    }

    // ---------- keyboard ----------
    /// Returns true if the key was handled.
    @discardableResult
    func handleKey(_ key: String, hasCommand: Bool) -> Bool {
        if hasCommand && key == "f" { return false }  // handled by search focus in shell
        if hasCommand && key == "i" { showInspector.toggle(); return true }
        if hasCommand { return false }
        guard onboarded else { return false }

        switch key {
        case "1", "2", "3", "4", "5":
            setRating(Int(key) ?? 0); push("评分 \(key) 星", "star")
        case "0":
            setRating(0); push("已清除评分")
        case "p":
            setFlag(.pick); push("标记为精选", "flag")
        case "x":
            setFlag(.reject); push("标记为拒绝", "reject")
        case "u":
            setFlag(.none); push("已清除旗标")
        case "6": setColor(.red)
        case "7": setColor(.yellow)
        case "8": setColor(.green)
        case "9": setColor(.blue)
        case "g":
            view = .grid
        case "e", " ":
            view = (view == .loupe) ? .grid : .loupe
        case "c":
            enterCompare()
        case "up", "down", "left", "right":
            moveSelection(key)
        case "delete", "backspace":
            removeSelected()
        default:
            return false
        }
        return true
    }

    private func moveSelection(_ key: String) {
        let ids = list.map { $0.id }
        guard let cur = ids.firstIndex(of: primaryId ?? "") else { return }
        var cols = 1
        if view == .grid {
            let w = gridWidth ?? 800
            cols = max(1, Int(w / (thumbSize + 14)))
        }
        var next = cur
        switch key {
        case "right": next = min(ids.count - 1, cur + 1)
        case "left": next = max(0, cur - 1)
        case "down": next = min(ids.count - 1, cur + cols)
        case "up": next = max(0, cur - cols)
        default: break
        }
        setPrimary(ids[next])
    }

    /// Updated by the grid so arrow-key navigation knows the column count.
    var gridWidth: CGFloat?
}
