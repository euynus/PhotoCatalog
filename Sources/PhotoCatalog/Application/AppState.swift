// ============================================================
//  AppState — port of App() state, derived collections & mutations
// ============================================================
import SwiftUI
import Observation
import AppKit
import UniformTypeIdentifiers

private struct StatusMetrics: Equatable, Sendable {
    var cacheBytes: Int64?
    var lastBackupDate: Date?
    var backupCount = 0
}

private final class CatalogOpenPanelDelegate: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, validate url: URL) throws {
        guard AppState.isValidCatalogSelection(url) else {
            throw NSError(domain: "PhotoCatalog.CatalogOpenPanel", code: 1,
                          userInfo: [
                            NSLocalizedDescriptionKey: "请选择有效的 .photolibrary 目录库"
                          ])
        }
    }
}

// @Observable gives per-property observation: a view re-renders only when a
// property it actually read in body changes, not on every mutation anywhere
// in the store. Lazy caches are @ObservationIgnored and their getters touch
// the tracked inputs instead — a cache HIT must still register the same
// dependencies as a miss, or views go stale (see the `_ = listInputsVersion`
// lines). Filling an ignored cache inside a getter is safe during body.
@MainActor
@Observable
final class AppState {
    // ----- onboarding -----
    var onboarded: Bool = UserDefaults.standard.string(forKey: "pc_onboarded") == "1"
    var welcomeAnim = false

    // ----- core data -----
    var assets: [Asset] {
        didSet {
            assetIndexCache = nil
            keywordListCache = nil
            keywordSuggestionPoolCache = nil
            projectListCache = nil
            clientListCache = nil
            folderTreeCache = nil
            folderTreeCountCache = nil
            libraryCountsCache = nil
            sidebarCountIndexCache = nil
            pinnedSidebarFavoritesCache = nil
            listInputsVersion &+= 1
        }
    }
    /// id → index map, lazily rebuilt after any `assets` change (invalidated above).
    @ObservationIgnored private var assetIndexCache: [String: Int]?
    private var assetIndex: [String: Int] {
        _ = listInputsVersion   // register the dependency even on a cache hit
        if let cache = assetIndexCache { return cache }
        var map = [String: Int](minimumCapacity: assets.count)
        for (i, a) in assets.enumerated() { map[a.id] = i }
        assetIndexCache = map
        return map
    }
    var albums: [Album] {
        didSet {
            sidebarCountIndexCache = nil
            pinnedSidebarFavoritesCache = nil
            listInputsVersion &+= 1
        }
    }
    var smartAlbums: [SmartAlbum] {
        didSet {
            sidebarCountIndexCache = nil
            pinnedSidebarFavoritesCache = nil
            listInputsVersion &+= 1
        }
    }
    var folders: [Folder] = DemoData.folders {
        didSet {
            folderTreeCache = nil
            folderTreeCountCache = nil
            pinnedSidebarFavoritesCache = nil
            listInputsVersion &+= 1
        }
    }
    var importing = false
    var importRun: ImportRun?
    var duplicateGroupsCache: [DuplicateGroup] = DemoData.duplicateGroups {
        didSet { photoStacksCache = nil; stackByAssetCache = nil; listInputsVersion &+= 1 }
    }
    private var collapsedStackIds: Set<String> = []
    @ObservationIgnored private var photoStacksCache: [PhotoStack]?
    @ObservationIgnored private var stackByAssetCache: [String: PhotoStack]?
    @ObservationIgnored private var keywordListCache: [KeywordCount]?
    @ObservationIgnored private var keywordSuggestionPoolCache: [String]?
    @ObservationIgnored private var projectListCache: [KeywordCount]?
    @ObservationIgnored private var clientListCache: [KeywordCount]?
    @ObservationIgnored private var folderTreeCache: [FolderTreeItem]?
    @ObservationIgnored private var folderTreeCountCache: [String: Int]?
    @ObservationIgnored private var libraryCountsCache: LibraryCounts?
    @ObservationIgnored private var sidebarCountIndexCache: SidebarCountIndex?
    private struct SidebarCountIndex {
        var folderCounts: [String: Int] = [:]
        var albumCounts: [String: Int] = [:]
        var keywordCounts: [String: Int] = [:]
        var projectCounts: [String: Int] = [:]
        var clientCounts: [String: Int] = [:]
        var smartAlbumCounts: [String: Int] = [:]
    }
    struct LibraryCounts: Equatable {
        var all = 0, recent = 0, unrated = 0, picks = 0, rejected = 0, missingOffline = 0, places = 0, people = 0
    }
    /// Bumped whenever an array input to `list` changes (assets/albums/smartAlbums/folders/
    /// source roots/priorities/duplicate groups); the small value inputs are compared directly.
    private var listInputsVersion = 0   // tracked: cached getters read it so cache HITS register deps
    var assetRenderVersion = 0
    var thumbnailCacheGeneration = 0
    @ObservationIgnored private var listCache: (signature: ListSignature, value: [Asset])?
    @ObservationIgnored private var automaticXMPWriter = AutomaticXMPWriter()
    @ObservationIgnored private var automaticXMPWriteSequence: UInt64 = 0
    private struct ListSignature: Equatable {
        let inputsVersion: Int
        let selection: Selection
        let filters: Filters
        let search: String
        let sort: Sort
        let collapsed: Set<String>
        let recentDays: Int
    }

    private func replaceAssetsForMutation(_ updated: [Asset]) {
        assets = updated
        assetRenderVersion &+= 1
        // Force views that render derived asset snapshots to re-read the current selection.
        let currentPrimary = primaryId
        primaryId = currentPrimary
    }

    // ----- settings (PRD §17) -----
    var importMode: ImportMode =
        ImportMode(rawValue: UserDefaults.standard.string(forKey: "pc_importMode") ?? "") ?? .referenced {
        didSet { UserDefaults.standard.set(importMode.rawValue, forKey: "pc_importMode") }
    }
    var managedArchiveRule: ManagedArchiveRule =
        ManagedArchiveRule(rawValue: UserDefaults.standard.string(forKey: "pc_managedArchive") ?? "") ?? .date {
        didSet { UserDefaults.standard.set(managedArchiveRule.rawValue, forKey: "pc_managedArchive") }
    }
    var importDuplicateStrategy: ImportDuplicateStrategy =
        ImportDuplicateStrategy(rawValue: UserDefaults.standard.string(forKey: "pc_importDuplicateStrategy") ?? "")
            ?? .groupExact {
        didSet {
            UserDefaults.standard.set(importDuplicateStrategy.rawValue, forKey: "pc_importDuplicateStrategy")
        }
    }
    var importPostKeywords = UserDefaults.standard.string(forKey: "pc_importPostKeywords") ?? "" {
        didSet { UserDefaults.standard.set(importPostKeywords, forKey: "pc_importPostKeywords") }
    }
    var importPostColorLabel = UserDefaults.standard.string(forKey: "pc_importPostColorLabel") ?? "" {
        didSet { UserDefaults.standard.set(importPostColorLabel, forKey: "pc_importPostColorLabel") }
    }
    var importPostAlbumName = UserDefaults.standard.string(forKey: "pc_importPostAlbumName") ?? "" {
        didSet { UserDefaults.standard.set(importPostAlbumName, forKey: "pc_importPostAlbumName") }
    }
    var exportWritesXMP = UserDefaults.standard.bool(forKey: "pc_exportXMP") {
        didSet { UserDefaults.standard.set(exportWritesXMP, forKey: "pc_exportXMP") }
    }
    var readXMPSidecar: Bool = (UserDefaults.standard.object(forKey: "pc_readXMP") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(readXMPSidecar, forKey: "pc_readXMP") }
    }
    var autoWriteXMPSidecar = UserDefaults.standard.bool(forKey: "pc_autoWriteXMP") {
        didSet { UserDefaults.standard.set(autoWriteXMPSidecar, forKey: "pc_autoWriteXMP") }
    }
    var exportDirectoryStructure: ExportDirectoryStructure =
        ExportDirectoryStructure(rawValue: UserDefaults.standard.string(forKey: "pc_exportDirectoryStructure") ?? "")
            ?? .flat {
        didSet {
            UserDefaults.standard.set(exportDirectoryStructure.rawValue, forKey: "pc_exportDirectoryStructure")
        }
    }
    var exportPresets: [ExportPreset] = AppState.loadExportPresets() {
        didSet { AppState.saveExportPresets(exportPresets) }
    }
    var recentImportDays: Int = (UserDefaults.standard.object(forKey: "pc_recentDays") as? Int) ?? 14 {
        didSet { UserDefaults.standard.set(recentImportDays, forKey: "pc_recentDays"); libraryCountsCache = nil }
    }
    var openLastCatalogOnLaunch: Bool =
        (UserDefaults.standard.object(forKey: "pc_openLast") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(openLastCatalogOnLaunch, forKey: "pc_openLast") }
    }
    var reduceBackgroundOnLowPower: Bool =
        (UserDefaults.standard.object(forKey: "pc_lowPower") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(reduceBackgroundOnLowPower, forKey: "pc_lowPower") }
    }

    var recentCutoff: Date { Date().addingTimeInterval(-86400 * Double(max(1, recentImportDays))) }
    var visionEnabled = UserDefaults.standard.bool(forKey: "pc_vision") {
        didSet { UserDefaults.standard.set(visionEnabled, forKey: "pc_vision") }
    }
    var cacheLimitMB: Int = {
        let saved = UserDefaults.standard.integer(forKey: "pc_cacheLimitMB")
        return saved > 0 ? saved : 2_048
    }() {
        didSet { UserDefaults.standard.set(cacheLimitMB, forKey: "pc_cacheLimitMB") }
    }
    var previewMaxPixel: Int = {
        let saved = UserDefaults.standard.integer(forKey: "pc_previewMaxPixel")
        return saved == 1600 ? 1600 : 2_048
    }() {
        didSet { UserDefaults.standard.set(previewMaxPixel, forKey: Self.previewMaxPixelKey) }
    }
    private var automaticBackupFrequencyStorage = AppState.normalizedAutomaticBackupFrequency(
        UserDefaults.standard.string(forKey: "pc_autoBackupFrequency") ?? "weekly"
    )
    var automaticBackupFrequency: String {
        get { automaticBackupFrequencyStorage }
        set {
            automaticBackupFrequencyStorage = Self.normalizedAutomaticBackupFrequency(newValue)
            UserDefaults.standard.set(automaticBackupFrequencyStorage, forKey: "pc_autoBackupFrequency")
        }
    }
    var healthReport: HealthReport?
    private var statusMetrics = StatusMetrics()
    private var recentCatalogPaths =
        UserDefaults.standard.stringArray(forKey: "pc_recentCatalogs") ?? []

    // ----- catalog (real persistence / scanning) -----
    private var store: CatalogStore?
    private var coordinator: ImportCoordinator?
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var watchedRoots: [URL] = []
    @ObservationIgnored private var securityScopedRoots: [URL] = []
    @ObservationIgnored private var sourceRootPathsById: [String: String] = [:] {
        didSet {
            folderTreeCache = nil
            folderTreeCountCache = nil
            listInputsVersion &+= 1
        }
    }
    private var sourceManagementModesById: [String: String] = [:]
    @ObservationIgnored private var volumeMonitor: VolumeMonitor?
    @ObservationIgnored private var availabilityScanTask: Task<Void, Never>?
    @ObservationIgnored private var availabilityScanGeneration = 0
    private(set) var isCheckingOriginals = false
    @ObservationIgnored private var lastImportSessionPersistedCount = 0
    @ObservationIgnored private var importControl: ImportControl?
    @ObservationIgnored private var activeImportJobId: String?
    @ObservationIgnored private var launchCatalogHandled = false
    @ObservationIgnored var confirmDestructiveAction = AppState.confirmDestructiveAction
    private static let catalogURLKey = "pc_catalogURL"
    private static let recentCatalogsKey = "pc_recentCatalogs"
    private static let lastAutoBackupKey = "pc_lastAutoBackupAt"
    private static let pinnedSidebarItemsKey = "pc_pinnedSidebarItems"
    private static let sourcePrioritiesKey = "pc_sourcePriorities"
    private static let previewMaxPixelKey = "pc_previewMaxPixel"

    private static func normalizedAutomaticBackupFrequency(_ value: String) -> String {
        ["off", "daily", "weekly"].contains(value) ? value : "weekly"
    }

    // ----- selection / view -----
    var selection = Selection(type: .lib, id: "all", name: "全部照片")
    var selectedIds: Set<String> = []
    var primaryId: String?
    var view: ViewMode = .grid
    var thumbSize: CGFloat = 168
    var showInspector = true
    var showInfo = true
    var insTab = "org"
    private var pinnedSidebarItems = AppState.loadPinnedSidebarItems() {
        didSet { pinnedSidebarFavoritesCache = nil }
    }
    private var sourcePriorities = AppState.loadSourcePriorities() {
        didSet { folderTreeCache = nil; listInputsVersion &+= 1 }
    }
    @ObservationIgnored private var anchorId: String?

    // ----- filters / sort -----
    var filters = Filters()
    var filterOpen = false
    var search = ""
    var sort = Sort()

    // ----- compare -----
    var compareIds: [String] = []
    var winner: String?

    // ----- sheets / toasts -----
    var sheet: String? {
        didSet {
            if sheet != "smart" { smartAlbumEditingID = nil }
        }
    }
    var smartAlbumEditingID: String?
    let toastCenter = ToastCenter()

    // ----- search focus signal (Cmd+F) -----
    var searchFocusToken = 0
    var searchBlurToken = 0
    func focusSearch() { searchFocusToken += 1 }
    func blurSearch() { searchBlurToken += 1 }

    func showSettings() { sheet = "settings" }

    func showNewSmartAlbumBuilder() {
        smartAlbumEditingID = nil
        sheet = "smart"
    }

    func toggleFilterBar() {
        filterOpen.toggle()
        push(filterOpen ? "已显示筛选栏" : "已隐藏筛选栏", "filter")
    }

    func toggleGridInfo() {
        showInfo.toggle()
        push(showInfo ? "已显示缩略图信息" : "已隐藏缩略图信息", showInfo ? "info" : "eye")
    }

    func adjustThumbnailSize(by delta: CGFloat) {
        let next = min(280, max(108, thumbSize + delta))
        guard next != thumbSize else { return }
        thumbSize = next
    }

    func resetThumbnailSize() {
        thumbSize = 168
    }

    @discardableResult
    func dismissTransientUI() -> Bool {
        if sheet != nil {
            sheet = nil
            smartAlbumEditingID = nil
            return true
        }
        if filterOpen {
            filterOpen = false
            return true
        }
        if view != .grid {
            view = .grid
            return true
        }
        return false
    }

    init(arguments: [String] = CommandLine.arguments) {
        let a = DemoData.assets
        assets = a
        albums = DemoData.initialAlbums(a)
        smartAlbums = DemoData.initialSmartAlbums(a)
        if onboarded, let launchURL = Self.launchCatalogURL(from: arguments) {
            launchCatalogHandled = true
            if !openCatalog(at: launchURL), store == nil, openLastCatalogOnLaunch,
               let error = loadExistingCatalog() {
                push(catalogOpenFailureMessage(error), "warning")
            }
        } else if onboarded && openLastCatalogOnLaunch, let error = loadExistingCatalog() {
            push(catalogOpenFailureMessage(error), "warning")
        }
        if onboarded && store == nil {
            UserDefaults.standard.set("0", forKey: "pc_onboarded")
            onboarded = false
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
    var hasOpenCatalog: Bool { store != nil }
    var canRunCatalogMaintenance: Bool { hasOpenCatalog && !importing }

    var catalogPath: String {
        store?.packageURL.path ?? "未打开目录库"
    }

    var catalogDisplayName: String {
        store?.packageURL.deletingPathExtension().lastPathComponent ?? "PhotoCatalog"
    }

    var recentCatalogs: [RecentCatalog] {
        recentCatalogPaths
            .filter { Self.isValidCatalogSelection(URL(fileURLWithPath: $0)) }
            .map { RecentCatalog(path: $0) }
    }

    var statusAssetCount: Int { libraryCounts.all }

    var catalogManagementText: String {
        let real = assets.filter { !$0.deleted && !$0.isDemo }
        if real.isEmpty {
            return importMode == .managed
                ? "托管式管理 · 原件在目录库"
                : "引用式管理 · 原件只读"
        }
        let modes = Set(real.map { managementMode(for: $0) })
        if modes == Set([ImportMode.managed]) { return "托管式管理 · 原件在目录库" }
        if modes.contains(.managed) { return "混合管理 · 原件只读" }
        return "引用式管理 · 原件只读"
    }

    var statusCacheText: String {
        guard let cacheBytes = statusMetrics.cacheBytes else { return "缓存 --" }
        if cacheBytes == 0 { return "缓存 0 KB" }
        return "缓存 " + ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file)
    }

    var statusBackupText: String {
        guard let date = statusMetrics.lastBackupDate else { return "尚未备份" }
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        if Calendar.current.isDateInToday(date) {
            return "上次备份 今天 \(time)"
        }
        if Calendar.current.isDateInYesterday(date) {
            return "上次备份 昨天 \(time)"
        }
        let day = date.formatted(.dateTime.month(.twoDigits).day(.twoDigits))
        return "上次备份 \(day) \(time)"
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
        refreshStatusMetrics()
        let real = ((try? s.loadAssets()) ?? []).filter { !$0.isDemo && !$0.deleted }
        let hasInterruptedImport = (try? s.loadJobs(type: "scan", states: ["running", "paused"]).isEmpty) == false
        guard !real.isEmpty else {
            assets = []
            albums = []
            smartAlbums = []
            folders = []
            duplicateGroupsCache = []
            restoreSourceRoots(from: s)
            restoreAlbums(from: s, assets: [])
            if hasInterruptedImport {
                recoverInterruptedImportJobs(existingAssets: [])
            }
            ensurePrimaryValid()
            return nil
        }

        assets = []
        albums = []
        smartAlbums = []
        folders = []
        restoreSourceRoots(from: s)

        let sourceRootsById = sourceRootRecordsById(from: s)
        let repaired = repairSourceRootOwnership(real, sourceRootsById: sourceRootsById)
        let checked = repaired.assets
        if !repaired.changed.isEmpty { try? s.upsert(repaired.changed) }
        assets = checked
        for (fid, items) in Dictionary(grouping: checked, by: { $0.folderId }) where
            !folders.contains(where: { $0.id == fid }) {
            folders.append(Folder(id: fid, name: items.first?.folderName ?? fid,
                                  status: folderStatus(for: fid, in: checked)))
        }
        for index in folders.indices where
            sourceManagementModesById[folders[index].id] == ImportMode.managed.rawValue {
            let status = folderStatus(for: folders[index].id, in: checked)
            folders[index].status = status
            try? s.updateSourceRootStatus(id: folders[index].id, status: status)
        }
        recomputeDuplicates()
        restoreAlbums(from: s, assets: checked)
        recoverInterruptedImportJobs(existingAssets: checked)
        ensurePrimaryValid()
        backfillThumbnails()
        detectMissingRealAssets()
        refreshStatusMetrics()
        return nil
    }

    private func restoreAlbums(from store: CatalogStore, assets: [Asset]) {
        albums = (try? store.loadAlbums()) ?? []
        let loadedSmartAlbums = (try? store.loadSmartAlbums()) ?? []
        smartAlbums = loadedSmartAlbums.map { album in
            SmartAlbum(id: album.id, name: album.name, rule: album.rule,
                       count: SmartMatcher.count(assets, album.rule))
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

            sourceManagementModesById[root.id] = root.managementMode
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
        if root.managementMode == ImportMode.managed.rawValue {
            return (nil, "online")
        }
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

    private func repairSourceRootOwnership(_ loaded: [Asset],
                                           sourceRootsById: [String: SourceRootRecord])
    -> (assets: [Asset], changed: [Asset]) {
        let validSourceIds = Set(sourceRootsById.keys)
        guard !validSourceIds.isEmpty else { return (loaded, []) }

        let roots = sourceRootsById.values.map { root in
            (id: root.id,
             name: root.displayName,
             path: URL(fileURLWithPath: sourceRootPathsById[root.id] ?? root.pathHint).standardizedFileURL.path)
        }.sorted { $0.path.count > $1.path.count }

        var updated = loaded
        var changed: [Asset] = []
        for index in updated.indices where !updated[index].isDemo && !validSourceIds.contains(updated[index].folderId) {
            guard let localPath = updated[index].localPath else { continue }
            let assetPath = URL(fileURLWithPath: localPath).standardizedFileURL.path
            guard let root = roots.first(where: { Self.path(assetPath, isIn: $0.path) }) else { continue }
            updated[index].folderId = root.id
            updated[index].folderName = root.name
            changed.append(updated[index])
        }
        return (updated, changed)
    }

    private static func path(_ path: String, isIn root: String) -> Bool {
        let root = root.hasSuffix("/") && root.count > 1 ? String(root.dropLast()) : root
        return path == root || path.hasPrefix(root + "/")
    }

    private func setSourceFolder(id: String, name: String, path: String, status: String) {
        sourceRootPathsById[id] = path
        if let index = folders.firstIndex(where: { $0.id == id }) {
            folders[index] = Folder(id: id, name: name, status: status)
        } else {
            folders.append(Folder(id: id, name: name, status: status))
        }
    }

    private func openOrCreateCatalog() {
        guard store == nil else { return }
        do {
            let s = try CatalogStore(packageURL: configuredCatalogURL)
            store = s
            coordinator = ImportCoordinator(store: s)
            refreshStatusMetrics()
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
        createCatalog(at: selected)
    }

    @discardableResult
    func createCatalog(at selected: URL) -> Bool {
        guard !importing else {
            push("导入中无法切换目录库", "warning")
            return false
        }
        let url = Self.catalogPackageURL(for: selected)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            push("目录库已存在，请选择其他名称", "warning")
            return false
        }

        do {
            closeCurrentCatalog()
            resetToEmptyCatalog()
            let nextStore = try CatalogStore(packageURL: url)
            store = nextStore
            coordinator = ImportCoordinator(store: nextStore)
            setActiveCatalog(url)
            refreshStatusMetrics()
            UserDefaults.standard.set("1", forKey: "pc_onboarded")
            onboarded = true
            push("已创建目录库 · \(url.lastPathComponent)", "check")
            return true
        } catch {
            resetToDemoCatalog()
            loadExistingCatalog()
            push(catalogOpenFailureMessage(error, fallback: "创建目录库失败"), "warning")
            return false
        }
    }

    func openCatalog() {
        guard !importing else {
            push("导入中无法切换目录库", "warning")
            return
        }
        let panel = NSOpenPanel()
        configureCatalogOpenPanel(panel)
        let panelDelegate = CatalogOpenPanelDelegate()
        panel.delegate = panelDelegate
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        openCatalog(at: selected)
    }

    func closeCatalog() {
        guard !importing else {
            push("导入中无法关闭目录库", "warning")
            return
        }
        guard hasOpenCatalog else { return }

        closeCurrentCatalog()
        search = ""
        filters = Filters()
        filterOpen = false
        view = .grid
        sheet = nil
        resetToDemoCatalog()
        UserDefaults.standard.removeObject(forKey: Self.catalogURLKey)
        UserDefaults.standard.set("0", forKey: "pc_onboarded")
        onboarded = false
        push("已关闭目录库", "check")
    }

    func configureCatalogOpenPanel(_ panel: NSOpenPanel) {
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "打开"
        panel.message = "选择 .photolibrary 目录库"
        if let libraryType = UTType(filenameExtension: "photolibrary") {
            panel.allowedContentTypes = [libraryType]
        }
    }

    @discardableResult
    func openCatalog(at selected: URL) -> Bool {
        guard !importing else {
            push("导入中无法切换目录库", "warning")
            return false
        }

        let url = Self.catalogPackageURL(for: selected)
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

    func confirmClearRecentCatalogs() {
        guard confirmDestructiveAction("清除最近目录库？", "只会清除本机最近打开列表，不会删除目录库文件。", "清除") else { return }
        clearRecentCatalogs()
    }

    private func catalogOpenFailureMessage(_ error: Error?, fallback: String = "打开目录库失败") -> String {
        if let error = error as? CatalogStoreError,
           case let .incompatibleSchema(current, supported) = error {
            return "目录库版本过新（schema \(current)，当前支持 \(supported)），请升级 PhotoCatalog 后再打开"
        }
        return fallback
    }

    nonisolated static func isValidCatalogSelection(_ selected: URL) -> Bool {
        let url = catalogPackageURL(for: selected)
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("catalog.sqlite").path)
    }

    private nonisolated static func catalogPackageURL(for url: URL) -> URL {
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
        // referenced assets already in this source folder can be reused on a re-import instead
        // of being re-read/re-thumbnailed/re-Vision'd (process() skips by id)
        let knownAssetsById = Dictionary(
            assets.filter { !$0.deleted && !$0.isDemo && $0.folderId == sourceId }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
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
        cancelBackfill()  // let the import generate thumbnails without a background pass contending
        importing = true
        sheet = "import"
        try? store.startImportSession(id: run.id.uuidString, startedAt: run.startedAt)
        try? store.startImportJob(id: jobId, sessionId: run.id.uuidString, sourcePath: folder.path,
                                  mode: mode, autoTag: vision, archiveRule: archiveRule,
                                  readSidecar: readXMP, previewMaxPixel: previewSize)
        push("正在导入「\(folder.lastPathComponent)」…", "importIcon")
        let bookmark = FileAccessService.createBookmark(for: folder)
        Task { [weak self, coordinator, store, folder, mode, vision, previewSize, archiveRule, readXMP, bookmark, existingIds, sourceId, run, control, knownAssetsById] in
            let imported = await Task.detached(priority: .userInitiated) { [coordinator, folder, mode, vision, previewSize, archiveRule, readXMP, control, knownAssetsById] in
                coordinator.importFolder(folder, mode: mode, autoTag: vision, archiveRule: archiveRule,
                                         readSidecar: readXMP, previewMaxPixel: previewSize, control: control,
                                         knownAssetsById: knownAssetsById) { progress in
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

    // O(1) failure-dedup state: the set of failure ids already recorded for the current run
    @ObservationIgnored private var failureSeenIds: (runId: UUID?, ids: Set<String>) = (nil, [])
    // Progress events arrive once per file; accumulate here and publish to the
    // observed importRun at most every ~100 ms — each publish redraws every
    // observing view, so per-file publishing stalls the UI on fast imports.
    @ObservationIgnored private var pendingImportRun: ImportRun?
    @ObservationIgnored private var lastImportRunFlush: ContinuousClock.Instant?

    private func recordImportProgress(_ progress: ImportProgress, for runId: UUID) {
        guard let live = importRun, live.id == runId, live.phase.isActive else { return }
        var run = (pendingImportRun?.id == runId ? pendingImportRun : nil) ?? live
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
        if let failure = progress.latestFailure {
            // rebuild the seen-id set once when the run changes, then dedup in O(1) per event
            // instead of an O(n) scan of run.failures on every failed file
            if failureSeenIds.runId != run.id {
                failureSeenIds = (run.id, Set(run.failures.map(\.id)))
            }
            if failureSeenIds.ids.insert(failure.id).inserted {
                run.failures.append(failure)
            }
        }
        pendingImportRun = run
        persistImportSessionProgress(run)
        let due = lastImportRunFlush.map { ContinuousClock.now - $0 >= .milliseconds(100) } ?? true
        let final = progress.total > 0 && progress.processed + progress.failed >= progress.total
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

    private func finishImport(folder: URL, imported: [Asset], existingIds: Set<String>, store: CatalogStore,
                              bookmark: Data?, mode: ImportMode, runId: UUID, sourceId: String? = nil,
                              persistSourceRoot: Bool) {
        flushPendingImportRun()  // adopt any progress still waiting on the 100 ms window
        let dedup = ImportDeduplicationService.apply(
            imported: imported,
            existingAssets: assets.filter { !$0.deleted && !$0.isDemo },
            existingIds: existingIds,
            strategy: importDuplicateStrategy)
        let fresh = applyPostImportMetadata(to: dedup.fresh)
        let skipped = dedup.skipped
        var persistFailed = false
        do {
            try store.upsert(fresh)
        } catch {
            persistFailed = true
        }
        if !fresh.isEmpty && !persistFailed {
            replaceAssetsForMutation(assets + fresh)
        }
        var rootId: String?
        if let fid = fresh.first?.folderId ?? imported.first?.folderId ?? sourceId {
            rootId = fid
            if persistFailed && skipped == 0 {
                folders.removeAll { $0.id == fid }
                sourceRootPathsById.removeValue(forKey: fid)
                sourceManagementModesById.removeValue(forKey: fid)
            } else {
                if persistSourceRoot && (!fresh.isEmpty || skipped > 0) {
                    try? store.addSourceRoot(id: fid, displayName: folder.lastPathComponent,
                                             path: folder.path, bookmark: bookmark, mode: mode,
                                             volumeIdentifier: VolumeMonitor.volumeIdentifier(for: folder))
                }
                sourceManagementModesById[fid] = mode.rawValue
                if fresh.isEmpty && skipped == 0 {
                    folders.removeAll { $0.id == fid }
                    sourceRootPathsById.removeValue(forKey: fid)
                    sourceManagementModesById.removeValue(forKey: fid)
                } else {
                    setSourceFolder(id: fid, name: folder.lastPathComponent, path: folder.path, status: "online")
                    select(Selection(type: .folder, id: fid, name: folder.lastPathComponent))
                }
            }
        }
        if !persistFailed, mode == .referenced, (!fresh.isEmpty || skipped > 0), !watchedRoots.contains(folder) {
            watchedRoots.append(folder)
            refreshWatcher()
        }

        if var run = importRun, run.id == runId {
            run.phase = persistFailed ? .failed : .complete
            run.total = max(run.total, imported.count + run.failed)
            run.processed = imported.count
            run.skipped = skipped
            run.finishedAt = .now
            let previewAssets = fresh.isEmpty ? imported : fresh
            run.recentAssets = Array(previewAssets.prefix(28))
            run.errorMessage = persistFailed
                ? [importFailureSummary(run.failures), "写入目录库失败"].compactMap { $0 }.joined(separator: " · ")
                : importFailureSummary(run.failures)
            importRun = run
            lastImportSessionPersistedCount = run.processed + run.failed
            try? store.updateImportSession(id: run.id.uuidString, rootId: rootId,
                                           state: persistFailed ? "failed" : "completed",
                                           totalCount: run.total, importedCount: run.imported,
                                           skippedCount: run.skipped, failedCount: run.failed,
                                           finishedAt: run.finishedAt, errorMessage: run.errorMessage)
        }

        importing = false
        importControl = nil
        if let activeImportJobId {
            try? store.updateJob(id: activeImportJobId, state: persistFailed ? "failed" : "succeeded",
                                 lockedAt: nil, lastError: importRun?.errorMessage)
            self.activeImportJobId = nil
        }
        if !persistFailed {
            applyPostImportAlbum(assetIds: fresh.map(\.id))
        }
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
        } else if persistFailed {
            message = "已导入 \(fresh.count) 张，但写入目录库失败，请重试"
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
        flushPendingImportRun()  // pause/resume must act on current counts
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
                               archiveRule: recoveredArchiveRule(payload),
                               readSidecar: payload.readSidecar ?? readXMPSidecar,
                               previewMaxPixel: payload.previewMaxPixel ?? previewMaxPixel,
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
                               archiveRule: recoveredArchiveRule(payload),
                               readSidecar: payload.readSidecar ?? readXMPSidecar,
                               previewMaxPixel: payload.previewMaxPixel ?? previewMaxPixel,
                               existingIds: Set(assets.map { $0.id }))
    }

    private func restartRecoveredImport(jobId: String, run: ImportRun, folder: URL, mode: ImportMode,
                                        autoTag: Bool, archiveRule: ManagedArchiveRule,
                                        readSidecar: Bool, previewMaxPixel: Int,
                                        existingIds: Set<String>) {
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
        // skip re-processing originals already cataloged before the crash (referenced mode)
        let knownAssetsById = Dictionary(
            assets.filter { !$0.deleted && !$0.isDemo && $0.folderId == sourceId }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        importing = true
        sheet = "import"
        try? store.updateJob(id: jobId, state: "running")
        try? store.updateImportSession(id: runningRun.id.uuidString, state: "running",
                                       totalCount: runningRun.total, importedCount: runningRun.imported,
                                       skippedCount: runningRun.skipped, failedCount: runningRun.failed)
        push("正在恢复导入「\(folder.lastPathComponent)」…", "refresh")

        Task { [weak self, coordinator, store, folder, mode, autoTag, archiveRule, readSidecar, previewMaxPixel, existingIds, sourceId, runningRun, control, knownAssetsById] in
            let imported = await Task.detached(priority: .userInitiated) { [coordinator, folder, mode, autoTag, archiveRule, readSidecar, previewMaxPixel, control, knownAssetsById] in
                coordinator.importFolder(folder, mode: mode, autoTag: autoTag,
                                         archiveRule: archiveRule, readSidecar: readSidecar,
                                         previewMaxPixel: previewMaxPixel, control: control,
                                         knownAssetsById: knownAssetsById) { progress in
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

    private func recoveredArchiveRule(_ payload: ImportJobPayload) -> ManagedArchiveRule {
        payload.archiveRule.flatMap(ManagedArchiveRule.init(rawValue:)) ?? managedArchiveRule
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
        let archiveRule = managedArchiveRule
        let readXMP = readXMPSidecar
        importing = true
        try? store.startImportSession(id: retry.id.uuidString, startedAt: retry.startedAt)
        try? store.startImportJob(id: jobId, sessionId: retry.id.uuidString, sourcePath: folder.path,
                                  mode: retry.mode, autoTag: vision, archiveRule: archiveRule,
                                  readSidecar: readXMP, previewMaxPixel: previewSize)
        push("正在重试 \(files.count) 个失败文件…", "refresh")
        Task { [weak self, coordinator, store, folder, files, existingIds, retry, vision, archiveRule, readXMP, previewSize, control] in
            let imported = await Task.detached(priority: .userInitiated) { [coordinator, folder, files, retry, vision, archiveRule, readXMP, previewSize, control] in
                coordinator.importFiles(files, from: folder, mode: retry.mode, autoTag: vision,
                                        archiveRule: archiveRule, readSidecar: readXMP,
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
    @ObservationIgnored private var isIncrementalRescanning = false
    @ObservationIgnored private var needsIncrementalRescan = false
    @ObservationIgnored private var incrementalRescanGeneration = 0

    private func refreshWatcher() {
        watcher?.stop()
        let paths = prioritizedWatchedRoots(watchedRoots).map { $0.path }
        guard !paths.isEmpty else { watcher = nil; return }
        let w = FileWatcher(paths: paths) { [weak self] _ in self?.incrementalRescan() }
        w.start()
        watcher = w
    }

    func replaceWatchedSourceRoot(oldRootPath: String?, newRoot: URL) {
        let newPath = newRoot.standardizedFileURL.path
        if let oldRootPath, oldRootPath != newRoot.path {
            let oldPath = URL(fileURLWithPath: oldRootPath).standardizedFileURL.path
            watchedRoots.removeAll { $0.standardizedFileURL.path == oldPath }
        }
        if !watchedRoots.contains(where: { $0.standardizedFileURL.path == newPath }) {
            watchedRoots.append(newRoot)
        }
        refreshWatcher()
    }

    private func incrementalRescan() {
        guard let coordinator, let store else { return }
        if isIncrementalRescanning {
            needsIncrementalRescan = true
            return
        }
        isIncrementalRescanning = true
        incrementalRescanGeneration &+= 1
        let generation = incrementalRescanGeneration
        let roots = prioritizedWatchedRoots(watchedRoots)
        let liveAssets = assets.filter { !$0.deleted }
        let vision = visionEnabled
        let previewSize = previewMaxPixel
        let readXMP = readXMPSidecar
        let folderNamesById = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.name) })
        var sourceInfoByPath: [String: (id: String, name: String)] = [:]
        for (id, path) in sourceRootPathsById {
            let name = folderNamesById[id] ?? URL(fileURLWithPath: path).lastPathComponent
            for alias in PathIdentity.aliases(forPath: path) {
                sourceInfoByPath[alias] = (id, name)
            }
        }
        Task { [weak self, coordinator, store, roots, liveAssets, vision, previewSize, readXMP, sourceInfoByPath] in
            let delta = await Task.detached(priority: .utility) {
                // build the path index off the main thread (resolvingSymlinksInPath stats each asset)
                var knownAssetsByPath: [String: Asset] = [:]
                for asset in liveAssets {
                    if let path = asset.localPath {
                        for alias in PathIdentity.aliases(forPath: path) {
                            knownAssetsByPath[alias] = asset
                        }
                    }
                }
                let knownPaths = Set(knownAssetsByPath.keys)
                var fresh: [Asset] = []
                var changed: [Asset] = []
                for root in roots {
                    let sourceInfo = PathIdentity.aliases(for: root).lazy.compactMap { sourceInfoByPath[$0] }.first
                    fresh.append(contentsOf: coordinator.scanNew(in: root, knownPaths: knownPaths,
                                                                 mode: .referenced, autoTag: vision,
                                                                 readSidecar: readXMP,
                                                                 previewMaxPixel: previewSize,
                                                                 sourceRootId: sourceInfo?.id,
                                                                 folderName: sourceInfo?.name))
                    changed.append(contentsOf: coordinator.scanChanged(in: root,
                                                                       knownAssetsByPath: knownAssetsByPath,
                                                                       mode: .referenced,
                                                                       autoTag: vision,
                                                                       readSidecar: readXMP,
                                                                       previewMaxPixel: previewSize,
                                                                       sourceRootId: sourceInfo?.id,
                                                                       folderName: sourceInfo?.name))
                }
                return (fresh: fresh, changed: changed)
            }.value
            guard let self else { return }
            guard self.incrementalRescanGeneration == generation else { return }
            defer {
                self.isIncrementalRescanning = false
                if self.needsIncrementalRescan {
                    self.needsIncrementalRescan = false
                    self.incrementalRescan()
                }
            }
            var indexById = [String: Int](minimumCapacity: self.assets.count)
            for (i, a) in self.assets.enumerated() { indexById[a.id] = i }
            let trulyNew = delta.fresh.filter { indexById[$0.id] == nil }
            let changedAssets = delta.changed.filter { indexById[$0.id] != nil }
            if !trulyNew.isEmpty || !changedAssets.isEmpty {
                do {
                    try store.upsert(trulyNew + changedAssets)
                } catch {
                    self.push("重新扫描保存失败", "warning")
                    return
                }
                var updated = self.assets
                // appending leaves existing indices valid, so indexById stays correct for replacements
                updated.append(contentsOf: trulyNew)
                for asset in changedAssets {
                    if let index = indexById[asset.id] { updated[index] = asset }
                }
                self.replaceAssetsForMutation(updated)
                self.recomputeDuplicates()
                self.enforceCacheLimitIfNeeded()
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
        guard !importing else { push("导入中无法重新扫描", "warning"); return }
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
        guard let store else {
            isCheckingOriginals = false
            updateFolderStatusesFromAssets()
            return
        }

        availabilityScanTask?.cancel()
        availabilityScanGeneration &+= 1
        let generation = availabilityScanGeneration
        let packageURL = store.packageURL
        let snapshot = assets
        let sourceRootsById = sourceRootRecordsById(from: store)
        isCheckingOriginals = true

        availabilityScanTask = Task { [weak self, store, snapshot, sourceRootsById] in
            let worker = Task.detached(priority: .utility) { () -> ([AssetAvailabilityUpdate]?, Bool) in
                guard let changes = AssetAvailabilityService.changes(
                    in: snapshot,
                    sourceRootsById: sourceRootsById
                ) else { return (nil, true) }
                guard !Task.isCancelled else { return (nil, true) }
                do {
                    try store.updateAssetAvailability(changes)
                    return (changes, true)
                } catch {
                    return (changes, false)
                }
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }

            guard let self,
                  self.availabilityScanGeneration == generation,
                  self.store?.packageURL == packageURL else { return }
            self.availabilityScanTask = nil
            self.isCheckingOriginals = false
            guard let changes = result.0 else { return }
            guard result.1 else {
                self.push("缺失状态保存失败", "warning")
                return
            }

            let changesById = Dictionary(uniqueKeysWithValues: changes.map { ($0.assetId, $0) })
            var updated = self.assets
            var didChange = false
            for index in updated.indices {
                guard let change = changesById[updated[index].id] else { continue }
                if updated[index].status != change.status || updated[index].localPath != change.localPath {
                    updated[index].status = change.status
                    updated[index].localPath = change.localPath
                    didChange = true
                }
            }
            if didChange { self.replaceAssetsForMutation(updated) }
            self.updateFolderStatusesFromAssets()
        }
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
        guard mutate(ids, {
            $0.date = $0.date.addingTimeInterval(Double(totalMinutes) * 60)
            $0.captureDateSource = "手动调整"
        }) else { return }
        let absT = abs(totalMinutes)
        push("已调整 \(ids.count) 张拍摄时间 \(totalMinutes > 0 ? "+" : "-")\(absT / 60)时\(absT % 60)分", "clock")
    }

    /// Set an absolute capture time on the selection (§4.2 / META-008).
    func setCaptureDate(_ date: Date) {
        let ids = targetIds
        guard !ids.isEmpty else { return }
        guard mutate(ids, {
            $0.date = date
            $0.captureDateSource = "手动设置"
        }) else { return }
        push("已将 \(ids.count) 张拍摄时间设为指定时间", "clock")
    }

    // ---------- XMP sidecar write (§6.5 META-007) ----------
    func writeXMPForSelection() {
        let ids = targetIds
        let real = assets.filter { ids.contains($0.id) && hasExistingOriginal($0) }
        guard !real.isEmpty else { push("仅可为已导入照片写入 XMP", "warning"); return }
        var count = 0
        for a in real {
            guard let path = a.localPath else { continue }
            let url = XMPSidecar.sidecarURL(for: URL(fileURLWithPath: path))
            if XMPSidecar.write(a, to: url) { count += 1 }
        }
        let failures = real.count - count
        if failures > 0 {
            push("已写入 \(count) 个 · \(failures) 失败", "warning")
        } else {
            push("已写入 \(count) 个 XMP sidecar", "check")
        }
    }

    // ---------- batch rename (§4.2) ----------
    /// Rename selected originals from a token template ({seq}/{date}/{time}/{camera}/{original}).
    /// A plain prefix with no token becomes "<prefix>_{seq}".
    func batchRename(template rawTemplate: String) {
        let trimmed = rawTemplate.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let template = trimmed.contains("{") ? trimmed : "\(trimmed)_{seq}"
        let ids = targetIds
        let real = list.filter { ids.contains($0.id) && hasExistingOriginal($0) }
        guard !real.isEmpty else { push("仅可重命名已导入照片", "warning"); return }
        guard confirmDestructiveAction(
            "重命名原件？",
            "将重命名 \(real.count) 个磁盘原件，并更新目录库中的文件路径。",
            "重命名"
        ) else { return }
        let map = RenameService.renameWithTemplate(real, template: template)
        guard !map.isEmpty else {
            push("重命名失败", "warning")
            return
        }

        let changedIds = Set(map.keys)
        var updated = assets
        for index in updated.indices {
            guard let url = map[updated[index].id] else { continue }
            updated[index].filename = url.lastPathComponent
            updated[index].localPath = url.path
        }
        guard persist(changedIds, in: updated) else {
            let rolledBack = OriginalFileOperationService.rollBackMoves(map, originals: real)
            push("重命名未完成"
                 + (rolledBack > 0 ? " · 已回滚 \(rolledBack) 张照片" : " · 回滚失败")
                 + " · 目录库保存失败",
                 "warning")
            return
        }
        replaceAssetsForMutation(updated)
        let saved = map.count
        push("已重命名 \(saved) 张照片" + (saved < real.count ? " · \(real.count - saved) 失败" : ""),
             saved < real.count ? "warning" : "check")
    }

    var canOperateOnSelectedOriginals: Bool {
        selectedAssetsContainLocalOriginalReference
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
        guard let operationCatalogURL = store?.packageURL else {
            push("无目录库", "warning")
            return
        }
        guard confirmOriginalFileOperation(operation, count: real.count) else { return }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = operation == .move ? "移动到此处" : "复制到此处"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        Task { [weak self, operation, real, destination, operationCatalogURL] in
            let report = await Task.detached(priority: .userInitiated) {
                OriginalFileOperationService.perform(operation, assets: real, destination: destination)
            }.value
            guard let self else {
                if operation == .move {
                    _ = await Task.detached(priority: .userInitiated) {
                        OriginalFileOperationService.rollBackMoves(report.updatedLocations, originals: real)
                    }.value
                }
                return
            }
            let locationsSaved = operation != .move
                || report.moved == 0
                || self.applyMovedOriginalLocations(report.updatedLocations,
                                                    expectedCatalogURL: operationCatalogURL)
            let persistenceFailed = !locationsSaved
            let rolledBack = persistenceFailed && operation == .move
                ? await Task.detached(priority: .userInitiated) {
                    OriginalFileOperationService.rollBackMoves(report.updatedLocations, originals: real)
                }.value
                : 0
            self.pushOriginalFileOperationReport(report, operation: operation,
                                                 persistenceFailed: persistenceFailed,
                                                 rolledBack: rolledBack)
        }
    }

    private func selectedRealAssetsWithOriginals() -> [Asset] {
        let ids = targetIds
        return assets.filter { asset in
            ids.contains(asset.id) && hasExistingOriginal(asset)
        }
    }

    private func hasExistingOriginal(_ asset: Asset) -> Bool {
        guard !asset.deleted, !asset.isDemo, let path = asset.localPath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    private func selectedAssetsWithExportablePreviews() -> [Asset] {
        let ids = targetIds
        let fm = FileManager.default
        return assets.filter { asset in
            guard ids.contains(asset.id), !asset.deleted, !asset.isDemo else { return false }
            for path in [asset.preview, asset.thumb] where !path.isEmpty && !path.hasPrefix("http") {
                if fm.fileExists(atPath: path) { return true }
            }
            if let path = asset.localPath, fm.fileExists(atPath: path) { return true }
            return false
        }
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

    @discardableResult
    func applyMovedOriginalLocations(_ locations: [String: URL], expectedCatalogURL: URL? = nil) -> Bool {
        guard !locations.isEmpty else { return true }
        if let expectedCatalogURL, store?.packageURL != expectedCatalogURL { return false }
        let ids = Set(locations.keys)
        var updated = assets
        for index in updated.indices {
            guard let url = locations[updated[index].id] else { continue }
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            updated[index].filename = url.lastPathComponent
            updated[index].localPath = url.path
            updated[index].fileModifiedAt = attrs?[.modificationDate] as? Date
            updated[index].fileCreatedAt = attrs?[.creationDate] as? Date
            updated[index].status = .ready
        }
        guard persist(ids, in: updated) else { return false }
        replaceAssetsForMutation(updated)
        return true
    }

    private func pushOriginalFileOperationReport(_ report: OriginalFileOperationReport,
                                                 operation: OriginalFileOperation,
                                                 persistenceFailed: Bool = false,
                                                 rolledBack: Int = 0) {
        if operation == .move, persistenceFailed {
            push("移动未完成"
                 + (rolledBack > 0 ? " · 已回滚 \(rolledBack) 个原件" : " · 回滚失败")
                 + " · 目录库保存失败",
                 "warning")
            return
        }
        let completed = operation == .move ? report.moved : report.copied
        let verb = operation == .move ? "移动" : "复制"
        push("已\(verb) \(completed) 个原件"
             + (report.failed > 0 ? " · \(report.failed) 失败" : "")
             + (report.skipped > 0 ? " · \(report.skipped) 跳过" : "")
             + (persistenceFailed ? " · 目录库保存失败" : ""),
             report.failed > 0 || persistenceFailed ? "warning" : "check")
    }

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
            self.push(report.summary, report.isHealthy ? "check" : "warning")
        }
    }

    private func applyHealthReport(_ report: HealthReport) {
        healthReport = report
        statusMetrics = StatusMetrics(cacheBytes: report.cacheBytes,
                                      lastBackupDate: statusMetrics.lastBackupDate,
                                      backupCount: report.backupCount)
    }

    private func refreshStatusMetrics() {
        guard let store else {
            statusMetrics = StatusMetrics()
            return
        }
        let packageURL = store.packageURL
        Task { [weak self, store, packageURL] in
            let metrics = await Task.detached(priority: .utility) {
                let backups = BackupService.listBackups(store)
                let lastBackupDate = backups.first.flatMap {
                    try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                }
                return StatusMetrics(cacheBytes: CatalogHealth.directorySize(store.cacheURL),
                                     lastBackupDate: lastBackupDate,
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

    @ObservationIgnored private var isBackfilling = false
    @ObservationIgnored private var backfillTask: Task<Void, Never>?
    @ObservationIgnored private var backfillGeneration = 0

    /// Stop any in-flight thumbnail backfill (e.g. when a fresh import is about to
    /// generate its own thumbnails, or the catalog is closing) so the two passes
    /// don't contend for disk I/O. Resets state eagerly so a subsequent
    /// backfillThumbnails() isn't blocked by the cancelled run's lingering flag, and
    /// bumps the generation so the orphaned task's cleanup can't clobber a newer run.
    func cancelBackfill() {
        backfillTask?.cancel()
        backfillTask = nil
        isBackfilling = false
        backfillGeneration &+= 1
    }

    /// Low-priority background pass that fills in any missing/stale thumbnails for
    /// imported photos (visible-first generation is handled per-cell). PRD §6.6 THM-003.
    ///
    /// Processed in small chunks so the pass stays cooperative: it yields between
    /// chunks, honors cancellation, and re-checks Low Power Mode mid-run rather than
    /// only once at the start.
    func backfillThumbnails() {
        guard let coordinator, !isBackfilling else { return }
        // battery saver: skip background work under Low Power Mode (§17.5)
        if reduceBackgroundOnLowPower, ProcessInfo.processInfo.isLowPowerModeEnabled { return }
        let real = thumbnailMaintenanceAssets
        guard !real.isEmpty else { return }
        isBackfilling = true
        backfillGeneration &+= 1
        let generation = backfillGeneration
        let previewSize = previewMaxPixel
        let lowPowerSensitive = reduceBackgroundOnLowPower
        backfillTask = Task { [weak self, coordinator, real, previewSize] in
            // Let the initial window and visible thumbnails settle before
            // maintenance starts competing for disk and Image I/O.
            do { try await Task.sleep(for: .milliseconds(750)) } catch { return }
            let chunkSize = 8
            var index = 0
            while index < real.count {
                if Task.isCancelled { break }
                // re-check Low Power Mode between chunks — it can be toggled mid-run
                if lowPowerSensitive, ProcessInfo.processInfo.isLowPowerModeEnabled { break }
                let chunk = Array(real[index..<min(index + chunkSize, real.count)])
                let worker = Task.detached(priority: .background) {
                    for a in chunk {
                        guard !Task.isCancelled else { return }
                        guard let path = a.localPath,
                              FileManager.default.fileExists(atPath: path) else { continue }
                        let original = URL(fileURLWithPath: path)
                        _ = coordinator.thumbnails.ensureCached(
                            from: original, fallbackPreview: nil,
                            catalogModificationDate: a.fileModifiedAt, assetId: a.id, kind: .thumb512)
                        _ = coordinator.thumbnails.ensureCached(
                            from: original, fallbackPreview: nil,
                            catalogModificationDate: a.fileModifiedAt, assetId: a.id,
                            kind: ThumbnailService.previewKind(forCachePath: a.preview, fallbackMaxPixel: previewSize))
                    }
                }
                await withTaskCancellationHandler {
                    await worker.value
                } onCancel: {
                    worker.cancel()
                }
                index += chunkSize
                do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
            }
            // only reset shared state if we're still the current run — a cancel or a newer
            // backfill may have superseded us and must not have its state clobbered.
            guard let self, self.backfillGeneration == generation else { return }
            self.isBackfilling = false
            self.backfillTask = nil
            self.enforceCacheLimitIfNeeded()
        }
    }

    var thumbnailMaintenanceAssets: [Asset] {
        assets.filter {
            !$0.deleted && !$0.isDemo && $0.status == .ready && $0.localPath != nil
        }
    }

    /// Privacy: delete catalog log files (§17.6).
    func confirmClearLogs() {
        guard confirmDestructiveAction("清除日志？", "将删除当前目录库中的本地日志文件。", "清除") else { return }
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
        guard confirmDestructiveAction("清除安全书签？", "当前目录库的源文件夹下次访问时需要重新授权。", "清除") else { return }
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
        guard confirmDestructiveAction("清理缓存？", "将删除当前目录库的缩略图和预览缓存，可稍后重新生成。", "清理") else { return }
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
        thumbnailCacheGeneration &+= 1
    }

    private static func confirmDestructiveAction(title: String, message: String, confirmTitle: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "取消")
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
        let requestedExists = await Task.detached(priority: .userInitiated) {
            !requestedSource.isEmpty && FileManager.default.fileExists(atPath: requestedSource)
        }.value
        if requestedExists {
            let cached = URL(fileURLWithPath: requestedSource)
            let needsRegeneration = await Task.detached(priority: .userInitiated) {
                ThumbnailService.cacheIsStale(cache: cached, originalModificationDate: asset.fileModifiedAt)
                    || thumbnails.cachedRepresentationNeedsRegeneration(at: cached, original: original, kind: resolvedKind)
            }.value
            if !needsRegeneration {
                return requestedSource
            }
        }
        // Only touch a referenced original after the local cache is missing, stale, or damaged.
        let (originalExists, previewExists) = await Task.detached(priority: .userInitiated) {
            [localPath, preview = asset.preview] in
            let fm = FileManager.default
            return (fm.fileExists(atPath: localPath),
                    !preview.isEmpty && fm.fileExists(atPath: preview))
        }.value
        guard originalExists || previewExists else {
            return requestedSource
        }
        let restored = await Task.detached(priority: .userInitiated) {
            thumbnails.ensureCached(from: original,
                                    fallbackPreview: fallbackPreview,
                                    catalogModificationDate: asset.fileModifiedAt,
                                    assetId: assetId,
                                    kind: resolvedKind)
        }.value
        return restored?.path ?? requestedSource
    }

    func pruneCacheToLimit() {
        guard let store else { push("无目录库", "warning"); return }
        let packageURL = store.packageURL
        let snapshot = assets
        let maxBytes = cacheLimitBytes
        let limitMB = cacheLimitMB
        Task { [weak self, store, packageURL, snapshot, maxBytes, limitMB] in
            let result = await Task.detached(priority: .utility) {
                let report = CacheService.prune(store.cacheURL, maxBytes: maxBytes)
                return (report, CatalogHealth.check(store, assets: snapshot))
            }.value
            guard let self, self.store?.packageURL == packageURL else { return }
            self.applyHealthReport(result.1)
            if result.0.removedFiles == 0 {
                self.push("缓存已在 \(limitMB) MB 上限内", "check")
            } else {
                self.push("已清理缓存 \(self.formatCacheMB(result.0.removedBytes)) · \(result.0.removedFiles) 个文件", "trash")
            }
        }
    }

    private var cacheLimitBytes: Int64 {
        Int64(cacheLimitMB) * 1024 * 1024
    }

    private func enforceCacheLimitIfNeeded() {
        guard let store else { return }
        let packageURL = store.packageURL
        let snapshot = assets
        let maxBytes = cacheLimitBytes
        Task { [weak self, store, packageURL, snapshot, maxBytes] in
            let result = await Task.detached(priority: .utility) {
                let report = CacheService.prune(store.cacheURL, maxBytes: maxBytes)
                let health = report.removedFiles > 0 ? CatalogHealth.check(store, assets: snapshot) : nil
                let cacheBytes = health?.cacheBytes ?? CatalogHealth.directorySize(store.cacheURL)
                return (health, cacheBytes)
            }.value
            guard let self, self.store?.packageURL == packageURL else { return }
            if let report = result.0 {
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
    /// so deleting photos reclaims their cache instead of leaving orphans behind. Deletion is
    /// one-way (no un-delete), so this is safe to do eagerly.
    private func purgeCacheFiles<S: Sequence>(forAssetIds ids: S) where S.Element == String {
        guard let thumbnails = coordinator?.thumbnails else { return }
        let fm = FileManager.default
        let kinds: [ThumbnailService.Kind] = [.thumb256, .thumb512, .preview1600, .preview2048]
        for id in ids {
            for kind in kinds {
                try? fm.removeItem(at: thumbnails.cachePath(assetId: id, kind: kind))
            }
        }
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
        guard !ids.isEmpty else {
            push("请先选择照片", "warning")
            return
        }
        let selected = assets.filter { ids.contains($0.id) && !$0.deleted }
        let real = selectedRealAssetsWithOriginals()
        guard !real.isEmpty else {
            push(selected.allSatisfy(\.isDemo) ? "演示照片没有本地原件可导出" : "没有可导出的本地原件", "warning")
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
        let exportCatalogURL = store?.packageURL
        Task { [weak self, real, dest, xmp, directoryStructure,
                 albumNamesByAssetId, sourceRootPathsByFolderId, exportCatalogURL] in
            let result = await Task.detached(priority: .userInitiated) {
                let report = ExportService.copyOriginals(real, to: dest, xmp: xmp,
                                                         directoryStructure: directoryStructure,
                                                         albumNamesByAssetId: albumNamesByAssetId,
                                                         sourceRootPathsByFolderId: sourceRootPathsByFolderId)
                let jsonOK = ExportService.exportMetadataJSON(real, to: dest.appendingPathComponent("metadata.json"))
                let csvOK = ExportService.exportMetadataCSV(real, to: dest.appendingPathComponent("metadata.csv"))
                return (report: report, metadataOK: jsonOK && csvOK)
            }.value
            self?.finishOriginalExport(result, xmp: xmp, expectedCatalogURL: exportCatalogURL)
        }
    }

    @discardableResult
    func finishOriginalExport(_ result: (report: ExportReport, metadataOK: Bool),
                              xmp: Bool,
                              expectedCatalogURL: URL? = nil) -> Bool {
        if let expectedCatalogURL, store?.packageURL != expectedCatalogURL { return false }
        let xmpNote = xmp
            ? (result.report.xmpFailed > 0 ? " · \(result.report.xmpFailed) 个 XMP 失败" : " · 含 XMP")
            : ""
        push("已导出 \(result.report.copied) 张原件"
             + (result.report.failed > 0 ? " · \(result.report.failed) 失败" : "")
             + xmpNote
             + (result.metadataOK ? " · 含元数据" : " · 元数据失败"), "export")
        return true
    }

    func exportSelectionPreviews() {
        let selected = selectedAssetsWithExportablePreviews()
        guard !selected.isEmpty else {
            push(targetIds.isEmpty ? "请先选择照片" : "没有可导出的预览图", "warning")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "导出预览到此处"
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        let thumbnails = coordinator?.thumbnails
        let previewSize = previewMaxPixel
        let exportCatalogURL = store?.packageURL
        Task { [weak self, selected, dest, thumbnails, previewSize, exportCatalogURL] in
            let report = await Task.detached(priority: .userInitiated) {
                ExportService.exportPreviews(selected, to: dest,
                                             thumbnails: thumbnails,
                                             previewMaxPixel: previewSize)
            }.value
            self?.finishPreviewExport(report, expectedCatalogURL: exportCatalogURL)
        }
    }

    @discardableResult
    func finishPreviewExport(_ report: ExportReport, expectedCatalogURL: URL? = nil) -> Bool {
        if let expectedCatalogURL, store?.packageURL != expectedCatalogURL { return false }
        push("已导出 \(report.copied) 张预览图"
             + (report.failed > 0 ? " · \(report.failed) 失败" : "")
             + (report.skipped > 0 ? " · \(report.skipped) 跳过" : ""),
             report.failed > 0 ? "warning" : "export")
        return true
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
        guard !importing else { push("导入中无法备份目录库", "warning"); return }
        guard let store else { push("无目录库可备份", "warning"); return }
        let packageURL = store.packageURL
        let snapshot = assets.filter { !$0.isDemo }
        Task { [weak self, store, packageURL, snapshot] in
            let url = await Task.detached(priority: .utility) { () -> URL? in
                do {
                    try store.upsert(snapshot)
                    return try BackupService.backup(store)
                } catch {
                    return nil
                }
            }.value
            guard let self, self.store?.packageURL == packageURL else { return }
            if let url {
                self.refreshStatusMetrics()
                self.push("已备份目录库 · \(url.lastPathComponent)", "check")
            } else {
                self.push("备份失败", "warning")
            }
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

        let backupKey = Self.lastAutoBackupKey(for: store.packageURL)
        let last = UserDefaults.standard.object(forKey: backupKey) as? Date
        if let last, now.timeIntervalSince(last) < interval {
            return
        }

        let packageURL = store.packageURL
        let snapshot = assets.filter { !$0.isDemo }
        Task { [weak self, store, packageURL, snapshot, backupKey, now] in
            let url = await Task.detached(priority: .utility) { () -> URL? in
                do {
                    try store.upsert(snapshot)
                    return try BackupService.backup(store, at: now)
                } catch {
                    return nil
                }
            }.value
            guard let self, self.store?.packageURL == packageURL else { return }
            if let url {
                UserDefaults.standard.set(now, forKey: backupKey)
                self.refreshStatusMetrics()
                self.push("已自动备份目录库 · \(url.lastPathComponent)", "check")
            } else {
                self.push("自动备份失败", "warning")
            }
        }
    }

    private static func lastAutoBackupKey(for packageURL: URL) -> String {
        lastAutoBackupKey + "." + packageURL.standardizedFileURL.path
    }

    func restoreBackup() {
        // never replace the catalog file while an import task still holds the live connection
        guard !importing else { push("导入中无法恢复备份", "warning"); return }
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
        importing = false
        store = nil
        coordinator = nil
        statusMetrics = StatusMetrics()
    }

    private func resetToDemoCatalog() {
        duplicateRecomputeGeneration &+= 1
        let a = DemoData.assets
        assets = a
        albums = DemoData.initialAlbums(a)
        smartAlbums = DemoData.initialSmartAlbums(a)
        folders = DemoData.folders
        sourceRootPathsById = [:]
        sourceManagementModesById = [:]
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

    private func resetToEmptyCatalog() {
        duplicateRecomputeGeneration &+= 1
        assets = []
        albums = []
        smartAlbums = []
        folders = []
        sourceRootPathsById = [:]
        sourceManagementModesById = [:]
        duplicateGroupsCache = []
        selection = Selection(type: .lib, id: "all", name: "全部照片")
        primaryId = nil
        selectedIds = []
        anchorId = nil
        compareIds = []
        winner = nil
        importRun = nil
        healthReport = nil
    }

    // ---------- duplicate groups (§6.10): exact (content) + similar (perceptual) ----------
    var duplicateGroups: [DuplicateGroup] { duplicateGroupsCache }
    @ObservationIgnored private var duplicateRecomputeGeneration = 0

    /// Recompute duplicates off the main thread (dHash reads thumbnails from disk).
    func recomputeDuplicates() {
        duplicateRecomputeGeneration &+= 1
        let generation = duplicateRecomputeGeneration
        let live = assets.filter { !$0.isDemo && !$0.deleted }
        guard !live.isEmpty else {
            let demoLiveIds = Set(assets.filter { $0.isDemo && !$0.deleted }.map(\.id))
            duplicateGroupsCache = DemoData.duplicateGroups.filter { group in
                group.items.contains { demoLiveIds.contains($0.id) }
            }
            let validStackIds = Set(PhotoStackService.stacks(from: duplicateGroupsCache).map(\.id))
            collapsedStackIds.formIntersection(validStackIds)
            return
        }
        Task { [weak self, live] in
            let groups = await Task.detached(priority: .utility) {
                HashService.exactDuplicateGroups(live)
                    + HashService.suspectedDuplicateGroups(live)
                    + PerceptualHash.similarGroups(live)
            }.value
            guard let self else { return }
            guard self.duplicateRecomputeGeneration == generation else { return }
            self.duplicateGroupsCache = groups
            let validStackIds = Set(PhotoStackService.stacks(from: groups).map(\.id))
            self.collapsedStackIds.formIntersection(validStackIds)
        }
    }

    @discardableResult
    func resolveDuplicateGroup(_ group: DuplicateGroup, keepId: String?,
                               action: DuplicateResolutionAction) -> Bool {
        let resolvedKeepId = keepId ?? group.items.first?.id
        guard let resolvedKeepId, group.items.contains(where: { $0.id == resolvedKeepId }) else {
            push("重复文件处理失败", "warning")
            return false
        }
        guard group.items.contains(where: { !$0.isDemo }) else {
            push("演示重复组不可处理", "warning")
            return false
        }
        let count = group.items.filter { $0.id != resolvedKeepId && !$0.isDemo }.count
        switch action {
        case .removeFromCatalog:
            guard confirmDestructiveAction(
                "从目录库移除？",
                "将从目录库移除 \(count) 个重复照片记录，磁盘原件会保留。",
                "移除"
            ) else { return false }
        case .moveToTrash:
            guard confirmDestructiveAction(
                "移到废纸篓？",
                "将把 \(count) 个重复照片的磁盘原件移到废纸篓，并从目录库移除对应记录。",
                "移到废纸篓"
            ) else { return false }
        }

        var updated = assets
        let report = DuplicateResolutionService.resolve(group, keepId: resolvedKeepId, in: &updated, action: action)
        guard !report.removedIds.isEmpty else {
            push(report.failedCount > 0 ? "重复文件处理失败" : "没有可处理的重复文件", "warning")
            return false
        }

        guard persist(report.removedIds, in: updated) else {
            if action == .moveToTrash {
                let rolledBack = OriginalFileOperationService.rollBackTrash(report.trashedLocations)
                push("重复文件处理未完成"
                     + (rolledBack > 0 ? " · 已回滚 \(rolledBack) 个原件" : " · 回滚失败")
                     + " · 目录库保存失败",
                     "warning")
            }
            return false
        }
        replaceAssetsForMutation(updated)
        purgeCacheFiles(forAssetIds: report.removedIds)
        duplicateGroupsCache.removeAll { $0.id == group.id }
        recomputeDuplicates()
        ensurePrimaryValid()

        let actionText = action == .moveToTrash ? "移到废纸篓" : "从目录库移除"
        let failedText = report.failedCount > 0 ? " · \(report.failedCount) 失败" : ""
        push("已\(actionText) \(report.affectedCount) 张重复照片\(failedText)", "check")
        return report.failedCount == 0
    }

    @discardableResult
    private func persist(_ ids: Set<String>, in sourceAssets: [Asset]? = nil) -> Bool {
        let snapshot = sourceAssets ?? assets
        let changed = snapshot.filter { ids.contains($0.id) && !$0.isDemo }
        guard let store else { return true }
        if !changed.isEmpty {
            // this is the single funnel for every metadata edit and the soft-delete-on-trash;
            // a swallowed failure here desyncs the catalog from disk, so surface it (§16.2).
            do {
                try store.upsert(changed)
            } catch {
                push("保存失败，更改未写入目录库", "warning")
                return false
            }
        }
        enqueueAutomaticXMPWrite(changed)
        return true
    }

    private func enqueueAutomaticXMPWrite(_ changed: [Asset]) {
        guard autoWriteXMPSidecar, !changed.isEmpty else { return }
        automaticXMPWriteSequence &+= 1
        let sequence = automaticXMPWriteSequence
        let writer = automaticXMPWriter
        Task { [weak self, writer, changed, sequence] in
            let failures = await writer.write(changed, sequence: sequence)
            guard failures > 0 else { return }
            self?.push("\(failures) 个 XMP sidecar 写入失败", "warning")
        }
    }

    // ---------- toasts ----------
    func push(_ message: String, _ icon: String = "check") {
        toastCenter.push(message, icon)
    }

    // ---------- keyword sidebar list ----------
    var keywordList: [KeywordCount] {
        _ = listInputsVersion   // register the dependency even on a cache hit
        if let cache = keywordListCache { return cache }
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
        let result = order.map { KeywordCount(name: $0, count: counts[$0] ?? 0) }
            .sorted { $0.count > $1.count }   // Swift 5 sort is stable
            .prefix(8)
            .map { $0 }
        keywordListCache = result
        return result
    }

    var keywordSuggestionPool: [String] {
        _ = listInputsVersion   // register the dependency even on a cache hit
        if let cache = keywordSuggestionPoolCache { return cache }
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
        keywordSuggestionPoolCache = result
        return result
    }

    var projectList: [KeywordCount] {
        _ = listInputsVersion   // register the dependency even on a cache hit
        if let cache = projectListCache { return cache }
        let result = countMetadataValues(\.project)
        projectListCache = result
        return result
    }

    var clientList: [KeywordCount] {
        _ = listInputsVersion   // register the dependency even on a cache hit
        if let cache = clientListCache { return cache }
        let result = countMetadataValues(\.client)
        clientListCache = result
        return result
    }

    /// Library sidebar tallies in one pass, cached and invalidated on assets/recent-days change.
    var libraryCounts: LibraryCounts {
        _ = listInputsVersion   // register the dependency even on a cache hit
        _ = recentImportDays    // its didSet clears this cache without bumping the version
        if let cache = libraryCountsCache { return cache }
        var counts = LibraryCounts()
        let cutoff = recentCutoff
        for a in assets where !a.deleted {
            counts.all += 1
            if a.importedAt > cutoff { counts.recent += 1 }
            if a.rating == 0 && a.flag != .reject { counts.unrated += 1 }
            if a.flag == .pick { counts.picks += 1 }
            if a.flag == .reject { counts.rejected += 1 }
            if a.status == .missing || a.status == .offline { counts.missingOffline += 1 }
            if a.hasGPS { counts.places += 1 }
            if a.faces > 0 { counts.people += 1 }
        }
        libraryCountsCache = counts
        return counts
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

    // Cached like the other derived sidebar collections — resolving a pinned
    // keyword scans every asset, and Sidebar reads this on each render.
    @ObservationIgnored private var pinnedSidebarFavoritesCache: [PinnedSidebarItem]?
    var pinnedSidebarFavorites: [PinnedSidebarItem] {
        _ = listInputsVersion   // register the dependency even on a cache hit
        _ = pinnedSidebarItems  // its didSet clears this cache without bumping the version
        if let cache = pinnedSidebarFavoritesCache { return cache }
        let resolved = pinnedSidebarItems.compactMap(resolvePinnedSidebarItem)
        pinnedSidebarFavoritesCache = resolved
        return resolved
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
        _ = listInputsVersion   // register the dependency even on a cache hit
        if let cache = folderTreeCache { return cache }
        let tree = FolderTreeService.build(sourceFolders: orderedFolders, assets: assets,
                                           sourceRootPaths: sourceRootPathsById)
        folderTreeCache = tree
        return tree
    }

    private var folderTreeCounts: [String: Int] {
        _ = listInputsVersion   // register the dependency even on a cache hit
        if let cache = folderTreeCountCache { return cache }
        let items = folderTree
        let counts = FolderTreeService.counts(for: items, assets: assets)
        folderTreeCountCache = counts
        return counts
    }

    private var photoStacks: [PhotoStack] {
        _ = listInputsVersion   // register the dependency even on a cache hit
        if let cache = photoStacksCache { return cache }
        let stacks = PhotoStackService.stacks(from: duplicateGroupsCache)
        photoStacksCache = stacks
        return stacks
    }

    /// O(1) asset → stack lookup, rebuilt only when the stacks change (invalidated in didSet).
    private var stackByAsset: [String: PhotoStack] {
        _ = listInputsVersion   // register the dependency even on a cache hit
        if let cache = stackByAssetCache { return cache }
        var map: [String: PhotoStack] = [:]
        for stack in photoStacks { for id in stack.assetIds { map[id] = stack } }
        stackByAssetCache = map
        return map
    }

    func stackInfo(for asset: Asset) -> (count: Int, collapsed: Bool)? {
        guard let stack = stackByAsset[asset.id] else { return nil }
        return (stack.count, collapsedStackIds.contains(stack.id))
    }

    func toggleStack(containing assetId: String) {
        guard let stack = stackByAsset[assetId] else { return }
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
        folderTreeCounts[item.id] ?? 0
    }

    func managementDisplayText(for asset: Asset) -> String {
        switch managementMode(for: asset) {
        case .managed: return "托管式 (Managed)"
        case .referenced: return "引用式 (Referenced)"
        }
    }

    private func managementMode(for asset: Asset) -> ImportMode {
        ImportMode(rawValue: sourceManagementModesById[asset.folderId] ?? "") ?? .referenced
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
        let counts = sidebarCountIndex
        switch item.type {
        case .folder:
            return "\(counts.folderCounts[item.selectionId] ?? 0)"
        case .album:
            return "\(counts.albumCounts[item.selectionId] ?? 0)"
        case .smart:
            return "\(counts.smartAlbumCounts[item.selectionId] ?? 0)"
        case .keyword:
            return "\(counts.keywordCounts[item.selectionId] ?? 0)"
        case .project:
            return "\(counts.projectCounts[item.selectionId] ?? 0)"
        case .client:
            return "\(counts.clientCounts[item.selectionId] ?? 0)"
        case .lib:
            return ""
        }
    }

    func countForSmartAlbum(_ album: SmartAlbum) -> Int {
        sidebarCountIndex.smartAlbumCounts[album.id] ?? album.count
    }

    func countForAlbum(_ album: Album) -> Int {
        sidebarCountIndex.albumCounts[album.id] ?? 0
    }

    private var sidebarCountIndex: SidebarCountIndex {
        _ = listInputsVersion   // register the dependency even on a cache hit
        if let cache = sidebarCountIndexCache { return cache }
        let live = assets.filter { !$0.deleted }
        let liveIds = Set(live.map(\.id))
        var index = SidebarCountIndex()
        for asset in live {
            index.folderCounts[asset.folderId, default: 0] += 1
            for keyword in asset.keywords {
                index.keywordCounts[keyword, default: 0] += 1
            }
            if !asset.project.isEmpty {
                index.projectCounts[asset.project, default: 0] += 1
            }
            if !asset.client.isEmpty {
                index.clientCounts[asset.client, default: 0] += 1
            }
        }
        for album in smartAlbums {
            index.smartAlbumCounts[album.id] = SmartMatcher.count(live, album.rule)
        }
        for album in albums {
            index.albumCounts[album.id] = album.assetIds.filter { liveIds.contains($0) }.count
        }
        sidebarCountIndexCache = index
        return index
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
            let memberIds = Set(al.assetIds)
            return live.filter { memberIds.contains($0.id) }
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
                return live.filter(\.hasGPS)
            case "people":
                return live.filter { $0.faces > 0 }
            default:
                return live
            }
        }
    }

    // ---------- apply filter bar + search + sort ----------
    var list: [Asset] {
        let signature = ListSignature(inputsVersion: listInputsVersion, selection: selection,
                                      filters: filters, search: search, sort: sort,
                                      collapsed: collapsedStackIds, recentDays: recentImportDays)
        if let cache = listCache, cache.signature == signature { return cache.value }
        let value = computeList()
        listCache = (signature, value)
        return value
    }

    private func computeList() -> [Asset] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let indexedSearchIds: Set<String>? = if q.count >= 3, let store {
            Set(store.search(q))
        } else {
            nil
        }
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
                if !SmartMatcher.matchesDatePreset(a.date, filters.date) { return false }
            }
            if filters.gps == "yes" && !a.hasGPS { return false }
            if filters.gps == "no" && a.hasGPS { return false }
            if filters.status != "any" && a.status.rawValue != filters.status { return false }
            if !q.isEmpty {
                if let indexedSearchIds {
                    if !indexedSearchIds.contains(a.id) { return false }
                } else {
                    let haystack = ([a.filename, a.camera, a.lens, a.title, a.caption, a.location,
                                     a.project, a.client]
                        + a.keywords).joined(separator: " ")
                    if !haystack.localizedStandardContains(q) { return false }
                }
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

    var primary: Asset? {
        _ = listInputsVersion
        return primaryId.flatMap { assetIndex[$0] }.map { assets[$0] }
    }
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
        guard let name = promptAlbumName(defaultName: defaultFilterSmartAlbumName(),
                                         messageText: "新建智能相册") else { return }

        let rule = SmartRule(match: "all", conditions: conditions)
        let count = SmartMatcher.count(assets.filter { !$0.deleted }, rule)
        saveSmart(name: name, rule: rule, count: count)
    }

    private func defaultFilterSmartAlbumName() -> String {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty { return "筛选 · \(q)" }
        return "当前筛选"
    }

    private func ensurePrimaryValid() {
        let ids = list
        guard !ids.isEmpty else {
            selectedIds = []
            primaryId = nil
            anchorId = nil
            if view == .compare {
                compareIds = []
                winner = nil
            }
            return
        }
        let visibleIds = Set(ids.map(\.id))
        // selection must never retain assets hidden by the current collection/filter/search,
        // or batch edits (rating, flag, keyword, delete) would silently mutate off-screen photos.
        selectedIds.formIntersection(visibleIds)
        if view == .compare {
            compareIds.removeAll { !visibleIds.contains($0) }
            if let winner, !visibleIds.contains(winner) { self.winner = nil }
        }
        if primaryId == nil || !visibleIds.contains(primaryId!) {
            primaryId = ids[0].id
            selectedIds = [ids[0].id]
            anchorId = ids[0].id
        } else if selectedIds.isEmpty {
            selectedIds = [primaryId!]
        }
        if view == .compare, compareIds.isEmpty, let primaryId {
            compareIds = [primaryId]
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

    var hasSelection: Bool { onboarded && !targetIds.isEmpty }
    var canApplySelectionToAlbum: Bool { hasSelection }
    var canExportOriginalSelection: Bool { canOperateOnSelectedOriginals }
    var canExportPreviewSelection: Bool { selectedAssetsContainPreviewReference }
    var canRemoveSelectionFromCurrentAlbum: Bool { selection.type == .album && hasSelection }
    var canRemoveSelectedSource: Bool { selectedFolderIsCatalogSource }
    var canReauthorizeSelectedSource: Bool {
        selectedFolderIsCatalogSource
            && sourceManagementModesById[selection.id] != ImportMode.managed.rawValue
    }

    private var selectedFolderIsCatalogSource: Bool {
        selection.type == .folder
            && store != nil
            && !DemoData.folders.contains { $0.id == selection.id }
            && folders.contains { $0.id == selection.id }
    }

    // Capability checks are read while SwiftUI builds toolbars and menus. Keep
    // them metadata-only; the action revalidates paths before touching files.
    private var selectedAssetsContainLocalOriginalReference: Bool {
        targetIds.contains { id in
            guard let index = assetIndex[id] else { return false }
            let asset = assets[index]
            return !asset.deleted && !asset.isDemo && asset.status == .ready && asset.localPath != nil
        }
    }

    private var selectedAssetsContainPreviewReference: Bool {
        targetIds.contains { id in
            guard let index = assetIndex[id] else { return false }
            let asset = assets[index]
            guard !asset.deleted && !asset.isDemo else { return false }
            let hasLocalCacheReference = [asset.preview, asset.thumb].contains {
                !$0.isEmpty && !$0.hasPrefix("http")
            }
            return hasLocalCacheReference || (asset.status == .ready && asset.localPath != nil)
        }
    }

    /// Apply an in-place edit to the current selection (or an explicit set).
    @discardableResult
    func mutate(_ ids: Set<String>? = nil, _ transform: (inout Asset) -> Void) -> Bool {
        let target = ids ?? targetIds
        guard !target.isEmpty else { return false }
        var updated = assets
        for i in updated.indices where target.contains(updated[i].id) {
            transform(&updated[i])
        }
        guard persist(target, in: updated) else { return false }
        replaceAssetsForMutation(updated)
        ensurePrimaryValid()
        return true
    }

    @discardableResult
    func mutateAsset(_ id: String, _ transform: (inout Asset) -> Void) -> Bool {
        guard let i = assetIndex[id] else { return false }
        var updated = assets
        transform(&updated[i])
        guard persist([id], in: updated) else { return false }
        replaceAssetsForMutation(updated)
        ensurePrimaryValid()
        return true
    }

    @discardableResult
    func setRating(_ n: Int) -> Bool {
        mutateIndexedMetadata({ $0.rating = n }) { store, ids in
            try store.updateRatings(n, assetIDs: ids)
        }
    }
    @discardableResult
    func setFlag(_ f: Flag) -> Bool {
        mutateIndexedMetadata({ $0.flag = f }) { store, ids in
            try store.updateFlags(f, assetIDs: ids)
        }
    }
    @discardableResult
    func setColor(_ c: ColorLabel?) -> Bool {
        mutateIndexedMetadata({ $0.colorLabel = c }) { store, ids in
            try store.updateColorLabels(c, assetIDs: ids)
        }
    }

    private func mutateIndexedMetadata(
        _ transform: (inout Asset) -> Void,
        persist: (CatalogStore, Set<String>) throws -> Void
    ) -> Bool {
        let ids = targetIds
        guard !ids.isEmpty else { return false }
        var updated = assets
        var changed: [Asset] = []
        changed.reserveCapacity(ids.count)
        for index in updated.indices where ids.contains(updated[index].id) {
            transform(&updated[index])
            if !updated[index].isDemo { changed.append(updated[index]) }
        }
        if let store, !changed.isEmpty {
            do {
                try persist(store, Set(changed.map(\.id)))
            } catch {
                push("保存失败，更改未写入目录库", "warning")
                return false
            }
        }
        replaceAssetsForMutation(updated)
        ensurePrimaryValid()
        enqueueAutomaticXMPWrite(changed)
        return true
    }

    @discardableResult
    func applyRatingShortcut(_ rating: Int) -> Bool {
        guard (0...5).contains(rating), !targetIds.isEmpty else { return false }
        guard setRating(rating) else { return false }
        if rating == 0 {
            push("已清除评分")
        } else {
            push("评分 \(rating) 星", "star")
        }
        return true
    }

    func removeSelectedSource() {
        guard selectedFolderIsCatalogSource else { return }
        let folderId = selection.id
        let folderName = selection.name
        let indexed = assets.filter { !$0.deleted && !$0.isDemo && $0.folderId == folderId }
        guard !indexed.isEmpty || folders.contains(where: { $0.id == folderId }) else { return }

        guard confirmDestructiveAction(
            "移除源文件夹？",
            "将从目录库移除「\(folderName)」的索引记录，磁盘上的原件不会被删除。",
            "移除索引"
        ) else { return }

        let sourceRootPath = sourceRootPathsById[folderId]
        let ids = Set(indexed.map(\.id))
        do {
            try store?.removeSourceRootAndSoftDeleteAssets(id: folderId)
        } catch {
            push("源移除失败", "warning")
            return
        }
        if !ids.isEmpty {
            var updated = assets
            for index in updated.indices where ids.contains(updated[index].id) {
                updated[index].deleted = true
            }
            replaceAssetsForMutation(updated)
            ensurePrimaryValid()
            purgeCacheFiles(forAssetIds: ids)
        }
        folders.removeAll { $0.id == folderId }
        sourceRootPathsById.removeValue(forKey: folderId)
        sourcePriorities.removeValue(forKey: folderId)
        saveSourcePriorities()
        if let sourceRootPath {
            let removedPath = URL(fileURLWithPath: sourceRootPath).standardizedFileURL.path
            watchedRoots.removeAll { $0.standardizedFileURL.path == removedPath }
        } else {
            watchedRoots.removeAll { root in
                let rootPath = root.standardizedFileURL.path
                return indexed.contains {
                    $0.localPath.map { Self.path(URL(fileURLWithPath: $0).standardizedFileURL.path, isIn: rootPath) } ?? false
                }
            }
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
        let oldRootPath = sourceRootPathsById[folderId]

        let panel = NSOpenPanel()
        configureSourceReauthorizationPanel(panel, currentPath: oldRootPath)
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
        if let oldRootPath, oldRootPath != folder.path {
            rebaseSourceRootAssetPaths(folderId: folderId, oldRoot: oldRootPath, newRoot: folder.path)
        }
        replaceWatchedSourceRoot(oldRootPath: oldRootPath, newRoot: folder)
        detectMissingRealAssets()
        push("已恢复源文件夹访问", "check")
    }

    func configureSourceReauthorizationPanel(_ panel: NSOpenPanel, currentPath: String?) {
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "重新授权"
        panel.message = "选择源文件夹以恢复访问权限"
        guard let currentPath else { return }
        let currentURL = URL(fileURLWithPath: currentPath, isDirectory: true).standardizedFileURL
        if FileManager.default.fileExists(atPath: currentURL.path) {
            panel.directoryURL = currentURL
        }
    }

    func rebaseSourceRootAssetPaths(folderId: String, oldRoot: String, newRoot: String) {
        var updated = assets
        var changedIds = Set<String>()
        for index in updated.indices where updated[index].folderId == folderId {
            guard let path = updated[index].localPath,
                  let replacement = VolumeMonitor.pathByReplacingVolumeRoot(in: path,
                                                                             oldRoot: oldRoot,
                                                                             newRoot: newRoot),
                  FileManager.default.fileExists(atPath: replacement) else { continue }
            updated[index].localPath = replacement
            updated[index].status = .ready
            changedIds.insert(updated[index].id)
        }
        guard !changedIds.isEmpty else { return }
        guard persist(changedIds, in: updated) else { return }
        replaceAssetsForMutation(updated)
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

    func renameAlbum(_ id: String) {
        guard let album = albums.first(where: { $0.id == id }),
              let name = promptAlbumName(defaultName: album.name,
                                         messageText: "重命名相册",
                                         confirmTitle: "保存") else { return }
        _ = renameAlbum(id, to: name)
    }

    @discardableResult
    func renameAlbum(_ id: String, to name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let index = albums.firstIndex(where: { $0.id == id }) else { return false }
        guard albums[index].name != name else { return true }
        do {
            try store?.renameAlbum(id: id, name: name)
        } catch {
            push("相册重命名失败", "warning")
            return false
        }
        let previous = albums[index]
        albums[index] = Album(id: previous.id, name: name, assetIds: previous.assetIds)
        if selection.type == .album, selection.id == id {
            selection = Selection(type: .album, id: id, name: name)
        }
        push("已将相册「\(previous.name)」重命名为「\(name)」", "album")
        return true
    }

    func deleteAlbum(_ id: String) {
        guard let index = albums.firstIndex(where: { $0.id == id }) else { return }
        let album = albums[index]
        guard confirmDestructiveAction(
            "删除相册？",
            "只会删除相册「\(album.name)」及其目录库关系，不会删除任何照片或原件。",
            "删除相册"
        ) else { return }
        do {
            try store?.deleteAlbum(id: id)
        } catch {
            push("相册删除失败", "warning")
            return
        }
        albums.remove(at: index)
        pinnedSidebarItems.removeAll { $0.type == .album && $0.selectionId == id }
        savePinnedSidebarItems()
        if selection.type == .album, selection.id == id {
            selection = Selection(type: .lib, id: "all", name: "全部照片")
            ensurePrimaryValid()
        }
        push("已删除相册「\(album.name)」", "trash")
    }

    func editSmartAlbum(_ id: String) {
        guard smartAlbums.contains(where: { $0.id == id }) else { return }
        smartAlbumEditingID = id
        sheet = "smart"
    }

    func dismissSmartAlbumBuilder() {
        smartAlbumEditingID = nil
        sheet = nil
    }

    func deleteSmartAlbum(_ id: String) {
        guard let index = smartAlbums.firstIndex(where: { $0.id == id }) else { return }
        let album = smartAlbums[index]
        guard confirmDestructiveAction(
            "删除智能相册？",
            "只会删除智能相册「\(album.name)」及其规则，不会删除任何照片或原件。",
            "删除智能相册"
        ) else { return }
        do {
            try store?.deleteSmartAlbum(id: id)
        } catch {
            push("智能相册删除失败", "warning")
            return
        }
        smartAlbums.remove(at: index)
        pinnedSidebarItems.removeAll { $0.type == .smart && $0.selectionId == id }
        savePinnedSidebarItems()
        if smartAlbumEditingID == id {
            dismissSmartAlbumBuilder()
        }
        if selection.type == .smart, selection.id == id {
            selection = Selection(type: .lib, id: "all", name: "全部照片")
            ensurePrimaryValid()
        }
        push("已删除智能相册「\(album.name)」", "trash")
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

    private func promptAlbumName(defaultName: String, messageText: String = "新建相册",
                                 confirmTitle: String = "创建") -> String? {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = defaultName
        let alert = NSAlert()
        alert.messageText = messageText
        alert.accessoryView = field
        alert.addButton(withTitle: confirmTitle)
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
        guard mutateAsset(id, {
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
        }) else { return }
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
        guard mutate(ids, { $0.deleted = true }) else { return }
        purgeCacheFiles(forAssetIds: ids)
        push("已从目录库移除 \(ids.count) 张（原件保留）", "trash")
        selectedIds = []
        ensurePrimaryValid()
        // drop the removed assets from duplicate groups / collapsed stacks, like the
        // trash and duplicate-resolution paths do — otherwise the sidebar count, the
        // Duplicates sheet, and stack badges keep showing ghosts of the removed photos.
        recomputeDuplicates()
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
        guard let trashCatalogURL = store?.packageURL else {
            push("无目录库", "warning")
            return
        }
        Task { [weak self, real, trashCatalogURL] in
            let result = await Task.detached(priority: .userInitiated) {
                OriginalFileOperationService.trashOriginals(real)
            }.value

            guard let self,
                  self.applyTrashedOriginals(result, expectedCatalogURL: trashCatalogURL) else {
                if !result.trashedIds.isEmpty {
                    let rolledBack = await Task.detached(priority: .userInitiated) {
                        OriginalFileOperationService.rollBackTrash(result.locations)
                    }.value
                    self?.push("移到废纸篓未完成"
                               + (rolledBack > 0 ? " · 已回滚 \(rolledBack) 个原件" : " · 回滚失败")
                               + " · 目录库保存失败",
                               "warning")
                }
                return
            }
        }
    }

    @discardableResult
    func applyTrashedOriginals(_ result: OriginalTrashReport, expectedCatalogURL: URL? = nil) -> Bool {
        guard !result.trashedIds.isEmpty else {
            push("已移到废纸篓 0 张"
                 + (result.failed > 0 ? " · \(result.failed) 失败" : ""),
                 result.failed > 0 ? "warning" : "check")
            return true
        }
        if let expectedCatalogURL, store?.packageURL != expectedCatalogURL { return false }
        guard mutate(result.trashedIds, { $0.deleted = true }) else { return false }
        purgeCacheFiles(forAssetIds: result.trashedIds)
        selectedIds.subtract(result.trashedIds)
        ensurePrimaryValid()
        recomputeDuplicates()
        push("已移到废纸篓 \(result.trashedIds.count) 张"
             + (result.failed > 0 ? " · \(result.failed) 失败" : ""),
             result.failed > 0 ? "warning" : "check")
        return true
    }

    // ---------- compare ----------
    func enterCompare() {
        // order by display position so the chosen subset is deterministic
        var ids = list.map { $0.id }.filter { selectedIds.contains($0) }
        if ids.count < 2 { ids = list.prefix(3).map { $0.id } }
        compareIds = Array(ids.prefix(4))
        // align the grid selection with the compared panels so rating/flag/color shortcuts
        // act on what's on screen rather than a now-hidden grid selection
        syncCompareSelection()
        winner = nil
        view = .compare
    }

    func addToCompare(_ id: String) {
        guard compareIds.count < 4,
              !compareIds.contains(id),
              list.contains(where: { $0.id == id }) else { return }
        compareIds.append(id)
        syncCompareSelection()
    }

    func removeFromCompare(_ id: String) {
        compareIds.removeAll { $0 == id }
        syncCompareSelection()
    }

    private func syncCompareSelection() {
        let ids = Set(compareIds)
        selectedIds = ids
        if let winner, !ids.contains(winner) { self.winner = nil }
        if let primaryId, ids.contains(primaryId) {
            anchorId = primaryId
            return
        }
        primaryId = compareIds.first
        anchorId = primaryId
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
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !rule.conditions.isEmpty else {
            push("智能相册需要名称和至少一个条件", "warning")
            return
        }
        if let id = smartAlbumEditingID {
            guard let index = smartAlbums.firstIndex(where: { $0.id == id }) else {
                push("智能相册不存在", "warning")
                return
            }
            let previous = smartAlbums[index]
            let album = SmartAlbum(id: id, name: name, rule: rule, count: count)
            if let store {
                do {
                    try store.saveSmartAlbum(album, sortOrder: index)
                } catch {
                    push("智能相册保存失败", "warning")
                    return
                }
            }
            smartAlbums[index] = album
            dismissSmartAlbumBuilder()
            selection = Selection(type: .smart, id: id, name: name)
            ensurePrimaryValid()
            push("已更新智能相册「\(previous.name)」", "sparkles")
            return
        }
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
        dismissSmartAlbumBuilder()
        selection = Selection(type: .smart, id: id, name: name)
        ensurePrimaryValid()
        push("已创建智能相册「\(name)」", "sparkles")
    }

    // ---------- keyboard ----------
    /// Returns true if the key was handled.
    @discardableResult
    func handleKey(_ key: String, hasCommand: Bool, hasShift: Bool = false) -> Bool {
        // Sheets are overlays, not real modal windows — while one is open,
        // global shortcuts must not reach the photos behind the backdrop
        // (rating/flag/delete keys would silently mutate the selection).
        if sheet != nil {
            if !hasCommand && key == "escape" { return dismissTransientUI() }
            if hasCommand {
                switch key {
                case "n", "o", "f", "i", "e", "r", ",", "b", "s", "a",
                     "=", "+", "-", "0", "delete", "backspace":
                    return true
                default:
                    return false
                }
            }
            return false
        }
        if hasCommand {
            if !onboarded {
                switch key {
                case "n":
                    createCatalog()
                case "o":
                    openCatalog()
                default:
                    return false
                }
                return true
            }
            switch key {
            case "n":
                createCatalog()
            case "o":
                openCatalog()
            case "f":
                if hasShift {
                    toggleFilterBar()
                } else {
                    focusSearch()
                }
            case "i":
                if hasShift {
                    addFolder()
                } else {
                    showInspector.toggle()
                }
            case "e":
                if hasShift {
                    exportSelectionPreviews()
                } else {
                    exportSelection()
                }
            case "r":
                rescanCurrentSource()
            case ",":
                showSettings()
            case "b":
                if hasShift {
                    restoreBackup()
                } else {
                    runBackup()
                }
            case "s":
                guard canSaveCurrentFilter else { return false }
                saveCurrentFilterAsSmartAlbum()
            case "a":
                if hasShift {
                    guard invertVisibleSelection() else { return false }
                    push("已反选当前列表")
                } else {
                    guard selectAllVisible() else { return false }
                    push("已全选当前列表")
                }
            case "=", "+":
                adjustThumbnailSize(by: 16)
            case "-":
                adjustThumbnailSize(by: -16)
            case "0":
                resetThumbnailSize()
            case "delete", "backspace":
                trashSelectedOriginals()
            default:
                return false
            }
            return true
        }
        guard onboarded else { return false }

        switch key {
        case "escape":
            guard dismissTransientUI() else { return false }
        case "return":
            guard let primaryId else { return false }
            openLoupe(primaryId)
        case "1", "2", "3", "4", "5":
            guard applyRatingShortcut(Int(key) ?? 0) else { return false }
        case "0":
            guard applyRatingShortcut(0) else { return false }
        case "p":
            guard !targetIds.isEmpty else { return false }
            guard setFlag(.pick) else { return false }
            push("标记为精选", "flag")
        case "x":
            guard !targetIds.isEmpty else { return false }
            guard setFlag(.reject) else { return false }
            push("标记为拒绝", "reject")
        case "u":
            guard !targetIds.isEmpty else { return false }
            guard setFlag(.none) else { return false }
            push("已清除旗标")
        case "6":
            guard !targetIds.isEmpty else { return false }
            guard setColor(.red) else { return false }
            push("颜色标签：红", "tag")
        case "7":
            guard !targetIds.isEmpty else { return false }
            guard setColor(.yellow) else { return false }
            push("颜色标签：黄", "tag")
        case "8":
            guard !targetIds.isEmpty else { return false }
            guard setColor(.green) else { return false }
            push("颜色标签：绿", "tag")
        case "9":
            guard !targetIds.isEmpty else { return false }
            guard setColor(.blue) else { return false }
            push("颜色标签：蓝", "tag")
        case "f":
            toggleFilterBar()
        case "g":
            view = .grid
        case "e", " ":
            view = (view == .loupe) ? .grid : .loupe
        case "c":
            enterCompare()
        case "i":
            toggleGridInfo()
        case "s":
            toggleStackForPrimary()
        case "up", "down", "left", "right":
            if view == .compare { return false }  // don't navigate the hidden grid from compare
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
            // mirror GridView's exact column math so arrow nav lands on the right row
            let w = gridWidth ?? 800
            let gap = max(8, thumbSize * 0.06)
            cols = max(1, Int((w + gap) / (thumbSize + gap)))
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
    @ObservationIgnored var gridWidth: CGFloat?
}
