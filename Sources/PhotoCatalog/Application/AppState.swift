// ============================================================
//  AppState — port of App() state, derived collections & mutations
// ============================================================
import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers

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
    @Published private var collapsedStackIds: Set<String> = []

    // ----- settings (PRD §17) -----
    @Published var importMode: ImportMode =
        ImportMode(rawValue: UserDefaults.standard.string(forKey: "pc_importMode") ?? "") ?? .referenced {
        didSet { UserDefaults.standard.set(importMode.rawValue, forKey: "pc_importMode") }
    }
    @Published var managedArchiveRule: ManagedArchiveRule =
        ManagedArchiveRule(rawValue: UserDefaults.standard.string(forKey: "pc_managedArchive") ?? "") ?? .date {
        didSet { UserDefaults.standard.set(managedArchiveRule.rawValue, forKey: "pc_managedArchive") }
    }
    @Published var importDuplicateStrategy: ImportDuplicateStrategy =
        ImportDuplicateStrategy(rawValue: UserDefaults.standard.string(forKey: "pc_importDuplicateStrategy") ?? "")
            ?? .groupExact {
        didSet {
            UserDefaults.standard.set(importDuplicateStrategy.rawValue, forKey: "pc_importDuplicateStrategy")
        }
    }
    @Published var importPostKeywords = UserDefaults.standard.string(forKey: "pc_importPostKeywords") ?? "" {
        didSet { UserDefaults.standard.set(importPostKeywords, forKey: "pc_importPostKeywords") }
    }
    @Published var importPostColorLabel = UserDefaults.standard.string(forKey: "pc_importPostColorLabel") ?? "" {
        didSet { UserDefaults.standard.set(importPostColorLabel, forKey: "pc_importPostColorLabel") }
    }
    @Published var importPostAlbumName = UserDefaults.standard.string(forKey: "pc_importPostAlbumName") ?? "" {
        didSet { UserDefaults.standard.set(importPostAlbumName, forKey: "pc_importPostAlbumName") }
    }
    @Published var exportWritesXMP = UserDefaults.standard.bool(forKey: "pc_exportXMP") {
        didSet { UserDefaults.standard.set(exportWritesXMP, forKey: "pc_exportXMP") }
    }
    @Published var readXMPSidecar: Bool = (UserDefaults.standard.object(forKey: "pc_readXMP") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(readXMPSidecar, forKey: "pc_readXMP") }
    }
    @Published var autoWriteXMPSidecar = UserDefaults.standard.bool(forKey: "pc_autoWriteXMP") {
        didSet { UserDefaults.standard.set(autoWriteXMPSidecar, forKey: "pc_autoWriteXMP") }
    }
    @Published var exportDirectoryStructure: ExportDirectoryStructure =
        ExportDirectoryStructure(rawValue: UserDefaults.standard.string(forKey: "pc_exportDirectoryStructure") ?? "")
            ?? .flat {
        didSet {
            UserDefaults.standard.set(exportDirectoryStructure.rawValue, forKey: "pc_exportDirectoryStructure")
        }
    }
    @Published var exportPresets: [ExportPreset] = AppState.loadExportPresets() {
        didSet { AppState.saveExportPresets(exportPresets) }
    }
    @Published var recentImportDays: Int = (UserDefaults.standard.object(forKey: "pc_recentDays") as? Int) ?? 14 {
        didSet { UserDefaults.standard.set(recentImportDays, forKey: "pc_recentDays") }
    }
    @Published var openLastCatalogOnLaunch: Bool =
        (UserDefaults.standard.object(forKey: "pc_openLast") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(openLastCatalogOnLaunch, forKey: "pc_openLast") }
    }
    @Published var reduceBackgroundOnLowPower: Bool =
        (UserDefaults.standard.object(forKey: "pc_lowPower") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(reduceBackgroundOnLowPower, forKey: "pc_lowPower") }
    }

    var recentCutoff: Date { Date().addingTimeInterval(-86400 * Double(max(1, recentImportDays))) }
    @Published var visionEnabled = UserDefaults.standard.bool(forKey: "pc_vision") {
        didSet { UserDefaults.standard.set(visionEnabled, forKey: "pc_vision") }
    }
    @Published var cacheLimitMB: Int = {
        let saved = UserDefaults.standard.integer(forKey: "pc_cacheLimitMB")
        return saved > 0 ? saved : 2_048
    }() {
        didSet { UserDefaults.standard.set(cacheLimitMB, forKey: "pc_cacheLimitMB") }
    }
    @Published var previewMaxPixel: Int = {
        let saved = UserDefaults.standard.integer(forKey: "pc_previewMaxPixel")
        return saved == 1600 ? 1600 : 2_048
    }() {
        didSet { UserDefaults.standard.set(previewMaxPixel, forKey: Self.previewMaxPixelKey) }
    }
    @Published var automaticBackupFrequency =
        UserDefaults.standard.string(forKey: "pc_autoBackupFrequency") ?? "weekly" {
        didSet { UserDefaults.standard.set(automaticBackupFrequency, forKey: "pc_autoBackupFrequency") }
    }
    @Published var healthReport: HealthReport?
    @Published private var recentCatalogPaths =
        UserDefaults.standard.stringArray(forKey: "pc_recentCatalogs") ?? []

    // ----- catalog (real persistence / scanning) -----
    private var store: CatalogStore?
    private var coordinator: ImportCoordinator?
    private var watcher: FileWatcher?
    private var watchedRoots: [URL] = []
    private var securityScopedRoots: [URL] = []
    private var sourceRootPathsById: [String: String] = [:]
    private var volumeMonitor: VolumeMonitor?
    private var lastImportSessionPersistedCount = 0
    private var importControl: ImportControl?
    private var activeImportJobId: String?
    private var launchCatalogHandled = false
    private static let catalogURLKey = "pc_catalogURL"
    private static let recentCatalogsKey = "pc_recentCatalogs"
    private static let lastAutoBackupKey = "pc_lastAutoBackupAt"
    private static let pinnedSidebarItemsKey = "pc_pinnedSidebarItems"
    private static let sourcePrioritiesKey = "pc_sourcePriorities"
    private static let previewMaxPixelKey = "pc_previewMaxPixel"

    // ----- selection / view -----
    @Published var selection = Selection(type: .lib, id: "all", name: "全部照片")
    @Published var selectedIds: Set<String> = []
    @Published var primaryId: String?
    @Published var view: ViewMode = .grid
    @Published var thumbSize: CGFloat = 168
    @Published var showInspector = true
    @Published var showInfo = true
    @Published var insTab = "org"
    @Published private var pinnedSidebarItems = AppState.loadPinnedSidebarItems()
    @Published private var sourcePriorities = AppState.loadSourcePriorities()
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
        if openLastCatalogOnLaunch, let error = loadExistingCatalog() {
            push(catalogOpenFailureMessage(error), "warning")
        }
        startVolumeMonitor()
        runAutomaticBackupIfNeeded()
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
    var catalogPath: String {
        (store?.packageURL ?? configuredCatalogURL).path
    }

    var recentCatalogs: [RecentCatalog] {
        recentCatalogPaths
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { RecentCatalog(path: $0) }
    }

    private var configuredCatalogURL: URL {
        UserDefaults.standard.url(forKey: Self.catalogURLKey) ?? CatalogStore.defaultURL
    }

    @discardableResult
    private func loadExistingCatalog() -> Error? {
        let url = configuredCatalogURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let s: CatalogStore
        do {
            s = try CatalogStore(packageURL: url)
        } catch {
            return error
        }
        store = s
        coordinator = ImportCoordinator(store: s)
        rememberCatalog(url)
        let real = ((try? s.loadAssets()) ?? []).filter { !$0.isDemo && !$0.deleted }
        let hasInterruptedImport = (try? s.loadJobs(type: "scan", states: ["running", "paused"]).isEmpty) == false
        guard !real.isEmpty else {
            if hasInterruptedImport {
                assets = []
                albums = []
                smartAlbums = []
                folders = []
            }
            restoreSourceRoots(from: s)
            if hasInterruptedImport {
                recoverInterruptedImportJobs(existingAssets: [])
            }
            return nil
        }

        assets = []
        albums = []
        smartAlbums = []
        folders = []
        restoreSourceRoots(from: s)

        // missing/offline detection (§6.4 ORG-003/007)
        let sourceRootsById = sourceRootRecordsById(from: s)
        let checked = real.map { resolveAssetAccess($0, sourceRootsById: sourceRootsById) }
        assets = checked
        for (fid, items) in Dictionary(grouping: checked, by: { $0.folderId }) where
            !folders.contains(where: { $0.id == fid }) {
            folders.append(Folder(id: fid, name: items.first?.folderName ?? fid,
                                  status: folderStatus(for: fid, in: checked)))
        }
        recomputeDuplicates()
        restoreAlbums(from: s, assets: checked)
        recoverInterruptedImportJobs(existingAssets: checked)
        backfillThumbnails()
        return nil
    }

    private func restoreAlbums(from store: CatalogStore, assets: [Asset]) {
        albums = (try? store.loadAlbums()) ?? []
        let loadedSmartAlbums = (try? store.loadSmartAlbums()) ?? []
        smartAlbums = loadedSmartAlbums.map { album in
            SmartAlbum(id: album.id, name: album.name, rule: album.rule,
                       count: SmartMatcher.match(assets, album.rule).count)
        }
    }

    private func restoreSourceRoots(from store: CatalogStore) {
        guard let roots = try? store.loadSourceRoots() else { return }
        for root in roots {
            let resolved = resolveSourceRoot(root)
            if resolved.status == "online", let url = resolved.url, url.path != root.pathHint {
                try? store.updateSourceRootAccess(
                    id: root.id,
                    displayName: root.displayName,
                    path: url.path,
                    bookmark: root.bookmarkData,
                    status: resolved.status,
                    volumeIdentifier: VolumeMonitor.volumeIdentifier(for: url) ?? root.volumeIdentifier
                )
            } else {
                try? store.updateSourceRootStatus(id: root.id, status: resolved.status)
            }

            sourceRootPathsById[root.id] = resolved.url?.path ?? root.pathHint
            if let index = folders.firstIndex(where: { $0.id == root.id }) {
                folders[index].status = resolved.status
            } else {
                folders.append(Folder(id: root.id, name: root.displayName, status: resolved.status))
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
                if let relocated = VolumeMonitor.relocatedURL(for: resolved.url.path,
                                                              volumeIdentifier: root.volumeIdentifier) {
                    return (relocated, "online")
                }
                return (resolved.url, VolumeMonitor.status(
                    forInaccessible: resolved.url.path,
                    volumeIdentifier: root.volumeIdentifier
                ).rawValue)
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
        if let relocated = VolumeMonitor.relocatedURL(for: root.pathHint,
                                                      volumeIdentifier: root.volumeIdentifier) {
            return (relocated, preferredStatus ?? "online")
        }
        return (nil, preferredStatus ?? VolumeMonitor.status(
            forInaccessible: root.pathHint,
            volumeIdentifier: root.volumeIdentifier
        ).rawValue)
    }

    private func sourceRootRecordsById(from store: CatalogStore) -> [String: SourceRootRecord] {
        let roots = (try? store.loadSourceRoots()) ?? []
        return Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0) })
    }

    private func setSourceFolder(id: String, name: String, path: String, status: String) {
        sourceRootPathsById[id] = path
        if let index = folders.firstIndex(where: { $0.id == id }) {
            folders[index] = Folder(id: id, name: name, status: status)
        } else {
            folders.append(Folder(id: id, name: name, status: status))
        }
    }

    private func resolveAssetAccess(_ asset: Asset,
                                    sourceRootsById: [String: SourceRootRecord]) -> Asset {
        guard let path = asset.localPath else { return asset }
        var resolved = asset
        if FileManager.default.fileExists(atPath: path) {
            resolved.status = .ready
            return resolved
        }

        let sourceRoot = sourceRootsById[asset.folderId]
        if let relocated = VolumeMonitor.relocatedURL(for: path,
                                                      volumeIdentifier: sourceRoot?.volumeIdentifier) {
            resolved.localPath = relocated.path
            resolved.status = .ready
            return resolved
        }

        resolved.status = VolumeMonitor.status(
            forInaccessible: path,
            volumeIdentifier: sourceRoot?.volumeIdentifier
        )
        return resolved
    }

    private func openOrCreateCatalog() {
        guard store == nil else { return }
        do {
            let s = try CatalogStore(packageURL: configuredCatalogURL)
            store = s
            coordinator = ImportCoordinator(store: s)
        } catch {
            push(catalogOpenFailureMessage(error, fallback: "无法创建目录库"), "warning")
        }
    }

    func createCatalog() {
        guard !importing else {
            push("导入中无法切换目录库", "warning")
            return
        }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "PhotoCatalog Library.photolibrary"
        panel.prompt = "创建"
        if let libraryType = UTType(filenameExtension: "photolibrary") {
            panel.allowedContentTypes = [libraryType]
        }
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        let url = catalogPackageURL(from: selected)

        do {
            closeCurrentCatalog()
            resetToDemoCatalog()
            let nextStore = try CatalogStore(packageURL: url)
            store = nextStore
            coordinator = ImportCoordinator(store: nextStore)
            setActiveCatalog(url)
            UserDefaults.standard.set("1", forKey: "pc_onboarded")
            onboarded = true
            push("已创建目录库 · \(url.lastPathComponent)", "check")
        } catch {
            resetToDemoCatalog()
            loadExistingCatalog()
            push(catalogOpenFailureMessage(error, fallback: "创建目录库失败"), "warning")
        }
    }

    func openCatalog() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "打开"
        panel.message = "选择 .photolibrary 目录库"
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        openCatalog(at: selected)
    }

    @discardableResult
    func openCatalog(at selected: URL) -> Bool {
        guard !importing else {
            push("导入中无法切换目录库", "warning")
            return false
        }

        let url = catalogPackageURL(from: selected)
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("catalog.sqlite").path) else {
            push("所选目录库无效", "warning")
            forgetCatalog(url)
            return false
        }

        let previousURL = configuredCatalogURL
        closeCurrentCatalog()
        resetToDemoCatalog()
        setActiveCatalog(url)
        let error = loadExistingCatalog()
        if store == nil {
            forgetCatalog(url)
            setActiveCatalog(previousURL)
            resetToDemoCatalog()
            loadExistingCatalog()
            push(catalogOpenFailureMessage(error), "warning")
            return false
        } else {
            UserDefaults.standard.set("1", forKey: "pc_onboarded")
            onboarded = true
            push("已打开目录库 · \(url.lastPathComponent)", "check")
            return true
        }
    }

    func openRecentCatalog(_ recent: RecentCatalog) {
        let url = URL(fileURLWithPath: recent.path)
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("catalog.sqlite").path) else {
            forgetCatalog(url)
            push("最近目录库不可访问", "warning")
            return
        }
        openCatalog(at: url)
    }

    func openLaunchCatalogIfNeeded(arguments: [String] = CommandLine.arguments) {
        guard !launchCatalogHandled else { return }
        launchCatalogHandled = true
        guard let url = Self.launchCatalogURL(from: arguments) else { return }
        openCatalog(at: url)
    }

    func clearRecentCatalogs() {
        recentCatalogPaths = []
        UserDefaults.standard.set(recentCatalogPaths, forKey: Self.recentCatalogsKey)
        push("已清除最近目录库", "trash")
    }

    private func catalogOpenFailureMessage(_ error: Error?, fallback: String = "打开目录库失败") -> String {
        if let error = error as? CatalogStoreError,
           case let .incompatibleSchema(current, supported) = error {
            return "目录库版本过新（schema \(current)，当前支持 \(supported)），请升级 PhotoCatalog 后再打开"
        }
        return fallback
    }

    private func catalogPackageURL(from url: URL) -> URL {
        url.pathExtension == "photolibrary" ? url : url.appendingPathExtension("photolibrary")
    }

    nonisolated static func launchCatalogURL(from arguments: [String]) -> URL? {
        for arg in arguments.dropFirst() where !arg.hasPrefix("--") {
            let url = URL(string: arg).flatMap { $0.isFileURL ? $0 : nil } ?? URL(fileURLWithPath: arg)
            if url.pathExtension == "photolibrary" { return url }
        }
        return nil
    }

    private func setActiveCatalog(_ url: URL) {
        UserDefaults.standard.set(url, forKey: Self.catalogURLKey)
        rememberCatalog(url)
    }

    private func rememberCatalog(_ url: URL) {
        let path = url.path
        recentCatalogPaths.removeAll { $0 == path }
        recentCatalogPaths.insert(path, at: 0)
        if recentCatalogPaths.count > 8 {
            recentCatalogPaths.removeLast(recentCatalogPaths.count - 8)
        }
        UserDefaults.standard.set(recentCatalogPaths, forKey: Self.recentCatalogsKey)
    }

    private func forgetCatalog(_ url: URL) {
        recentCatalogPaths.removeAll { $0 == url.path }
        UserDefaults.standard.set(recentCatalogPaths, forKey: Self.recentCatalogsKey)
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
        let sourceId = coordinator.sourceId(forFolder: folder)
        setSourceFolder(id: sourceId, name: folder.lastPathComponent, path: folder.path, status: "scanning")
        let existingIds = Set(assets.map { $0.id })
        let run = ImportRun(source: folder, mode: mode)
        let control = ImportControl()
        let jobId = "job-" + run.id.uuidString
        importRun = run
        importControl = control
        activeImportJobId = jobId
        lastImportSessionPersistedCount = 0
        let vision = visionEnabled
        let previewSize = previewMaxPixel
        let archiveRule = managedArchiveRule
        let readXMP = readXMPSidecar
        importing = true
        sheet = "import"
        try? store.startImportSession(id: run.id.uuidString, startedAt: run.startedAt)
        try? store.startImportJob(id: jobId, sessionId: run.id.uuidString, sourcePath: folder.path,
                                  mode: mode, autoTag: vision)
        push("正在导入「\(folder.lastPathComponent)」…", "importIcon")
        let bookmark = FileAccessService.createBookmark(for: folder)
        Task { [weak self, coordinator, store, folder, mode, vision, previewSize, archiveRule, readXMP, bookmark, existingIds, sourceId, run, control] in
            let imported = await Task.detached(priority: .userInitiated) { [coordinator, folder, mode, vision, previewSize, archiveRule, readXMP, control] in
                coordinator.importFolder(folder, mode: mode, autoTag: vision, archiveRule: archiveRule,
                                         readSidecar: readXMP, previewMaxPixel: previewSize, control: control) { progress in
                    Task { @MainActor [weak self] in
                        self?.recordImportProgress(progress, for: run.id)
                    }
                }
            }.value
            guard let self else { return }
            self.finishImport(folder: folder, imported: imported, existingIds: existingIds,
                              store: store, bookmark: bookmark, mode: mode, runId: run.id,
                              sourceId: sourceId,
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
                              bookmark: Data?, mode: ImportMode, runId: UUID, sourceId: String? = nil,
                              persistSourceRoot: Bool) {
        let dedup = ImportDeduplicationService.apply(
            imported: imported,
            existingAssets: assets.filter { !$0.deleted && !$0.isDemo },
            existingIds: existingIds,
            strategy: importDuplicateStrategy)
        let fresh = applyPostImportMetadata(to: dedup.fresh)
        let skipped = dedup.skipped
        assets.append(contentsOf: fresh)
        try? store.upsert(fresh)
        var rootId: String?
        if let fid = fresh.first?.folderId ?? imported.first?.folderId ?? sourceId {
            rootId = fid
            if persistSourceRoot && (!fresh.isEmpty || skipped > 0) {
                try? store.addSourceRoot(id: fid, displayName: folder.lastPathComponent,
                                         path: folder.path, bookmark: bookmark,
                                         volumeIdentifier: VolumeMonitor.volumeIdentifier(for: folder))
            }
            if fresh.isEmpty && skipped == 0 {
                folders.removeAll { $0.id == fid }
                sourceRootPathsById.removeValue(forKey: fid)
            } else {
                setSourceFolder(id: fid, name: folder.lastPathComponent, path: folder.path, status: "online")
                select(Selection(type: .folder, id: fid, name: folder.lastPathComponent))
            }
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
        applyPostImportAlbum(assetIds: fresh.map(\.id))
        recomputeDuplicates()
        enforceCacheLimitIfNeeded()
        backfillThumbnails()
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

    private func applyPostImportMetadata(to fresh: [Asset]) -> [Asset] {
        let actions = ImportPostActions(
            keywords: ImportPostActionService.normalizeKeywords(importPostKeywords),
            colorLabel: ColorLabel(rawValue: importPostColorLabel))
        return ImportPostActionService.apply(to: fresh, actions: actions)
    }

    private func applyPostImportAlbum(assetIds: [String]) {
        let name = importPostAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !assetIds.isEmpty else { return }

        if let index = albums.firstIndex(where: { $0.name == name }) {
            var album = albums[index]
            let existing = Set(album.assetIds)
            let additions = assetIds.filter { !existing.contains($0) }
            guard !additions.isEmpty else { return }
            album.assetIds.append(contentsOf: additions)
            guard saveManualAlbum(album, sortOrder: index) else { return }
            albums[index] = album
        } else {
            let album = Album(id: "al-" + UUID().uuidString.prefix(8), name: name, assetIds: assetIds)
            guard saveManualAlbum(album, sortOrder: albums.count) else { return }
            albums.append(album)
        }
    }

    func toggleImportPaused() {
        guard var run = importRun, run.phase.isActive else { return }
        guard let importControl else {
            if run.phase == .paused {
                resumeRecoveredImport(run)
            }
            return
        }
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

    private func recoverInterruptedImportJobs(existingAssets: [Asset]) {
        guard !importing, let store else { return }
        guard let job = (try? store.loadJobs(type: "scan", states: ["running", "paused"]))?.first else { return }
        guard let payload = importJobPayload(from: job),
              payload.kind == "importFolder",
              let mode = ImportMode(rawValue: payload.mode) else {
            try? store.updateJob(id: job.id, state: "failed", lockedAt: nil,
                                 lastError: "无法解析导入任务")
            return
        }

        let folder = URL(fileURLWithPath: payload.sourcePath)
        guard FileManager.default.fileExists(atPath: folder.path) else {
            try? store.updateJob(id: job.id, state: "failed", lockedAt: nil,
                                 lastError: "源文件夹不可访问")
            push("未能恢复导入：源文件夹不可访问", "warning")
            return
        }

        let phase: ImportPhase = job.state == "paused" ? .paused : .importing
        let run = restoredImportRun(job: job, payload: payload, folder: folder, mode: mode, phase: phase)
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
                               existingIds: Set(existingAssets.map { $0.id }))
    }

    private func resumeRecoveredImport(_ run: ImportRun) {
        guard let store, let activeImportJobId,
              let job = (try? store.loadJobs(type: "scan", states: ["running", "paused"]))?
                .first(where: { $0.id == activeImportJobId }),
              let payload = importJobPayload(from: job),
              let mode = ImportMode(rawValue: payload.mode) else { return }
        let folder = URL(fileURLWithPath: payload.sourcePath)
        guard FileManager.default.fileExists(atPath: folder.path) else {
            try? store.updateJob(id: job.id, state: "failed", lockedAt: nil,
                                 lastError: "源文件夹不可访问")
            var failedRun = run
            failedRun.phase = .failed
            failedRun.errorMessage = "源文件夹不可访问"
            importRun = failedRun
            importControl = nil
            self.activeImportJobId = nil
            importing = false
            push("源文件夹不可访问", "warning")
            return
        }

        restartRecoveredImport(jobId: job.id, run: run, folder: folder, mode: mode,
                               autoTag: payload.autoTag,
                               existingIds: Set(assets.map { $0.id }))
    }

    private func restartRecoveredImport(jobId: String, run: ImportRun, folder: URL, mode: ImportMode,
                                        autoTag: Bool, existingIds: Set<String>) {
        guard let coordinator, let store else { return }
        let control = ImportControl()
        var runningRun = run
        runningRun.phase = .importing
        importRun = runningRun
        importControl = control
        activeImportJobId = jobId
        lastImportSessionPersistedCount = runningRun.processed + runningRun.failed
        let sourceId = coordinator.sourceId(forFolder: folder)
        setSourceFolder(id: sourceId, name: folder.lastPathComponent, path: folder.path, status: "scanning")
        importing = true
        sheet = "import"
        try? store.updateJob(id: jobId, state: "running")
        try? store.updateImportSession(id: runningRun.id.uuidString, state: "running",
                                       totalCount: runningRun.total, importedCount: runningRun.imported,
                                       skippedCount: runningRun.skipped, failedCount: runningRun.failed)
        push("正在恢复导入「\(folder.lastPathComponent)」…", "refresh")
        let previewSize = previewMaxPixel

        Task { [weak self, coordinator, store, folder, mode, autoTag, previewSize, existingIds, sourceId, runningRun, control] in
            let imported = await Task.detached(priority: .userInitiated) { [coordinator, folder, mode, autoTag, previewSize, control] in
                coordinator.importFolder(folder, mode: mode, autoTag: autoTag,
                                         previewMaxPixel: previewSize, control: control) { progress in
                    Task { @MainActor [weak self] in
                        self?.recordImportProgress(progress, for: runningRun.id)
                    }
                }
            }.value
            guard let self else { return }
            self.finishImport(folder: folder, imported: imported, existingIds: existingIds,
                              store: store, bookmark: nil, mode: mode, runId: runningRun.id,
                              sourceId: sourceId,
                              persistSourceRoot: true)
        }
    }

    private func restoredImportRun(job: JobRecord, payload: ImportJobPayload, folder: URL,
                                   mode: ImportMode, phase: ImportPhase) -> ImportRun {
        let session = store.flatMap { store in
            (try? store.loadImportSessions())?.first { $0.id == payload.sessionId }
        }
        let runId = UUID(uuidString: payload.sessionId) ?? UUID()
        var run = ImportRun(id: runId, source: folder, mode: mode,
                            startedAt: session?.startedAt ?? job.createdAt)
        run.phase = phase
        if let session {
            run.total = session.totalCount
            run.skipped = session.skippedCount
            run.failed = session.failedCount
            run.processed = session.importedCount + session.skippedCount
            run.finishedAt = session.finishedAt
            run.errorMessage = session.errorMessage
        }
        return run
    }

    private func importJobPayload(from job: JobRecord) -> ImportJobPayload? {
        guard let data = job.payloadJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ImportJobPayload.self, from: data)
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
        let previewSize = previewMaxPixel
        importing = true
        try? store.startImportSession(id: retry.id.uuidString, startedAt: retry.startedAt)
        try? store.startImportJob(id: jobId, sessionId: retry.id.uuidString, sourcePath: folder.path,
                                  mode: retry.mode, autoTag: vision)
        push("正在重试 \(files.count) 个失败文件…", "refresh")
        Task { [weak self, coordinator, store, folder, files, existingIds, retry, vision, previewSize, control] in
            let imported = await Task.detached(priority: .userInitiated) { [coordinator, folder, files, retry, vision, previewSize, control] in
                coordinator.importFiles(files, from: folder, mode: retry.mode, autoTag: vision,
                                        previewMaxPixel: previewSize, control: control) { progress in
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
        let paths = prioritizedWatchedRoots(watchedRoots).map { $0.path }
        guard !paths.isEmpty else { watcher = nil; return }
        let w = FileWatcher(paths: paths) { [weak self] _ in self?.incrementalRescan() }
        w.start()
        watcher = w
    }

    private func incrementalRescan() {
        guard let coordinator, let store else { return }
        let roots = prioritizedWatchedRoots(watchedRoots)
        var knownAssetsByPath: [String: Asset] = [:]
        for asset in assets where !asset.deleted {
            if let path = asset.localPath {
                knownAssetsByPath[path] = asset
                knownAssetsByPath[URL(fileURLWithPath: path).resolvingSymlinksInPath().path] = asset
            }
        }
        let knownPaths = Set(knownAssetsByPath.keys)
        let vision = visionEnabled
        let previewSize = previewMaxPixel
        let readXMP = readXMPSidecar
        Task { [weak self, coordinator, store, roots, knownAssetsByPath, knownPaths, vision, previewSize, readXMP] in
            let delta = await Task.detached(priority: .utility) {
                var fresh: [Asset] = []
                var changed: [Asset] = []
                for root in roots {
                    fresh.append(contentsOf: coordinator.scanNew(in: root, knownPaths: knownPaths,
                                                                 mode: .referenced, autoTag: vision,
                                                                 readSidecar: readXMP,
                                                                 previewMaxPixel: previewSize))
                    changed.append(contentsOf: coordinator.scanChanged(in: root,
                                                                       knownAssetsByPath: knownAssetsByPath,
                                                                       mode: .referenced,
                                                                       autoTag: vision,
                                                                       readSidecar: readXMP,
                                                                       previewMaxPixel: previewSize))
                }
                return (fresh: fresh, changed: changed)
            }.value
            guard let self else { return }
            let trulyNew = delta.fresh.filter { a in !self.assets.contains { $0.id == a.id } }
            let changedAssets = delta.changed.filter { a in self.assets.contains { $0.id == a.id } }
            if !trulyNew.isEmpty || !changedAssets.isEmpty {
                self.assets.append(contentsOf: trulyNew)
                for asset in changedAssets {
                    if let index = self.assets.firstIndex(where: { $0.id == asset.id }) {
                        self.assets[index] = asset
                    }
                }
                try? store.upsert(trulyNew + changedAssets)
                self.recomputeDuplicates()
                if !trulyNew.isEmpty {
                    self.push("检测到 \(trulyNew.count) 张新照片", "importIcon")
                }
                if !changedAssets.isEmpty {
                    self.push("已更新 \(changedAssets.count) 张修改过的照片", "refresh")
                }
            }
            self.detectMissingRealAssets()
        }
    }

    /// User-invokable rescan of the watched source roots (Cmd+R, §15 / §6.3 IMP-002).
    func rescanCurrentSource() {
        guard coordinator != nil else { push("无已导入的源文件夹", "warning"); return }
        guard !watchedRoots.isEmpty else { push("当前没有可重新扫描的源", "warning"); return }
        push("正在重新扫描…", "refresh")
        incrementalRescan()
    }

    private func prioritizedWatchedRoots(_ roots: [URL]) -> [URL] {
        guard let store, let sourceRoots = try? store.loadSourceRoots() else { return roots }
        var idByPath: [String: String] = [:]
        for root in sourceRoots {
            idByPath[URL(fileURLWithPath: root.pathHint).standardizedFileURL.path] = root.id
        }
        var originalOrder: [String: Int] = [:]
        for (index, root) in roots.enumerated() where originalOrder[root.standardizedFileURL.path] == nil {
            originalOrder[root.standardizedFileURL.path] = index
        }
        return roots.sorted { lhs, rhs in
            let leftPath = lhs.standardizedFileURL.path
            let rightPath = rhs.standardizedFileURL.path
            let leftId = idByPath[leftPath]
            let rightId = idByPath[rightPath]
            let leftPriority = leftId.flatMap { sourcePriorities[$0] } ?? (originalOrder[leftPath] ?? 0)
            let rightPriority = rightId.flatMap { sourcePriorities[$0] } ?? (originalOrder[rightPath] ?? 0)
            if leftPriority != rightPriority { return leftPriority < rightPriority }
            return (originalOrder[leftPath] ?? 0) < (originalOrder[rightPath] ?? 0)
        }
    }

    func detectMissingRealAssets() {
        var changed = false
        let sourceRootsById = store.map { sourceRootRecordsById(from: $0) } ?? [:]
        for i in assets.indices where !assets[i].isDemo {
            let resolved = resolveAssetAccess(assets[i], sourceRootsById: sourceRootsById)
            if assets[i].status != resolved.status || assets[i].localPath != resolved.localPath {
                assets[i] = resolved
                changed = true
            }
        }
        updateFolderStatusesFromAssets()
        if changed, let store { try? store.upsert(assets.filter { !$0.isDemo }) }
    }

    private func updateFolderStatusesFromAssets() {
        for i in folders.indices {
            let status = folderStatus(for: folders[i].id, in: assets)
            if folders[i].status != status {
                folders[i].status = status
            }
        }
    }

    private func folderStatus(for folderId: String, in sourceAssets: [Asset]) -> String {
        let statuses = sourceAssets
            .filter { !$0.deleted && !$0.isDemo && $0.folderId == folderId }
            .map(\.status)
        if statuses.contains(.offline) { return "offline" }
        if statuses.contains(.missing) { return "missing" }
        if !statuses.isEmpty { return "online" }
        return folders.first(where: { $0.id == folderId })?.status ?? "online"
    }

    private func startVolumeMonitor() {
        let m = VolumeMonitor { [weak self] in self?.detectMissingRealAssets() }
        m.start()
        volumeMonitor = m
    }

    // ---------- batch capture-time shift (§4.2 / META-008) ----------
    func shiftCaptureTime(hours: Int, minutes: Int = 0) {
        let totalMinutes = hours * 60 + minutes
        guard totalMinutes != 0 else { return }
        let ids = targetIds
        guard !ids.isEmpty else { return }
        mutate(ids) {
            $0.date = $0.date.addingTimeInterval(Double(totalMinutes) * 60)
            $0.captureDateSource = "手动调整"
        }
        let absT = abs(totalMinutes)
        push("已调整 \(ids.count) 张拍摄时间 \(totalMinutes > 0 ? "+" : "-")\(absT / 60)时\(absT % 60)分", "clock")
    }

    /// Set an absolute capture time on the selection (§4.2 / META-008).
    func setCaptureDate(_ date: Date) {
        let ids = targetIds
        guard !ids.isEmpty else { return }
        mutate(ids) {
            $0.date = date
            $0.captureDateSource = "手动设置"
        }
        push("已将 \(ids.count) 张拍摄时间设为指定时间", "clock")
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
    /// Rename selected originals from a token template ({seq}/{date}/{time}/{camera}/{original}).
    /// A plain prefix with no token becomes "<prefix>_{seq}".
    func batchRename(template rawTemplate: String) {
        let trimmed = rawTemplate.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let template = trimmed.contains("{") ? trimmed : "\(trimmed)_{seq}"
        let real = list.filter { selectedIds.contains($0.id) && !$0.isDemo && $0.localPath != nil }
        guard !real.isEmpty else { push("仅可重命名已导入照片", "warning"); return }
        let map = RenameService.renameWithTemplate(real, template: template)
        for (id, url) in map {
            mutateAsset(id) { $0.filename = url.lastPathComponent; $0.localPath = url.path }
        }
        push("已重命名 \(map.count) 张照片", "check")
    }

    var canOperateOnSelectedOriginals: Bool {
        !selectedRealAssetsWithOriginals().isEmpty
    }

    func copySelectedOriginals() {
        runOriginalFileOperation(.copy)
    }

    func moveSelectedOriginals() {
        runOriginalFileOperation(.move)
    }

    private func runOriginalFileOperation(_ operation: OriginalFileOperation) {
        let real = selectedRealAssetsWithOriginals()
        guard !real.isEmpty else {
            push("仅可处理已导入照片的原件", "warning")
            return
        }
        guard confirmOriginalFileOperation(operation, count: real.count) else { return }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = operation == .move ? "移动到此处" : "复制到此处"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        Task { [weak self, operation, real, destination] in
            let report = await Task.detached(priority: .userInitiated) {
                OriginalFileOperationService.perform(operation, assets: real, destination: destination)
            }.value
            if operation == .move {
                self?.applyMovedOriginalLocations(report.updatedLocations)
            }
            self?.pushOriginalFileOperationReport(report, operation: operation)
        }
    }

    private func selectedRealAssetsWithOriginals() -> [Asset] {
        let ids = targetIds
        return assets.filter { ids.contains($0.id) && !$0.deleted && !$0.isDemo && $0.localPath != nil }
    }

    private func confirmOriginalFileOperation(_ operation: OriginalFileOperation, count: Int) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = operation == .move ? .warning : .informational
        alert.messageText = operation == .move ? "移动原件" : "复制原件"
        alert.informativeText = operation == .move
            ? "将移动 \(count) 个磁盘原件，并更新目录库中的文件路径。"
            : "将复制 \(count) 个磁盘原件，目录库中的文件路径保持不变。"
        alert.addButton(withTitle: operation == .move ? "移动" : "复制")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func applyMovedOriginalLocations(_ locations: [String: URL]) {
        guard !locations.isEmpty else { return }
        let ids = Set(locations.keys)
        for index in assets.indices {
            guard let url = locations[assets[index].id] else { continue }
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            assets[index].filename = url.lastPathComponent
            assets[index].localPath = url.path
            assets[index].fileModifiedAt = attrs?[.modificationDate] as? Date
            assets[index].fileCreatedAt = attrs?[.creationDate] as? Date
            assets[index].status = .ready
        }
        persist(ids)
    }

    private func pushOriginalFileOperationReport(_ report: OriginalFileOperationReport,
                                                 operation: OriginalFileOperation) {
        let completed = operation == .move ? report.moved : report.copied
        let verb = operation == .move ? "移动" : "复制"
        push("已\(verb) \(completed) 个原件"
             + (report.failed > 0 ? " · \(report.failed) 失败" : "")
             + (report.skipped > 0 ? " · \(report.skipped) 跳过" : ""),
             report.failed > 0 ? "warning" : "check")
    }

    // ---------- catalog health / cache (§6.1, §17.3) ----------
    func runHealthCheck() {
        openOrCreateCatalog()
        guard let store else { push("无目录库", "warning"); return }
        let report = CatalogHealth.check(store, assets: assets)
        healthReport = report
        push(report.summary, report.isHealthy ? "check" : "warning")
    }

    func rebuildThumbnails() {
        guard let coordinator else { push("无已导入照片", "warning"); return }
        let real = assets.filter { !$0.isDemo && $0.localPath != nil }
        guard !real.isEmpty else { push("无已导入照片", "warning"); return }
        push("正在重建缩略图…", "refresh")
        let previewSize = previewMaxPixel
        Task { [weak self, coordinator, real, previewSize] in
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
            self?.enforceCacheLimitIfNeeded()
            self?.push("缩略图已重建", "check")
        }
    }

    private var isBackfilling = false

    /// Low-priority background pass that fills in any missing/stale thumbnails for
    /// imported photos (visible-first generation is handled per-cell). PRD §6.6 THM-003.
    func backfillThumbnails() {
        guard let coordinator, !isBackfilling else { return }
        // battery saver: skip background work under Low Power Mode (§17.5)
        if reduceBackgroundOnLowPower, ProcessInfo.processInfo.isLowPowerModeEnabled { return }
        let real = assets.filter { !$0.isDemo && $0.localPath != nil }
        guard !real.isEmpty else { return }
        isBackfilling = true
        let previewSize = previewMaxPixel
        Task { [weak self, coordinator, real, previewSize] in
            await Task.detached(priority: .background) {
                for a in real {
                    guard let path = a.localPath,
                          FileManager.default.fileExists(atPath: path) else { continue }
                    let original = URL(fileURLWithPath: path)
                    _ = coordinator.thumbnails.ensureCached(from: original, assetId: a.id, kind: .thumb512)
                    _ = coordinator.thumbnails.ensureCached(
                        from: original, assetId: a.id,
                        kind: ThumbnailService.previewKind(forCachePath: a.preview, fallbackMaxPixel: previewSize))
                }
            }.value
            self?.isBackfilling = false
            self?.enforceCacheLimitIfNeeded()
        }
    }

    /// Privacy: delete catalog log files (§17.6).
    func clearLogs() {
        guard let store else { push("无目录库", "warning"); return }
        let fm = FileManager.default
        let logs = (try? fm.contentsOfDirectory(at: store.logsURL, includingPropertiesForKeys: nil)) ?? []
        for url in logs { try? fm.removeItem(at: url) }
        push("已清除日志", "trash")
    }

    /// Privacy: drop stored security-scoped bookmarks; sources need re-authorization (§17.6).
    func clearSecurityBookmarks() {
        guard let store else { push("无目录库", "warning"); return }
        try? store.clearSourceBookmarks()
        push("已清除安全书签，下次访问需重新授权", "trash")
    }

    func clearCache() {
        guard let store else { push("无目录库", "warning"); return }
        let fm = FileManager.default
        try? fm.removeItem(at: store.cacheURL)
        for dir in [store.thumb256URL, store.thumb512URL, store.preview1600URL, store.preview2048URL] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        push("已清理缩略图缓存", "trash")
    }

    func visibleImageSource(for asset: Asset, requestedSource: String,
                            kind: ThumbnailService.Kind) async -> String {
        if requestedSource.hasPrefix("http") || asset.isDemo {
            return requestedSource
        }

        let fm = FileManager.default
        let requestedExists = !requestedSource.isEmpty && fm.fileExists(atPath: requestedSource)
        if requestedExists && (!kind.isThumbnail || !asset.isRaw) {
            return requestedSource
        }

        guard let coordinator,
              let localPath = asset.localPath else {
            return requestedSource
        }

        let original = URL(fileURLWithPath: localPath)
        let fallbackPreview = asset.preview.isEmpty ? nil : URL(fileURLWithPath: asset.preview)
        guard fm.fileExists(atPath: localPath)
              || fallbackPreview.map({ fm.fileExists(atPath: $0.path) }) == true else {
            return requestedSource
        }

        let assetId = asset.id
        let thumbnails = coordinator.thumbnails
        let resolvedKind = kind.isPreview
            ? ThumbnailService.previewKind(forCachePath: requestedSource, fallbackMaxPixel: previewMaxPixel)
            : kind
        if requestedExists {
            let cached = URL(fileURLWithPath: requestedSource)
            let needsRegeneration = await Task.detached(priority: .userInitiated) {
                thumbnails.cachedRepresentationNeedsRegeneration(at: cached, original: original, kind: resolvedKind)
            }.value
            if !needsRegeneration {
                return requestedSource
            }
        }
        let restored = await Task.detached(priority: .userInitiated) {
            thumbnails.ensureCached(from: original,
                                    fallbackPreview: fallbackPreview,
                                    assetId: assetId,
                                    kind: resolvedKind)
        }.value
        return restored?.path ?? requestedSource
    }

    func pruneCacheToLimit() {
        guard let store else { push("无目录库", "warning"); return }
        let report = CacheService.prune(store.cacheURL, maxBytes: cacheLimitBytes)
        healthReport = CatalogHealth.check(store, assets: assets)
        if report.removedFiles == 0 {
            push("缓存已在 \(cacheLimitMB) MB 上限内", "check")
        } else {
            push("已清理缓存 \(formatCacheMB(report.removedBytes)) · \(report.removedFiles) 个文件", "trash")
        }
    }

    private var cacheLimitBytes: Int64 {
        Int64(cacheLimitMB) * 1024 * 1024
    }

    private func enforceCacheLimitIfNeeded() {
        guard let store else { return }
        let report = CacheService.prune(store.cacheURL, maxBytes: cacheLimitBytes)
        if report.removedFiles > 0 {
            healthReport = CatalogHealth.check(store, assets: assets)
        }
    }

    private func formatCacheMB(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    // ---------- export presets (§4.2) ----------
    static func loadExportPresets() -> [ExportPreset] {
        guard let data = UserDefaults.standard.data(forKey: "pc_exportPresets"),
              let presets = try? JSONDecoder().decode([ExportPreset].self, from: data) else { return [] }
        return presets
    }
    static func saveExportPresets(_ presets: [ExportPreset]) {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: "pc_exportPresets")
        }
    }

    func saveExportPreset(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let preset = ExportPreset(name: trimmed,
                                  directoryStructure: exportDirectoryStructure.rawValue,
                                  writesXMP: exportWritesXMP)
        exportPresets.removeAll { $0.name == trimmed }
        exportPresets.append(preset)
        push("已保存导出预设「\(trimmed)」", "check")
    }
    func applyExportPreset(_ preset: ExportPreset) {
        exportDirectoryStructure = ExportDirectoryStructure(rawValue: preset.directoryStructure) ?? .flat
        exportWritesXMP = preset.writesXMP
        push("已应用导出预设「\(preset.name)」")
    }
    func deleteExportPreset(_ preset: ExportPreset) {
        exportPresets.removeAll { $0.name == preset.name }
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
        let directoryStructure = exportDirectoryStructure
        let albumNamesByAssetId = exportAlbumNamesByAssetId()
        let sourceRootPathsByFolderId = exportSourceRootPathsByFolderId()
        Task { [weak self, real, dest, xmp, directoryStructure, albumNamesByAssetId, sourceRootPathsByFolderId] in
            let result = await Task.detached(priority: .userInitiated) {
                let report = ExportService.copyOriginals(real, to: dest, xmp: xmp,
                                                         directoryStructure: directoryStructure,
                                                         albumNamesByAssetId: albumNamesByAssetId,
                                                         sourceRootPathsByFolderId: sourceRootPathsByFolderId)
                let jsonOK = ExportService.exportMetadataJSON(real, to: dest.appendingPathComponent("metadata.json"))
                let csvOK = ExportService.exportMetadataCSV(real, to: dest.appendingPathComponent("metadata.csv"))
                return (report: report, metadataOK: jsonOK && csvOK)
            }.value
            self?.push("已导出 \(result.report.copied) 张原件"
                       + (result.report.failed > 0 ? " · \(result.report.failed) 失败" : "")
                       + (xmp ? " · 含 XMP" : "")
                       + (result.metadataOK ? " · 含元数据" : " · 元数据失败"), "export")
        }
    }

    func exportSelectionPreviews() {
        let ids = targetIds
        let selected = assets.filter { ids.contains($0.id) && !$0.deleted }
        guard !selected.isEmpty else {
            push("请先选择照片", "warning")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "导出预览到此处"
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        Task { [weak self, selected, dest] in
            let report = await Task.detached(priority: .userInitiated) {
                ExportService.exportPreviews(selected, to: dest)
            }.value
            self?.push("已导出 \(report.copied) 张预览图"
                       + (report.failed > 0 ? " · \(report.failed) 失败" : "")
                       + (report.skipped > 0 ? " · \(report.skipped) 跳过" : ""),
                       report.failed > 0 ? "warning" : "export")
        }
    }

    private func exportAlbumNamesByAssetId() -> [String: String] {
        var names: [String: String] = [:]
        for album in albums {
            for id in album.assetIds where names[id] == nil {
                names[id] = album.name
            }
        }
        return names
    }

    private func exportSourceRootPathsByFolderId() -> [String: String] {
        guard let store, let roots = try? store.loadSourceRoots() else { return [:] }
        return Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0.pathHint) })
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

    private func runAutomaticBackupIfNeeded(now: Date = .now) {
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

        let last = UserDefaults.standard.object(forKey: Self.lastAutoBackupKey) as? Date
        if let last, now.timeIntervalSince(last) < interval {
            return
        }

        do {
            try store.upsert(assets.filter { !$0.isDemo })
            let url = try BackupService.backup(store, at: now)
            UserDefaults.standard.set(now, forKey: Self.lastAutoBackupKey)
            push("已自动备份目录库 · \(url.lastPathComponent)", "check")
        } catch {
            push("自动备份失败", "warning")
        }
    }

    func restoreBackup() {
        openOrCreateCatalog()
        guard let packageURL = store?.packageURL else {
            push("无目录库可恢复", "warning")
            return
        }
        let backupsURL = store?.backupsURL
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = backupsURL
        panel.prompt = "恢复"
        panel.message = "选择一个目录库 SQLite 备份文件"
        if let sqliteType = UTType(filenameExtension: "sqlite") {
            panel.allowedContentTypes = [sqliteType]
        }
        guard panel.runModal() == .OK, let backup = panel.url else { return }

        let alert = NSAlert()
        alert.messageText = "恢复目录库备份？"
        alert.informativeText = "当前目录库数据库会被所选备份替换。应用会先尝试创建一次当前状态备份。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "恢复")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            if let store {
                try store.upsert(assets.filter { !$0.isDemo })
                _ = try BackupService.backup(store)
            }
            closeCurrentCatalog()
            resetToDemoCatalog()
            try BackupService.restore(backup, intoPackageAt: packageURL)
            loadExistingCatalog()
            push("已恢复备份 · \(backup.lastPathComponent)", "check")
        } catch {
            resetToDemoCatalog()
            loadExistingCatalog()
            push("恢复备份失败", "warning")
        }
    }

    private func closeCurrentCatalog() {
        watcher?.stop()
        watcher = nil
        for url in securityScopedRoots {
            url.stopAccessingSecurityScopedResource()
        }
        securityScopedRoots = []
        watchedRoots = []
        sourceRootPathsById = [:]
        importControl = nil
        activeImportJobId = nil
        importing = false
        store = nil
        coordinator = nil
    }

    private func resetToDemoCatalog() {
        let a = DemoData.assets
        assets = a
        albums = DemoData.initialAlbums(a)
        smartAlbums = DemoData.initialSmartAlbums(a)
        folders = DemoData.folders
        sourceRootPathsById = [:]
        duplicateGroupsCache = DemoData.duplicateGroups
        selection = Selection(type: .lib, id: "all", name: "全部照片")
        primaryId = list.first?.id
        selectedIds = primaryId.map { Set([$0]) } ?? []
        anchorId = primaryId
        compareIds = []
        winner = nil
        importRun = nil
        healthReport = nil
    }

    // ---------- duplicate groups (§6.10): exact (content) + similar (perceptual) ----------
    var duplicateGroups: [DuplicateGroup] { duplicateGroupsCache }

    /// Recompute duplicates off the main thread (dHash reads thumbnails from disk).
    func recomputeDuplicates() {
        let live = assets.filter { !$0.isDemo && !$0.deleted }
        guard !live.isEmpty else {
            duplicateGroupsCache = DemoData.duplicateGroups
            collapsedStackIds = []
            return
        }
        Task { [weak self, live] in
            let groups = await Task.detached(priority: .utility) {
                HashService.exactDuplicateGroups(live)
                    + HashService.suspectedDuplicateGroups(live)
                    + PerceptualHash.similarGroups(live)
            }.value
            guard let self else { return }
            self.duplicateGroupsCache = groups
            let validStackIds = Set(PhotoStackService.stacks(from: groups).map(\.id))
            self.collapsedStackIds.formIntersection(validStackIds)
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
        // mirror user-metadata edits to XMP sidecars when enabled (§17.4 META-007)
        if autoWriteXMPSidecar {
            for a in changed where a.localPath != nil {
                XMPSidecar.write(a, to: XMPSidecar.sidecarURL(for: URL(fileURLWithPath: a.localPath!)))
            }
        }
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

    var keywordSuggestionPool: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for asset in assets where !asset.deleted {
            for keyword in KeywordService.normalize(asset.keywords) where seen.insert(keyword).inserted {
                result.append(keyword)
            }
        }
        for keyword in DemoData.keywordPool where seen.insert(keyword).inserted {
            result.append(keyword)
        }
        return result
    }

    var projectList: [KeywordCount] {
        countMetadataValues(\.project)
    }

    var clientList: [KeywordCount] {
        countMetadataValues(\.client)
    }

    private func countMetadataValues(_ keyPath: KeyPath<Asset, String>) -> [KeywordCount] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for asset in assets where !asset.deleted {
            let value = asset[keyPath: keyPath].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            if counts[value] == nil { order.append(value) }
            counts[value, default: 0] += 1
        }
        return order.map { KeywordCount(name: $0, count: counts[$0] ?? 0) }
            .sorted { $0.count > $1.count }
    }

    var pinnedSidebarFavorites: [PinnedSidebarItem] {
        pinnedSidebarItems.compactMap(resolvePinnedSidebarItem)
    }

    var orderedFolders: [Folder] {
        let originalOrder = Dictionary(uniqueKeysWithValues: folders.enumerated().map { ($0.element.id, $0.offset) })
        return folders.sorted { lhs, rhs in
            let leftPriority = sourcePriorities[lhs.id] ?? (originalOrder[lhs.id] ?? 0)
            let rightPriority = sourcePriorities[rhs.id] ?? (originalOrder[rhs.id] ?? 0)
            if leftPriority != rightPriority { return leftPriority < rightPriority }
            return (originalOrder[lhs.id] ?? 0) < (originalOrder[rhs.id] ?? 0)
        }
    }

    var folderTree: [FolderTreeItem] {
        FolderTreeService.build(sourceFolders: orderedFolders, assets: assets,
                                sourceRootPaths: sourceRootPathsById)
    }

    private var photoStacks: [PhotoStack] {
        PhotoStackService.stacks(from: duplicateGroupsCache)
    }

    func stackInfo(for asset: Asset) -> (count: Int, collapsed: Bool)? {
        guard let stack = PhotoStackService.stack(containing: asset.id, in: photoStacks) else {
            return nil
        }
        return (stack.count, collapsedStackIds.contains(stack.id))
    }

    func toggleStack(containing assetId: String) {
        guard let stack = PhotoStackService.stack(containing: assetId, in: photoStacks) else { return }
        if collapsedStackIds.contains(stack.id) {
            collapsedStackIds.remove(stack.id)
            push("已展开堆栈")
        } else {
            collapsedStackIds.insert(stack.id)
            push("已折叠 \(stack.count) 张照片为堆栈")
        }
        normalizeSelectionToVisibleList()
    }

    func toggleStackForPrimary() {
        guard let primaryId else { return }
        toggleStack(containing: primaryId)
    }

    func countForFolderTreeItem(_ item: FolderTreeItem) -> Int {
        assets.filter { !$0.deleted && FolderTreeService.matches($0, item: item) }.count
    }

    var canPromoteSelectedSource: Bool {
        selectedFolderIsCatalogSource && orderedFolders.first?.id != selection.id
    }

    var canDemoteSelectedSource: Bool {
        selectedFolderIsCatalogSource && orderedFolders.last?.id != selection.id
    }

    func promoteSelectedSource() {
        moveSelectedSourcePriority(up: true)
    }

    func demoteSelectedSource() {
        moveSelectedSourcePriority(up: false)
    }

    var canPinCurrentSelection: Bool {
        selection.type != .lib && currentPinnedSidebarItem() != nil
    }

    var isCurrentSelectionPinned: Bool {
        guard let item = currentPinnedSidebarItem() else { return false }
        return pinnedSidebarItems.contains { $0.id == item.id }
    }

    func togglePinCurrentSelection() {
        guard let item = currentPinnedSidebarItem() else { return }
        if let index = pinnedSidebarItems.firstIndex(where: { $0.id == item.id }) {
            pinnedSidebarItems.remove(at: index)
            push("已从收藏夹移除「\(item.name)」", "star")
        } else {
            pinnedSidebarItems.append(item)
            push("已固定「\(item.name)」到收藏夹", "star")
        }
        savePinnedSidebarItems()
    }

    func countForPinnedSidebarItem(_ item: PinnedSidebarItem) -> String {
        let live = assets.filter { !$0.deleted }
        switch item.type {
        case .folder:
            return "\(live.filter { $0.folderId == item.selectionId }.count)"
        case .album:
            return "\(albums.first(where: { $0.id == item.selectionId })?.assetIds.count ?? 0)"
        case .smart:
            guard let smart = smartAlbums.first(where: { $0.id == item.selectionId }) else { return "0" }
            return "\(SmartMatcher.match(live, smart.rule).count)"
        case .keyword:
            return "\(live.filter { $0.keywords.contains(item.selectionId) }.count)"
        case .project:
            return "\(live.filter { $0.project == item.selectionId }.count)"
        case .client:
            return "\(live.filter { $0.client == item.selectionId }.count)"
        case .lib:
            return ""
        }
    }

    private static func loadPinnedSidebarItems() -> [PinnedSidebarItem] {
        guard let data = UserDefaults.standard.data(forKey: pinnedSidebarItemsKey),
              let items = try? JSONDecoder().decode([PinnedSidebarItem].self, from: data) else {
            return []
        }
        return items
    }

    private func savePinnedSidebarItems() {
        if let data = try? JSONEncoder().encode(pinnedSidebarItems) {
            UserDefaults.standard.set(data, forKey: Self.pinnedSidebarItemsKey)
        }
    }

    private static func loadSourcePriorities() -> [String: Int] {
        guard let data = UserDefaults.standard.data(forKey: sourcePrioritiesKey),
              let priorities = try? JSONDecoder().decode([String: Int].self, from: data) else {
            return [:]
        }
        return priorities
    }

    private func saveSourcePriorities() {
        if let data = try? JSONEncoder().encode(sourcePriorities) {
            UserDefaults.standard.set(data, forKey: Self.sourcePrioritiesKey)
        }
    }

    private func moveSelectedSourcePriority(up: Bool) {
        var ordered = orderedFolders
        guard let index = ordered.firstIndex(where: { $0.id == selection.id }) else { return }
        let target = up ? index - 1 : index + 1
        guard ordered.indices.contains(target) else { return }
        ordered.swapAt(index, target)
        sourcePriorities = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element.id, $0.offset) })
        saveSourcePriorities()
        refreshWatcher()
        push(up ? "已提高源优先级" : "已降低源优先级", "sort")
    }

    private func currentPinnedSidebarItem() -> PinnedSidebarItem? {
        resolvePinnedSidebarItem(PinnedSidebarItem(type: selection.type,
                                                   selectionId: selection.id,
                                                   name: selection.name))
    }

    private func resolvePinnedSidebarItem(_ item: PinnedSidebarItem) -> PinnedSidebarItem? {
        switch item.type {
        case .folder:
            guard let folder = folders.first(where: { $0.id == item.selectionId }) else { return nil }
            return PinnedSidebarItem(type: .folder, selectionId: folder.id, name: folder.name)
        case .album:
            guard let album = albums.first(where: { $0.id == item.selectionId }) else { return nil }
            return PinnedSidebarItem(type: .album, selectionId: album.id, name: album.name)
        case .smart:
            guard let smart = smartAlbums.first(where: { $0.id == item.selectionId }) else { return nil }
            return PinnedSidebarItem(type: .smart, selectionId: smart.id, name: smart.name)
        case .keyword:
            let exists = assets.contains { !$0.deleted && $0.keywords.contains(item.selectionId) }
            guard exists else { return nil }
            return PinnedSidebarItem(type: .keyword, selectionId: item.selectionId, name: item.name)
        case .project:
            guard projectList.contains(where: { $0.name == item.selectionId }) else { return nil }
            return PinnedSidebarItem(type: .project, selectionId: item.selectionId, name: item.name)
        case .client:
            guard clientList.contains(where: { $0.name == item.selectionId }) else { return nil }
            return PinnedSidebarItem(type: .client, selectionId: item.selectionId, name: item.name)
        case .lib:
            return nil
        }
    }

    // ---------- base collection from sidebar ----------
    var baseList: [Asset] {
        let live = assets.filter { !$0.deleted }
        switch selection.type {
        case .folder:
            if let item = folderTree.first(where: { $0.id == selection.id }) {
                return live.filter { FolderTreeService.matches($0, item: item) }
            }
            return live.filter { $0.folderId == selection.id }
        case .album:
            guard let al = albums.first(where: { $0.id == selection.id }) else { return [] }
            return live.filter { al.assetIds.contains($0.id) }
        case .smart:
            guard let sa = smartAlbums.first(where: { $0.id == selection.id }) else { return [] }
            return SmartMatcher.match(live, sa.rule)
        case .keyword:
            return live.filter { $0.keywords.contains(selection.id) }
        case .project:
            return live.filter { $0.project == selection.id }
        case .client:
            return live.filter { $0.client == selection.id }
        case .lib:
            switch selection.id {
            case "recent":
                return live.filter { $0.importedAt > recentCutoff }
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
        let calendar = Calendar.current
        let now = Date.now
        let currentDate = calendar.dateComponents([.year, .month], from: now)
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let cameraQuery = filters.camera.trimmingCharacters(in: .whitespacesAndNewlines)
        let lensQuery = filters.lens.trimmingCharacters(in: .whitespacesAndNewlines)
        var l = baseList.filter { a in
            if filters.minRating > 0 && a.rating < filters.minRating { return false }
            if filters.flag != "any" && a.flag.rawValue != filters.flag { return false }
            if filters.color != "any" && a.colorLabel?.rawValue != filters.color { return false }
            if filters.type != "any" {
                if filters.type == "RAW" && !a.isRaw { return false }
                if filters.type != "RAW" && a.type != filters.type { return false }
            }
            if !cameraQuery.isEmpty && !a.camera.localizedStandardContains(cameraQuery) { return false }
            if !lensQuery.isEmpty && !a.lens.localizedStandardContains(lensQuery) { return false }
            if filters.date != "any" {
                let assetDate = calendar.dateComponents([.year, .month], from: a.date)
                if filters.date == "thisYear" && assetDate.year != currentDate.year { return false }
                if filters.date == "thisMonth" &&
                    (assetDate.year != currentDate.year || assetDate.month != currentDate.month) {
                    return false
                }
            }
            let hasGPS = !(a.gps.0 == 0 && a.gps.1 == 0)
            if filters.gps == "yes" && !hasGPS { return false }
            if filters.gps == "no" && hasGPS { return false }
            if filters.status != "any" && a.status.rawValue != filters.status { return false }
            if !q.isEmpty {
                let haystack = ([a.filename, a.camera, a.lens, a.title, a.caption, a.location,
                                 a.project, a.client]
                    + a.keywords).joined(separator: " ")
                if !haystack.localizedStandardContains(q) { return false }
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
        return PhotoStackService.visibleAssets(l, stacks: photoStacks, collapsedStackIds: collapsedStackIds)
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

    var canSaveCurrentFilter: Bool {
        !filters.smartConditions(search: search).isEmpty
    }

    func saveCurrentFilterAsSmartAlbum() {
        let conditions = filters.smartConditions(search: search)
        guard !conditions.isEmpty else {
            push("没有可保存的筛选条件", "warning")
            return
        }
        guard let name = promptAlbumName(defaultName: defaultFilterSmartAlbumName()) else { return }

        let rule = SmartRule(match: "all", conditions: conditions)
        let count = SmartMatcher.match(assets.filter { !$0.deleted }, rule).count
        saveSmart(name: name, rule: rule, count: count)
    }

    private func defaultFilterSmartAlbumName() -> String {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty { return "筛选 · \(q)" }
        return "当前筛选"
    }

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

    @discardableResult
    func selectAllVisible() -> Bool {
        let ids = list.map(\.id)
        guard !ids.isEmpty else { return false }
        selectedIds = Set(ids)
        if primaryId == nil || !selectedIds.contains(primaryId ?? "") {
            primaryId = ids.first
        }
        anchorId = primaryId
        return true
    }

    @discardableResult
    func invertVisibleSelection() -> Bool {
        let ids = list.map(\.id)
        guard !ids.isEmpty else { return false }
        let visible = Set(ids)
        selectedIds = visible.subtracting(selectedIds)
        primaryId = ids.first { selectedIds.contains($0) }
        anchorId = primaryId
        return true
    }

    private func normalizeSelectionToVisibleList() {
        let ids = list.map(\.id)
        guard !ids.isEmpty else {
            selectedIds = []
            primaryId = nil
            anchorId = nil
            return
        }
        let visible = Set(ids)
        selectedIds.formIntersection(visible)
        if let primaryId, visible.contains(primaryId) {
            if selectedIds.isEmpty { selectedIds = [primaryId] }
            anchorId = primaryId
            return
        }
        let next = ids.first { selectedIds.contains($0) } ?? ids[0]
        primaryId = next
        selectedIds = [next]
        anchorId = next
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

    var canApplySelectionToAlbum: Bool { !targetIds.isEmpty }
    var canRemoveSelectionFromCurrentAlbum: Bool { selection.type == .album && !targetIds.isEmpty }
    var canRemoveSelectedSource: Bool { selectedFolderIsCatalogSource }
    var canReauthorizeSelectedSource: Bool { selectedFolderIsCatalogSource }

    private var selectedFolderIsCatalogSource: Bool {
        selection.type == .folder
            && store != nil
            && !DemoData.folders.contains { $0.id == selection.id }
            && folders.contains { $0.id == selection.id }
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
    func setProject(_ p: String) { mutate { $0.project = p.trimmingCharacters(in: .whitespacesAndNewlines) } }
    func setClient(_ c: String) { mutate { $0.client = c.trimmingCharacters(in: .whitespacesAndNewlines) } }

    func removeSelectedSource() {
        guard selectedFolderIsCatalogSource else { return }
        let folderId = selection.id
        let folderName = selection.name
        let indexed = assets.filter { !$0.deleted && !$0.isDemo && $0.folderId == folderId }
        guard !indexed.isEmpty || folders.contains(where: { $0.id == folderId }) else { return }

        let alert = NSAlert()
        alert.messageText = "移除源文件夹？"
        alert.informativeText = "将从目录库移除「\(folderName)」的索引记录，磁盘上的原件不会被删除。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "移除索引")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let ids = Set(indexed.map(\.id))
        if !ids.isEmpty {
            mutate(ids) { $0.deleted = true }
        }
        try? store?.removeSourceRoot(id: folderId)
        folders.removeAll { $0.id == folderId }
        sourceRootPathsById.removeValue(forKey: folderId)
        sourcePriorities.removeValue(forKey: folderId)
        saveSourcePriorities()
        watchedRoots.removeAll { root in
            indexed.contains { $0.localPath?.hasPrefix(root.path + "/") == true }
        }
        refreshWatcher()
        selection = Selection(type: .lib, id: "all", name: "全部照片")
        selectedIds = []
        primaryId = list.first?.id
        if let primaryId {
            selectedIds = [primaryId]
            anchorId = primaryId
        } else {
            anchorId = nil
        }
        recomputeDuplicates()
        push("已移除源「\(folderName)」的索引", "trash")
    }

    func reauthorizeSelectedSource() {
        guard selectedFolderIsCatalogSource else { return }
        let folderId = selection.id

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "重新授权"
        panel.message = "选择源文件夹以恢复访问权限"
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        let bookmark = FileAccessService.createBookmark(for: folder)
        do {
            try store?.updateSourceRootAccess(id: folderId, displayName: folder.lastPathComponent,
                                              path: folder.path, bookmark: bookmark,
                                              volumeIdentifier: VolumeMonitor.volumeIdentifier(for: folder))
        } catch {
            push("重新授权失败", "warning")
            return
        }

        for i in folders.indices where folders[i].id == folderId {
            folders[i] = Folder(id: folderId, name: folder.lastPathComponent, status: "online")
        }
        sourceRootPathsById[folderId] = folder.path
        if !watchedRoots.contains(folder) {
            watchedRoots.append(folder)
            refreshWatcher()
        }
        detectMissingRealAssets()
        push("已恢复源文件夹访问", "check")
    }

    func createAlbumFromSelection() {
        guard let name = promptAlbumName(defaultName: "新建相册") else { return }
        let album = Album(id: "al-" + UUID().uuidString.prefix(8), name: name,
                          assetIds: orderedTargetAssetIds())
        guard saveManualAlbum(album, sortOrder: albums.count) else { return }
        albums.append(album)
        selection = Selection(type: .album, id: album.id, name: album.name)
        push("已创建相册「\(album.name)」", "album")
    }

    func addSelectionToAlbum() {
        let ids = orderedTargetAssetIds()
        guard !ids.isEmpty else {
            push("请先选择照片", "warning")
            return
        }
        guard !albums.isEmpty else {
            createAlbumFromSelection()
            return
        }

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        popup.addItems(withTitles: albums.map(\.name))
        let alert = NSAlert()
        alert.messageText = "加入相册"
        alert.accessoryView = popup
        alert.addButton(withTitle: "加入")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let index = popup.indexOfSelectedItem
        guard albums.indices.contains(index) else { return }

        var album = albums[index]
        let existing = Set(album.assetIds)
        let additions = ids.filter { !existing.contains($0) }
        guard !additions.isEmpty else {
            push("所选照片已在相册中", "info")
            return
        }
        album.assetIds.append(contentsOf: additions)
        guard saveManualAlbum(album, sortOrder: index) else { return }
        albums[index] = album
        push("已加入 \(additions.count) 张照片到「\(album.name)」", "album")
    }

    func removeSelectionFromCurrentAlbum() {
        guard selection.type == .album,
              let index = albums.firstIndex(where: { $0.id == selection.id }) else { return }
        let ids = targetIds
        guard !ids.isEmpty else { return }
        var album = albums[index]
        let before = album.assetIds.count
        album.assetIds.removeAll { ids.contains($0) }
        let removed = before - album.assetIds.count
        guard removed > 0 else { return }
        guard saveManualAlbum(album, sortOrder: index) else { return }
        albums[index] = album
        selectedIds.subtract(ids)
        ensurePrimaryValid()
        push("已从「\(album.name)」移除 \(removed) 张照片", "album")
    }

    private func orderedTargetAssetIds() -> [String] {
        let ids = targetIds
        return list.map(\.id).filter { ids.contains($0) }
    }

    private func saveManualAlbum(_ album: Album, sortOrder: Int) -> Bool {
        guard let store else { return true }
        do {
            try store.saveAlbum(album, sortOrder: sortOrder)
            return true
        } catch {
            push("相册保存失败", "warning")
            return false
        }
    }

    private func promptAlbumName(defaultName: String) -> String? {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = defaultName
        let alert = NSAlert()
        alert.messageText = "新建相册"
        alert.accessoryView = field
        alert.addButton(withTitle: "创建")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

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
        let meta = MetadataReader.read(replacement)
        mutateAsset(id) {
            $0.localPath = replacement.path
            $0.filename = replacement.lastPathComponent
            $0.fileMB = Double(size) / (1024 * 1024)
            $0.fileModifiedAt = attrs?[.modificationDate] as? Date
            $0.fileCreatedAt = attrs?[.creationDate] as? Date
            $0.hasICCProfile = meta.hasICCProfile
            $0.gpsAltitude = meta.gpsAltitude
            $0.quickHash = HashService.quickHash(replacement, fileSize: size)
            $0.contentHash = HashService.contentHash(replacement)
            $0.status = .ready
        }
        recomputeDuplicates()
        push("已重新定位原件", "link")
    }

    func addKeyword(_ kw: String) {
        let keywords = KeywordService.normalize(kw)
        guard !keywords.isEmpty else { return }
        mutate {
            for keyword in keywords where !$0.keywords.contains(keyword) {
                $0.keywords.append(keyword)
            }
        }
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

    /// Delete-key flow: confirm whether to remove from the catalog or trash the originals (§15).
    func confirmDeleteSelected() {
        let ids = targetIds
        guard !ids.isEmpty else { return }
        let real = selectedRealAssetsWithOriginals()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "移除照片"
        alert.informativeText = "将 \(ids.count) 张从目录库移除。原件默认保留。"
        alert.addButton(withTitle: "从目录库移除")
        if !real.isEmpty { alert.addButton(withTitle: "移到废纸篓") }
        alert.addButton(withTitle: "取消")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            removeSelected()
        } else if !real.isEmpty, response == .alertSecondButtonReturn {
            performTrashOriginals(real)
        }
    }

    func trashSelectedOriginals() {
        let real = selectedRealAssetsWithOriginals()
        guard !real.isEmpty else {
            push("仅可将已导入照片的原件移到废纸篓", "warning")
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "移到废纸篓"
        alert.informativeText = "将 \(real.count) 个磁盘原件移到废纸篓，并从目录库移除对应记录。"
        alert.addButton(withTitle: "移到废纸篓")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        performTrashOriginals(real)
    }

    /// Move the given originals to the Trash and remove their catalog records (no extra prompt).
    private func performTrashOriginals(_ real: [Asset]) {
        Task { [weak self, real] in
            let result = await Task.detached(priority: .userInitiated) { () -> (trashed: Set<String>, failed: Int) in
                var trashed = Set<String>()
                var failed = 0
                let fm = FileManager.default
                for asset in real {
                    guard let path = asset.localPath else { failed += 1; continue }
                    do {
                        try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                        trashed.insert(asset.id)
                    } catch {
                        failed += 1
                    }
                }
                return (trashed, failed)
            }.value

            if !result.trashed.isEmpty {
                self?.mutate(result.trashed) { $0.deleted = true }
                self?.selectedIds.subtract(result.trashed)
                self?.ensurePrimaryValid()
                self?.recomputeDuplicates()
            }
            self?.push("已移到废纸篓 \(result.trashed.count) 张"
                       + (result.failed > 0 ? " · \(result.failed) 失败" : ""),
                       result.failed > 0 ? "warning" : "check")
        }
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
        let album = SmartAlbum(id: id, name: name, rule: rule, count: count)
        if let store {
            do {
                try store.saveSmartAlbum(album, sortOrder: smartAlbums.count)
            } catch {
                push("智能相册保存失败", "warning")
                return
            }
        }
        smartAlbums.append(album)
        sheet = nil
        selection = Selection(type: .smart, id: id, name: name)
        push("已创建智能相册「\(name)」", "sparkles")
    }

    // ---------- keyboard ----------
    /// Returns true if the key was handled.
    @discardableResult
    func handleKey(_ key: String, hasCommand: Bool, hasShift: Bool = false) -> Bool {
        if hasCommand {
            switch key {
            case "f":
                focusSearch()
            case "i":
                showInspector.toggle()
            case "e":
                exportSelection()
            case "r":
                rescanCurrentSource()
            case "a":
                if hasShift {
                    guard invertVisibleSelection() else { return false }
                    push("已反选当前列表")
                } else {
                    guard selectAllVisible() else { return false }
                    push("已全选当前列表")
                }
            default:
                return false
            }
            return true
        }
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
        case "s":
            toggleStackForPrimary()
        case "up", "down", "left", "right":
            moveSelection(key)
        case "delete", "backspace":
            confirmDeleteSelected()
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
