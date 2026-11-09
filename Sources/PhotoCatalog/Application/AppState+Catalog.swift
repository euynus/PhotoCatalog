import AppKit
import Foundation
import UniformTypeIdentifiers

private enum DeferredCatalogLoadOutcome: Sendable {
    case success(CatalogStore, AssetPage)
    case incompatibleSchema(current: Int, supported: Int)
    case failure
}

private enum DeferredCatalogHydrationOutcome: Sendable {
    case success([Asset], AppState.CatalogDerivedData)
    case failure
}

private final class CatalogOpenPanelDelegate: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, validate url: URL) throws {
        guard AppState.isValidCatalogSelection(url) else {
            throw NSError(domain: "PhotoCatalog.CatalogOpenPanel", code: 1,
                          userInfo: [
                            NSLocalizedDescriptionKey: L("请选择有效的 .photolibrary 目录库")
                          ])
        }
    }
}

@MainActor
extension AppState {
    // ---------- catalog open / load ----------
    var hasOpenCatalog: Bool { store != nil }
    var canRunCatalogMaintenance: Bool { hasOpenCatalog && !importing && !isLoadingCatalog }

    var catalogPath: String {
        store?.packageURL.path ?? loadingCatalogURL?.path ?? L("未打开目录库")
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
            text = mode == .managed ? L("原件已复制到目录库") : L("原位添加 · 原件只读")
        } else if hasManaged {
            text = hasReferenced ? L("混合管理 · 原件只读") : L("原件已复制到目录库")
        } else {
            text = L("原位添加 · 原件只读")
        }
        catalogManagementTextCache = (version, modes, mode, text)
        return text
    }

    var statusCacheText: String {
        guard let cacheBytes = statusMetrics.cacheBytes else { return L("缓存 --") }
        if cacheBytes == 0 { return L("缓存 0 KB") }
        return L("缓存 \(ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file))")
    }

    var statusBackupText: String {
        guard let date = statusMetrics.lastBackupDate else { return L("尚未备份") }
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        if Calendar.current.isDateInToday(date) {
            return L("上次备份 今天 \(time)")
        }
        if Calendar.current.isDateInYesterday(date) {
            return L("上次备份 昨天 \(time)")
        }
        let day = date.formatted(.dateTime.month(.twoDigits).day(.twoDigits))
        return L("上次备份 \(day) \(time)")
    }

    private var configuredCatalogURL: URL {
        UserDefaults.app.url(forKey: Self.catalogURLKey) ?? CatalogStore.defaultURL
    }

    @discardableResult
    func loadExistingCatalog(creatingIfMissing: Bool = false) -> Error? {
        let url = configuredCatalogURL
        FileAccessService.reach(url)
        guard creatingIfMissing || FileManager.default.fileExists(atPath: url.path) else { return nil }
        let s: CatalogStore
        let real: [Asset]
        let collections: CatalogCollections
        do {
            s = try CatalogStore(packageURL: url)
            // read whole before any of it is shown: a part that can't be read fails the open,
            // rather than showing as an empty catalog that later edits would build on
            real = try s.loadAssets().filter { !$0.isDemo && !$0.deleted }
            collections = try s.loadCatalogCollections()
        } catch {
            return error
        }
        store = s
        coordinator = ImportCoordinator(store: s)
        rememberCatalog(url)
        refreshStatusMetrics()
        applyLoadedCatalog(real, from: s, collections: collections)
        return nil
    }

    func applyLoadedCatalog(_ real: [Asset], from store: CatalogStore, collections: CatalogCollections,
                                    derived: CatalogDerivedData? = nil) {
        guard !real.isEmpty else {
            assets = []
            albums = []
            quickCollection = []
            smartAlbums = []
            albumSets = []
            folders = []
            duplicateGroupsCache = []
            restoreSourceRoots(from: store)
            movedSourceRoots = []
            restoreAlbums(from: store, collections: collections)
            recoverInterruptedImportJobs()
            ensurePrimaryValid()
            return
        }

        assets = []
        albums = []
        quickCollection = []
        smartAlbums = []
        albumSets = []
        folders = []
        restoreSourceRoots(from: store)

        let sourceRootsById = sourceRootRecordsById(from: store)
        let repaired = repairSourceRootOwnership(real, sourceRootsById: sourceRootsById)
        let checked = repaired.assets
        if !repaired.changed.isEmpty { try? store.upsert(repaired.changed) }
        assets = checked
        // computed off the main thread from this very array; a repair makes it stale
        if let derived, repaired.changed.isEmpty { seedDerivedCaches(derived) }
        let summaries = Self.folderSummaries(checked)
        let known = Set(folders.map(\.id))
        for (fid, summary) in summaries.sorted(by: { $0.key < $1.key }) where !known.contains(fid) {
            folders.append(Folder(id: fid, name: summary.name, status: summary.status))
        }
        for index in folders.indices where
            sourceManagementModesById[folders[index].id] == ImportMode.managed.rawValue {
            let status = summaries[folders[index].id]?.status ?? folders[index].status
            folders[index].status = status
            try? store.updateSourceRootStatus(id: folders[index].id, status: status)
        }
        recomputeDuplicates()
        restoreAlbums(from: store, collections: collections)
        recoverInterruptedImportJobs()
        primeDefaultListCache(with: checked)
        ensurePrimaryValid()
        for moved in movedSourceRoots {
            rebaseSourceRootAssetPaths(folderId: moved.id, oldRoot: moved.from, newRoot: moved.to)
        }
        movedSourceRoots = []
        backfillThumbnails()
        detectMissingRealAssets()
        checkExternalXMPChanges()
        refreshStatusMetrics()
    }

    /// Starts the production launch load after SwiftUI has created the first window.
    func startDeferredCatalogLoadingIfNeeded() {
        guard let arguments = deferredCatalogArguments else { return }
        deferredCatalogArguments = nil

        let launchURL = Self.launchCatalogURL(from: arguments).map(Self.catalogPackageURL(for:))
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
        FileAccessService.reach(url)
        invalidateDescriptionReview()
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
            /// Says why the catalog didn't open, then opens the fallback, or leaves the failure showing.
            @MainActor func fail(_ message: String) {
                if let fallbackURL {
                    self.push(verbatim: message, "warning")
                    self.beginDeferredCatalogLoad(at: fallbackURL, fallbackURL: nil)
                } else {
                    self.finishDeferredCatalogLoadFailure(message: message)
                }
            }
            switch outcome {
            case .success(let store, let page):
                self.store = store
                self.coordinator = ImportCoordinator(store: store)
                self.applyCatalogPreview(page)

                // the preview stays live while the rest is read: menus and Settings can still edit it
                let mutations = self.assetMutationCount
                let pairsRawJpeg = self.pairRawAndJpeg
                let recentDays = self.recentImportDays
                let recentCutoff = self.recentCutoff
                let hydration = await Task.detached(priority: .userInitiated) {
                    do {
                        let live = try store.loadAssets().filter { !$0.isDemo && !$0.deleted }
                        let derived = CatalogDerivedData.derive(from: live, pairsRawJpeg: pairsRawJpeg,
                                                                recentCutoff: recentCutoff)
                        return DeferredCatalogHydrationOutcome.success(live, derived)
                    } catch {
                        return DeferredCatalogHydrationOutcome.failure
                    }
                }.value
                if let gate = self.catalogHydrationGate { await gate() }
                guard self.catalogLoadGeneration == generation, !Task.isCancelled else { return }
                switch hydration {
                case .success(let loaded, let derived):
                    // read now, with whatever changed in them while the photos loaded; a part that
                    // can't be read fails the open, as the photos would, rather than showing empty
                    guard let collections = try? store.loadCatalogCollections() else {
                        self.discardCatalogPreview()
                        fail(L("打开目录库失败"))
                        return
                    }
                    self.catalogLoadTask = nil
                    self.setActiveCatalog(url)
                    self.refreshStatusMetrics()
                    self.loadingCatalogTotalCount = nil
                    // edits made meanwhile were saved as they were made, so the photos on screen
                    // are newer than the copies read in the background
                    let edited = self.assetMutationCount != mutations
                    let assets = edited ? Self.overlaying(self.assets, onto: loaded) : loaded
                    // counted from the copies read, under the settings of the time
                    let current = !edited && self.pairRawAndJpeg == pairsRawJpeg && self.recentImportDays == recentDays
                    self.applyLoadedCatalog(assets, from: store, collections: collections,
                                            derived: current ? derived : nil)
                    self.hasCatalogPreview = false
                    self.isLoadingCatalog = false
                    self.loadingCatalogURL = nil
                    UserDefaults.app.set("1", forKey: "pc_onboarded")
                    self.onboarded = true
                    self.seedInitialSelection()
                    self.runAutomaticBackupIfNeeded()
                    if announceSuccess {
                        self.push("已打开目录库 · \(url.lastPathComponent)", "check")
                    }
                case .failure:
                    self.discardCatalogPreview()
                    fail(L("打开目录库失败"))
                }
            case .incompatibleSchema(let current, let supported):
                fail(L("目录库版本过新（schema \(current)，当前支持 \(supported)），请升级 PhotoCatalog 后再打开"))
            case .failure:
                fail(L("打开目录库失败"))
            }
        }
    }

    /// `loaded` with `edited` (the photos on screen as the load finishes) in place of the copies
    /// read before their edits: removed ones dropped, ones made meanwhile (virtual copies) added.
    nonisolated static func overlaying(_ edited: [Asset], onto loaded: [Asset]) -> [Asset] {
        var pending = Dictionary(edited.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var merged: [Asset] = []
        merged.reserveCapacity(loaded.count + edited.count)
        for asset in loaded {
            guard let newer = pending.removeValue(forKey: asset.id) else {
                merged.append(asset)
                continue
            }
            if !newer.deleted { merged.append(newer) }
        }
        for asset in edited where !asset.deleted && pending.removeValue(forKey: asset.id) != nil {
            merged.append(asset)
        }
        return merged
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
        resetCatalog(toDemo: false)
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
        resetCatalog(toDemo: true)
        UserDefaults.app.set("0", forKey: "pc_onboarded")
        onboarded = false
        if let message { push(verbatim: message, "warning") }
    }

    private func restoreAlbums(from store: CatalogStore, collections: CatalogCollections) {
        developSettings = collections.developSettings
        clearDevelopRecordCaches()
        loadFaces(from: store)
        // the quick collection is stored as an album under a reserved id, and listed apart
        let loadedAlbums = collections.albums
        quickCollection = Set(loadedAlbums.first { $0.id == Self.quickCollectionID }?.assetIds ?? [])
        albums = loadedAlbums.filter { $0.id != Self.quickCollectionID }
        // counted by the sidebar (sidebarCounts), on all cores and once: matching every rule over
        // the catalog here as well added most of a second to opening a large one
        smartAlbums = collections.smartAlbums
        albumSets = collections.albumSets
        xmpSyncTimes = collections.xmpSyncTimes
        externallyChangedXMPIds = []
        xmpConflictIds = []
    }

    private func restoreSourceRoots(from store: CatalogStore) {
        // originals relocated or moved outside the source folders
        FileAccessService.reachOriginals()
        guard let roots = try? store.loadSourceRoots() else { return }
        for root in roots {
            applySourceRoot(root, resolved: resolveSourceRoot(root), in: store)
        }
        refreshWatcher()
    }

    /// Records where a source folder was found, or why it wasn't, in the catalog and the sidebar,
    /// and watches a referenced folder that's there (the caller restarts the watcher).
    func applySourceRoot(_ root: SourceRootRecord, resolved: (url: URL?, status: String, bookmark: Data?),
                                 in store: CatalogStore) {
        if resolved.status == "online", let url = resolved.url,
           url.path != root.pathHint || resolved.bookmark != root.bookmarkData {
            try? store.updateSourceRootAccess(
                id: root.id,
                displayName: root.displayName,
                path: url.path,
                bookmark: resolved.bookmark,
                status: resolved.status,
                volumeIdentifier: volumeProbe.identifier(url) ?? root.volumeIdentifier
            )
            // found elsewhere — renamed or moved (a stale bookmark), or its drive mounted under
            // another name: its photos move with it, before anything at their old paths (on
            // another drive of the old name, say) is taken for them
            if url.path != root.pathHint {
                movedSourceRoots.append((root.id, root.pathHint, url.path))
            }
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

    /// Where a source folder is now, whether it can be read, and its bookmark: a stale one is
    /// replaced by one made as it's opened.
    func resolveSourceRoot(_ root: SourceRootRecord) -> (url: URL?, status: String, bookmark: Data?) {
        if root.managementMode == ImportMode.managed.rawValue {
            return (nil, "online", root.bookmarkData)
        }
        // its drive isn't mounted: whatever has that drive's name now (another drive) isn't it
        if volumeProbe.placement(of: root.pathHint, onVolume: root.volumeIdentifier) == .absent {
            return (nil, "offline", root.bookmarkData)
        }
        guard var bookmark = root.bookmarkData else {
            let fallback = fallbackSourceRoot(root, preferredStatus: nil)
            return (fallback.url, fallback.status, nil)
        }
        guard let resolved = FileAccessService.resolveBookmark(bookmark) else {
            // a drive that isn't plugged in can't resolve it either: that's offline, not a lost permission
            let driveAway = volumeProbe.volumeRoot(of: root.pathHint).map { !FileManager.default.fileExists(atPath: $0) }
            let fallback = fallbackSourceRoot(root, preferredStatus: driveAway == true ? nil : "permissionLost")
            return (fallback.url, fallback.status, bookmark)
        }
        // looked for again each time a drive comes or goes: access opened once is kept
        let ok = securityScopedRoots.contains(resolved.url) || resolved.url.startAccessingSecurityScopedResource()
        if ok, !securityScopedRoots.contains(resolved.url) { securityScopedRoots.append(resolved.url) }
        if resolved.isStale {
            // a renamed or moved folder still opens; the bookmark made now finds it next time
            guard ok, let fresh = FileAccessService.createBookmark(for: resolved.url) else {
                return (resolved.url, "permissionLost", bookmark)
            }
            bookmark = fresh
        }
        // on its own drive, wherever that's mounted now
        guard let path = volumeProbe.currentPath(of: resolved.url.path, onVolume: root.volumeIdentifier) else {
            return (nil, "offline", bookmark)
        }
        let url = path == resolved.url.path ? resolved.url : URL(fileURLWithPath: path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (url, volumeProbe.status(forInaccessible: url.path, volumeIdentifier: root.volumeIdentifier).rawValue,
                    bookmark)
        }
        guard FileAccessService.canRead(url.path) else {
            return (url, "permissionLost", bookmark)
        }
        return (url, "online", bookmark)
    }

    private func fallbackSourceRoot(_ root: SourceRootRecord, preferredStatus: String?) -> (url: URL?, status: String) {
        // on its own drive, wherever that's mounted now
        guard let path = volumeProbe.currentPath(of: root.pathHint, onVolume: root.volumeIdentifier) else {
            return (nil, "offline")
        }
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: url.path) {
            return (url, preferredStatus ?? (FileAccessService.canRead(url.path) ? "online" : "permissionLost"))
        }
        return (nil, preferredStatus ?? volumeProbe.status(
            forInaccessible: path,
            volumeIdentifier: root.volumeIdentifier
        ).rawValue)
    }

    func sourceRootRecordsById(from store: CatalogStore) -> [String: SourceRootRecord] {
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

    static func path(_ path: String, isIn root: String) -> Bool {
        let root = root.hasSuffix("/") && root.count > 1 ? String(root.dropLast()) : root
        return path == root || path.hasPrefix(root + "/")
    }

    func setSourceFolder(id: String, name: String, path: String, status: String) {
        // an import sets this again with each batch: the same values mustn't rebuild the folder tree
        if sourceRootPathsById[id] != path { sourceRootPathsById[id] = path }
        let folder = Folder(id: id, name: name, status: status)
        if let index = folders.firstIndex(where: { $0.id == id }) {
            if folders[index] != folder { folders[index] = folder }
        } else {
            folders.append(folder)
        }
    }

    /// The configured catalog — created the first time — for an import with none open (Add
    /// Photo Folder from the Welcome screen), loaded like any catalog opened: the demo photos
    /// still in memory make way for its own, its albums and Quick Collection with them.
    func openOrCreateCatalog() {
        guard store == nil else { return }
        let url = configuredCatalogURL
        resetCatalog(toDemo: false)
        let error = loadExistingCatalog(creatingIfMissing: true)
        guard store != nil else {
            resetCatalog(toDemo: true)
            push(verbatim: catalogOpenFailureMessage(error, fallback: L("无法创建目录库")), "warning")
            return
        }
        setActiveCatalog(url)
    }

    func createCatalog() {
        guard !importing else {
            push("导入中无法切换目录库", "warning")
            return
        }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "PhotoCatalog Library.photolibrary"
        panel.prompt = L("创建")
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
            resetCatalog(toDemo: false)
            let nextStore = try CatalogStore(packageURL: url)
            store = nextStore
            coordinator = ImportCoordinator(store: nextStore)
            setActiveCatalog(url)
            refreshStatusMetrics()
            UserDefaults.app.set("1", forKey: "pc_onboarded")
            onboarded = true
            push("已创建目录库 · \(url.lastPathComponent)", "check")
            return true
        } catch {
            resetCatalog(toDemo: true)
            loadExistingCatalog()
            push(verbatim: catalogOpenFailureMessage(error, fallback: L("创建目录库失败")), "warning")
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
        resetCatalog(toDemo: true)
        UserDefaults.app.removeObject(forKey: Self.catalogURLKey)
        UserDefaults.app.set("0", forKey: "pc_onboarded")
        onboarded = false
        push("已关闭目录库", "check")
    }

    func configureCatalogOpenPanel(_ panel: NSOpenPanel) {
        panel.allowsMultipleSelection = false
        panel.prompt = L("打开")
        panel.message = L("选择 .photolibrary 目录库")
        if let libraryType = UTType(filenameExtension: "photolibrary") {
            panel.allowedContentTypes = [libraryType]
        }
        // Setting allowedContentTypes updates these flags on macOS 27 and later.
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
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
        resetCatalog(toDemo: true)
        setActiveCatalog(url)
        let error = loadExistingCatalog()
        if store == nil {
            forgetCatalog(url)
            setActiveCatalog(previousURL)
            resetCatalog(toDemo: true)
            loadExistingCatalog()
            push(verbatim: catalogOpenFailureMessage(error), "warning")
            return false
        } else {
            UserDefaults.app.set("1", forKey: "pc_onboarded")
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
        // opened from the Finder, it needn't be among the recents: an invalid one is only refused
        beginCatalogSwitch(at: selected, forgettingInvalid: false)
    }

    private func beginCatalogSwitch(at selected: URL, announceSuccess: Bool = false, forgettingInvalid: Bool = true) {
        guard !importing else {
            push("导入中无法切换目录库", "warning")
            return
        }
        let url = Self.catalogPackageURL(for: selected)
        if (store?.packageURL ?? loadingCatalogURL)?.standardizedFileURL == url.standardizedFileURL {
            return
        }
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("catalog.sqlite").path) else {
            if forgettingInvalid { forgetCatalog(url) }
            push("所选目录库无效", "warning")
            return
        }

        let fallbackURL = store?.packageURL
        closeCurrentCatalog()
        resetCatalog(toDemo: false)
        beginDeferredCatalogLoad(at: url, fallbackURL: fallbackURL, announceSuccess: announceSuccess)
    }

    func clearRecentCatalogs() {
        let active = configuredCatalogURL.standardizedFileURL.path
        for path in recentCatalogPaths where path != active { FileAccessService.forget(URL(fileURLWithPath: path)) }
        recentCatalogPaths = []
        UserDefaults.app.set(recentCatalogPaths, forKey: Self.recentCatalogsKey)
        push("已清除最近目录库", "trash")
    }

    func confirmClearRecentCatalogs() {
        guard confirmDestructiveAction(L("清除最近目录库？"), L("只会清除本机最近打开列表，不会删除目录库文件。"), L("清除")) else { return }
        clearRecentCatalogs()
    }

    func catalogOpenFailureMessage(_ error: Error?, fallback: String = L("打开目录库失败")) -> String {
        if let error = error as? CatalogStoreError,
           case let .incompatibleSchema(current, supported) = error {
            return L("目录库版本过新（schema \(current)，当前支持 \(supported)），请升级 PhotoCatalog 后再打开")
        }
        // a snapshot made by a newer version, refused before it replaced the catalog
        if let error = error as? BackupError, case let .newerSchema(current, supported) = error {
            return L("目录库版本过新（schema \(current)，当前支持 \(supported)），请升级 PhotoCatalog 后再打开")
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
        UserDefaults.app.set(url, forKey: Self.catalogURLKey)
        // so a sandboxed copy can open it again in a later launch
        FileAccessService.remember(url)
        rememberCatalog(url)
    }

    private func rememberCatalog(_ url: URL) {
        let path = url.path
        recentCatalogPaths.removeAll { $0 == path }
        recentCatalogPaths.insert(path, at: 0)
        if recentCatalogPaths.count > 8 {
            recentCatalogPaths.removeLast(recentCatalogPaths.count - 8)
        }
        UserDefaults.app.set(recentCatalogPaths, forKey: Self.recentCatalogsKey)
    }

    private func forgetCatalog(_ url: URL) {
        recentCatalogPaths.removeAll { $0 == url.path }
        UserDefaults.app.set(recentCatalogPaths, forKey: Self.recentCatalogsKey)
        if url.standardizedFileURL != configuredCatalogURL.standardizedFileURL { FileAccessService.forget(url) }
    }
}
