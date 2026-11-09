// ============================================================
//  AppState — port of App() state, derived collections & mutations
// ============================================================
import SwiftUI
import Observation
import AppKit
import UniformTypeIdentifiers

struct StatusMetrics: Equatable, Sendable {
    var cacheBytes: Int64?
    var lastBackupDate: Date?
    var backupCount = 0
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
    var onboarded: Bool = UserDefaults.app.string(forKey: "pc_onboarded") == "1"
    var welcomeAnim = false

    // ----- core data -----
    var assets: [Asset] {
        didSet {
            assetMutationCount &+= 1
            let scope = nextAssetEditScope
            nextAssetEditScope = .any
            if scope.contains(.structure) {
                structureVersion &+= 1
                assetIndexCache = nil
                // edited copies stack with their originals by name, so file changes can move stacks
                photoStacksCache = nil
                stackByAssetCache = nil
                stackInputsVersion &+= 1
                keywordCountsCache = nil
                projectCountsCache = nil
                clientCountsCache = nil
                gearCountsCache = nil
                captureDateGroupsCache = nil
                folderTreeCache = nil
                folderTreeCountCache = nil
            }
            if !scope.isDisjoint(with: [.metadata, .structure]) {
                keywordListCache = nil   // re-derived from the (patched) counts
                keywordSuggestionPoolCache = nil
                pinnedSidebarFavoritesCache = nil   // pins of keywords, projects, clients and dates
            }
            // edits patch these again (applyAssetEdits) when they leave files and folders alone
            libraryCountsCache = nil
            sidebarCountIndexCache = nil
            listInputsVersion &+= 1
        }
    }
    @ObservationIgnored var nextAssetEditScope: AssetEditScope = .any
    /// Counts every change to `assets`: a catalog load tells by it whether the photos on screen
    /// were edited while it read the rest.
    @ObservationIgnored var assetMutationCount = 0
    /// id → index map, lazily rebuilt after any `assets` change (invalidated above).
    @ObservationIgnored var assetIndexCache: [String: Int]?
    var albums: [Album] {
        didSet {
            // photos put in an album just before they're added (an import batch) aren't in the
            // sidebar's counts yet: adding them moves the album's count (appendAssets)
            if albumsGainOnlyPhotosToCome {
                albumsGainOnlyPhotosToCome = false
            } else if var index = sidebarCountIndexCache, index.day == sidebarDay {
                // taken out, so its counts change in place: only albums whose photos changed are counted
                sidebarCountIndexCache = nil
                carryAlbumCounts(&index, from: oldValue)
                sidebarCountIndexCache = index
            } else {
                sidebarCountIndexCache = nil
            }
            pinnedSidebarFavoritesCache = nil
            listInputsVersion &+= 1
        }
    }
    @ObservationIgnored var albumsGainOnlyPhotosToCome = false
    var smartAlbums: [SmartAlbum] {
        didSet {
            // a rename, a move into a set, a new order or a deletion matches no photo again
            if var index = sidebarCountIndexCache, index.day == sidebarDay {
                sidebarCountIndexCache = nil
                if carrySmartAlbumCounts(&index, from: oldValue) { sidebarCountIndexCache = index }
            } else {
                sidebarCountIndexCache = nil
            }
            pinnedSidebarFavoritesCache = nil
            listInputsVersion &+= 1
        }
    }
    /// Folders of albums in the sidebar; they hold no photos themselves.
    var albumSets: [AlbumSet] = []
    var folders: [Folder] = DemoData.folders {
        didSet {
            // a source's status (its drive unplugged or back) changes only how its rows show
            if let tree = folderTreeCache, folders.map(\.id) == oldValue.map(\.id),
               folders.map(\.name) == oldValue.map(\.name) {
                folderTreeCache = FolderTreeService.withStatuses(of: folders, in: tree)
            } else {
                folderTreeCache = nil
                folderTreeCountCache = nil
            }
            pinnedSidebarFavoritesCache = nil
            listInputsVersion &+= 1
        }
    }
    var importing = false
    var importRun: ImportRun? {
        didSet { if let run = importRun { recordImportTask(run) } }
    }
    var duplicateGroupsCache: [DuplicateGroup] = DemoData.duplicateGroups {
        didSet {
            currentDuplicateGroupsCache = nil
            photoStacksCache = nil
            stackByAssetCache = nil
            stackInputsVersion &+= 1
            if !collapsedStackIds.isEmpty { listInputsVersion &+= 1 }
        }
    }
    var collapsedStackIds: Set<String> = []
    @ObservationIgnored var photoStacksCache: [PhotoStack]?
    @ObservationIgnored var captureTimeGroupsCache: (version: Int, seconds: Double, groups: [[String]])?
    /// The photos auto-stacking reads, in capture order: sorted once per structure change (and
    /// pairing), whatever the interval, which the groups are then a pass over.
    @ObservationIgnored var captureOrderCache: (version: Int, pairs: Bool, count: Int,
                                                        order: PhotoStackService.CaptureOrder)?
    /// Auto-stacking by capture time: photos from one camera taken within this many seconds of
    /// each other stack together, as Lightroom's Auto-Stack by Capture Time (nil: off).
    var autoStackSeconds: Double? = UserDefaults.app.object(forKey: "pc_autoStackSeconds") as? Double {
        didSet {
            UserDefaults.app.set(autoStackSeconds, forKey: "pc_autoStackSeconds")
            captureTimeGroupsCache = nil
            if autoStackSeconds == nil { captureOrderCache = nil }
            photoStacksCache = nil
            stackByAssetCache = nil
            stackInputsVersion &+= 1
            listInputsVersion &+= 1
        }
    }
    /// Originals with their edited copies, derived from file names once per structure change.
    @ObservationIgnored var editGroupsCache: (version: Int, index: EditedVersions.Index,
                                                      groups: [DuplicateGroup])?
    /// How often what stacks are worked out from (edited copies, capture order) was worked out
    /// from every photo (for tests).
    @ObservationIgnored var stackSourceDerivations = 0
    @ObservationIgnored var stackByAssetCache: [String: Int]?
    @ObservationIgnored var keywordListCache: [KeywordCount]?
    @ObservationIgnored var gearCountsCache: (cameras: MetadataValueCounts, lenses: MetadataValueCounts)?
    /// Every keyword's photo count, in first-seen order; metadata edits patch it in place.
    @ObservationIgnored var keywordCountsCache: KeywordTally?
    @ObservationIgnored var keywordSuggestionPoolCache: [String]?
    /// The project and client lists; metadata edits patch them in place.
    @ObservationIgnored var projectCountsCache: MetadataValueCounts?
    @ObservationIgnored var clientCountsCache: MetadataValueCounts?
    /// The capture-date tree, and the photos by day it was made from.
    @ObservationIgnored var captureDateGroupsCache: (days: [Int: Int], groups: [CaptureDateBucket])?
    var captureStatisticsCache: (request: CaptureStatisticsRequest, value: CaptureStatistics)?
    @ObservationIgnored var captureStatisticsTask: Task<CaptureStatistics, Error>?
    @ObservationIgnored var captureStatisticsGeneration = 0
    @ObservationIgnored var folderTreeCache: [FolderTreeItem]?
    @ObservationIgnored var folderTreeCountCache: [String: Int]?
    @ObservationIgnored var libraryCountsCache: LibraryCounts?
    @ObservationIgnored var sidebarCountIndexCache: SidebarCountIndex?
    /// How often the sidebar's counts were worked out from every photo (for tests).
    @ObservationIgnored var sidebarCountIndexRebuilds = 0
    /// The time relative dates (smart albums, the filter bar's Today…) are counted and listed at
    /// (tests move it).
    @ObservationIgnored var sidebarClock: () -> Date = { .now }
    /// Bumped whenever an array input to `list` changes (assets/albums/smartAlbums/folders/
    /// source roots/priorities or collapsed-stack membership); small values are compared directly.
    var listInputsVersion = 0   // tracked: cached getters read it so cache HITS register deps
    /// Bumped only by non-review asset edits (ids, paths, status, deletion…); values that
    /// can't change with a rating key on this so they neither recompute nor re-render.
    var structureVersion = 0
    var stackInputsVersion = 0
    var assetRenderVersion = 0
    var thumbnailCacheGeneration = 0
    @ObservationIgnored var listCache: (signature: ListSignature, value: [Asset])?
    @ObservationIgnored var uncollapsedListCache: (signature: ListSignature, value: [Asset])?
    /// Where photo lists the list's caches no longer hold are let go of, off the main thread
    /// (tests hold it shut).
    @ObservationIgnored var listReleaseQueue = DispatchQueue.global(qos: .utility)
    /// How many such lists were handed to `listReleaseQueue` (for tests).
    @ObservationIgnored var listsReleasedOffMain = 0
    /// How many list positions patching edits into the list has looked at one by one (for tests).
    @ObservationIgnored var listPatchScannedPhotos = 0
    /// How many list positions lookups of photos in the list have looked at one by one (for tests).
    @ObservationIgnored var listPositionScannedPhotos = 0
    /// How many times the list's photos have been worked out from the catalog (for tests).
    @ObservationIgnored var listComputations = 0
    /// Where in `assets` the photos of the last pass over them are, in catalog order: a change of
    /// sort sorts these again. Positions in the photos as they were, so keyed by the list's inputs.
    @ObservationIgnored var matchingPositionsCache: (signature: ListSignature, positions: [Int])?
    /// How many passes over every photo have tested them for the list (for tests).
    @ObservationIgnored var listFilterPasses = 0
    /// Every sidecar write, automatic or asked for, goes through the writer with the next sequence.
    @ObservationIgnored var automaticXMPWriter = AutomaticXMPWriter()
    @ObservationIgnored var automaticXMPWriteSequence: UInt64 = 0

    /// The window's undo manager (set by the main view), so ⌘Z, the Edit menu's titles and
    /// text-field undo all behave like any Mac app.
    @ObservationIgnored weak var undoManager: UndoManager? {
        didSet { undoManager?.levelsOfUndo = 100 }
    }

    /// Sources removed, and originals moved to the Trash, since the catalog was opened. Neither
    /// is undoable, so undo and redo of an earlier step leave their photos out of the catalog —
    /// and a trashed original's virtual copies — rather than bring back photos of a source the
    /// catalog no longer has, or of a file in the Trash.
    @ObservationIgnored var removedSourceIds: Set<String> = []
    @ObservationIgnored var trashedOriginalIds: Set<String> = []
    // ----- settings (PRD §17) -----
    var importMode: ImportMode =
        ImportMode(rawValue: UserDefaults.app.string(forKey: "pc_importMode") ?? "") ?? .referenced {
        didSet { UserDefaults.app.set(importMode.rawValue, forKey: "pc_importMode") }
    }
    var managedArchiveRule: ManagedArchiveRule =
        ManagedArchiveRule(rawValue: UserDefaults.app.string(forKey: "pc_managedArchive") ?? "") ?? .date {
        didSet { UserDefaults.app.set(managedArchiveRule.rawValue, forKey: "pc_managedArchive") }
    }
    var importDuplicateStrategy: ImportDuplicateStrategy =
        ImportDuplicateStrategy(rawValue: UserDefaults.app.string(forKey: "pc_importDuplicateStrategy") ?? "")
            ?? .groupExact {
        didSet {
            UserDefaults.app.set(importDuplicateStrategy.rawValue, forKey: "pc_importDuplicateStrategy")
        }
    }
    var importPostKeywords = UserDefaults.app.string(forKey: "pc_importPostKeywords") ?? "" {
        didSet { UserDefaults.app.set(importPostKeywords, forKey: "pc_importPostKeywords") }
    }
    var importPostColorLabel = UserDefaults.app.string(forKey: "pc_importPostColorLabel") ?? "" {
        didSet { UserDefaults.app.set(importPostColorLabel, forKey: "pc_importPostColorLabel") }
    }
    /// Metadata template applied to every import (§ roadmap 4.2).
    var importAuthor = UserDefaults.app.string(forKey: "pc_importAuthor") ?? "" {
        didSet { UserDefaults.app.set(importAuthor, forKey: "pc_importAuthor") }
    }
    var importCopyright = UserDefaults.app.string(forKey: "pc_importCopyright") ?? "" {
        didSet { UserDefaults.app.set(importCopyright, forKey: "pc_importCopyright") }
    }
    var importPostAlbumName = UserDefaults.app.string(forKey: "pc_importPostAlbumName") ?? "" {
        didSet { UserDefaults.app.set(importPostAlbumName, forKey: "pc_importPostAlbumName") }
    }
    /// The develop preset every import applies ("" for none), as Lightroom's import panel does.
    var importDevelopPresetId = UserDefaults.app.string(forKey: "pc_importDevelopPreset") ?? "" {
        didSet { UserDefaults.app.set(importDevelopPresetId, forKey: "pc_importDevelopPreset") }
    }
    /// RAW defaults, as in Lightroom: the preset a camera's RAW files start from, by camera
    /// model; "" is every camera without its own, and "none" keeps a camera as shot.
    var rawDefaultPresetIds: [String: String] =
        (UserDefaults.app.dictionary(forKey: "pc_rawDefaults") as? [String: String]) ?? [:] {
        didSet {
            UserDefaults.app.set(rawDefaultPresetIds, forKey: "pc_rawDefaults")
            rawDefaultsCache = nil
        }
    }
    /// `rawDefaults`, made from the choices and presets above: the Develop panel asks for it each
    /// time it draws. Dropped when either changes.
    @ObservationIgnored var rawDefaultsCache: RawDefaults?
    /// How many times `rawDefaults` was made (for tests).
    @ObservationIgnored var rawDefaultsBuilds = 0
    /// After a rating / flag / color key on one photo, move to the next (Shift does it once).
    var autoAdvance: Bool = UserDefaults.app.bool(forKey: "pc_autoAdvance") {
        didSet { UserDefaults.app.set(autoAdvance, forKey: "pc_autoAdvance") }
    }
    /// Sidebar column visibility; Tab hides it together with the inspector for culling.
    var sidebarVisible = true

    /// Show a RAW and its same-name JPEG/HEIC as one photo; off lists every file separately.
    var pairRawAndJpeg: Bool = (UserDefaults.app.object(forKey: "pc_pairRawJpeg") as? Bool) ?? true {
        didSet {
            guard pairRawAndJpeg != oldValue else { return }
            UserDefaults.app.set(pairRawAndJpeg, forKey: "pc_pairRawJpeg")
            invalidatePresentationCaches()
            reseedSidecarBaselines(pairingWas: oldValue)
        }
    }
    @ObservationIgnored var assetPairingCache: (version: Int, pairing: AssetPairing)?

    var appearance: AppAppearance = .stored {
        didSet {
            UserDefaults.app.set(appearance.rawValue, forKey: AppAppearance.defaultsKey)
            appearance.apply()
        }
    }
    /// The UI language picked in Settings; macOS applies it when the app launches.
    var language: AppLanguage = .stored {
        didSet { if language != oldValue { language.store() } }
    }
    var exportWritesXMP = UserDefaults.app.bool(forKey: "pc_exportXMP") {
        didSet { UserDefaults.app.set(exportWritesXMP, forKey: "pc_exportXMP") }
    }
    var readXMPSidecar: Bool = (UserDefaults.app.object(forKey: "pc_readXMP") as? Bool) ?? true {
        didSet { UserDefaults.app.set(readXMPSidecar, forKey: "pc_readXMP") }
    }
    var autoWriteXMPSidecar = UserDefaults.app.bool(forKey: "pc_autoWriteXMP") {
        didSet { UserDefaults.app.set(autoWriteXMPSidecar, forKey: "pc_autoWriteXMP") }
    }
    var exportDirectoryStructure: ExportDirectoryStructure =
        ExportDirectoryStructure(rawValue: UserDefaults.app.string(forKey: "pc_exportDirectoryStructure") ?? "")
            ?? .flat {
        didSet {
            UserDefaults.app.set(exportDirectoryStructure.rawValue, forKey: "pc_exportDirectoryStructure")
        }
    }
    var exportPresets: [ExportPreset] = AppState.loadJSON([ExportPreset].self, forKey: "pc_exportPresets") ?? [] {
        didSet { AppState.store(exportPresets, forKey: "pc_exportPresets") }
    }
    var recentImportDays: Int = (UserDefaults.app.object(forKey: "pc_recentDays") as? Int) ?? 14 {
        didSet { UserDefaults.app.set(recentImportDays, forKey: "pc_recentDays"); libraryCountsCache = nil }
    }
    var openLastCatalogOnLaunch: Bool =
        (UserDefaults.app.object(forKey: "pc_openLast") as? Bool) ?? true {
        didSet { UserDefaults.app.set(openLastCatalogOnLaunch, forKey: "pc_openLast") }
    }
    var reduceBackgroundOnLowPower: Bool =
        (UserDefaults.app.object(forKey: "pc_lowPower") as? Bool) ?? true {
        didSet { UserDefaults.app.set(reduceBackgroundOnLowPower, forKey: "pc_lowPower") }
    }
    var visionEnabled = UserDefaults.app.bool(forKey: "pc_vision") {
        didSet { UserDefaults.app.set(visionEnabled, forKey: "pc_vision") }
    }
    /// The cache limit chosen in Settings, in MB; 0 until one is chosen, and then the limit follows
    /// the catalog (`CacheLimit.automaticMB`). Never over what Settings offers: stepping down from an
    /// automatic limit above that used to save one over it.
    var cacheLimitMB: Int = min(max(0, UserDefaults.app.integer(forKey: "pc_cacheLimitMB")),
                                CacheLimit.rangeMB.upperBound) {
        didSet {
            if cacheLimitMB > 0 { UserDefaults.app.set(cacheLimitMB, forKey: "pc_cacheLimitMB") }
            else { UserDefaults.app.removeObject(forKey: "pc_cacheLimitMB") }
        }
    }
    var previewMaxPixel: Int = {
        let saved = UserDefaults.app.integer(forKey: "pc_previewMaxPixel")
        return saved == 1600 ? 1600 : 2_048
    }() {
        didSet { UserDefaults.app.set(previewMaxPixel, forKey: Self.previewMaxPixelKey) }
    }
    var automaticBackupFrequencyStorage = AppState.normalizedAutomaticBackupFrequency(
        UserDefaults.app.string(forKey: "pc_autoBackupFrequency") ?? "weekly"
    )
    var healthReport: HealthReport?
    var statusMetrics = StatusMetrics()
    var recentCatalogPaths =
        UserDefaults.app.stringArray(forKey: "pc_recentCatalogs") ?? []

    // ----- catalog (real persistence / scanning) -----
    var store: CatalogStore? {
        didSet {
            if oldValue !== store { invalidateDescriptionReview() }
            configureTaskHistory()
        }
    }
    let fullBackup = FullBackupState()
    var backgroundTasks: [BackgroundTask] = []
    var taskHistoryError: String?
    @ObservationIgnored var taskHistory: BackgroundTaskHistory?
    @ObservationIgnored var taskActions: [UUID: BackgroundTask.Actions] = [:]
    // Live worker identities survive catalog switches; unsaved final snapshots stay here
    // until their original history can be flushed. Neither case starts work on recovery.
    @ObservationIgnored var workerTaskHistories: [UUID: BackgroundTaskHistory] = [:]
    var coordinator: ImportCoordinator?
    var isLoadingCatalog = false
    var hasCatalogPreview = false
    var loadingCatalogTotalCount: Int? {
        didSet { libraryCountsCache = nil }
    }
    var loadingCatalogURL: URL?
    @ObservationIgnored var deferredCatalogArguments: [String]?
    @ObservationIgnored var catalogLoadTask: Task<Void, Never>?
    @ObservationIgnored var catalogLoadGeneration = 0
    /// For checks: awaited once a background open has read the whole catalog, before installing it.
    @ObservationIgnored var catalogHydrationGate: (@MainActor () async -> Void)?
    @ObservationIgnored var watcher: FileWatcher?
    @ObservationIgnored var watchedRoots: [URL] = []
    @ObservationIgnored var securityScopedRoots: [URL] = []
    /// Source folders found renamed or moved as the catalog opened; their photos follow once loaded.
    @ObservationIgnored var movedSourceRoots: [(id: String, from: String, to: String)] = []
    @ObservationIgnored var sourceRootPathsById: [String: String] = [:] {
        didSet {
            folderTreeCache = nil
            folderTreeCountCache = nil
            listInputsVersion &+= 1
        }
    }
    var sourceManagementModesById: [String: String] = [:]
    @ObservationIgnored var volumeMonitor: VolumeMonitor?
    /// Where drives are mounted and which is which: the system's answers, or a test's.
    @ObservationIgnored var volumeProbe = VolumeProbe.system
    /// Where generative fills are kept: GenerativeFill's folder, or a test's.
    @ObservationIgnored var generatedFillFolder = GenerativeFill.folder
    @ObservationIgnored var availabilityScanTask: Task<Void, Never>?
    @ObservationIgnored var availabilityScanGeneration = 0
    var isCheckingOriginals = false
    @ObservationIgnored var lastImportSessionPersistedCount = 0
    @ObservationIgnored var importControl: ImportControl?
    @ObservationIgnored var activeImportJobId: String?
    @ObservationIgnored var importOptions: ImportOptionsSnapshot?
    @ObservationIgnored var importCheckpoints: [String: ImportFileCheckpoint] = [:]
    @ObservationIgnored var pendingImportFiles: [ImportFileResult] = []
    @ObservationIgnored var lastImportBatchWrite: ContinuousClock.Instant?
    @ObservationIgnored var confirmDestructiveAction = AppState.confirmDestructiveAction
    // ----- selection / view -----
    var selection = Selection(type: .lib, id: "all", name: L("全部照片"))
    var selectedIds: Set<String> = [] {
        didSet { selectionVersion &+= 1 }
    }
    var primaryId: String? {
        didSet { selectionVersion &+= 1 }
    }
    /// Bumped on every selection change; keys the selection summary.
    @ObservationIgnored var selectionVersion = 0
    /// The library view last shown, where the toolbar's 图库 returns from Develop.
    @ObservationIgnored private(set) var lastLibraryView: ViewMode = .grid
    var view: ViewMode = .grid {
        didSet {
            if view != .develop {
                lastLibraryView = view
                developCropping = false; developPickingWhiteBalance = false; developMasking = false; developSpotting = false
                developComparing = false; developPickingFocus = false; developShowsDepth = false
            }
            if oldValue == .survey && view != .survey { leaveSurvey() }
        }
    }
    var thumbSize: CGFloat = 168
    var showInspector = true
    /// The file name row under each grid photo (I); remembered across launches.
    var showInfo = UserDefaults.app.object(forKey: "pc_gridShowInfo") as? Bool ?? true {
        didSet { UserDefaults.app.set(showInfo, forKey: "pc_gridShowInfo") }
    }
    /// Grid photos cropped to fill their squares, without the letterbox around portraits.
    var gridFill = UserDefaults.app.bool(forKey: "pc_gridFill") {
        didSet { UserDefaults.app.set(gridFill, forKey: "pc_gridFill") }
    }
    var insTab = "org"
    var pinnedSidebarItems = AppState.loadJSON([PinnedSidebarItem].self, forKey: pinnedSidebarItemsKey) ?? [] {
        didSet {
            pinnedSidebarFavoritesCache = nil
            AppState.store(pinnedSidebarItems, forKey: Self.pinnedSidebarItemsKey)
        }
    }
    var sourcePriorities = AppState.loadJSON([String: Int].self, forKey: sourcePrioritiesKey) ?? [:] {
        didSet {
            folderTreeCache = nil
            listInputsVersion &+= 1
            AppState.store(sourcePriorities, forKey: Self.sourcePrioritiesKey)
        }
    }
    @ObservationIgnored var anchorId: String?

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
    var developSettings: [String: DevelopSettings] = [:] {
        didSet { developSettingsVersion &+= 1 }
    }
    @ObservationIgnored var developSettingsVersion = 0
    /// Each photo's settings fingerprint, with the settings it was made from: views ask for it
    /// many times a frame, and a masked edit's takes a fraction of a millisecond to make.
    @ObservationIgnored var developFingerprintCache: [String: (settings: DevelopSettings, fingerprint: String)] = [:]
    /// Settings while a slider drags — drives the live preview; saved on release.
    var developDraft: DevelopDraft?
    /// Before / after (\): show the photo as shot.
    var developShowsOriginal = false {
        didSet { if developShowsOriginal { developComparing = false } }
    }
    /// Before and after side by side (Y): the photo as shot, framed like the edit, beside it.
    /// The tools and zoom make way.
    var developComparing = false {
        didSet {
            if developComparing {
                developShowsOriginal = false; loupeZoom = nil
                developCropping = false; developMasking = false; developSpotting = false; developPickingWhiteBalance = false
            }
        }
    }
    /// Camera-recorded RAW white balance, learned when a photo is first rendered.
    var developAsShot: [String: DevelopAsShot] = [:]

    /// Crop & straighten tool (R). The photo is shown whole with the crop drawn over it.
    var developCropping = false {
        didSet {
            if developCropping {
                loupeZoom = nil; developMasking = false; developSpotting = false; developPickingWhiteBalance = false
                developComparing = false
            }
        }
    }

    /// Masking tool (M / ⇧M): the photo is shown whole with the selected mask's handles.
    var developMasking = false {
        didSet {
            if developMasking {
                loupeZoom = nil; developCropping = false; developPickingWhiteBalance = false; developSpotting = false
                developComparing = false
            }
            if !developMasking { developMaskCreation = nil; developRefiningMask = false; developPickingRangeColor = false }
        }
    }
    /// Spot removal tool (Q): the photo is shown whole; a click heals the speck under it.
    var developSpotting = false {
        didSet {
            if developSpotting {
                loupeZoom = nil; developCropping = false; developPickingWhiteBalance = false; developMasking = false
                developComparing = false
            } else {
                developVisualizeSpots = false
            }
        }
    }
    var developSelectedSpotId: String?
    /// Size, feather, opacity and mode for new spots.
    var developSpotBrush = SpotBrush()
    /// Shows only fine detail, where sensor dust stands out.
    var developVisualizeSpots = false

    /// A remove spot's fill being made, while the model works.
    var developRemoving = false

    /// The mask whose handles and sliders are shown.
    var developSelectedMaskId: String? {
        didSet { if developSelectedMaskId != oldValue { developPickingRangeColor = false } }
    }
    /// Sampling colors for the selected mask's color range: clicks on the photo add samples.
    var developPickingRangeColor = false
    /// A gradient the next drag on the photo draws (a click places one of default size), or the
    /// brush, whose first stroke starts a new brush mask.
    var developMaskCreation: LocalAdjustment.Kind?
    /// Brush size, feather, density and mode for new strokes.
    var developBrush = BrushSettings()
    /// Painting on the selected gradient, subject or sky: strokes add to it, erasing takes away.
    var developRefiningMask = false
    /// O: tints the selected mask's coverage red.
    var developShowsMaskOverlay = false

    /// The automatic mask being looked for, while Vision works.
    var developDetectingMask: LocalAdjustment.Kind?

    /// How many people each photo looked at for a people mask shows (asset id → count), for
    /// the mask's choice of person.
    var developPeopleCounts: [String: Int] = [:]
    /// Crop shape the tool holds while resizing.
    var developCropAspect: CropAspect = .original
    /// Decoded photo sizes before rotation and crop, learned from Develop renders.
    @ObservationIgnored var developSourceSizes: [String: CGSize] = [:]
    // ---------- selection summary ----------
    @ObservationIgnored var selectionSummaryCache: (key: SelectionSummaryKey, value: SelectionSummary)?

    /// Develop's white-balance eyedropper (W): the next click on the photo picks a neutral point.
    var developPickingWhiteBalance = false {
        didSet {
            // the eyedropper clicks on the photo itself: the other tools make way
            if developPickingWhiteBalance {
                developCropping = false; developMasking = false; developSpotting = false; developPickingFocus = false
            }
        }
    }

    // ----- lens blur: the photo blurred by depth (see LensBlur, DepthMap) -----
    /// The next click on the photo in Develop sets lens blur's focus.
    var developPickingFocus = false {
        didSet {
            if developPickingFocus {
                developCropping = false; developMasking = false; developSpotting = false; developPickingWhiteBalance = false
            }
        }
    }
    /// Develop shows lens blur's depth map instead of the photo.
    var developShowsDepth = false
    // ----- soft proofing: the photo in Develop as another color space or a printer shows it -----
    /// Whether Develop shows the proof (S): a way of looking, off at each launch.
    var softProofing = false
    var softProof: SoftProof = AppState.loadJSON(SoftProof.self, forKey: "pc_softProof") ?? SoftProof() {
        didSet { AppState.store(softProof, forKey: "pc_softProof") }
    }
    /// The profiles to proof with, found when proofing first turns on.
    var softProofProfiles: [SoftProofing.Profile] = []

    /// Bumped by Space in the loupe: the playing video pauses, a paused one plays.
    var videoPlaybackToggle = 0
    // ----- develop: copy / paste / sync and presets -----
    /// Settings copied with ⇧⌘C, waiting for ⇧⌘V.
    var developClipboard: DevelopTransfer?
    /// The user's own presets; built-ins come first wherever presets are listed.
    var developPresets: [DevelopPreset] = AppState.loadJSON([DevelopPreset].self, forKey: developPresetsKey) ?? [] {
        didSet {
            AppState.store(developPresets, forKey: AppState.developPresetsKey)
            rawDefaultsCache = nil
        }
    }
    /// Fields the copy / sync dialog offers checked, as last used.
    var developTransferFields: Set<DevelopField> =
        AppState.loadJSON(Set<DevelopField>.self, forKey: developTransferFieldsKey) ?? DevelopField.defaultCopy {
        didSet { AppState.store(developTransferFields, forKey: AppState.developTransferFieldsKey) }
    }
    var developTransferMode: DevelopTransferMode = .copy
    // ----- preset amount: how strongly the last preset applied in Develop takes effect -----
    var developPresetAmountState: DevelopPresetAmount?
    /// The amount being dragged, before it's saved.
    var developPresetAmountDraft: Double?
    // ----- preset preview: the photo shows a preset's look while the pointer rests on it -----
    @ObservationIgnored var developPresetPreview: DevelopPresetPreview?
    // ----- LUTs: creative looks from .cube files, kept in the app's own folder -----
    var developLUTs: [DevelopLUT] = AppState.loadJSON([DevelopLUT].self, forKey: "pc_luts") ?? [] {
        didSet { AppState.store(developLUTs, forKey: "pc_luts") }
    }
    // ----- preset files -----

    /// Tone distribution of the photo's latest finished Develop render.
    var developHistogram: (assetId: String, histogram: DevelopHistogram)?
    // ----- develop history and snapshots, loaded per photo when first shown -----
    @ObservationIgnored var developHistoryCache: [String: [DevelopHistoryStep]] = [:]
    @ObservationIgnored var developSnapshotCache: [String: [DevelopSnapshot]] = [:]
    /// Bumped whenever a loaded history or snapshot list changes.
    var developRecordsVersion = 0
    /// Photos whose history or snapshots are in memory, the most recently shown last. With a
    /// catalog they're read again when shown again, so only the recent ones are kept.
    @ObservationIgnored var developRecordOrder: [String] = []
    /// Shared by every Compare panel, so zoom and pan stay linked across them.
    var compareZoom: ImageZoom?
    // ----- sheets / toasts -----
    var sheet: String? {
        didSet {
            if sheet != "smart" { smartAlbumEditingID = nil }
            // closed by Cancel, Esc or anything else: the search it started stops, and a reply
            // that comes anyway sets no filter and closes no dialog opened since
            if oldValue == "naturalSearch", sheet != "naturalSearch" { cancelNaturalSearch() }
        }
    }
    var smartAlbumEditingID: String?
    let toastCenter = ToastCenter()

    // ----- search focus signal (Cmd+F) -----
    var searchFocusToken = 0

    /// Bumped to bring up the settings window, which RootView opens: a window of its own.
    var settingsRequest = 0

    /// The settings category to open at, taken once by the settings window.
    @ObservationIgnored var settingsStartCategory: String?

    init(arguments: [String] = CommandLine.arguments, deferCatalogLoading: Bool = false) {
        let a = DemoData.assets
        assets = a
        albums = DemoData.initialAlbums(a)
        smartAlbums = DemoData.initialSmartAlbums(a)
        albumSets = []
        if deferCatalogLoading {
            deferredCatalogArguments = arguments
            if onboarded || Self.launchCatalogURL(from: arguments) != nil {
                isLoadingCatalog = true
                resetCatalog(toDemo: false)
            }
        } else {
            if onboarded, let launchURL = Self.launchCatalogURL(from: arguments) {
                if !openCatalog(at: launchURL), store == nil, openLastCatalogOnLaunch,
                   let error = loadExistingCatalog() {
                    push(verbatim: catalogOpenFailureMessage(error), "warning")
                }
            } else if onboarded && openLastCatalogOnLaunch, let error = loadExistingCatalog() {
                push(verbatim: catalogOpenFailureMessage(error), "warning")
            }
            if onboarded && store == nil {
                UserDefaults.app.set("0", forKey: "pc_onboarded")
                onboarded = false
            }
        }
        startVolumeMonitor()
        if !deferCatalogLoading {
            runAutomaticBackupIfNeeded()
            seedInitialSelection()
        }
    }

    deinit {
        catalogLoadTask?.cancel()
        captureStatisticsTask?.cancel()
        for url in securityScopedRoots {
            url.stopAccessingSecurityScopedResource()
        }
    }

    // ---------- catalog open / load ----------
    @ObservationIgnored var catalogManagementTextCache:
        (version: Int, modes: [String: String], importMode: ImportMode, text: String)?
    // ---------- memory-card import ----------
    /// Mounted cards (volumes with DCIM), refreshed as volumes come and go.
    var cardVolumes: [CardVolume] = CardImportService.detectCards()
    /// The card the import dialog opens on.
    var cardImportVolume: CardVolume?
    var cardImportOptions: CardImportOptions = AppState.loadJSON(CardImportOptions.self, forKey: "pc_cardImportOptions")
        ?? .standard {
        didSet { AppState.store(cardImportOptions, forKey: "pc_cardImportOptions") }
    }
    // ---------- camera / phone import ----------
    /// Cameras and phones on a cable (PTP), which don't mount as volumes.
    var cameraDevices: [CameraDevice] = []
    /// The camera the import dialog opens on, instead of a card.
    var cardImportDevice: CameraDevice?
    @ObservationIgnored var deviceBrowsingStarted: Date?
    // ---------- tethered capture ----------
    /// The next (or running) tethered session's settings.
    var tetherSettings: TetherSettings = AppState.loadJSON(TetherSettings.self, forKey: "pc_tether") ?? TetherSettings() {
        didSet { AppState.store(tetherSettings, forKey: "pc_tether") }
    }
    var tether: TetherStatus?
    @ObservationIgnored var tetherSource: (any TetherSource)?
    @ObservationIgnored var tetherNamer = TetherNamer(session: "", naming: .original, existing: [])
    @ObservationIgnored var tetherQueue: [TetherShot] = []
    @ObservationIgnored var tetherPreset: DevelopPreset?
    /// The source folder that contains the session's folder, when one does.
    @ObservationIgnored var tetherRoot: (id: String, name: String)?
    @ObservationIgnored var tetherFolderRegistered = false

    /// The copy import whose failed files Retry Failed sends through its preparer again: they
    /// are a card's files, to be copied off it (renamed, backed up), never cataloged on it.
    @ObservationIgnored var copyImportRetry: (runId: UUID, preparer: any ImportFilePreparer)?

    // O(1) failure-dedup state: the set of failure ids already recorded for the current run
    @ObservationIgnored var failureSeenIds: (runId: UUID?, ids: Set<String>) = (nil, [])
    // Progress events arrive once per file; accumulate here and publish to the
    // observed importRun at most every ~100 ms — each publish redraws every
    // observing view, so per-file publishing stalls the UI on fast imports.
    @ObservationIgnored var pendingImportRun: ImportRun?
    @ObservationIgnored var lastImportRunFlush: ContinuousClock.Instant?
    // ---------- FSEvents incremental watch (§12.8) ----------
    @ObservationIgnored var isIncrementalRescanning = false
    @ObservationIgnored var needsIncrementalRescan = false
    /// The paths the rescan queued behind the running one quick-hashes: those the batches it
    /// stands for named; nil, every file, once one of them may not have named its changes.
    @ObservationIgnored var pendingRescanHashing: Set<String>?
    @ObservationIgnored var incrementalRescanGeneration = 0
    // ---------- sidecars changed by other apps ----------
    /// Each photo's sidecar modification time as of our last read or write (seconds since 1970).
    @ObservationIgnored var xmpSyncTimes: [String: Double] = [:]
    /// Photos whose sidecar another app changed since we last read or wrote it.
    var externallyChangedXMPIds: Set<String> = [] {
        // the 已在其他应用中更改 collection lists them
        didSet { if externallyChangedXMPIds != oldValue { listInputsVersion &+= 1 } }
    }
    @ObservationIgnored var isCheckingXMP = false
    /// When the last check started, and whether another is waiting its turn: rescans ask for a
    /// check each time, and every check looks at every photo's sidecar.
    @ObservationIgnored var lastXMPCheck: Date?
    @ObservationIgnored var xmpCheckPending = false
    /// Our own sidecar writes under way (automatic or asked for), and whether a check waits for
    /// them: a write records the new times of the sidecars it rewrote only once it's done.
    @ObservationIgnored var xmpWritesInFlight = 0
    @ObservationIgnored var xmpCheckAwaitsWrites = false
    /// Reads sidecar changes other apps make as soon as they're noticed.
    var autoReadChangedXMP = UserDefaults.app.bool(forKey: "pc_autoReadChangedXMP") {
        didSet { UserDefaults.app.set(autoReadChangedXMP, forKey: "pc_autoReadChangedXMP") }
    }

    /// A running count of sidecar times remembered (and changes found), and when each photo's
    /// was: what a check or re-seed worked out in the background from before then is older, and
    /// doesn't replace it.
    @ObservationIgnored var xmpSyncCount: UInt64 = 0
    @ObservationIgnored var xmpSyncRecordedAt: [String: UInt64] = [:]
    /// When an automatic write last found a photo's sidecar changed elsewhere, on the same count.
    @ObservationIgnored var xmpChangeFoundAt: [String: UInt64] = [:]
    /// Photos edited while their changed sidecar was read automatically: the edit won, and the
    /// sidecar shows as changed elsewhere, unread, until it's read or written or changes again.
    @ObservationIgnored var xmpConflictIds: Set<String> = []
    // ---------- editing in another app ----------
    /// The app photos open in for pixel editing (Photoshop, Pixelmator Pro…); asked the first time.
    var externalEditorPath: String? = UserDefaults.app.string(forKey: "pc_externalEditor") {
        didSet { UserDefaults.app.set(externalEditorPath, forKey: "pc_externalEditor") }
    }
    // ---------- photo merge ----------
    var photoMergeKind: PhotoMergeKind = .hdr
    /// The photos the open merge dialog merges, taken as it opened.
    @ObservationIgnored var photoMergeTargets: [Asset] = []
    var hdrOptions = PhotoMerge.HDROptions()
    /// A merge is running: another waits.
    var isMergingPhotos = false
    // ---------- AI: language models (Settings → AI) ----------
    var llmConfiguration: LLMConfiguration = AppState.loadJSON(LLMConfiguration.self, forKey: "pc_llm") ?? .anthropic {
        didSet {
            AppState.store(llmConfiguration, forKey: "pc_llm")
            llmTestResult = nil
        }
    }
    /// What the last connection test said, and whether it worked.
    var llmTestResult: (ok: Bool, message: String)?
    var llmTesting = false
    /// Checks and tests set a key here instead of the keychain.
    @ObservationIgnored var llmKeyOverride: String?

    /// Tests answer here instead of the configured service.
    @ObservationIgnored var llmOverride: ((LLMRequest) async throws -> String)?
    // ---------- AI: describe photos ----------
    var describeOptions = DescribeOptions()
    var describeTargets: [Asset] = []
    var describeProgress: (done: Int, total: Int)?
    var descriptionReview: DescriptionReview?
    @ObservationIgnored var descriptionReviewContext: DescriptionReviewContext?
    @ObservationIgnored var describeCancellation: CancellationFlag?
    @ObservationIgnored var describeTask: Task<Void, Never>?

    // ---------- AI: natural-language search ----------
    var naturalSearchRunning = false
    /// The last sentence searched for, to start the dialog with.
    var naturalSearchQuery = ""
    @ObservationIgnored var naturalSearchTask: Task<Void, Never>?
    // ---------- AI: develop by text ----------
    var developByTextRunning = false
    /// The last look described, kept for the field.
    var developByTextQuery = ""

    /// Develop → AI 调整: the photo in Develop edited as `description` asks — the model sees its
    /// current values, and the photo when it reads images — as one undoable step.
    /// Asks before 用文字修图 first sends a photo to an AI service off this Mac, once per service:
    /// a photo is shared with a third party only with the user's say-so.
    @ObservationIgnored var confirmSendingPhoto = AppState.confirmSendingPhoto
    // ---------- enhance: AI denoise and super resolution ----------
    /// The photos the Enhance dialog works on.
    var enhanceTargets: [Asset] = []
    var enhanceOptions: Enhance.Options = {
        let defaults = UserDefaults.app
        var options = Enhance.Options()
        if let denoise = defaults.object(forKey: "pc_enhanceDenoise") as? Bool { options.denoise = denoise }
        if let amount = defaults.object(forKey: "pc_enhanceAmount") as? Double { options.denoiseAmount = amount }
        options.superResolution = defaults.bool(forKey: "pc_enhanceSuperResolution")
        return options
    }() {
        didSet {
            let defaults = UserDefaults.app
            defaults.set(enhanceOptions.denoise, forKey: "pc_enhanceDenoise")
            defaults.set(enhanceOptions.denoiseAmount, forKey: "pc_enhanceAmount")
            defaults.set(enhanceOptions.superResolution, forKey: "pc_enhanceSuperResolution")
        }
    }
    /// The run in progress: photos finished, how many in all, and how far the current one is.
    var enhanceProgress: (done: Int, total: Int, fraction: Double)?
    @ObservationIgnored var enhanceCancellation: CancellationFlag?
    // ---------- batch rename (§4.2) ----------

    /// The photos the open rename dialog reaches, taken as it opened: its preview and the
    /// rename itself stay on them whatever the selection does meanwhile.
    @ObservationIgnored var renameSheetTargets: [Asset] = []
    // ---------- updates ----------

    /// Settings → 自动检查更新: at most once a day, shortly after launch.
    var autoCheckForUpdates: Bool = (UserDefaults.app.object(forKey: "pc_autoCheckUpdates") as? Bool) ?? true {
        didSet { UserDefaults.app.set(autoCheckForUpdates, forKey: "pc_autoCheckUpdates") }
    }

    /// The version being downloaded and installed.
    var installingUpdate: String?
    // ---------- catalog health / cache (§6.1, §17.3) ----------

    /// Cache repairs that failed this session (or made a black RAW render again), by `id|kind`.
    @ObservationIgnored var failedCacheRepairs = Set<String>()
    /// Cache files checked (or made) this session, by photo, which a lookup takes without touching
    /// the disk. Whatever deletes cache files drops them: a prune all of them, removing photos
    /// from the catalog theirs.
    @ObservationIgnored var verifiedCacheSources: [String: Set<String>] = [:]
    /// Cache repairs under way, each with the requests waiting for it: the loupe asks for a photo's
    /// preview while its neighbor prefetch is still making it, and then waits for that instead of
    /// decoding the same RAW a second time.
    @ObservationIgnored var repairsInFlight: [String: [CheckedContinuation<Void, Never>]] = [:]
    @ObservationIgnored var isBackfilling = false
    @ObservationIgnored var backfillTask: Task<Void, Never>?
    @ObservationIgnored var backfillGeneration = 0
    @ObservationIgnored var backfillCancellation: CancellationFlag?
    /// Rebuild Thumbnails under way: it shares the background lane with the backfill, so it's
    /// stopped when the catalog closes, and when a rebuild starts again.
    @ObservationIgnored var thumbnailRebuildTask: Task<Void, Never>?
    @ObservationIgnored let cachePurges = CachePurges()
    // ---------- rendered export (Lightroom's Export dialog) ----------
    /// The dialog reopens with the settings and folder last used.
    var renderedExportSettings: ExportSettings = AppState.loadJSON(ExportSettings.self, forKey: "pc_renderedExportSettings")
        ?? ExportSettings() {
        didSet { AppState.store(renderedExportSettings, forKey: "pc_renderedExportSettings") }
    }
    var renderedExportFolder: String = UserDefaults.app.string(forKey: "pc_renderedExportFolder")
        ?? FileAccessService.picturesFolder.appendingPathComponent(L("PhotoCatalog 导出")).path {
        didSet { UserDefaults.app.set(renderedExportFolder, forKey: "pc_renderedExportFolder") }
    }
    var renderedExportPresets: [RenderedExportPreset] =
        AppState.loadJSON([RenderedExportPreset].self, forKey: "pc_renderedExportPresets") ?? [] {
        didSet { AppState.store(renderedExportPresets, forKey: "pc_renderedExportPresets") }
    }
    /// The job being written first, then the ones waiting behind it.
    @ObservationIgnored var renderedExportJobs: [RenderedExportJob] = []
    var renderedExportProgress: RenderedExportProgress?
    @ObservationIgnored let renderedExportCancellation = ExportCancellation()
    // ----- slideshow (Lightroom's Slideshow module) -----
    var slideshowSettings: SlideshowSettings =
        AppState.loadJSON(SlideshowSettings.self, forKey: "pc_slideshow") ?? SlideshowSettings() {
        didSet { AppState.store(slideshowSettings, forKey: "pc_slideshow") }
    }
    /// How far a slideshow video has got, while one is being written.
    var slideshowExportProgress: Double?
    @ObservationIgnored var slideshowCancellation: CancellationFlag?
    @ObservationIgnored var slideshowPlayer: SlideshowPlayer?
    // ----- web gallery (Lightroom's Web module) -----
    var webGallerySettings: WebGallerySettings =
        AppState.loadJSON(WebGallerySettings.self, forKey: "pc_webGallery") ?? WebGallerySettings() {
        didSet { AppState.store(webGallerySettings, forKey: "pc_webGallery") }
    }
    /// How far a web gallery has got, while one is being written.
    var webGalleryProgress: Double?
    @ObservationIgnored var webGalleryCancellation: CancellationFlag?
    // ----- photo book (Lightroom's Book module) -----
    var bookSettings: BookSettings = AppState.loadJSON(BookSettings.self, forKey: "pc_book") ?? BookSettings() {
        didSet { AppState.store(bookSettings, forKey: "pc_book") }
    }
    /// How far a book's PDF has got, while one is being written.
    var bookProgress: Double?
    @ObservationIgnored var bookCancellation: CancellationFlag?
    // ----- print: the selection on paper (Lightroom's Print module) -----
    var printSettings: PrintSettings = AppState.loadJSON(PrintSettings.self, forKey: "pc_printSettings") ?? PrintSettings() {
        didSet { AppState.store(printSettings, forKey: "pc_printSettings") }
    }
    // ---------- duplicate groups (§6.10): exact (content) + similar (perceptual) ----------
    @ObservationIgnored var currentDuplicateGroupsCache: (version: Int, groups: [DuplicateGroup])?
    @ObservationIgnored var duplicateRecomputeGeneration = 0

    /// Photos edited while their original was out of reach (its drive unplugged), whose sidecar
    /// is still to be written.
    @ObservationIgnored var pendingXMPWriteIds: Set<String> = []
    // ---------- keyword sidebar list ----------

    /// How often the project and client lists were counted from every photo (for tests).
    @ObservationIgnored var metadataListRebuilds = 0

    // Cached like the other derived sidebar collections — resolving a pinned
    // keyword scans every asset, and Sidebar reads this on each render.
    @ObservationIgnored var pinnedSidebarFavoritesCache: [PinnedSidebarItem]?
    // ---------- apply filter bar + search + sort ----------
    @ObservationIgnored var listPositionsCache: (signature: ListSignature, positions: [String: Int])?

    /// The last position a lookup found. Navigation and rating mostly ask about the photo
    /// they just moved to, so this answers them without a scan; it is verified on every use.
    @ObservationIgnored var listPositionHint: (id: String, position: Int)?

    /// Photos a review edit just took out of the list (rated out of Unrated, say), for the list
    /// they left: looking them up again would walk the whole list for nothing.
    @ObservationIgnored var listDepartedIds: (signature: ListSignature, ids: Set<String>)?

    /// Changes whenever `list` is rebuilt (other photos or another order may follow), but not
    /// when edits are patched into the same positions.
    @ObservationIgnored var listIdentity = 0

    /// Photos per chunk when the list is worked out on every core, and per run its sort sorts
    /// before merging (tests make them small, so chunks and runs split everywhere).
    @ObservationIgnored var listChunk = 16_384
    // ---------- selection ----------

    // Self-checks must exercise interactions, not the launch-loading guard.
    /// Off for benchmarks: thumbnail backfill, the availability scan and duplicate grouping
    /// would compete with what is being timed (and flag synthetic photos as missing).
    @ObservationIgnored var runsBackgroundMaintenance = true
    // ----- quick collection (B) -----

    /// Lightroom's Quick Collection: a scratch set of photos gathered with B while culling,
    /// kept in the catalog (as an album under a reserved id) but listed apart from albums.
    var quickCollection: Set<String> = [] {
        didSet { if quickCollection != oldValue { listInputsVersion &+= 1 } }
    }
    // ---------- location: place on a map, match a GPX track ----------
    /// A GPX file loaded for the matching dialog.
    var gpxTrack: (name: String, track: GPXTrack)?
    // ---------- people: faces found on device, grouped and named ----------
    /// Faces by id, loaded with the catalog; views observe `facesRevision`.
    @ObservationIgnored var faces: [String: FaceRecord] = [:]
    @ObservationIgnored var faceScannedAssetIds: Set<String> = []
    /// Photos analysed before faces were told apart by SFace, waiting to be analysed again.
    @ObservationIgnored var faceOutdatedAssetIds: Set<String> = []
    /// Bumped with every change of the two sets above (each also bumps `facesRevision`).
    @ObservationIgnored var faceScanVersion = 0
    /// The People banner's counts of photos not analysed and analysed by the earlier method, by
    /// the scans, the photos' structure and the pairing they were counted for.
    @ObservationIgnored var faceAnalysisCountsCache: (scan: Int, structure: Int, pairs: Bool, unscanned: Int, outdated: Int)?
    /// Photos the analysis found a face in: the 人物 collection's photos.
    @ObservationIgnored var faceAssetIds: Set<String> = [] {
        didSet {
            guard faceAssetIds != oldValue else { return }
            libraryCountsCache = nil
            if isPeople { listInputsVersion &+= 1 }
        }
    }
    var facesRevision = 0
    /// Unnamed faces in likely-one-person groups, largest first, those in photos removed from
    /// the catalog included (`faceClusters` leaves them out).
    var allFaceClusters: [FaceCluster] = [] {
        didSet { faceClustersCache = nil }
    }
    @ObservationIgnored var faceClustersCache: (structure: Int, clusters: [FaceCluster])?
    /// Progress while photos are being analysed.
    var faceAnalysis: (done: Int, total: Int)?
    @ObservationIgnored var faceAnalysisGeneration = 0
    @ObservationIgnored var peopleCache: (revision: Int, structure: Int, people: [PersonSummary])?
    // ---------- survey (N) ----------
    /// Photos laid out side by side in Survey, in list order. The primary one is active and is
    /// the whole selection, so rating and flag keys act on it alone, as in Lightroom.
    var surveyIds: [String] = []
    // ---------- keyboard ----------

    /// Updated by the grid so arrow-key navigation knows the column count.
    @ObservationIgnored var gridWidth: CGFloat?
}

extension AppAppearance {
    static let defaultsKey = "pc_appearance"
    static var stored: AppAppearance {
        AppAppearance(rawValue: UserDefaults.app.string(forKey: defaultsKey) ?? "") ?? .system
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

extension AppLanguage {
    private static let defaultsKey = "AppleLanguages"

    /// The choice kept in this app's own AppleLanguages, which macOS reads at launch.
    static var stored: AppLanguage {
        let domain = UserDefaults.app.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")
        return (domain?[defaultsKey] as? [String])?.first.flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    func store() {
        if self == .system {
            UserDefaults.app.removeObject(forKey: Self.defaultsKey)
        } else {
            UserDefaults.app.set([rawValue], forKey: Self.defaultsKey)
        }
    }
}

/// A project or client (or camera) as the sidebar and the filter bar list it: without the spaces
/// and line breaks around it, so " Wedding " and "Wedding" are one project.
func listedValue(_ raw: String) -> String {
    // Nearly every value starts and ends with a printable ASCII character, which no trimming
    // takes off: only the others go through Foundation (a call per photo, at 500k photos a
    // quarter of a second for the filter bar's cameras and lenses).
    if let first = raw.utf8.first, let last = raw.utf8.last, (0x21...0x7E).contains(first), (0x21...0x7E).contains(last) {
        return raw
    }
    return raw.trimmingCharacters(in: .whitespacesAndNewlines)
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
