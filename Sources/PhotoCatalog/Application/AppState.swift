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

private enum DeferredCatalogLoadOutcome: Sendable {
    case success(CatalogStore, AssetPage)
    case incompatibleSchema(current: Int, supported: Int)
    case failure
}

private enum DeferredCatalogHydrationOutcome: Sendable {
    case success([Asset])
    case failure
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
            let scope = nextAssetEditScope
            nextAssetEditScope = .any
            if scope == .any {
                structureVersion &+= 1
                assetIndexCache = nil
                keywordListCache = nil
                keywordSuggestionPoolCache = nil
                projectListCache = nil
                clientListCache = nil
                captureDateGroupsCache = nil
                folderTreeCache = nil
                folderTreeCountCache = nil
            }
            libraryCountsCache = nil
            sidebarCountIndexCache = nil
            pinnedSidebarFavoritesCache = nil
            listInputsVersion &+= 1
        }
    }
    /// What an `assets` write may have changed. Review edits (rating / flag / color label)
    /// keep ids, order, paths, dates, status and keywords, so the structural caches —
    /// folder tree and counts, capture-date tree, id index, keyword/project/client lists —
    /// stay valid. Rebuilding them on every rating keystroke cost ~150 ms on 8k photos.
    enum AssetEditScope { case any, review }
    @ObservationIgnored private var nextAssetEditScope: AssetEditScope = .any
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
        didSet {
            photoStacksCache = nil
            stackByAssetCache = nil
            stackInputsVersion &+= 1
            if !collapsedStackIds.isEmpty { listInputsVersion &+= 1 }
        }
    }
    private var collapsedStackIds: Set<String> = []
    @ObservationIgnored private var photoStacksCache: [PhotoStack]?
    @ObservationIgnored private var stackByAssetCache: [String: PhotoStack]?
    @ObservationIgnored private var keywordListCache: [KeywordCount]?
    @ObservationIgnored private var keywordSuggestionPoolCache: [String]?
    @ObservationIgnored private var projectListCache: [KeywordCount]?
    @ObservationIgnored private var clientListCache: [KeywordCount]?
    @ObservationIgnored private var captureDateGroupsCache: [CaptureDateBucket]?
    private var captureStatisticsCache: (request: CaptureStatisticsRequest, value: CaptureStatistics)?
    @ObservationIgnored private var captureStatisticsTask: Task<CaptureStatistics, Error>?
    @ObservationIgnored private var captureStatisticsGeneration = 0
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

        /// The only counts a rating / flag / color edit can move.
        mutating func applyReviewChange(from old: Asset, to new: Asset) {
            guard !old.deleted else { return }
            func one(_ condition: Bool) -> Int { condition ? 1 : 0 }
            unrated += one(new.rating == 0 && new.flag != .reject) - one(old.rating == 0 && old.flag != .reject)
            picks += one(new.flag == .pick) - one(old.flag == .pick)
            rejected += one(new.flag == .reject) - one(old.flag == .reject)
        }
    }
    /// Bumped whenever an array input to `list` changes (assets/albums/smartAlbums/folders/
    /// source roots/priorities or collapsed-stack membership); small values are compared directly.
    private var listInputsVersion = 0   // tracked: cached getters read it so cache HITS register deps
    /// Bumped only by non-review asset edits (ids, paths, status, deletion…); values that
    /// can't change with a rating key on this so they neither recompute nor re-render.
    private var structureVersion = 0
    private var stackInputsVersion = 0
    var assetRenderVersion = 0
    var thumbnailCacheGeneration = 0
    @ObservationIgnored private var listCache: (signature: ListSignature, value: [Asset])?
    @ObservationIgnored private var uncollapsedListCache: (signature: ListSignature, value: [Asset])?
    @ObservationIgnored private var automaticXMPWriter = AutomaticXMPWriter()
    @ObservationIgnored private var automaticXMPWriteSequence: UInt64 = 0
    fileprivate struct ListSignature: Equatable {
        let inputsVersion: Int
        let selection: Selection
        let filters: Filters
        let search: String
        let sort: Sort
        let collapsed: Set<String>
        let recentDays: Int
        let captureDay: Date
    }

    struct CaptureStatisticsRequest: Equatable {
        fileprivate let list: ListSignature
        fileprivate let selectedIds: Set<String>?
        fileprivate let catalogGeneration: Int
        fileprivate let isLoading: Bool
    }

    /// The window's undo manager (set by the main view), so ⌘Z, the Edit menu's titles and
    /// text-field undo all behave like any Mac app.
    @ObservationIgnored weak var undoManager: UndoManager? {
        didSet { undoManager?.levelsOfUndo = 100 }
    }

    /// Records how to put `before` back. Undoing registers the reverse, which is what redo replays.
    private func registerUndo(restoring before: [Asset], actionName: String?) {
        guard let actionName, let undoManager, !before.isEmpty else { return }
        undoManager.registerUndo(withTarget: self) { app in
            MainActor.assumeIsolated { app.restoreSnapshot(before, actionName: actionName) }
        }
        undoManager.setActionName(actionName)
    }

    private func restoreSnapshot(_ snapshot: [Asset], actionName: String) {
        let index = assetIndex
        let current = snapshot.compactMap { index[$0.id].map { assets[$0] } }
        var updated = assets
        for asset in snapshot { if let offset = index[asset.id] { updated[offset] = asset } }
        guard persist(Set(snapshot.map(\.id)), in: updated) else { return }
        let deletionChanged = zip(current, snapshot).contains { $0.deleted != $1.deleted }
        replaceAssetsForMutation(updated)
        ensurePrimaryValid()
        enqueueAutomaticXMPWrite(snapshot.filter { !$0.isDemo && !$0.deleted })
        if deletionChanged { recomputeDuplicates() }
        registerUndo(restoring: current, actionName: actionName)
    }

    private func replaceAssetsForMutation(_ updated: [Asset], scope: AssetEditScope = .any) {
        nextAssetEditScope = scope
        assets = updated
        didMutateAssets()
    }

    /// Writes edited copies back at their offsets in one mutation (one didSet, no array copy).
    /// Review edits also patch the library counts and — when the current collection,
    /// filters and sort ignore review fields — the cached list, instead of rescanning
    /// and re-sorting every asset.
    private func applyAssetEdits(_ edits: [(offset: Int, asset: Asset)], scope: AssetEditScope) {
        var patchedCounts: LibraryCounts?
        var listBefore: ListSignature?
        if scope == .review {
            let pairing = assetPairing
            patchedCounts = libraryCountsCache.map { counts in
                edits.reduce(into: counts) { counts, edit in
                    guard !pairing.isHiddenCompanion(edit.asset.id) else { return }
                    counts.applyReviewChange(from: assets[edit.offset], to: edit.asset)
                }
            }
            if !listDependsOnReviewFields { listBefore = currentListSignature }
        }
        nextAssetEditScope = scope
        assets.withUnsafeMutableBufferPointer { buffer in
            for edit in edits { buffer[edit.offset] = edit.asset }
        }
        if let patchedCounts { libraryCountsCache = patchedCounts }
        if let listBefore { patchListCaches(with: edits, validFor: listBefore) }
        didMutateAssets()
    }

    private var listDependsOnReviewFields: Bool {
        if filters.minRating > 0 || filters.flag != "any" || filters.color != "any" { return true }
        if sort.field == .rating || selection.type == .smart { return true }
        return selection.type == .lib && ["unrated", "picks", "rejected"].contains(selection.id)
    }

    /// Replaces edited assets inside list caches that were current before the edit.
    private func patchListCaches(with edits: [(offset: Int, asset: Asset)], validFor before: ListSignature) {
        let after = currentListSignature
        let edited = Dictionary(edits.map { ($0.asset.id, $0.asset) }, uniquingKeysWith: { $1 })
        func patch(_ list: inout [Asset]) {
            list.withUnsafeMutableBufferPointer { buffer in
                for i in buffer.indices {
                    if let asset = edited[buffer[i].id] { buffer[i] = asset }
                }
            }
        }
        guard var uncollapsed = uncollapsedListCache, uncollapsed.signature == before else { return }
        patch(&uncollapsed.value)
        uncollapsedListCache = (after, uncollapsed.value)
        guard var visible = listCache, visible.signature == before else { return }
        if collapsedStackIds.isEmpty {
            visible.value = uncollapsed.value   // identical when nothing is collapsed
        } else {
            patch(&visible.value)
        }
        listCache = (after, visible.value)
    }

    private func didMutateAssets() {
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
    /// Metadata template applied to every import (§ roadmap 4.2).
    var importAuthor = UserDefaults.standard.string(forKey: "pc_importAuthor") ?? "" {
        didSet { UserDefaults.standard.set(importAuthor, forKey: "pc_importAuthor") }
    }
    var importCopyright = UserDefaults.standard.string(forKey: "pc_importCopyright") ?? "" {
        didSet { UserDefaults.standard.set(importCopyright, forKey: "pc_importCopyright") }
    }
    var importPostAlbumName = UserDefaults.standard.string(forKey: "pc_importPostAlbumName") ?? "" {
        didSet { UserDefaults.standard.set(importPostAlbumName, forKey: "pc_importPostAlbumName") }
    }
    /// After a rating / flag / color key on one photo, move to the next (Shift does it once).
    var autoAdvance: Bool = UserDefaults.standard.bool(forKey: "pc_autoAdvance") {
        didSet { UserDefaults.standard.set(autoAdvance, forKey: "pc_autoAdvance") }
    }
    /// Sidebar column visibility; Tab hides it together with the inspector for culling.
    var sidebarVisible = true

    func togglePanels() {
        let anyVisible = sidebarVisible || (showInspector && inspectorAvailable)
        sidebarVisible = !anyVisible
        showInspector = !anyVisible
    }

    /// Show a RAW and its same-name JPEG/HEIC as one photo; off lists every file separately.
    var pairRawAndJpeg: Bool = (UserDefaults.standard.object(forKey: "pc_pairRawJpeg") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(pairRawAndJpeg, forKey: "pc_pairRawJpeg")
            invalidatePresentationCaches()
        }
    }
    @ObservationIgnored private var assetPairingCache: (version: Int, pairing: AssetPairing)?
    /// Rebuilt only on structural edits: pairing depends on paths and deletion, never on ratings.
    var assetPairing: AssetPairing {
        guard pairRawAndJpeg else { return .empty }
        let version = structureVersion
        if let cache = assetPairingCache, cache.version == version { return cache.pairing }
        let pairing = AssetPairing.rawJpeg(assets)
        assetPairingCache = (version, pairing)
        return pairing
    }

    /// `ids` plus their paired JPEG/HEIC files, for edits that must reach both.
    func withCompanions(_ ids: Set<String>) -> Set<String> { assetPairing.withCompanions(ids) }

    /// Companion files presented behind this asset's tile (e.g. its JPEG).
    func companions(of asset: Asset) -> [Asset] {
        (assetPairing.companionsByPrimary[asset.id] ?? []).compactMap { id in
            assetIndex[id].map { assets[$0] }
        }
    }

    /// Live assets as the library presents them: companions are folded into their RAW.
    private func presentedAssets() -> [Asset] {
        let pairing = assetPairing
        return assets.filter { !$0.deleted && !pairing.isHiddenCompanion($0.id) }
    }

    /// Pairing changes what every count and list shows.
    private func invalidatePresentationCaches() {
        folderTreeCountCache = nil
        captureDateGroupsCache = nil
        keywordListCache = nil
        projectListCache = nil
        clientListCache = nil
        libraryCountsCache = nil
        sidebarCountIndexCache = nil
        pinnedSidebarFavoritesCache = nil
        listInputsVersion &+= 1
        ensurePrimaryValid()
    }

    var appearance: AppAppearance = .stored {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: AppAppearance.defaultsKey)
            appearance.apply()
        }
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
    private(set) var isLoadingCatalog = false
    private(set) var hasCatalogPreview = false
    private(set) var loadingCatalogTotalCount: Int? {
        didSet { libraryCountsCache = nil }
    }
    private var loadingCatalogURL: URL?
    @ObservationIgnored private var deferredCatalogArguments: [String]?
    @ObservationIgnored private var catalogLoadTask: Task<Void, Never>?
    @ObservationIgnored private var catalogLoadGeneration = 0
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
    private static let catalogPreviewPageSize = 240

    private static func normalizedAutomaticBackupFrequency(_ value: String) -> String {
        ["off", "daily", "weekly"].contains(value) ? value : "weekly"
    }

    // ----- selection / view -----
    var selection = Selection(type: .lib, id: "all", name: "全部照片")
    var selectedIds: Set<String> = []
    var primaryId: String?
    var view: ViewMode = .grid {
        didSet { if view != .develop { developCropping = false } }
    }
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
    /// nil = fit. Kept while stepping through photos so a burst can be checked at one spot.
    /// Loupe and Develop share it.
    var loupeZoom: ImageZoom?

    // ----- develop: non-destructive adjustments -----
    /// Saved adjustments by asset id; photos without an entry are as shot.
    var developSettings: [String: DevelopSettings] = [:]
    struct DevelopDraft: Equatable { let assetId: String; var settings: DevelopSettings }
    /// Settings while a slider drags — drives the live preview; saved on release.
    var developDraft: DevelopDraft?
    /// Before / after (\): show the photo as shot.
    var developShowsOriginal = false
    struct DevelopAsShot: Equatable { let temperature: Double; let tint: Double }
    /// Camera-recorded RAW white balance, learned when a photo is first rendered.
    var developAsShot: [String: DevelopAsShot] = [:]

    /// Crop & straighten tool (R). The photo is shown whole with the crop drawn over it.
    var developCropping = false {
        didSet { if developCropping { loupeZoom = nil } }
    }
    /// Crop shape the tool holds while resizing.
    var developCropAspect: CropAspect = .original
    /// Decoded photo sizes before rotation and crop, learned from Develop renders.
    @ObservationIgnored private var developSourceSizes: [String: CGSize] = [:]

    func recordDevelopSourceSize(_ size: CGSize, for id: String) { developSourceSizes[id] = size }

    /// The frame crops are expressed in: the photo after its quarter turns.
    func developFrame(for asset: Asset, settings: DevelopSettings) -> CGSize {
        let size = developSourceSizes[asset.id] ?? CGSize(width: max(asset.width, 1), height: max(asset.height, 1))
        return DevelopGeometry.rotatedSize(size, settings.rotation)
    }

    /// Photos with pixels to render: a local original, or at least a local preview.
    func canDevelop(_ asset: Asset) -> Bool {
        if asset.status == .ready, asset.localPath != nil { return true }
        return !asset.preview.isEmpty && !asset.preview.hasPrefix("http")
    }

    /// R: opens the crop tool (from any view) or closes it.
    func toggleCropTool() {
        if view == .develop {
            developCropping.toggle()
        } else {
            switchView(.develop)
            developCropping = view == .develop
        }
    }

    /// The photo in Develop, or every selected photo elsewhere, that can take an edit.
    private var developTargetIds: [String] {
        let ids = view == .develop ? primaryId.map { [$0] } ?? [] : selectionTargetIds.sorted()
        return ids.filter { id in assetIndex[id].map { canDevelop(assets[$0]) } ?? false }
    }

    /// Menu state: stops at the first photo that can take an edit.
    var canTransformSelection: Bool {
        guard onboarded, sheet == nil, view != .analysis else { return false }
        let ids = view == .develop ? Set(primaryId.map { [$0] } ?? []) : selectionTargetIds
        return ids.contains { id in assetIndex[id].map { canDevelop(assets[$0]) } ?? false }
    }

    /// ⌘[ / ⌘]: a quarter turn, stored as an adjustment — the original is never rewritten.
    func rotateSelection(clockwise: Bool) {
        let ids = developTargetIds
        guard !ids.isEmpty else { return }
        let changes = Dictionary(uniqueKeysWithValues: ids.map {
            ($0, DevelopGeometry.rotated(developSettings[$0] ?? .neutral, clockwise: clockwise))
        })
        commitDevelop(changes, undoName: clockwise ? "向右旋转" : "向左旋转")
    }

    func flipSelection() {
        let ids = developTargetIds
        guard !ids.isEmpty else { return }
        let changes = Dictionary(uniqueKeysWithValues: ids.map {
            ($0, DevelopGeometry.mirrored(developSettings[$0] ?? .neutral))
        })
        commitDevelop(changes, undoName: "水平翻转")
    }

    /// Levels the photo from the horizon Vision finds in it.
    func autoStraighten(_ asset: Asset) {
        guard canDevelop(asset) else { return }
        let settings = developSettings[asset.id] ?? .neutral
        let source: (url: URL, isRaw: Bool) = if asset.status == .ready, let path = asset.localPath {
            (URL(fileURLWithPath: path), asset.isRaw)
        } else {
            (URL(fileURLWithPath: asset.preview), false)
        }
        let id = asset.id
        Task { [weak self] in
            let angle = await ThumbnailRepairQueue.run(.visible) {
                DevelopRenderer.horizonAngle(url: source.url, isRaw: source.isRaw, settings: settings)
            } ?? nil
            guard let self else { return }
            guard let angle, abs(angle) <= DevelopGeometry.maxStraighten else {
                self.push("未找到可用于拉直的地平线", "info")
                return
            }
            var next = self.developSettings[id] ?? .neutral
            next.straighten = (angle * 10).rounded() / 10
            if let asset = self.assetIndex[id].map({ self.assets[$0] }) {
                let frame = self.developFrame(for: asset, settings: next)
                next.crop = next.crop.map { DevelopGeometry.fit($0, angle: next.straighten, frame: frame) }
            }
            self.commitDevelop([id: next], undoName: "自动拉直")
        }
    }

    // ----- develop: copy / paste / sync and presets -----
    /// Settings copied with ⇧⌘C, waiting for ⇧⌘V.
    var developClipboard: DevelopTransfer?
    /// The user's own presets; built-ins come first wherever presets are listed.
    var developPresets: [DevelopPreset] = AppState.loadDevelopPresets() {
        didSet { AppState.store(developPresets, forKey: AppState.developPresetsKey) }
    }
    var allDevelopPresets: [DevelopPreset] { DevelopPreset.builtIns + developPresets }
    /// A new preset offers what the photo has adjusted, leaving its framing out.
    var developPresetDefaultFields: Set<DevelopField> {
        let settings = primaryId.flatMap { developSettings[$0] } ?? .neutral
        let adjusted = Set(DevelopField.allCases.filter { $0.isAdjusted(in: settings) })
            .subtracting([.orientation, .crop])
        return adjusted.isEmpty ? developTransferFields : adjusted
    }
    /// Fields the copy / sync dialog offers checked, as last used.
    var developTransferFields: Set<DevelopField> = AppState.loadDevelopTransferFields() {
        didSet { AppState.store(developTransferFields, forKey: AppState.developTransferFieldsKey) }
    }
    enum DevelopTransferMode { case copy, sync, preset }
    var developTransferMode: DevelopTransferMode = .copy

    private static let developPresetsKey = "pc_developPresets"
    private static let developTransferFieldsKey = "pc_developTransferFields"

    private static func loadDevelopPresets() -> [DevelopPreset] {
        UserDefaults.standard.data(forKey: developPresetsKey)
            .flatMap { try? JSONDecoder().decode([DevelopPreset].self, from: $0) } ?? []
    }

    private static func loadDevelopTransferFields() -> Set<DevelopField> {
        UserDefaults.standard.data(forKey: developTransferFieldsKey)
            .flatMap { try? JSONDecoder().decode(Set<DevelopField>.self, from: $0) } ?? DevelopField.defaultCopy
    }

    private static func store<T: Encodable>(_ value: T, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }

    private var primaryCanDevelop: Bool { primary.map(canDevelop) ?? false }
    var canCopyDevelopSettings: Bool { onboarded && sheet == nil && view != .analysis && primaryCanDevelop }
    var canPasteDevelopSettings: Bool { developClipboard != nil && canTransformSelection }
    var canSyncDevelopSettings: Bool { canCopyDevelopSettings && view != .develop && selectionTargetIds.count > 1 }

    /// ⇧⌘C / ⇧⌘S / 存储为预设: the dialog that picks which settings travel.
    func showDevelopTransfer(_ mode: DevelopTransferMode) {
        guard canCopyDevelopSettings, mode != .sync || canSyncDevelopSettings else { return }
        developTransferMode = mode
        sheet = "developTransfer"
    }

    func copyDevelopSettings(fields: Set<DevelopField>) {
        guard let asset = primary, canDevelop(asset) else { return }
        developClipboard = DevelopTransfer(settings: developSettings[asset.id] ?? .neutral, fields: fields,
                                           sourceIsRaw: asset.isRaw)
        push("已拷贝修图设置", "doc.on.doc")
    }

    /// ⇧⌘V: onto the photo in Develop, or every selected photo elsewhere.
    func pasteDevelopSettings() {
        guard let clipboard = developClipboard else { return }
        let count = applyDevelopTransfer(clipboard, to: developTargetIds, undoName: "粘贴修图设置")
        if count > 1 { push("已粘贴到 \(count) 张照片", "doc.on.clipboard") }
    }

    /// The right-click menu can't disable itself without rebuilding every cell's menu, so it says why.
    func pasteDevelopSettingsIfCopied() {
        guard developClipboard != nil else {
            push("还没有拷贝修图设置（⇧⌘C）", "info")
            return
        }
        pasteDevelopSettings()
    }

    /// The selected photo's settings onto the rest of the selection.
    func syncDevelopSettings(fields: Set<DevelopField>) {
        guard let source = primary, canDevelop(source) else { return }
        let transfer = DevelopTransfer(settings: developSettings[source.id] ?? .neutral, fields: fields,
                                       sourceIsRaw: source.isRaw)
        let targets = developTargetIds.filter { $0 != source.id }
        let count = applyDevelopTransfer(transfer, to: targets, undoName: "同步修图设置")
        push("已同步到 \(count) 张照片", "arrow.triangle.2.circlepath")
    }

    func applyDevelopPreset(_ preset: DevelopPreset) {
        applyDevelopTransfer(preset.transfer, to: developTargetIds, undoName: "应用预设“\(preset.name)”")
    }

    /// Saves the selected photo's `fields` as a preset; a preset of the same name is replaced.
    func saveDevelopPreset(name: String, fields: Set<DevelopField>) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let asset = primary, canDevelop(asset), !name.isEmpty, !fields.isEmpty else { return }
        let transfer = DevelopTransfer(settings: developSettings[asset.id] ?? .neutral, fields: fields,
                                       sourceIsRaw: asset.isRaw)
        if let index = developPresets.firstIndex(where: { $0.name == name }) {
            developPresets[index].transfer = transfer
        } else {
            developPresets.append(DevelopPreset(id: UUID().uuidString, name: name, transfer: transfer))
        }
        push("已存储预设“\(name)”", "square.and.arrow.down")
    }

    func deleteDevelopPreset(_ id: String) {
        developPresets.removeAll { $0.id == id }
    }

    /// Returns every selected photo (or the one in Develop) to as shot.
    func resetDevelopSelection() {
        let ids = developTargetIds.filter { developSettings[$0] != nil }
        guard !ids.isEmpty else { return }
        commitDevelop(Dictionary(uniqueKeysWithValues: ids.map { ($0, DevelopSettings.neutral) }),
                      undoName: "复位修图调整")
    }

    var canResetDevelopSelection: Bool {
        canTransformSelection && developTargetIds.contains { developSettings[$0] != nil }
    }

    /// Applies a transfer as one undoable step; returns how many photos it reached.
    @discardableResult
    private func applyDevelopTransfer(_ transfer: DevelopTransfer, to ids: [String], undoName: String) -> Int {
        var changes: [String: DevelopSettings] = [:]
        for id in ids {
            guard let index = assetIndex[id] else { continue }
            let asset = assets[index]
            var next = transfer.applied(to: developSettings[id] ?? .neutral, targetIsRaw: asset.isRaw)
            // a crop from another photo may reach past this one's straightened edges
            let frame = developFrame(for: asset, settings: next)
            next.crop = next.crop.map { DevelopGeometry.fit($0, angle: next.straighten, frame: frame) }
            changes[id] = next
        }
        guard !changes.isEmpty else { return 0 }
        commitDevelop(changes, undoName: undoName)
        return changes.count
    }

    /// Tone distribution of the photo's latest finished Develop render.
    var developHistogram: (assetId: String, histogram: DevelopHistogram)?

    func recordDevelopHistogram(_ histogram: DevelopHistogram, for id: String) {
        if developHistogram?.assetId != id || developHistogram?.histogram != histogram {
            developHistogram = (id, histogram)
        }
    }

    func recordAsShotWhiteBalance(_ id: String, temperature: Double, tint: Double) {
        let value = DevelopAsShot(temperature: temperature, tint: tint)
        if developAsShot[id] != value { developAsShot[id] = value }
    }

    /// Changes whenever a photo's saved adjustments change; image views key their loads on it.
    func developFingerprint(for id: String) -> String? { developSettings[id]?.fingerprint }

    func developSettings(for id: String) -> DevelopSettings {
        if let draft = developDraft, draft.assetId == id { return draft.settings }
        return developSettings[id] ?? .neutral
    }

    func updateDevelopDraft(_ settings: DevelopSettings, for id: String) {
        developDraft = DevelopDraft(assetId: id, settings: settings)
    }

    /// Saves adjustments for each id (persisted and undoable; neutral clears the photo's edit).
    func commitDevelop(_ settings: [String: DevelopSettings], undoName: String) {
        developDraft = nil
        let before = Dictionary(uniqueKeysWithValues: settings.keys.map { ($0, developSettings[$0] ?? .neutral) })
        guard before != settings else { return }
        do {
            try store?.saveDevelopSettings(settings)
        } catch {
            push("保存调整失败，更改未写入目录库", "warning")
            return
        }
        for (id, value) in settings { developSettings[id] = value.isNeutral ? nil : value }
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { app in
            MainActor.assumeIsolated { app.commitDevelop(before, undoName: undoName) }
        }
        undoManager.setActionName(undoName)
    }
    /// Shared by every Compare panel, so zoom and pan stay linked across them.
    var compareZoom: ImageZoom?

    /// Z: fit ↔ 1:1 in Loupe and Compare; from the grid it opens the photo at 1:1.
    func toggleZoom() -> Bool {
        switch view {
        case .grid:
            guard let primaryId else { return false }
            openLoupe(primaryId)
            loupeZoom = .actualSize
        case .loupe:
            loupeZoom = loupeZoom == nil ? .actualSize : nil
        case .compare:
            compareZoom = compareZoom == nil ? .actualSize : nil
        case .develop:
            loupeZoom = loupeZoom == nil ? .actualSize : nil
        case .analysis:
            return false
        }
        return true
    }

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
        if view == .develop, developCropping {
            developCropping = false
            return true
        }
        if view == .loupe || view == .develop, loupeZoom != nil {
            loupeZoom = nil
            return true
        }
        if view == .compare, compareZoom != nil {
            compareZoom = nil
            return true
        }
        if view != .grid {
            view = .grid
            return true
        }
        return false
    }

    init(arguments: [String] = CommandLine.arguments, deferCatalogLoading: Bool = false) {
        let a = DemoData.assets
        assets = a
        albums = DemoData.initialAlbums(a)
        smartAlbums = DemoData.initialSmartAlbums(a)
        if deferCatalogLoading {
            deferredCatalogArguments = arguments
            if onboarded || Self.launchCatalogURL(from: arguments) != nil {
                isLoadingCatalog = true
                resetToEmptyCatalog()
            }
        } else {
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
        }
        startVolumeMonitor()
        if !deferCatalogLoading {
            runAutomaticBackupIfNeeded()
            seedInitialSelection()
        }
    }

    private func seedInitialSelection() {
        let first = list.first
        primaryId = first?.id
        if let id = first?.id { selectedIds = [id]; anchorId = id }
    }

    deinit {
        catalogLoadTask?.cancel()
        captureStatisticsTask?.cancel()
        for url in securityScopedRoots {
            url.stopAccessingSecurityScopedResource()
        }
    }

    // ---------- catalog open / load ----------
    var hasOpenCatalog: Bool { store != nil }
    var canRunCatalogMaintenance: Bool { hasOpenCatalog && !importing && !isLoadingCatalog }

    var catalogPath: String {
        store?.packageURL.path ?? loadingCatalogURL?.path ?? "未打开目录库"
    }

    var catalogDisplayName: String {
        (store?.packageURL ?? loadingCatalogURL)?.deletingPathExtension().lastPathComponent ?? "PhotoCatalog"
    }

    var recentCatalogs: [RecentCatalog] {
        recentCatalogPaths
            .filter { Self.isValidCatalogSelection(URL(fileURLWithPath: $0)) }
            .map { RecentCatalog(path: $0) }
    }

    var statusAssetCount: Int { loadingCatalogTotalCount ?? libraryCounts.all }

    var contentAssetCount: Int {
        if isLoadingCatalog,
           selection.type == .lib, selection.id == "all",
           filters.isEmpty,
           search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let loadingCatalogTotalCount {
            return loadingCatalogTotalCount
        }
        return list.count
    }

    /// Cached per structural version: review edits can't change it, and the old
    /// filter + map + Set copied every asset on each status-bar render.
    var catalogManagementText: String {
        let version = structureVersion
        let modes = sourceManagementModesById
        let mode = importMode
        if let cache = catalogManagementTextCache, cache.version == version,
           cache.modes == modes, cache.importMode == mode {
            return cache.text
        }
        var hasReal = false, hasManaged = false, hasReferenced = false
        for asset in assets where !asset.deleted && !asset.isDemo {
            hasReal = true
            if managementMode(for: asset) == .managed { hasManaged = true } else { hasReferenced = true }
            if hasManaged && hasReferenced { break }
        }
        let text: String
        if !hasReal {
            text = mode == .managed ? "托管式管理 · 原件在目录库" : "引用式管理 · 原件只读"
        } else if hasManaged {
            text = hasReferenced ? "混合管理 · 原件只读" : "托管式管理 · 原件在目录库"
        } else {
            text = "引用式管理 · 原件只读"
        }
        catalogManagementTextCache = (version, modes, mode, text)
        return text
    }
    @ObservationIgnored private var catalogManagementTextCache:
        (version: Int, modes: [String: String], importMode: ImportMode, text: String)?

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
        applyLoadedCatalog(real, from: s)
        return nil
    }

    private func applyLoadedCatalog(_ real: [Asset], from store: CatalogStore) {
        guard !real.isEmpty else {
            assets = []
            albums = []
            smartAlbums = []
            folders = []
            duplicateGroupsCache = []
            restoreSourceRoots(from: store)
            restoreAlbums(from: store, assets: [])
            recoverInterruptedImportJobs(existingAssets: [])
            ensurePrimaryValid()
            return
        }

        assets = []
        albums = []
        smartAlbums = []
        folders = []
        restoreSourceRoots(from: store)

        let sourceRootsById = sourceRootRecordsById(from: store)
        let repaired = repairSourceRootOwnership(real, sourceRootsById: sourceRootsById)
        let checked = repaired.assets
        if !repaired.changed.isEmpty { try? store.upsert(repaired.changed) }
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
            try? store.updateSourceRootStatus(id: folders[index].id, status: status)
        }
        recomputeDuplicates()
        restoreAlbums(from: store, assets: checked)
        recoverInterruptedImportJobs(existingAssets: checked)
        primeDefaultListCache(with: checked)
        ensurePrimaryValid()
        backfillThumbnails()
        detectMissingRealAssets()
        refreshStatusMetrics()
    }

    /// Starts the production launch load after SwiftUI has created the first window.
    func startDeferredCatalogLoadingIfNeeded() {
        guard let arguments = deferredCatalogArguments else { return }
        deferredCatalogArguments = nil

        let launchURL = Self.launchCatalogURL(from: arguments).map(Self.catalogPackageURL(for:))
        if launchURL != nil { launchCatalogHandled = true }
        let fallbackURL: URL? = if onboarded && openLastCatalogOnLaunch,
                                   FileManager.default.fileExists(
                                    atPath: configuredCatalogURL.appendingPathComponent("catalog.sqlite").path
                                   ) {
            configuredCatalogURL
        } else {
            nil
        }

        if let launchURL,
           FileManager.default.fileExists(atPath: launchURL.appendingPathComponent("catalog.sqlite").path) {
            let fallback = fallbackURL?.standardizedFileURL == launchURL.standardizedFileURL ? nil : fallbackURL
            beginDeferredCatalogLoad(at: launchURL, fallbackURL: fallback)
        } else if let fallbackURL {
            beginDeferredCatalogLoad(at: fallbackURL, fallbackURL: nil)
        } else {
            finishDeferredCatalogLoadFailure(message: nil)
        }
    }

    private func beginDeferredCatalogLoad(at url: URL, fallbackURL: URL?, announceSuccess: Bool = false) {
        catalogLoadTask?.cancel()
        catalogLoadGeneration &+= 1
        let generation = catalogLoadGeneration
        let previewPageSize = Self.catalogPreviewPageSize
        isLoadingCatalog = true
        hasCatalogPreview = false
        loadingCatalogTotalCount = nil
        loadingCatalogURL = url

        catalogLoadTask = Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> DeferredCatalogLoadOutcome in
                do {
                    let store = try CatalogStore(packageURL: url)
                    let page = try store.loadAssetPage(limit: previewPageSize)
                    return .success(store, page)
                } catch let error as CatalogStoreError {
                    switch error {
                    case .incompatibleSchema(let current, let supported):
                        return .incompatibleSchema(current: current, supported: supported)
                    }
                } catch {
                    return .failure
                }
            }.value

            guard let self, self.catalogLoadGeneration == generation, !Task.isCancelled else { return }
            switch outcome {
            case .success(let store, let page):
                self.store = store
                self.coordinator = ImportCoordinator(store: store)
                self.applyCatalogPreview(page)

                let hydration = await Task.detached(priority: .userInitiated) {
                    do {
                        return DeferredCatalogHydrationOutcome.success(
                            try store.loadAssets().filter { !$0.isDemo && !$0.deleted }
                        )
                    } catch {
                        return DeferredCatalogHydrationOutcome.failure
                    }
                }.value
                guard self.catalogLoadGeneration == generation, !Task.isCancelled else { return }
                switch hydration {
                case .success(let assets):
                    self.catalogLoadTask = nil
                    self.setActiveCatalog(url)
                    self.refreshStatusMetrics()
                    self.loadingCatalogTotalCount = nil
                    self.applyLoadedCatalog(assets, from: store)
                    self.hasCatalogPreview = false
                    self.isLoadingCatalog = false
                    self.loadingCatalogURL = nil
                    UserDefaults.standard.set("1", forKey: "pc_onboarded")
                    self.onboarded = true
                    self.seedInitialSelection()
                    self.runAutomaticBackupIfNeeded()
                    if announceSuccess {
                        self.push("已打开目录库 · \(url.lastPathComponent)", "check")
                    }
                case .failure:
                    self.discardCatalogPreview()
                    if let fallbackURL {
                        self.push("打开目录库失败", "warning")
                        self.beginDeferredCatalogLoad(at: fallbackURL, fallbackURL: nil)
                    } else {
                        self.finishDeferredCatalogLoadFailure(message: "打开目录库失败")
                    }
                }
            case .incompatibleSchema(let current, let supported):
                let message = "目录库版本过新（schema \(current)，当前支持 \(supported)），请升级 PhotoCatalog 后再打开"
                if let fallbackURL {
                    self.push(message, "warning")
                    self.beginDeferredCatalogLoad(at: fallbackURL, fallbackURL: nil)
                } else {
                    self.finishDeferredCatalogLoadFailure(message: message)
                }
            case .failure:
                if let fallbackURL {
                    self.push("打开目录库失败", "warning")
                    self.beginDeferredCatalogLoad(at: fallbackURL, fallbackURL: nil)
                } else {
                    self.finishDeferredCatalogLoadFailure(message: "打开目录库失败")
                }
            }
        }
    }

    private func applyCatalogPreview(_ page: AssetPage) {
        let preview = page.assets.filter { !$0.isDemo && !$0.deleted }
        assets = preview
        loadingCatalogTotalCount = page.totalCount
        primeDefaultListCache(with: preview)
        ensurePrimaryValid()
        hasCatalogPreview = !preview.isEmpty
    }

    private func discardCatalogPreview() {
        store = nil
        coordinator = nil
        hasCatalogPreview = false
        loadingCatalogTotalCount = nil
        resetToEmptyCatalog()
    }

    private func finishDeferredCatalogLoadFailure(message: String?) {
        catalogLoadTask?.cancel()
        catalogLoadTask = nil
        catalogLoadGeneration &+= 1
        store = nil
        coordinator = nil
        hasCatalogPreview = false
        loadingCatalogTotalCount = nil
        isLoadingCatalog = false
        loadingCatalogURL = nil
        resetToDemoCatalog()
        UserDefaults.standard.set("0", forKey: "pc_onboarded")
        onboarded = false
        if let message { push(message, "warning") }
    }

    private func restoreAlbums(from store: CatalogStore, assets: [Asset]) {
        developSettings = (try? store.loadDevelopSettings()) ?? [:]
        loadFaces(from: store)
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
        beginCatalogSwitch(at: selected, announceSuccess: true)
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
        beginCatalogSwitch(at: url, announceSuccess: true)
    }

    func openCatalogFromSystem(_ selected: URL) {
        guard !importing else {
            push("导入中无法切换目录库", "warning")
            return
        }
        let url = Self.catalogPackageURL(for: selected)
        if (store?.packageURL ?? loadingCatalogURL)?.standardizedFileURL == url.standardizedFileURL {
            return
        }
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("catalog.sqlite").path) else {
            push("所选目录库无效", "warning")
            return
        }

        beginCatalogSwitch(at: url)
    }

    func openLaunchCatalogIfNeeded(arguments: [String] = CommandLine.arguments) {
        guard !launchCatalogHandled else { return }
        launchCatalogHandled = true
        guard let url = Self.launchCatalogURL(from: arguments) else { return }
        beginCatalogSwitch(at: url)
    }

    private func beginCatalogSwitch(at selected: URL, announceSuccess: Bool = false) {
        guard !importing else {
            push("导入中无法切换目录库", "warning")
            return
        }
        let url = Self.catalogPackageURL(for: selected)
        if (store?.packageURL ?? loadingCatalogURL)?.standardizedFileURL == url.standardizedFileURL {
            return
        }
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("catalog.sqlite").path) else {
            forgetCatalog(url)
            push("所选目录库无效", "warning")
            return
        }

        let fallbackURL = store?.packageURL
        closeCurrentCatalog()
        resetToEmptyCatalog()
        beginDeferredCatalogLoad(at: url, fallbackURL: fallbackURL, announceSuccess: announceSuccess)
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
        importFolder(folder)
    }

    /// Imports one folder with the current mode — from the open panel or a Finder drop.
    func importFolder(_ folder: URL) {
        guard !importing else {
            sheet = "import"
            push("已有导入任务正在运行", "warning")
            return
        }
        let mode = importMode
        openOrCreateCatalog()
        guard let coordinator, let store else { return }
        let sourceId = coordinator.sourceId(forFolder: folder)
        let existingIds = Set(assets.map { $0.id })
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
        let bookmark = FileAccessService.createBookmark(for: folder)
        Task { [weak self, coordinator, store, folder, mode, vision, previewSize, archiveRule, readXMP, bookmark, existingIds, sourceId, run, control, knownAssetsById] in
            let imported = await Task.detached(priority: .userInitiated) { [coordinator, folder, mode, vision, previewSize, archiveRule, readXMP, control, knownAssetsById] in
                coordinator.importFolder(folder, mode: mode, autoTag: vision, archiveRule: archiveRule,
                                         readSidecar: readXMP, previewMaxPixel: previewSize, control: control,
                                         knownAssetsById: knownAssetsById) { progress in
                    Task { @MainActor [weak self] in
                        self?.recordImportProgress(progress, for: run.id, store: store)
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

    // ---------- memory-card import ----------
    /// Mounted cards (volumes with DCIM), refreshed as volumes come and go.
    var cardVolumes: [CardVolume] = CardImportService.detectCards()
    /// The card the import dialog opens on.
    var cardImportVolume: CardVolume?
    var cardImportOptions: CardImportOptions = AppState.loadJSON(CardImportOptions.self, forKey: "pc_cardImportOptions")
        ?? .standard {
        didSet { AppState.store(cardImportOptions, forKey: "pc_cardImportOptions") }
    }

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
        sheet = "cardImport"
    }

    /// Copies the chosen card photos into the destination (organized, renamed, backed up) and
    /// catalogs the copies as a referenced source. The card itself is never referenced.
    func importFromCard(_ card: CardVolume?, files: [CardFile], options: CardImportOptions) {
        guard !importing else {
            sheet = "import"
            push("已有导入任务正在运行", "warning")
            return
        }
        guard !files.isEmpty else { return }
        cardImportOptions = options
        openOrCreateCatalog()
        guard let coordinator, let store else { return }
        let root = options.destination
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            push("无法创建目标文件夹：\(error.localizedDescription)", "warning")
            return
        }
        let sourceId = coordinator.sourceId(forFolder: root)
        let existingIds = Set(assets.map { $0.id })
        // an interrupted import resumes from the copies, never from a card that may be gone
        let run = ImportRun(source: root, mode: .referenced)
        guard startPersistedImport(run, store: store), let control = importControl else { return }
        let vision = visionEnabled
        let previewSize = previewMaxPixel
        let readXMP = readXMPSidecar
        let copier = CardCopier(options: options, files: files)
        let urls = files.map(\.url)
        cancelBackfill()
        push("正在从「\(card?.name ?? "存储卡")」导入 \(files.count) 张照片…", "importIcon")
        let bookmark = FileAccessService.createBookmark(for: root)
        Task { [weak self, coordinator, store, root, vision, previewSize, readXMP, bookmark, existingIds, sourceId, run,
                control, copier, urls, card] in
            let imported = await Task.detached(priority: .userInitiated) {
                [coordinator, root, vision, previewSize, readXMP, control, copier, urls] in
                coordinator.importFiles(urls, from: root, mode: .referenced, autoTag: vision, readSidecar: readXMP,
                                        previewMaxPixel: previewSize, control: control,
                                        preparer: copier) { progress in
                    Task { @MainActor [weak self] in
                        self?.recordImportProgress(progress, for: run.id, store: store)
                    }
                }
            }.value
            guard let self else { return }
            self.finishImport(folder: root, imported: imported, existingIds: existingIds,
                              store: store, bookmark: bookmark, mode: .referenced, runId: run.id,
                              sourceId: sourceId, persistSourceRoot: true)
            if options.ejectAfter, let card, self.importRun?.failed == 0 {
                do {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: card.url)
                    self.push("已推出「\(card.name)」", "eject")
                } catch {
                    self.push("无法推出「\(card.name)」：\(error.localizedDescription)", "warning")
                }
            }
        }
    }

    // O(1) failure-dedup state: the set of failure ids already recorded for the current run
    @ObservationIgnored private var failureSeenIds: (runId: UUID?, ids: Set<String>) = (nil, [])
    // Progress events arrive once per file; accumulate here and publish to the
    // observed importRun at most every ~100 ms — each publish redraws every
    // observing view, so per-file publishing stalls the UI on fast imports.
    @ObservationIgnored private var pendingImportRun: ImportRun?
    @ObservationIgnored private var lastImportRunFlush: ContinuousClock.Instant?

    func recordImportProgress(_ progress: ImportProgress, for runId: UUID, store: CatalogStore) {
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
        guard persistImportSessionProgress(run, store: store) else { return }
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

    func finishImport(folder: URL, imported: [Asset], existingIds: Set<String>, store: CatalogStore,
                      bookmark: Data?, mode: ImportMode, runId: UUID, sourceId: String? = nil,
                      persistSourceRoot: Bool) {
        guard importRun?.id == runId else { return }
        defer {
            importing = false
            importControl = nil
            activeImportJobId = nil
        }
        flushPendingImportRun()  // adopt any progress still waiting on the 100 ms window
        // A failed checkpoint is terminal for this run, even if the worker has more results.
        guard var run = importRun, run.phase.isActive else { return }
        let dedup = ImportDeduplicationService.apply(
            imported: imported,
            existingAssets: assets.filter { !$0.deleted && !$0.isDemo },
            existingIds: existingIds,
            strategy: importDuplicateStrategy)
        let fresh = applyPostImportMetadata(to: dedup.fresh)
        let skipped = dedup.skipped
        let rootId = fresh.first?.folderId ?? imported.first?.folderId ?? sourceId
        var assetsSaved = false
        do {
            guard let activeImportJobId else { throw DBError.step("Missing active import job") }
            try store.upsert(fresh)
            assetsSaved = true
            run.total = max(run.total, imported.count + run.failed)
            run.processed = imported.count
            run.skipped = skipped
            run.finishedAt = .now
            run.recentAssets = Array((fresh.isEmpty ? imported : fresh).prefix(28))
            run.errorMessage = importFailureSummary(run.failures)
            // Asset upsert owns its transaction. Commit the source and both terminal records
            // together; if this second commit fails, report the already-saved assets explicitly.
            try store.db.transaction {
                if let rootId, persistSourceRoot, !fresh.isEmpty || skipped > 0 {
                    let existingBookmark = try store.loadSourceRoots().first { $0.id == rootId }?.bookmarkData
                    try store.addSourceRoot(id: rootId, displayName: folder.lastPathComponent,
                                            path: folder.path, bookmark: bookmark ?? existingBookmark, mode: mode,
                                            volumeIdentifier: VolumeMonitor.volumeIdentifier(for: folder))
                }
                try store.updateImportSession(id: run.id.uuidString, rootId: rootId,
                                              state: "completed", totalCount: run.total,
                                              importedCount: run.imported, skippedCount: run.skipped,
                                              failedCount: run.failed, finishedAt: run.finishedAt,
                                              errorMessage: run.errorMessage)
                try store.updateJob(id: activeImportJobId, state: "succeeded", lockedAt: nil,
                                    lastError: run.errorMessage)
            }
        } catch {
            if assetsSaved, !fresh.isEmpty {
                replaceAssetsForMutation(assets + fresh)
            } else if !assetsSaved {
                run.processed = 0
                run.skipped = 0
            }
            let detail = assetsSaved && !fresh.isEmpty
                ? "\(fresh.count) 张照片已写入，但源目录或导入状态未保存"
                : "本次导入未完成"
            failImportPersistence(error, run: run, store: store, detail: detail,
                                  hasSavedAssets: assetsSaved)
            return
        }
        if !fresh.isEmpty { replaceAssetsForMutation(assets + fresh) }
        if let rootId, !fresh.isEmpty || skipped > 0 {
            sourceManagementModesById[rootId] = mode.rawValue
            setSourceFolder(id: rootId, name: folder.lastPathComponent, path: folder.path, status: "online")
            select(Selection(type: .folder, id: rootId, name: folder.lastPathComponent))
        }
        if mode == .referenced, (!fresh.isEmpty || skipped > 0), !watchedRoots.contains(folder) {
            watchedRoots.append(folder)
            refreshWatcher()
        }
        run.phase = .complete
        importRun = run
        lastImportSessionPersistedCount = run.processed + run.failed
        importing = false
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
            colorLabel: ColorLabel(rawValue: importPostColorLabel),
            author: importAuthor, copyright: importCopyright)
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

    private func recoverInterruptedImportJobs(existingAssets: [Asset]) {
        guard !importing, let store else { return }
        do {
            guard let job = try store.loadJobs(type: "scan", states: ["running", "paused"]).first else { return }
            do {
                guard let payload = importJobPayload(from: job), payload.kind == "importFolder",
                      let mode = ImportMode(rawValue: payload.mode) else {
                    throw DBError.step("无法解析导入任务")
                }
                let folder = URL(fileURLWithPath: payload.sourcePath)
                let phase: ImportPhase = job.state == "paused" ? .paused : .importing
                let run = try restoredImportRun(job: job, payload: payload, folder: folder,
                                                mode: mode, phase: phase, store: store)
                guard FileManager.default.fileExists(atPath: folder.path) else {
                    throw DBError.step("源文件夹不可访问")
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
                                       previewMaxPixel: payload.previewMaxPixel ?? previewMaxPixel,
                                       existingIds: Set(existingAssets.map { $0.id }))
            } catch {
                var message = "未能恢复导入：\(error)"
                do {
                    try store.updateJob(id: job.id, state: "failed", lockedAt: nil, lastError: message)
                } catch { message += " · 任务失败状态也未保存：\(error)" }
                push(message, "warning")
            }
        } catch {
            push("读取导入任务失败：\(error)", "warning")
        }
    }

    private func resumeRecoveredImport(_ run: ImportRun) {
        guard let store else { return }
        do {
            guard let activeImportJobId,
                  let job = try store.loadJobs(type: "scan", states: ["running", "paused"])
                    .first(where: { $0.id == activeImportJobId }),
                  let payload = importJobPayload(from: job), payload.kind == "importFolder",
                  let mode = ImportMode(rawValue: payload.mode) else {
                throw DBError.step("导入任务缺失或无法解析")
            }
            let folder = URL(fileURLWithPath: payload.sourcePath)
            _ = try restoredImportRun(job: job, payload: payload, folder: folder,
                                       mode: mode, phase: .paused, store: store)
            guard FileManager.default.fileExists(atPath: folder.path) else {
                throw DBError.step("源文件夹不可访问")
            }
            restartRecoveredImport(jobId: job.id, run: run, folder: folder, mode: mode,
                                   autoTag: payload.autoTag,
                                   archiveRule: recoveredArchiveRule(payload),
                                   readSidecar: payload.readSidecar ?? readXMPSidecar,
                                   previewMaxPixel: payload.previewMaxPixel ?? previewMaxPixel,
                                   existingIds: Set(assets.map { $0.id }))
        } catch {
            failImportPersistence(error, run: run, store: store, detail: "未能恢复导入")
            importControl = nil
            self.activeImportJobId = nil
            importing = false
        }
    }

    private func restartRecoveredImport(jobId: String, run: ImportRun, folder: URL, mode: ImportMode,
                                        autoTag: Bool, archiveRule: ManagedArchiveRule,
                                        readSidecar: Bool, previewMaxPixel: Int,
                                        existingIds: Set<String>) {
        guard let coordinator, let store else { return }
        var runningRun = run
        runningRun.phase = .importing
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
        importing = true
        sheet = "import"
        push("正在恢复导入「\(folder.lastPathComponent)」…", "refresh")

        Task { [weak self, coordinator, store, folder, mode, autoTag, archiveRule, readSidecar, previewMaxPixel, existingIds, sourceId, runningRun, control, knownAssetsById] in
            let imported = await Task.detached(priority: .userInitiated) { [coordinator, folder, mode, autoTag, archiveRule, readSidecar, previewMaxPixel, control, knownAssetsById] in
                coordinator.importFolder(folder, mode: mode, autoTag: autoTag,
                                         archiveRule: archiveRule, readSidecar: readSidecar,
                                         previewMaxPixel: previewMaxPixel, control: control,
                                         knownAssetsById: knownAssetsById) { progress in
                    Task { @MainActor [weak self] in
                        self?.recordImportProgress(progress, for: runningRun.id, store: store)
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

    func restoredImportRun(job: JobRecord, payload: ImportJobPayload, folder: URL,
                           mode: ImportMode, phase: ImportPhase, store: CatalogStore) throws -> ImportRun {
        guard let runId = UUID(uuidString: payload.sessionId),
              let session = try store.loadImportSessions().first(where: { $0.id == payload.sessionId }),
              ["running", "paused"].contains(session.state), session.state == job.state else {
            throw DBError.step("导入会话缺失或状态不一致，不能自动恢复")
        }
        var run = ImportRun(id: runId, source: folder, mode: mode,
                            startedAt: session.startedAt)
        run.phase = phase
        run.total = session.totalCount
        run.skipped = session.skippedCount
        run.failed = session.failedCount
        run.processed = session.importedCount + session.skippedCount
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

    func retryFailedImport() {
        guard !importing, let run = importRun, run.phase.isFinished, !run.failures.isEmpty else { return }
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
        guard startPersistedImport(retry, store: store), let control = importControl else {
            importRun?.failures = run.failures
            return
        }
        let existingIds = Set(assets.map { $0.id })
        let vision = visionEnabled
        let previewSize = previewMaxPixel
        let archiveRule = managedArchiveRule
        let readXMP = readXMPSidecar
        push("正在重试 \(files.count) 个失败文件…", "refresh")
        Task { [weak self, coordinator, store, folder, files, existingIds, retry, vision, archiveRule, readXMP, previewSize, control] in
            let imported = await Task.detached(priority: .userInitiated) { [coordinator, folder, files, retry, vision, archiveRule, readXMP, previewSize, control] in
                coordinator.importFiles(files, from: folder, mode: retry.mode, autoTag: vision,
                                        archiveRule: archiveRule, readSidecar: readXMP,
                                        previewMaxPixel: previewSize, control: control) { progress in
                    Task { @MainActor [weak self] in
                        self?.recordImportProgress(progress, for: retry.id, store: store)
                    }
                }
            }.value
            guard let self else { return }
            self.finishImport(folder: folder, imported: imported, existingIds: existingIds,
                              store: store, bookmark: nil, mode: retry.mode, runId: retry.id,
                              persistSourceRoot: true)
        }
    }

    private func importFailureSummary(_ failures: [ImportFailure]) -> String? {
        guard !failures.isEmpty else { return nil }
        return failures.map { "\($0.filename): \($0.reason)" }.joined(separator: "\n")
    }

    func startPersistedImport(_ run: ImportRun, store: CatalogStore) -> Bool {
        guard !importing else { return false }
        sheet = "import"
        let jobId = "job-" + run.id.uuidString
        do {
            try store.db.transaction {
                try store.startImportSession(id: run.id.uuidString, startedAt: run.startedAt)
                try store.startImportJob(id: jobId, sessionId: run.id.uuidString,
                                         sourcePath: run.sourcePath, mode: run.mode,
                                         autoTag: visionEnabled, archiveRule: managedArchiveRule,
                                         readSidecar: readXMPSidecar, previewMaxPixel: previewMaxPixel)
            }
        } catch {
            failImportPersistence(error, run: run, store: store)
            return false
        }
        importRun = run
        pendingImportRun = nil
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
                                       detail: String = "本次处理结果未保存", hasSavedAssets: Bool = false) {
        var failed = run
        failed.phase = .failed
        failed.finishedAt = .now
        if !hasSavedAssets {
            failed.processed = 0
            failed.skipped = 0
            failed.recentAssets = []
        }
        var messages = ["写入目录库失败：\(error)", detail]
        if let summary = importFailureSummary(run.failures) { messages.append(summary) }
        if let activeImportJobId {
            // Attempt both independently: a broken session must not leave a resumable job.
            do {
                try store.updateJob(id: activeImportJobId, state: "failed", lockedAt: nil,
                                    lastError: messages.joined(separator: " · "))
            } catch { messages.append("任务失败状态也未保存：\(error)") }
            do {
                try store.updateImportSession(id: run.id.uuidString, state: "failed",
                                              totalCount: failed.total, importedCount: failed.imported,
                                              skippedCount: failed.skipped, failedCount: failed.failed,
                                              finishedAt: failed.finishedAt,
                                              errorMessage: messages.joined(separator: " · "))
            } catch { messages.append("会话失败状态也未保存：\(error)") }
        }
        failed.errorMessage = messages.joined(separator: " · ")
        pendingImportRun = nil
        importRun = failed
        // ponytail: cancellation takes effect between files; keep the lock until the current file exits.
        importControl?.cancel()
        push(failed.errorMessage ?? "导入失败", "warning")
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
        guard runsBackgroundMaintenance else { return }
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
        let m = VolumeMonitor { [weak self] in
            self?.detectMissingRealAssets()
            self?.refreshCardVolumes()
        }
        m.start()
        volumeMonitor = m
    }

    // ---------- batch capture-time shift (§4.2 / META-008) ----------
    func shiftCaptureTime(hours: Int, minutes: Int = 0) {
        let totalMinutes = hours * 60 + minutes
        guard totalMinutes != 0 else { return }
        let ids = targetIds
        guard !ids.isEmpty else { return }
        guard mutate(ids, undoName: "调整拍摄时间", {
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
        guard mutate(ids, undoName: "设置拍摄时间", {
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
        let ids = selectionTargetIds
        let real = list.filter { ids.contains($0.id) && hasExistingOriginal($0) }
        guard !real.isEmpty else { push("仅可重命名已导入照片", "warning"); return }
        // a paired JPEG takes the RAW's new base name so the pair survives the rename
        let partners = Dictionary(uniqueKeysWithValues: real.map { primary in
            (primary.id, companions(of: primary).filter(hasExistingOriginal))
        }).filter { !$0.value.isEmpty }
        let fileCount = real.count + partners.values.reduce(0) { $0 + $1.count }
        guard confirmDestructiveAction(
            "重命名原件？",
            "将重命名 \(fileCount) 个磁盘原件，并更新目录库中的文件路径。",
            "重命名"
        ) else { return }
        let map = RenameService.renameWithTemplate(real, template: template, companions: partners)
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
            let rolledBack = OriginalFileOperationService.rollBackMoves(
                map, originals: real + partners.values.flatMap { $0 })
            push("重命名未完成"
                 + (rolledBack > 0 ? " · 已回滚 \(rolledBack) 张照片" : " · 回滚失败")
                 + " · 目录库保存失败",
                 "warning")
            return
        }
        replaceAssetsForMutation(updated)
        let saved = map.count
        push("已重命名 \(saved) 个文件" + (saved < fileCount ? " · \(fileCount - saved) 失败" : ""),
             saved < fileCount ? "warning" : "check")
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
        let ids = selectionTargetIds   // one preview per photo, not per paired file
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

    @ObservationIgnored private var attemptedCacheRepairs = Set<String>()
    @ObservationIgnored private var verifiedCacheSources = Set<String>()
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
        guard runsBackgroundMaintenance, let coordinator, !isBackfilling else { return }
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
                // off the cooperative pool, one at a time at background QoS, so a large
                // backfill never competes with visible repairs or the UI
                _ = await ThumbnailRepairQueue.run(.background) {
                    for a in chunk {
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
        attemptedCacheRepairs.removeAll()
        verifiedCacheSources.removeAll()
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
        if let settings = developSettings[assetId], !settings.isNeutral {
            let edited = thumbnails.editedCachePath(assetId: assetId, kind: resolvedKind, settings: settings).path
            if verifiedCacheSources.contains(edited) { return edited }
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

    /// The ordinary (unadjusted) cached image, repaired from the original when missing or damaged.
    private func cachedImageSource(for asset: Asset, requestedSource: String, kind resolvedKind: ThumbnailService.Kind,
                                   original: URL, fallbackPreview: URL?,
                                   thumbnails: ThumbnailService) async -> String? {
        let assetId = asset.id
        let localPath = original.path
        // A cache file already checked this session (exists, fresh, not a black RAW render)
        // skips the stat + decode hops every time its cell scrolls back into view.
        let verifiedKey = "\(requestedSource)|\(asset.fileModifiedAt?.timeIntervalSince1970 ?? 0)"
        if verifiedCacheSources.contains(verifiedKey) { return requestedSource }
        let cachedIsUsable = await Task.detached(priority: .userInitiated) {
            guard !requestedSource.isEmpty, FileManager.default.fileExists(atPath: requestedSource) else {
                return false
            }
            let cached = URL(fileURLWithPath: requestedSource)
            return !ThumbnailService.cacheIsStale(cache: cached, originalModificationDate: asset.fileModifiedAt)
                && !thumbnails.cachedRepresentationNeedsRegeneration(at: cached, original: original, kind: resolvedKind)
        }.value
        if cachedIsUsable {
            verifiedCacheSources.insert(verifiedKey)
            return requestedSource
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
        // One repair per representation per session: a RAW that decodes black again
        // must not cost another multi-second decode every time its cell reappears.
        let repairKey = "\(assetId)|\(resolvedKind)"
        guard !attemptedCacheRepairs.contains(repairKey) else { return nil }
        guard let restored = await ThumbnailRepairQueue.run(.visible, {
            thumbnails.ensureCached(from: original,
                                    fallbackPreview: fallbackPreview,
                                    catalogModificationDate: asset.fileModifiedAt,
                                    assetId: assetId,
                                    kind: resolvedKind)
        }) else {
            return nil   // cancelled while queued; retry when shown again
        }
        attemptedCacheRepairs.insert(repairKey)
        return restored?.path
    }

    /// Developed rendering for an adjusted photo, rendered off the cooperative pool when missing.
    /// `base` (an already-rendered image) replaces the original; an unavailable original falls
    /// back to adjusting the cached preview.
    private func editedImageSource(for asset: Asset, settings: DevelopSettings, kind: ThumbnailService.Kind,
                                   thumbnails: ThumbnailService, base: String? = nil) async -> String? {
        let edited = thumbnails.editedCachePath(assetId: asset.id, kind: kind, settings: settings)
        let key = edited.path
        if verifiedCacheSources.contains(key) { return key }
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
                                    assetId: assetId, kind: kind)
        }), let rendered else { return nil }
        verifiedCacheSources.insert(rendered.path)
        return rendered.path
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
            if result.0.removedFiles > 0 { self.verifiedCacheSources.removeAll() }
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

    // ---------- rendered export (Lightroom's Export dialog) ----------
    /// The dialog reopens with the settings and folder last used.
    var renderedExportSettings: ExportSettings = AppState.loadJSON(ExportSettings.self, forKey: "pc_renderedExportSettings")
        ?? ExportSettings() {
        didSet { AppState.store(renderedExportSettings, forKey: "pc_renderedExportSettings") }
    }
    var renderedExportFolder: String = UserDefaults.standard.string(forKey: "pc_renderedExportFolder")
        ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("PhotoCatalog 导出").path ?? NSHomeDirectory() {
        didSet { UserDefaults.standard.set(renderedExportFolder, forKey: "pc_renderedExportFolder") }
    }
    var renderedExportPresets: [RenderedExportPreset] =
        AppState.loadJSON([RenderedExportPreset].self, forKey: "pc_renderedExportPresets") ?? [] {
        didSet { AppState.store(renderedExportPresets, forKey: "pc_renderedExportPresets") }
    }
    var allRenderedExportPresets: [RenderedExportPreset] { RenderedExportPreset.builtIns + renderedExportPresets }

    struct RenderedExportJob: Sendable {
        let items: [RenderedExportItem]
        let settings: ExportSettings
        let folder: URL
    }
    struct RenderedExportProgress: Equatable {
        var done: Int
        let total: Int
        var queued: Int
    }
    /// The job being written first, then the ones waiting behind it.
    @ObservationIgnored private var renderedExportJobs: [RenderedExportJob] = []
    var renderedExportProgress: RenderedExportProgress?
    @ObservationIgnored private let renderedExportCancellation = ExportCancellation()
    /// A serial queue of its own: RAW decodes must stay off the Swift cooperative pool, and
    /// one photo at a time bounds memory for 16-bit full-resolution renders.
    private static let renderedExportQueue = DispatchQueue(label: "PhotoCatalog.rendered-export", qos: .utility)

    /// Photos the export dialog would write: selected photos with a local original, in view order.
    func renderedExportItems() -> [RenderedExportItem] {
        let ids = selectionTargetIds
        guard !ids.isEmpty else { return [] }
        var ordered = list.filter { ids.contains($0.id) }
        let listed = Set(ordered.map(\.id))
        ordered += ids.subtracting(listed).sorted().compactMap { id in assetIndex[id].map { assets[$0] } }
        return ordered.compactMap { asset in
            guard asset.status == .ready, !asset.isDemo, !asset.deleted, let path = asset.localPath else { return nil }
            return RenderedExportItem(assetId: asset.id, sourcePath: path, isRaw: asset.isRaw,
                                      develop: developSettings[asset.id] ?? .neutral,
                                      originalSize: CGSize(width: asset.width, height: asset.height),
                                      baseName: (asset.filename as NSString).deletingPathExtension,
                                      date: asset.date, camera: asset.camera, title: asset.title,
                                      caption: asset.caption, keywords: asset.keywords, rating: asset.rating,
                                      author: asset.author, copyright: asset.copyright)
        }
    }

    /// Menu state: stops at the first photo with a local original.
    var canRenderedExport: Bool {
        guard onboarded, sheet == nil, view != .analysis else { return false }
        return selectionTargetIds.contains { id in
            assetIndex[id].map { assets[$0].status == .ready && !assets[$0].isDemo && assets[$0].localPath != nil } ?? false
        }
    }

    /// ⇧⌘E: the export dialog for the selection.
    func showRenderedExport() {
        guard canRenderedExport else {
            push(selectionTargetIds.isEmpty ? "请先选择照片" : "选中的照片没有可用的本地原件", "warning")
            return
        }
        sheet = "renderedExport"
    }

    /// Queues an export of the selection; jobs run one after another in the background.
    func startRenderedExport(settings: ExportSettings, folder: URL) {
        let items = renderedExportItems()
        guard !items.isEmpty else {
            push("没有可导出的照片（需要本地原件）", "warning")
            return
        }
        renderedExportSettings = settings
        renderedExportFolder = folder.path
        let subfolder = settings.subfolder.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        let destination = subfolder.isEmpty ? folder : folder.appendingPathComponent(subfolder, isDirectory: true)
        renderedExportJobs.append(RenderedExportJob(items: items, settings: settings, folder: destination))
        if renderedExportJobs.count == 1 {
            runNextRenderedExport()
        } else {
            renderedExportProgress?.queued = renderedExportJobs.count - 1
            push("已加入导出队列 · 前面还有 \(renderedExportJobs.count - 1) 个任务", "export")
        }
    }

    /// Stops the running export after the photo in progress and drops the queued ones.
    func cancelRenderedExport() {
        guard !renderedExportJobs.isEmpty else { return }
        renderedExportJobs.removeSubrange(1...)
        renderedExportProgress?.queued = 0
        renderedExportCancellation.cancel()
    }

    private func runNextRenderedExport() {
        guard let job = renderedExportJobs.first else {
            renderedExportProgress = nil
            return
        }
        renderedExportProgress = RenderedExportProgress(done: 0, total: job.items.count,
                                                        queued: renderedExportJobs.count - 1)
        let cancellation = renderedExportCancellation
        cancellation.reset()
        Self.renderedExportQueue.async { [weak self] in
            var reserved = Set<String>()
            var written: [URL] = [], skipped = 0, failures: [String] = []
            var folderReady = true
            do {
                try FileManager.default.createDirectory(at: job.folder, withIntermediateDirectories: true)
            } catch {
                failures.append("无法创建导出文件夹：\(error.localizedDescription)")
                folderReady = false
            }
            for (index, item) in job.items.enumerated() where folderReady {
                if cancellation.isCancelled { break }
                switch RenderedExportService.export(item, sequence: job.settings.sequenceStart + index,
                                                    settings: job.settings, to: job.folder, reserved: &reserved) {
                case .written(let url): written.append(url)
                case .skipped: skipped += 1
                case .failed(let reason): failures.append(reason)
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.renderedExportProgress?.done = index + 1 }
                }
            }
            let cancelled = cancellation.isCancelled
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.finishRenderedExport(job, written: written, skipped: skipped, failures: failures,
                                               cancelled: cancelled)
                }
            }
        }
    }

    private func finishRenderedExport(_ job: RenderedExportJob, written: [URL], skipped: Int, failures: [String],
                                      cancelled: Bool) {
        if !renderedExportJobs.isEmpty { renderedExportJobs.removeFirst() }
        var message = cancelled ? "导出已取消 · 已写入 \(written.count) 张" : "已导出 \(written.count) 张照片"
        if skipped > 0 { message += " · \(skipped) 张已存在而跳过" }
        if let first = failures.first { message += " · \(failures.count) 张失败（\(first)）" }
        push(message, failures.isEmpty ? "export" : "warning")
        if job.settings.revealInFinder, !written.isEmpty, !cancelled {
            // selecting thousands of files is slow in Finder; open the folder instead
            if written.count <= 50 {
                NSWorkspace.shared.activateFileViewerSelecting(written)
            } else {
                NSWorkspace.shared.open(job.folder)
            }
        }
        runNextRenderedExport()
    }

    func saveRenderedExportPreset(name: String, settings: ExportSettings) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let index = renderedExportPresets.firstIndex(where: { $0.name == name }) {
            renderedExportPresets[index].settings = settings
        } else {
            renderedExportPresets.append(RenderedExportPreset(id: UUID().uuidString, name: name, settings: settings))
        }
        push("已存储导出预设“\(name)”", "square.and.arrow.down")
    }

    func deleteRenderedExportPreset(_ id: String) {
        renderedExportPresets.removeAll { $0.id == id }
    }

    private static func loadJSON<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
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
            push(selectionTargetIds.isEmpty ? "请先选择照片" : "没有可导出的预览图", "warning")
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
        Task { [weak self, store, packageURL] in
            let url = await Task.detached(priority: .utility) { () -> URL? in
                do {
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
        Task { [weak self, store, packageURL, backupKey, now] in
            let url = await Task.detached(priority: .utility) { () -> URL? in
                do {
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
        developSettings = [:]
        clearFaces()
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
        developSettings = [:]
        clearFaces()
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
    var isAutomaticSimilarityAnalysisLimited: Bool {
        let liveCount = assets.lazy.filter { !$0.isDemo && !$0.deleted }.count
        return !PerceptualHash.canRunAutomaticAnalysis(assetCount: liveCount)
    }
    @ObservationIgnored private var duplicateRecomputeGeneration = 0

    /// Recompute duplicates off the main thread (dHash reads thumbnails from disk).
    func recomputeDuplicates() {
        guard runsBackgroundMaintenance else { return }
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
                var groups = HashService.exactDuplicateGroups(live)
                    + HashService.suspectedDuplicateGroups(live)
                if PerceptualHash.canRunAutomaticAnalysis(assetCount: live.count) {
                    groups += PerceptualHash.similarGroups(live)
                }
                return groups
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
        let pairing = assetPairing
        for a in assets where !a.deleted && !pairing.isHiddenCompanion(a.id) {
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

    var captureDateGroups: [CaptureDateBucket] {
        _ = listInputsVersion
        if let cached = captureDateGroupsCache { return cached }
        let grouped = CaptureDates.groups(presentedAssets())
        captureDateGroupsCache = grouped
        return grouped
    }

    func captureStatisticsRequest(selectedOnly: Bool) -> CaptureStatisticsRequest {
        CaptureStatisticsRequest(list: currentListSignature,
                                 selectedIds: selectedOnly ? selectedIds : nil,
                                 catalogGeneration: catalogLoadGeneration, isLoading: isLoadingCatalog)
    }

    func captureStatistics(for request: CaptureStatisticsRequest) -> CaptureStatistics? {
        guard !request.isLoading,
              request == captureStatisticsRequest(selectedOnly: request.selectedIds != nil),
              let cached = captureStatisticsCache, cached.request == request else { return nil }
        return cached.value
    }

    func loadCaptureStatistics(for request: CaptureStatisticsRequest) async {
        guard !Task.isCancelled, !request.isLoading,
              request == captureStatisticsRequest(selectedOnly: request.selectedIds != nil) else { return }
        captureStatisticsGeneration &+= 1
        let generation = captureStatisticsGeneration
        captureStatisticsTask?.cancel()
        captureStatisticsTask = nil
        if captureStatistics(for: request) != nil { return }

        // Share the grid snapshot, including members hidden inside collapsed stacks.
        // ponytail: filtering is still on the main actor; SQL paging must replace the shared list.
        _ = list
        guard let snapshot = uncollapsedListCache, snapshot.signature == request.list else { return }
        let matching = snapshot.value
        let ids = request.selectedIds
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let samples = ids.map { selected in matching.filter { selected.contains($0.id) } } ?? matching
            return try CaptureStatistics(assets: samples)
        }
        captureStatisticsTask = worker
        defer {
            if captureStatisticsGeneration == generation { captureStatisticsTask = nil }
        }
        do {
            let value = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, captureStatisticsGeneration == generation,
                  request == captureStatisticsRequest(selectedOnly: request.selectedIds != nil) else { return }
            captureStatisticsCache = (request, value)
        } catch {
            // Aggregation only throws CancellationError; cancelled work must never publish.
        }
    }

    /// Library sidebar tallies in one pass, cached and invalidated on assets/recent-days change.
    var libraryCounts: LibraryCounts {
        _ = listInputsVersion   // register the dependency even on a cache hit
        _ = recentImportDays    // its didSet clears this cache without bumping the version
        _ = isLoadingCatalog
        _ = loadingCatalogTotalCount
        if let cache = libraryCountsCache { return cache }
        var counts = LibraryCounts()
        let cutoff = recentCutoff
        let pairing = assetPairing
        for a in assets where !a.deleted {
            if a.status == .missing || a.status == .offline { counts.missingOffline += 1 }
            guard !pairing.isHiddenCompanion(a.id) else { continue }
            counts.all += 1
            if a.importedAt > cutoff { counts.recent += 1 }
            if a.rating == 0 && a.flag != .reject { counts.unrated += 1 }
            if a.flag == .pick { counts.picks += 1 }
            if a.flag == .reject { counts.rejected += 1 }
            if a.hasGPS { counts.places += 1 }
            if a.faces > 0 { counts.people += 1 }
        }
        if isLoadingCatalog, let loadingCatalogTotalCount {
            counts.all = loadingCatalogTotalCount
        }
        libraryCountsCache = counts
        return counts
    }

    private func countMetadataValues(_ keyPath: KeyPath<Asset, String>) -> [KeywordCount] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        let pairing = assetPairing
        for asset in assets where !asset.deleted && !pairing.isHiddenCompanion(asset.id) {
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
        let counts = FolderTreeService.counts(for: items, assets: presentedAssets())
        folderTreeCountCache = counts
        return counts
    }

    private var photoStacks: [PhotoStack] {
        _ = stackInputsVersion   // register the dependency even on a cache hit
        if let cache = photoStacksCache { return cache }
        let stacks = PhotoStackService.stacks(from: duplicateGroupsCache)
        photoStacksCache = stacks
        return stacks
    }

    /// O(1) asset → stack lookup, rebuilt only when the stacks change (invalidated in didSet).
    private var stackByAsset: [String: PhotoStack] {
        _ = stackInputsVersion   // register the dependency even on a cache hit
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
        case .captureDate:
            guard let range = CaptureDates.interval(for: item.selectionId) else { return "0" }
            return "\(assets.filter { !$0.deleted && CaptureDates.contains($0.date, in: range) }.count)"
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
        let live = presentedAssets()
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
        case .captureDate:
            guard let range = CaptureDates.interval(for: item.selectionId),
                  assets.contains(where: { !$0.deleted && CaptureDates.contains($0.date, in: range) }) else { return nil }
            return item
        case .lib:
            return nil
        }
    }

    // ---------- base collection from sidebar ----------
    var baseList: [Asset] {
        // Observed inputs are read once, outside the per-asset predicates, and live +
        // collection membership is one pass: no intermediate copy of every asset.
        let selection = self.selection
        // Missing/offline is file-level: a lost JPEG must show even when its RAW is fine.
        let pairing = selection.type == .lib && selection.id == "missing" ? .empty : assetPairing
        let live: (Asset) -> Bool = { !$0.deleted && !pairing.isHiddenCompanion($0.id) }
        let belongs: (Asset) -> Bool
        switch selection.type {
        case .folder:
            if let item = folderTree.first(where: { $0.id == selection.id }) {
                belongs = { FolderTreeService.matches($0, item: item) }
            } else {
                belongs = { $0.folderId == selection.id }
            }
        case .album:
            guard let al = albums.first(where: { $0.id == selection.id }) else { return [] }
            let memberIds = Set(al.assetIds)
            belongs = { memberIds.contains($0.id) }
        case .smart:
            guard let sa = smartAlbums.first(where: { $0.id == selection.id }) else { return [] }
            return SmartMatcher.match(assets.filter(live), sa.rule)
        case .keyword:
            belongs = { $0.keywords.contains(selection.id) }
        case .project:
            belongs = { $0.project == selection.id }
        case .client:
            belongs = { $0.client == selection.id }
        case .captureDate:
            guard let range = CaptureDates.interval(for: selection.id) else { return [] }
            belongs = { CaptureDates.contains($0.date, in: range) }
        case .lib:
            switch selection.id {
            case "recent":
                let cutoff = recentCutoff
                belongs = { $0.importedAt > cutoff }
            case "unrated":
                belongs = { $0.rating == 0 && $0.flag != .reject }
            case "picks":
                belongs = { $0.flag == .pick }
            case "rejected":
                belongs = { $0.flag == .reject }
            case "missing":
                belongs = { $0.status == .missing || $0.status == .offline }
            case "places":
                belongs = { $0.hasGPS }
            case "people":
                belongs = { $0.faces > 0 }
            default:
                return assets.filter(live)
            }
        }
        return assets.filter { live($0) && belongs($0) }
    }

    // ---------- apply filter bar + search + sort ----------
    var list: [Asset] {
        let signature = currentListSignature
        if let cache = listCache, cache.signature == signature { return cache.value }
        let matching = computeList()
        uncollapsedListCache = (signature, matching)
        let value = PhotoStackService.visibleAssets(matching, stacks: photoStacks, collapsedStackIds: collapsedStackIds)
        listCache = (signature, value)
        return value
    }

    private var currentListSignature: ListSignature {
        ListSignature(inputsVersion: listInputsVersion, selection: selection,
                      filters: filters, search: search, sort: sort,
                      collapsed: collapsedStackIds, recentDays: recentImportDays,
                      captureDay: Calendar.captureWallClock.startOfDay(for: .now))
    }

    private func primeDefaultListCache(with loadedAssets: [Asset]) {
        guard selection.type == .lib, selection.id == "all",
              filters.isEmpty,
              search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              sort == Sort(), collapsedStackIds.isEmpty else { return }
        listCache = (currentListSignature, loadedAssets)
        uncollapsedListCache = (currentListSignature, loadedAssets)
    }

    private func computeList() -> [Asset] {
        // Snapshot observed properties: reading them inside the per-asset filter and the
        // sort comparator paid observation bookkeeping tens of thousands of times.
        let filters = self.filters
        let sort = self.sort
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let pairing = assetPairing
        let indexedSearchIds: Set<String>? = if q.count >= 3, let store {
            // a hit on a hidden JPEG surfaces its RAW's tile
            Set(store.search(q).flatMap { [$0] + (pairing.primaryByCompanion[$0].map { [$0] } ?? []) })
        } else {
            nil
        }
        let cameraQuery = filters.camera.trimmingCharacters(in: .whitespacesAndNewlines)
        let lensQuery = filters.lens.trimmingCharacters(in: .whitespacesAndNewlines)
        let dateInterval = filters.captureDateInterval()
        let base = baseList
        let l = filters.isEmpty && q.isEmpty ? base : base.filter { a in
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
                guard let dateInterval, CaptureDates.contains(a.date, in: dateInterval) else { return false }
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
        return Self.sorted(l, by: sort)
    }

    /// Sorts indices by precomputed keys rather than moving whole `Asset` values
    /// (hundreds of bytes each). Ties keep collection order, as the stable sort did.
    nonisolated static func sorted(_ assets: [Asset], by sort: Sort) -> [Asset] {
        let descending = sort.descending
        var order = Array(assets.indices)
        if sort.field == .name {
            let names = assets.map(\.filename)
            order.sort { i, j in
                switch names[i].localizedCompare(names[j]) {
                case .orderedSame: return i < j
                case .orderedAscending: return !descending
                case .orderedDescending: return descending
                }
            }
        } else {
            let keys: [Double] = switch sort.field {
            case .capture: assets.map { $0.date.timeIntervalSince1970 }
            case .imported: assets.map { $0.importedAt.timeIntervalSince1970 }
            case .rating: assets.map { Double($0.rating) }
            case .size: assets.map(\.fileMB)
            case .name: []
            }
            order.sort { i, j in
                if keys[i] == keys[j] { return i < j }
                return descending ? keys[i] > keys[j] : keys[i] < keys[j]
            }
        }
        return order.map { assets[$0] }
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

    var canChangeVisibleSelection: Bool {
        onboarded && !isLoadingCatalog && sheet == nil && view != .compare
    }

    @discardableResult
    func selectAllVisible() -> Bool {
        guard canChangeVisibleSelection else { return false }
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
        guard canChangeVisibleSelection else { return false }
        let ids = list.map(\.id)
        guard !ids.isEmpty else { return false }
        let visible = Set(ids)
        selectedIds = visible.subtracting(selectedIds)
        primaryId = ids.first { selectedIds.contains($0) }
        anchorId = primaryId
        return true
    }

    // Self-checks must exercise interactions, not the launch-loading guard.
    /// Off for benchmarks: thumbnail backfill, the availability scan and duplicate grouping
    /// would compete with what is being timed (and flag synthetic photos as missing).
    @ObservationIgnored var runsBackgroundMaintenance = true

    /// The post-load step of opening a catalog, for the large-catalog benchmark.
    func applyLoadedCatalogForScaleCheck(_ loaded: [Asset], from store: CatalogStore) {
        applyLoadedCatalog(loaded, from: store)
    }

    /// A fixture backed by a scratch catalog, for checks of catalog-persisted features. It never
    /// goes through openCatalog, which would remember the scratch catalog in preferences.
    static func selfCheckFixture(store: CatalogStore) -> AppState {
        let app = selfCheckFixture()
        app.store = store
        return app
    }

    static func selfCheckFixture() -> AppState {
        let app = AppState(arguments: [], deferCatalogLoading: true)
        app.deferredCatalogArguments = nil
        app.isLoadingCatalog = false
        app.onboarded = true
        return app
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
        loupeZoom = nil
        view = .loupe
    }

    func setPrimary(_ id: String) {
        primaryId = id
        selectedIds = [id]
        anchorId = id
    }

    // ---------- mutations ----------
    /// What the user selected (one id per tile).
    private var selectionTargetIds: Set<String> {
        if !selectedIds.isEmpty { return selectedIds }
        if let p = primaryId { return [p] }
        return []
    }

    /// Files an edit or file operation acts on: the selection plus paired JPEG/HEIC files.
    private var targetIds: Set<String> { withCompanions(selectionTargetIds) }

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
        selectionTargetIds.contains { id in
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
    func mutate(_ ids: Set<String>? = nil, undoName: String? = nil,
                _ transform: (inout Asset) -> Void) -> Bool {
        let target = ids ?? targetIds
        guard !target.isEmpty else { return false }
        var updated = assets
        var before: [Asset] = []
        for i in updated.indices where target.contains(updated[i].id) {
            before.append(updated[i])
            transform(&updated[i])
        }
        guard persist(target, in: updated) else { return false }
        replaceAssetsForMutation(updated)
        ensurePrimaryValid()
        registerUndo(restoring: before, actionName: undoName)
        return true
    }

    @discardableResult
    func mutateAsset(_ id: String, scope: AssetEditScope = .any, withCompanions: Bool = false,
                     undoName: String? = nil, _ transform: (inout Asset) -> Void) -> Bool {
        let ids = withCompanions ? self.withCompanions([id]) : [id]
        let offsets = ids.compactMap { assetIndex[$0] }
        guard !offsets.isEmpty else { return false }
        var updated = assets
        let before = offsets.map { assets[$0] }
        for offset in offsets { transform(&updated[offset]) }
        guard persist(ids, in: updated) else { return false }
        registerUndo(restoring: before, actionName: undoName)
        replaceAssetsForMutation(updated, scope: scope)
        ensurePrimaryValid()
        return true
    }

    @discardableResult
    func setRating(_ n: Int) -> Bool {
        mutateIndexedMetadata(undoName: "评分", { $0.rating = n }) { store, ids in
            try store.updateRatings(n, assetIDs: ids)
        }
    }
    @discardableResult
    func setFlag(_ f: Flag) -> Bool {
        mutateIndexedMetadata(undoName: "旗标", { $0.flag = f }) { store, ids in
            try store.updateFlags(f, assetIDs: ids)
        }
    }
    @discardableResult
    func setColor(_ c: ColorLabel?) -> Bool {
        mutateIndexedMetadata(undoName: "颜色标签", { $0.colorLabel = c }) { store, ids in
            try store.updateColorLabels(c, assetIDs: ids)
        }
    }

    private func mutateIndexedMetadata(
        undoName: String,
        _ transform: (inout Asset) -> Void,
        persist: (CatalogStore, Set<String>) throws -> Void
    ) -> Bool {
        let ids = targetIds
        guard !ids.isEmpty else { return false }
        // Edit copies of only the targeted assets, persist, then write them back in place:
        // copying the whole array retained every string of every asset on each keystroke.
        let index = assetIndex
        let edits = ids.compactMap { id -> (offset: Int, asset: Asset)? in
            guard let offset = index[id] else { return nil }
            var asset = assets[offset]
            transform(&asset)
            return (offset, asset)
        }.sorted { $0.offset < $1.offset }
        let changed = edits.map(\.asset).filter { !$0.isDemo }
        if let store, !changed.isEmpty {
            do {
                try persist(store, Set(changed.map(\.id)))
            } catch {
                push("保存失败，更改未写入目录库", "warning")
                return false
            }
        }
        registerUndo(restoring: edits.map { assets[$0.offset] }, actionName: undoName)
        applyAssetEdits(edits, scope: .review)
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
        let ids = selectionTargetIds
        let companions = assetPairing.companionsByPrimary
        return list.map(\.id).filter { ids.contains($0) }.flatMap { [$0] + (companions[$0] ?? []) }
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

    /// Handles a Finder drop: the catalog manages originals by folder, so folders import and
    /// the catalog's own files (a photo dragged back onto the grid) are ignored.
    @discardableResult
    func importDroppedItems(_ urls: [URL]) -> Bool {
        let known = Set(assets.compactMap(\.localPath))
        let external = urls.filter { !known.contains($0.path) }
        guard !external.isEmpty else { return false }
        let folders = external.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        guard let folder = folders.first else {
            push("请拖入文件夹：目录库按文件夹管理原件", "info")
            return false
        }
        if folders.count > 1 { push("一次导入一个文件夹，先导入「\(folder.lastPathComponent)」", "info") }
        importFolder(folder)
        return true
    }

    /// Right-click acts on the selection when the clicked photo is part of it, else on that photo.
    func prepareContextSelection(_ id: String) {
        if !selectedIds.contains(id) { setPrimary(id) }
    }

    /// Existing original files of the selection in grid order; paired JPEGs on request.
    func selectionOriginalURLs(includingCompanions: Bool = false) -> [URL] {
        let ids = includingCompanions ? targetIds : selectionTargetIds
        let companions = includingCompanions ? assetPairing.companionsByPrimary : [:]
        let fm = FileManager.default
        return list.filter { ids.contains($0.id) }
            .flatMap { [$0] + (companions[$0.id] ?? []).compactMap { id in assetIndex[id].map { assets[$0] } } }
            .compactMap { $0.localPath }
            .filter { fm.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Opens the selection's originals — paired RAWs open as the RAW — in `app` or each file's default app.
    func openSelection(with app: URL? = nil) {
        let urls = selectionOriginalURLs()
        guard !urls.isEmpty else {
            push("所选照片没有可访问的原件", "warning")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        if let app {
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: configuration)
        } else {
            for url in urls { NSWorkspace.shared.open(url) }
        }
    }

    func revealSelectionInFinder() {
        let urls = selectionOriginalURLs(includingCompanions: true)
        guard !urls.isEmpty else {
            push("所选照片没有可访问的原件", "warning")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
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
        mutate(undoName: "添加关键词") {
            for keyword in keywords where !$0.keywords.contains(keyword) {
                $0.keywords.append(keyword)
            }
        }
    }
    func removeKeyword(_ kw: String) {
        mutate(undoName: "移除关键词") { $0.keywords.removeAll { $0 == kw } }
    }

    // ---------- location: place on a map, match a GPX track ----------
    /// A GPX file loaded for the matching dialog.
    var gpxTrack: (name: String, track: GPXTrack)?

    /// Photos a location edit applies to: the selection, or the photo in Loupe / Develop.
    var locationTargetIds: Set<String> {
        let ids = selectionTargetIds
        return Set(ids.filter { id in assetIndex[id].map { !assets[$0].deleted } ?? false })
    }

    var canEditLocation: Bool { onboarded && sheet == nil && !locationTargetIds.isEmpty }

    func showLocationEditor() {
        guard canEditLocation else { return }
        sheet = "location"
    }

    /// Where the location editor opens: the spot the selected photos share, else the primary's.
    var locationEditorStart: (Double, Double)? {
        let located = locationTargetIds.compactMap { id in assetIndex[id].map { assets[$0] } }.filter(\.hasGPS)
        if let first = located.first,
           located.count == locationTargetIds.count,
           located.allSatisfy({ $0.gps.0 == first.gps.0 && $0.gps.1 == first.gps.1 }) {
            return first.gps
        }
        return primary.flatMap { $0.hasGPS ? $0.gps : nil }
    }

    /// Sets (or with nil removes) the location of `ids`, as one undoable step.
    @discardableResult
    func setLocation(_ coordinate: (Double, Double)?, altitude: Double? = nil, for ids: Set<String>) -> Bool {
        guard !ids.isEmpty else { return false }
        // a RAW's paired JPEG was taken at the same spot
        let applied = mutate(withCompanions(ids), undoName: coordinate == nil ? "移除位置" : "设置位置") { asset in
            asset.gps = coordinate ?? (0, 0)
            asset.gpsAltitude = coordinate == nil ? nil : altitude
            asset.location = Asset.locationLabel(coordinate)
        }
        if applied {
            push(coordinate == nil ? "已移除 \(ids.count) 张照片的位置" : "已为 \(ids.count) 张照片设置位置", "location")
        }
        return applied
    }

    /// Opens a .gpx file and the matching dialog.
    func chooseGPXTrack() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "gpx") ?? .xml]
        panel.prompt = "打开轨迹"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let track = GPXParser.parse(contentsOf: url), !track.points.isEmpty else {
            push("「\(url.lastPathComponent)」里没有带时间的轨迹点", "warning")
            return
        }
        gpxTrack = (url.lastPathComponent, track)
        sheet = "gpx"
    }

    /// Where each photo of `ids` was along the track. Capture times are the camera's wall clock,
    /// so `cameraUTCOffset` (seconds) turns them into the track's UTC instants. Photos that
    /// already have a location are left alone unless `overwrite`.
    func gpxMatches(_ track: GPXTrack, ids: Set<String>, cameraUTCOffset: Int,
                    overwrite: Bool) -> [String: GPXPoint] {
        var matches: [String: GPXPoint] = [:]
        for id in ids {
            guard let index = assetIndex[id] else { continue }
            let asset = assets[index]
            guard overwrite || !asset.hasGPS else { continue }
            let instant = GPXTrack.instant(ofCapture: asset.date, cameraUTCOffset: cameraUTCOffset)
            if let point = track.location(at: instant) { matches[id] = point }
        }
        return matches
    }

    @discardableResult
    func applyGPXMatches(_ matches: [String: GPXPoint]) -> Bool {
        guard !matches.isEmpty else { return false }
        var points = matches
        for (id, point) in matches {
            for companion in withCompanions([id]) where points[companion] == nil { points[companion] = point }
        }
        let applied = mutate(Set(points.keys), undoName: "匹配 GPX 位置") { asset in
            guard let point = points[asset.id] else { return }
            asset.gps = (point.latitude, point.longitude)
            asset.gpsAltitude = point.elevation
            asset.location = Asset.locationLabel(asset.gps)
        }
        if applied { push("已按轨迹为 \(matches.count) 张照片添加位置", "location") }
        return applied
    }

    // ---------- people: faces found on device, grouped and named ----------
    /// Faces by id, loaded with the catalog; views observe `facesRevision`.
    @ObservationIgnored private(set) var faces: [String: FaceRecord] = [:]
    @ObservationIgnored private var faceScannedAssetIds: Set<String> = []
    var facesRevision = 0
    /// Unnamed faces in likely-one-person groups, largest first.
    var faceClusters: [FaceCluster] = []
    /// Progress while photos are being analysed.
    var faceAnalysis: (done: Int, total: Int)?
    @ObservationIgnored private var faceAnalysisGeneration = 0
    @ObservationIgnored private var peopleCache: (revision: Int, people: [PersonSummary])?
    /// One photo at a time, off the cooperative pool: originals without a preview may be RAWs.
    private static let faceQueue = DispatchQueue(label: "PhotoCatalog.faces", qos: .utility)

    struct PersonSummary: Identifiable, Equatable {
        let name: String
        let faceIds: [String]
        let photoCount: Int
        let coverFaceId: String
        /// Faces matched automatically and not yet confirmed.
        let unconfirmed: Int
        var id: String { name }
    }

    func loadFaces(from store: CatalogStore) {
        let loaded = (try? store.loadFaces()) ?? []
        faces = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        faceScannedAssetIds = (try? store.loadFaceScannedAssetIds()) ?? []
        faceClusters = []
        facesRevision &+= 1
        refreshFaceClusters()
    }

    private func clearFaces() {
        faceAnalysisGeneration &+= 1
        faceAnalysis = nil
        faces = [:]
        faceScannedAssetIds = []
        faceClusters = []
        facesRevision &+= 1
    }

    /// Named people, most photographed first.
    var people: [PersonSummary] {
        _ = facesRevision
        if let cache = peopleCache, cache.revision == facesRevision { return cache.people }
        var byPerson: [String: [FaceRecord]] = [:]
        for face in faces.values {
            if let person = face.person { byPerson[person, default: []].append(face) }
        }
        let result = byPerson.map { name, faces in
            let best = faces.max { ($0.confirmed ? 1 : 0, $0.quality) < ($1.confirmed ? 1 : 0, $1.quality) }!
            return PersonSummary(name: name, faceIds: faces.map(\.id),
                                 photoCount: Set(faces.filter(\.confirmed).map(\.assetId)).count,
                                 coverFaceId: best.id, unconfirmed: faces.filter { !$0.confirmed }.count)
        }
        .sorted { ($0.photoCount, $1.name) > ($1.photoCount, $0.name) }
        peopleCache = (facesRevision, result)
        return result
    }

    /// Photos not yet analysed (a RAW's paired JPEG is covered by the RAW).
    var faceUnscannedCount: Int {
        _ = facesRevision
        return presentedAssets().filter { !$0.isDemo && !faceScannedAssetIds.contains($0.id) }.count
    }

    var faceScannedCount: Int {
        _ = facesRevision
        return faceScannedAssetIds.count
    }

    func face(_ id: String) -> FaceRecord? { faces[id] }

    func asset(id: String) -> Asset? { assetIndex[id].map { assets[$0] } }

    /// A person's photos in the grid, through their `人物/名字` keyword.
    func showPhotos(of person: String) {
        select(Selection(type: .keyword, id: FaceClustering.keyword(for: person), name: person))
        view = .grid
    }

    /// Re-groups unnamed faces off the main thread.
    private func refreshFaceClusters() {
        let unnamed = faces.values.filter { $0.person == nil }
        let revision = facesRevision
        Task.detached(priority: .utility) { [weak self] in
            let clusters = FaceClustering.clusters(unnamed)
            await MainActor.run { [weak self] in
                guard let self, self.facesRevision == revision else { return }
                self.faceClusters = clusters
            }
        }
    }

    /// Looks for faces in every photo not analysed yet — from the cached preview, else the
    /// original — then names new faces that closely match someone already named.
    func startFaceAnalysis() {
        guard faceAnalysis == nil, store != nil else { return }
        let pending = presentedAssets().filter { !$0.isDemo && !faceScannedAssetIds.contains($0.id) }
        guard !pending.isEmpty else { return }
        faceAnalysisGeneration &+= 1
        let generation = faceAnalysisGeneration
        faceAnalysis = (0, pending.count)
        let inputs = pending.map { asset in
            (id: asset.id, preview: asset.preview.hasPrefix("http") ? "" : asset.preview, original: asset.localPath ?? "",
             isRaw: asset.isRaw)
        }
        Self.faceQueue.async { [weak self] in
            var batch: [String: [FaceRecord]] = [:]
            for (index, input) in inputs.enumerated() {
                let usePreview = !input.preview.isEmpty && FileManager.default.fileExists(atPath: input.preview)
                let path = usePreview ? input.preview : input.original
                let detected = path.isEmpty ? nil : autoreleasepool {
                    FaceService.faces(in: URL(fileURLWithPath: path), embeddedPreview: !usePreview && input.isRaw)
                }
                if let detected {   // an unreadable photo stays unscanned for a later try
                    batch[input.id] = detected.enumerated().map { offset, face in
                        FaceRecord(id: "\(input.id)-f\(offset)", assetId: input.id, box: face.box,
                                   quality: face.quality, vector: face.vector)
                    }
                }
                let last = index == inputs.count - 1
                if batch.count >= 24 || last {
                    let chunk = batch
                    batch = [:]
                    let done = index + 1
                    let keepGoing = DispatchQueue.main.sync {
                        MainActor.assumeIsolated { self?.recordFaceScans(chunk, done: done, generation: generation) ?? false }
                    }
                    if !keepGoing { return }
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finishFaceAnalysis(generation: generation) }
            }
        }
    }

    func cancelFaceAnalysis() {
        faceAnalysisGeneration &+= 1
        faceAnalysis = nil
    }

    /// Saves a batch of scans; false stops the worker (cancelled or the catalog changed).
    private func recordFaceScans(_ scans: [String: [FaceRecord]], done: Int, generation: Int) -> Bool {
        guard generation == faceAnalysisGeneration, let store else { return false }
        do {
            try store.saveFaceScans(scans)
        } catch {
            push("保存人脸分析结果失败", "warning")
            faceAnalysis = nil
            return false
        }
        for (assetId, found) in scans {
            faceScannedAssetIds.insert(assetId)
            for face in found { faces[face.id] = face }
        }
        faceAnalysis?.done = done
        facesRevision &+= 1
        // groups fill in as the analysis goes, not only at the end
        if done / 240 != (done - scans.count) / 240 { refreshFaceClusters() }
        return true
    }

    private func finishFaceAnalysis(generation: Int) {
        guard generation == faceAnalysisGeneration else { return }
        faceAnalysis = nil
        let unnamed = faces.values.filter { $0.person == nil }
        let matches = FaceClustering.matches(for: unnamed, named: Array(faces.values))
        if !matches.isEmpty {
            applyFaceNames(matches.mapValues { ($0, false) }, undoName: nil)
            push("找到 \(matches.count) 张可能是已命名人物的人脸，请在“人物”中确认", "person")
        }
        refreshFaceClusters()
    }

    /// Names a group of faces (merging into anyone already called `name`) and tags their photos.
    func nameFaces(_ ids: [String], as rawName: String) {
        let name = FaceClustering.cleanName(rawName)
        guard !name.isEmpty, !ids.isEmpty else { return }
        applyFaceNames(Dictionary(uniqueKeysWithValues: ids.map { ($0, (name, true)) }), undoName: "命名人物")
    }

    /// Confirms a person's suggested faces (all of them, or just `ids`).
    func confirmFaces(of person: String, ids: [String]? = nil) {
        let targets = ids ?? faces.values.filter { $0.person == person && !$0.confirmed }.map(\.id)
        applyFaceNames(Dictionary(uniqueKeysWithValues: targets.map { ($0, (person, true)) }), undoName: "确认人物")
    }

    /// "Not this person": the face goes back to the unnamed groups, and the photo loses the
    /// person's keyword unless another face in it is the same person.
    func removeFaceFromPerson(_ id: String) {
        guard let face = faces[id], face.person != nil else { return }
        setFaceStates([id: (nil, false)], undoName: "不是此人")
        refreshFaceClusters()
    }

    /// Person names on faces, plus the matching `人物/…` keywords on their photos; one undo step.
    private func applyFaceNames(_ changes: [String: (String, Bool)], undoName: String?) {
        guard !changes.isEmpty else { return }
        setFaceStates(changes.mapValues { (person: Optional($0.0), confirmed: $0.1) }, undoName: undoName)
        faceClusters = faceClusters.compactMap { cluster in
            let rest = cluster.faceIds.filter { changes[$0] == nil }
            return rest.isEmpty ? nil : FaceCluster(id: rest.contains(cluster.id) ? cluster.id : rest[0], faceIds: rest)
        }
    }

    /// Writes face names and keeps photo keywords in step: a photo carries `人物/名字` exactly
    /// when one of its faces is named so.
    private func setFaceStates(_ changes: [String: (person: String?, confirmed: Bool)], undoName: String?) {
        guard let store else { return }
        let before = Dictionary(uniqueKeysWithValues: changes.keys.compactMap { id in
            faces[id].map { (id, (person: $0.person, confirmed: $0.confirmed)) }
        })
        do {
            try store.setFacePeople(changes)
        } catch {
            push("保存人物失败", "warning")
            return
        }
        var touchedAssets = Set<String>()
        var names = Set<String>()
        for (id, change) in changes {
            guard var face = faces[id] else { continue }
            if let person = face.person { names.insert(person) }
            if let person = change.person { names.insert(person) }
            face.person = change.person
            face.confirmed = change.confirmed
            faces[id] = face
            touchedAssets.insert(face.assetId)
        }
        facesRevision &+= 1
        syncPersonKeywords(for: touchedAssets, names: names)
        guard let undoName, let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { app in
            MainActor.assumeIsolated {
                app.setFaceStates(before, undoName: undoName)
                app.refreshFaceClusters()
            }
        }
        undoManager.setActionName(undoName)
    }

    /// Makes the `人物/名字` keywords of `names` match the confirmed faces on each photo (and
    /// its paired JPEG). Suggestions wait for confirmation, and only these names are touched,
    /// so person keywords typed by hand survive.
    private func syncPersonKeywords(for assetIds: Set<String>, names: Set<String>) {
        guard !names.isEmpty else { return }
        var present: [String: Set<String>] = [:]
        for face in faces.values where assetIds.contains(face.assetId) {
            if face.confirmed, let person = face.person, names.contains(person) {
                present[face.assetId, default: []].insert(person)
            }
        }
        var wanted: [String: Set<String>] = [:]
        for id in assetIds {
            for member in withCompanions([id]) { wanted[member, default: []].formUnion(present[id] ?? []) }
        }
        let managed = Set(names.map(FaceClustering.keyword))
        let root = FaceClustering.keywordRoot
        let changed = Set(wanted.keys.filter { id in
            guard let index = assetIndex[id] else { return false }
            let keywords = assets[index].keywords
            let current = Set(keywords).intersection(managed)
            let orphanedRoot = keywords.contains(root) && !keywords.contains { $0.hasPrefix(root + "/") }
            return orphanedRoot || current != Set((wanted[id] ?? []).map(FaceClustering.keyword))
        })
        guard !changed.isEmpty else { return }
        // keywords follow the faces; the face edit carries the undo
        let registered = undoManager
        undoManager = nil
        mutate(changed) { asset in
            var keywords = asset.keywords.filter { !managed.contains($0) }
            keywords += (wanted[asset.id] ?? []).sorted().map(FaceClustering.keyword)
            // the bare 人物 parent goes once nothing sits under it
            if !keywords.contains(where: { $0.hasPrefix(root + "/") }) { keywords.removeAll { $0 == root } }
            asset.keywords = KeywordService.normalize(keywords)
        }
        undoManager = registered
    }

    /// Keeps face names in step when a `人物/…` keyword is renamed or deleted from the sidebar.
    private func syncFacesAfterKeywordChange(old: String, new: String?, undoName: String) {
        guard let oldPerson = FaceClustering.person(fromKeyword: old) else {
            // renaming or deleting the whole 人物 branch touches every person
            guard old == FaceClustering.keywordRoot else { return }
            var changes: [String: (person: String?, confirmed: Bool)] = [:]
            for face in faces.values {
                guard let person = face.person else { continue }
                let renamed = new.flatMap { FaceClustering.person(fromKeyword: $0 + "/" + person) }
                changes[face.id] = (renamed, renamed == nil ? false : face.confirmed)
            }
            if !changes.isEmpty { setFaceStates(changes, undoName: undoName) }
            return
        }
        let newPerson = new.flatMap(FaceClustering.person(fromKeyword:))
        var changes: [String: (person: String?, confirmed: Bool)] = [:]
        for face in faces.values where face.person == oldPerson {
            changes[face.id] = (newPerson, newPerson == nil ? false : face.confirmed)
        }
        guard !changes.isEmpty else { return }
        // same undo group as the keyword edit, so undo restores both together
        setFaceStates(changes, undoName: undoName)
        if newPerson == nil { refreshFaceClusters() }
    }

    func renamePerson(_ old: String, to new: String) {
        let name = FaceClustering.cleanName(new)
        guard !name.isEmpty, name != old else { return }
        renameKeyword(FaceClustering.keyword(for: old), to: FaceClustering.keyword(for: name))
    }

    func deletePerson(_ name: String) {
        deleteKeyword(FaceClustering.keyword(for: name))
    }

    /// Photos carrying `keyword` or anything under it, across the whole catalog.
    func photoIds(withKeyword keyword: String) -> Set<String> {
        Set(assets.lazy.filter { !$0.deleted && $0.keywords.contains { KeywordService.isWithin($0, keyword) } }
            .map(\.id))
    }

    /// Renames a keyword and its sub-keywords on every photo; an existing name merges them.
    @discardableResult
    func renameKeyword(_ old: String, to new: String) -> Bool {
        // never into its own subtree ("旅行" → "旅行/日本" would nest every keyword under itself)
        guard let target = KeywordService.normalize(new).last, target != old,
              !target.hasPrefix(old + "/") else { return false }
        let ids = photoIds(withKeyword: old)
        guard !ids.isEmpty,
              mutate(ids, undoName: "重命名关键词", { $0.keywords = KeywordService.replacing(old, with: target, in: $0.keywords) })
        else { return false }
        syncFacesAfterKeywordChange(old: old, new: target, undoName: "重命名关键词")
        if selection.type == .keyword, KeywordService.isWithin(selection.id, old) {
            let renamed = target + selection.id.dropFirst(old.count)
            select(Selection(type: .keyword, id: renamed, name: renamed))
        }
        push("已将「\(old)」重命名为「\(target)」· \(ids.count) 张照片", "tag")
        return true
    }

    /// Removes a keyword and its sub-keywords from every photo.
    @discardableResult
    func deleteKeyword(_ keyword: String) -> Bool {
        let ids = photoIds(withKeyword: keyword)
        guard !ids.isEmpty,
              mutate(ids, undoName: "删除关键词", { $0.keywords = KeywordService.replacing(keyword, with: nil, in: $0.keywords) })
        else { return false }
        syncFacesAfterKeywordChange(old: keyword, new: nil, undoName: "删除关键词")
        if selection.type == .keyword, KeywordService.isWithin(selection.id, keyword) {
            select(Selection(type: .lib, id: "all", name: "全部照片"))
        }
        push("已从 \(ids.count) 张照片中删除关键词「\(keyword)」", "tag")
        return true
    }

    /// Asks for a new name; typing an existing keyword merges into it.
    func promptRenameKeyword(_ keyword: String) {
        let alert = NSAlert()
        alert.messageText = "重命名关键词「\(keyword)」"
        alert.informativeText = "用于 \(photoIds(withKeyword: keyword).count) 张照片，下级关键词一并更新。输入已有的关键词即合并。"
        let field = NSTextField(string: keyword)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "重命名")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != keyword else { return }
        if !renameKeyword(keyword, to: name) { push("无法重命名为「\(name)」", "warning") }
    }

    func confirmDeleteKeyword(_ keyword: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "删除关键词「\(keyword)」？"
        alert.informativeText = "将从 \(photoIds(withKeyword: keyword).count) 张照片中移除它及其下级关键词。可以撤销。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        deleteKeyword(keyword)
    }

    func removeSelected() {
        let ids = targetIds
        guard !ids.isEmpty else { return }
        let photoCount = selectionTargetIds.count
        guard mutate(ids, undoName: "从目录库移除", { $0.deleted = true }) else { return }
        purgeCacheFiles(forAssetIds: ids)
        push("已从目录库移除 \(photoCount) 张（原件保留）", "trash")
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
        alert.informativeText = "将 \(selectionTargetIds.count) 张照片从目录库移除。原件默认保留。"
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
        if (v == .analysis || v == .develop) && isDuplicates {
            select(Selection(type: .lib, id: "all", name: "全部照片"))
        }
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
        if isLoadingCatalog { return true }
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
                } else if view != .analysis {
                    showInspector.toggle()
                }
            case "e":
                if hasShift {
                    showRenderedExport()
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
                guard !hasShift, canSaveCurrentFilter else { return false }   // ⇧⌘S syncs settings (menu)
                saveCurrentFilterAsSmartAlbum()
            case "a":
                guard canChangeVisibleSelection else { return true }
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
                guard view != .analysis else { return true }
                trashSelectedOriginals()
            default:
                return false
            }
            return true
        }
        guard onboarded else { return false }

        if view == .analysis && ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "p", "x", "u", "s", "delete", "backspace"].contains(key) {
            return false
        }

        switch key {
        case "escape":
            guard dismissTransientUI() else { return false }
        case "return":
            if view == .develop, developCropping {
                developCropping = false
                return true
            }
            guard let primaryId else { return false }
            openLoupe(primaryId)
        case "1", "2", "3", "4", "5", "0", "p", "x", "u", "6", "7", "8", "9":
            guard applyReviewKey(key, advance: hasShift || autoAdvance) else { return false }
        case "tab":
            togglePanels()
        case "f":
            toggleFilterBar()
        case "g":
            view = .grid
        case "e", " ":
            view = (view == .loupe) ? .grid : .loupe
        case "c":
            enterCompare()
        case "z":
            guard toggleZoom() else { return false }
        case "d":
            switchView(.develop)
        case "\\":
            guard view == .develop else { return false }
            developShowsOriginal.toggle()
        case "r":
            toggleCropTool()
        case "a":
            switchView(.analysis)
        case "i":
            toggleGridInfo()
        case "s":
            toggleStackForPrimary()
        case "up", "down", "left", "right":
            if view == .compare || view == .analysis { return false }
            moveSelection(key)
        case "delete", "backspace":
            confirmDeleteSelected()
        default:
            return false
        }
        return true
    }

    /// Rating / flag / color keys. The cursor keeps its place: a photo that leaves the view
    /// (rated inside 未评分) hands over to the one that slides into its slot, and `advance`
    /// moves one further — only for a single photo in Grid or Loupe, never a batch.
    private func applyReviewKey(_ key: String, advance: Bool) -> Bool {
        guard !targetIds.isEmpty else { return false }
        let before = list.map(\.id)
        let current = primaryId
        let slot = current.flatMap { before.firstIndex(of: $0) }
        let applied: Bool
        switch key {
        case "0", "1", "2", "3", "4", "5":
            applied = applyRatingShortcut(Int(key) ?? 0)
        case "p":
            applied = setFlag(.pick)
            if applied { push("标记为精选", "flag") }
        case "x":
            applied = setFlag(.reject)
            if applied { push("标记为拒绝", "reject") }
        case "u":
            applied = setFlag(.none)
            if applied { push("已清除旗标") }
        default:
            let color: ColorLabel = ["6": .red, "7": .yellow, "8": .green][key] ?? .blue
            applied = setColor(color)
            if applied { push("颜色标签：\(color.name)", "tag") }
        }
        guard applied, let current, let slot, selectionTargetIds.count <= 1,
              view == .grid || view == .loupe else { return applied }
        let ids = list.map(\.id)
        guard !ids.isEmpty else { return true }
        let next = ids.firstIndex(of: current).map { advance ? $0 + 1 : $0 } ?? slot
        let target = ids[min(ids.count - 1, next)]
        if target != primaryId { setPrimary(target) }
        return true
    }

    /// Selects every rejected photo in the current view and offers to remove them.
    func confirmRemoveRejected() {
        let rejected = list.filter { $0.flag == .reject }.map(\.id)
        guard !rejected.isEmpty else {
            push("当前视图中没有被拒绝的照片", "info")
            return
        }
        selectedIds = Set(rejected)
        primaryId = rejected.first
        confirmDeleteSelected()
    }

    private func moveSelection(_ key: String) {
        let ids = list.map { $0.id }
        guard let cur = ids.firstIndex(of: primaryId ?? "") else { return }
        var cols = 1
        if view == .grid {
            // same metrics as GridView so arrow nav lands on the right row
            cols = GridMetrics(width: gridWidth ?? 800, target: thumbSize).columns
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

extension AppAppearance {
    static let defaultsKey = "pc_appearance"
    static var stored: AppAppearance {
        AppAppearance(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .system
    }

    /// AppKit-level so menus, sheets and alerts follow along; `nil` tracks the system.
    @MainActor func apply() {
        let name: NSAppearance.Name? = switch self {
        case .system: nil
        case .light: .aqua
        case .dark: .darkAqua
        }
        NSApp.appearance = name.flatMap(NSAppearance.init(named:))
    }
}

/// Grid layout shared by GridView and arrow-key navigation. `target` is the
/// minimum cell size; cells grow to fill the row instead of leaving a ragged gap.
struct GridMetrics: Equatable {
    let columns: Int
    let cellSize: CGFloat
    let spacing: CGFloat

    init(width: CGFloat, target: CGFloat) {
        let spacing = max(6, (target * 0.05).rounded())
        let columns = max(1, Int((width + spacing) / (target + spacing)))
        self.columns = columns
        self.spacing = spacing
        cellSize = max(1, ((width - spacing * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down))
    }
}
