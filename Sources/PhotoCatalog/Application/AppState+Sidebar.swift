import AppKit
import Foundation

@MainActor
extension AppState {
    var sidebarDay: Date { CaptureDates.startOfToday(now: sidebarClock()) }
    /// Each sidebar row's photo count, by folder, album, keyword, project, client and smart album id.
    struct SidebarCounts: Equatable {
        var folders: [String: Int] = [:]
        var albums: [String: Int] = [:]
        var keywords: [String: Int] = [:]
        var projects: [String: Int] = [:]
        var clients: [String: Int] = [:]
        var smartAlbums: [String: Int] = [:]
    }
    struct SidebarCountIndex {
        var counts = SidebarCounts()
        /// The smart albums' rules as the counts were matched, so an edit is matched the same way.
        var smartRules: [(id: String, rule: SmartMatcher.Prepared)] = []
        /// The day they were matched on: Today, This Week and the other relative dates move at
        /// midnight, so the counts are of that day only.
        var day = Date.distantPast

        /// Moves a photo shown before and after an edit from what it was to what the edit made it:
        /// its smart albums, folder, keywords, project and client can change (what `count` takes
        /// out and puts in, without touching what didn't), the rules' text tests kept in `memos`.
        mutating func move(from old: Asset, to new: Asset, memos: inout [SmartMatcher.Memo]) {
            for (offset, (id, rule)) in smartRules.enumerated() {
                let change = (rule.matches(new, memo: &memos[offset]) ? 1 : 0) - (rule.matches(old, memo: &memos[offset]) ? 1 : 0)
                if change != 0 { counts.smartAlbums[id, default: 0] += change }
            }
            if old.folderId != new.folderId {
                Self.add(-1, to: old.folderId, in: &counts.folders)
                Self.add(1, to: new.folderId, in: &counts.folders)
            }
            if old.keywords != new.keywords {
                for keyword in old.keywords { Self.add(-1, to: keyword, in: &counts.keywords) }
                for keyword in new.keywords { Self.add(1, to: keyword, in: &counts.keywords) }
            }
            // under their names as listed, without the spaces around them
            let (oldProject, newProject) = (listedValue(old.project), listedValue(new.project))
            if oldProject != newProject {
                if !oldProject.isEmpty { Self.add(-1, to: oldProject, in: &counts.projects) }
                if !newProject.isEmpty { Self.add(1, to: newProject, in: &counts.projects) }
            }
            let (oldClient, newClient) = (listedValue(old.client), listedValue(new.client))
            if oldClient != newClient {
                if !oldClient.isEmpty { Self.add(-1, to: oldClient, in: &counts.clients) }
                if !newClient.isEmpty { Self.add(1, to: newClient, in: &counts.clients) }
            }
        }

        /// Counts in a photo the sidebar now shows, or with -1 one it no longer shows (but for the
        /// albums it's in), the smart albums' text tests kept in `memos` (one per rule).
        mutating func count(_ asset: Asset, _ sign: Int, memos: inout [SmartMatcher.Memo]) {
            for (offset, (id, rule)) in smartRules.enumerated() where rule.matches(asset, memo: &memos[offset]) {
                counts.smartAlbums[id, default: 0] += sign
            }
            Self.add(sign, to: asset.folderId, in: &counts.folders)
            for keyword in asset.keywords { Self.add(sign, to: keyword, in: &counts.keywords) }
            let project = asset.project.isEmpty ? "" : listedValue(asset.project)
            if !project.isEmpty { Self.add(sign, to: project, in: &counts.projects) }
            let client = asset.client.isEmpty ? "" : listedValue(asset.client)
            if !client.isEmpty { Self.add(sign, to: client, in: &counts.clients) }
        }

        /// A name no photo has any more is dropped, as a recount would leave it out.
        private static func add(_ change: Int, to key: String, in counts: inout [String: Int]) {
            let count = counts[key, default: 0] + change
            counts[key] = count == 0 ? nil : count
        }
    }
    struct LibraryCounts: Equatable {
        var all = 0, recent = 0, unrated = 0, picks = 0, rejected = 0, missingOffline = 0, places = 0, people = 0

        /// A live photo's file: missing or offline counts every file, a JPEG behind its RAW too.
        mutating func countFile(_ a: Asset, _ sign: Int = 1) {
            if a.status == .missing || a.status == .offline { missingOffline += sign }
        }

        /// A photo as the library shows it (or, with -1, one it no longer shows).
        mutating func count(_ a: Asset, recentCutoff cutoff: Date, withFaces: Set<String>, _ sign: Int = 1) {
            all += sign
            if a.importedAt > cutoff { recent += sign }
            if a.rating == 0 && a.flag != .reject { unrated += sign }
            if a.flag == .pick { picks += sign }
            if a.flag == .reject { rejected += sign }
            if a.hasGPS { places += sign }
            if a.faces > 0 || (!withFaces.isEmpty && withFaces.contains(a.id)) { people += sign }
        }

        /// Whether two states of a photo are counted alike as shown: `count` reads nothing else
        /// (a status or a path changes none of these counts).
        static func countAlike(_ a: Asset, _ b: Asset) -> Bool {
            a.importedAt == b.importedAt && a.rating == b.rating && a.flag == b.flag && a.faces == b.faces
                && a.gps == b.gps && a.location == b.location
        }

        fileprivate mutating func add(_ other: LibraryCounts) {
            all += other.all
            recent += other.recent
            unrated += other.unrated
            picks += other.picks
            rejected += other.rejected
            missingOffline += other.missingOffline
            places += other.places
            people += other.people
        }

        /// The only count a keyword / title / credit / location edit can move.
        mutating func applyMetadataChange(from old: Asset, to new: Asset) {
            guard !old.deleted else { return }
            places += (new.hasGPS ? 1 : 0) - (old.hasGPS ? 1 : 0)
        }

        /// The only counts a rating / flag / color edit can move.
        mutating func applyReviewChange(from old: Asset, to new: Asset) {
            guard !old.deleted else { return }
            func one(_ condition: Bool) -> Int { condition ? 1 : 0 }
            unrated += one(new.rating == 0 && new.flag != .reject) - one(old.rating == 0 && old.flag != .reject)
            picks += one(new.flag == .pick) - one(old.flag == .pick)
            rejected += one(new.flag == .reject) - one(old.flag == .reject)
        }
    }

    struct CaptureStatisticsRequest: Equatable {
        fileprivate let list: ListSignature
        fileprivate let selectedIds: Set<String>?
        fileprivate let catalogGeneration: Int
        fileprivate let isLoading: Bool
    }

    // ---------- keyword sidebar list ----------
    private var keywordCounts: KeywordTally {
        if let cache = keywordCountsCache { return cache }
        let result = Self.keywordCounts(of: assets, pairing: assetPairing)
        keywordCountsCache = result
        return result
    }

    /// Every keyword of the photos as shown: how many it's on, the order a pass meets them in
    /// (which orders the keyword list's ties), and the photo each is first met on.
    typealias KeywordTally = (order: [String], counts: [String: Int], first: [String: Int])

    /// Counted in chunks on every core and added up chunk by chunk, which keeps that order: one
    /// thread took ~0.4 s at 500k photos, and the sidebar waits for it after every import batch.
    nonisolated static func keywordCounts(of assets: [Asset], pairing: AssetPairing, chunk: Int = 32_768)
        -> KeywordTally {
        func count(_ range: Range<Int>) -> KeywordTally {
            var order: [String] = []
            var counts: [String: Int] = [:]
            var first: [String: Int] = [:]
            for position in range {
                let a = assets[position]
                guard pairing.isShown(a, at: position) else { continue }
                for k in a.keywords {
                    // one lookup per keyword: the table grows exactly when the keyword is new
                    let known = counts.count
                    counts[k, default: 0] += 1
                    if counts.count != known {
                        order.append(k)
                        first[k] = position
                    }
                }
            }
            return (order, counts, first)
        }
        let parts = Chunks.map(assets.count, chunk: chunk, count)
        guard parts.count > 1 else { return parts.first ?? ([], [:], [:]) }
        var order: [String] = []
        var counts: [String: Int] = [:]
        var first: [String: Int] = [:]
        for part in parts {
            for keyword in part.order {
                if counts[keyword] == nil {
                    order.append(keyword)
                    first[keyword] = part.first[keyword]
                }
                counts[keyword, default: 0] += part.counts[keyword] ?? 0
            }
        }
        return (order, counts, first)
    }

    /// What the sidebar and inspector derive from a whole catalog, computed on the loading
    /// thread so a 500k-photo catalog doesn't freeze the first render for seconds.
    struct CatalogDerivedData: @unchecked Sendable {
        let pairing: AssetPairing
        let indexById: [String: Int]
        let keywordCounts: KeywordTally
        let captureDayCounts: [Int: Int]
        let captureDateGroups: [CaptureDateBucket]
        let projects: MetadataValueCounts
        let clients: MetadataValueCounts
        let libraryCounts: LibraryCounts

        nonisolated static func derive(from assets: [Asset], pairsRawJpeg: Bool, recentCutoff: Date) -> CatalogDerivedData {
            let pairing = pairsRawJpeg ? AssetPairing.rawJpeg(assets) : .empty
            let indexById = AppState.positionsById(assets)
            let days = CaptureDates.dayCounts(assets, pairing: pairing)
            return CatalogDerivedData(
                pairing: pairing, indexById: indexById,
                keywordCounts: AppState.keywordCounts(of: assets, pairing: pairing),
                captureDayCounts: days, captureDateGroups: CaptureDates.groups(dayCounts: days),
                projects: AppState.metadataCounts(assets, pairing: pairing, \.project),
                clients: AppState.metadataCounts(assets, pairing: pairing, \.client),
                libraryCounts: AppState.libraryCounts(assets, pairing: pairing, recentCutoff: recentCutoff))
        }
    }

    /// Seeds the derived caches for the catalog just installed (only valid for that exact array).
    func seedDerivedCaches(_ derived: CatalogDerivedData) {
        assetIndexCache = derived.indexById
        if pairRawAndJpeg { assetPairingCache = (structureVersion, derived.pairing) }
        keywordCountsCache = derived.keywordCounts
        captureDateGroupsCache = (derived.captureDayCounts, derived.captureDateGroups)
        projectCountsCache = derived.projects
        clientCountsCache = derived.clients
        libraryCountsCache = derived.libraryCounts
    }

    var keywordList: [KeywordCount] {
        _ = listInputsVersion   // register the dependency even on a cache hit
        if let cache = keywordListCache { return cache }
        // Preserve first-encounter order (like a JS Map) so ties sort stably,
        // matching the prototype's keyword sidebar order.
        let result = Self.keywordList(from: keywordCounts)
        keywordListCache = result
        return result
    }

    private static func keywordList(from keywordCounts: KeywordTally) -> [KeywordCount] {
        let (order, counts, _) = keywordCounts
        return order.compactMap { name in counts[name].flatMap { $0 > 0 ? KeywordCount(name: name, count: $0) : nil } }
            .sorted { $0.count > $1.count }   // Swift 5 sort is stable
            .prefix(8)
            .map { $0 }
    }

    var keywordSuggestionPool: [String] {
        _ = listInputsVersion   // register the dependency even on a cache hit
        if let cache = keywordSuggestionPoolCache { return cache }
        // the distinct keywords the counts already know, not every photo's list again
        // (normalizing 1.2M keyword lists took 1.4 s at 500k photos)
        let (order, counts, _) = keywordCounts
        var seen = Set<String>()
        var result: [String] = []
        for keyword in KeywordService.normalize(order.filter { (counts[$0] ?? 0) > 0 })
        where seen.insert(keyword).inserted {
            result.append(keyword)
        }
        for keyword in DemoData.keywordPool where seen.insert(keyword).inserted {
            result.append(keyword)
        }
        keywordSuggestionPoolCache = result
        return result
    }

    /// The keyword list as counted afresh from every photo, leaving the cached one alone (for tests).
    func recountedKeywordList() -> [KeywordCount] {
        Self.keywordList(from: Self.keywordCounts(of: assets, pairing: assetPairing))
    }

    /// The lists as counted afresh from every photo, leaving the cached ones alone (for tests).
    func recountedMetadataLists() -> (projects: [KeywordCount], clients: [KeywordCount]) {
        (countMetadataValues(\.project), countMetadataValues(\.client))
    }

    var projectList: [KeywordCount] {
        _ = listInputsVersion   // register the dependency even on a cache hit
        if let cache = projectCountsCache { return cache.list }
        let result = Self.metadataCounts(assets, pairing: assetPairing, \.project)
        metadataListRebuilds &+= 1
        projectCountsCache = result
        return result.list
    }

    var clientList: [KeywordCount] {
        _ = listInputsVersion   // register the dependency even on a cache hit
        if let cache = clientCountsCache { return cache.list }
        let result = Self.metadataCounts(assets, pairing: assetPairing, \.client)
        metadataListRebuilds &+= 1
        clientCountsCache = result
        return result.list
    }

    var captureDateGroups: [CaptureDateBucket] {
        _ = listInputsVersion
        if let cached = captureDateGroupsCache { return cached.groups }
        let days = CaptureDates.dayCounts(assets, pairing: assetPairing)
        let grouped = CaptureDates.groups(dayCounts: days)
        captureDateGroupsCache = (days, grouped)
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
        _ = facesRevision       // the people count follows face analysis
        if let cache = libraryCountsCache { return cache }
        var counts = Self.libraryCounts(assets, pairing: assetPairing, recentCutoff: recentCutoff, withFaces: faceAssetIds)
        if isLoadingCatalog, let loadingCatalogTotalCount {
            counts.all = loadingCatalogTotalCount
        }
        libraryCountsCache = counts
        return counts
    }

    /// Counted in chunks on every core: one thread took ~0.2 s at 500k photos, and the sidebar
    /// waits for it after every structural change.
    nonisolated static func libraryCounts(_ assets: [Asset], pairing: AssetPairing, recentCutoff cutoff: Date,
                                          withFaces: Set<String> = [], chunk: Int = 32_768) -> LibraryCounts {
        func count(_ range: Range<Int>) -> LibraryCounts {
            var counts = LibraryCounts()
            for position in range {
                let a = assets[position]
                guard !a.deleted else { continue }
                counts.countFile(a)
                if pairing.isShown(a, at: position) { counts.count(a, recentCutoff: cutoff, withFaces: withFaces) }
            }
            return counts
        }
        return Chunks.map(assets.count, chunk: chunk, count).reduce(into: LibraryCounts()) { $0.add($1) }
    }

    /// The library's cameras and lenses, most used first: what the filter bar offers.
    var gearCounts: (cameras: [KeywordCount], lenses: [KeywordCount]) {
        _ = listInputsVersion   // register the dependency even on a cache hit
        if let cache = gearCountsCache { return (cache.cameras.list, cache.lenses.list) }
        let pairing = assetPairing
        let result = (cameras: Self.metadataCounts(assets, pairing: pairing, \.camera),
                      lenses: Self.metadataCounts(assets, pairing: pairing, \.lens))
        gearCountsCache = result
        return (result.cameras.list, result.lenses.list)
    }

    func countMetadataValues(_ keyPath: KeyPath<Asset, String>) -> [KeywordCount] {
        Self.metadataCounts(assets, pairing: assetPairing, keyPath).list
    }

    /// The values photos have for a field (a project, a client, a camera) as the sidebar and the
    /// filter bar list them: trimmed, each with how many of the photos as shown have it, most
    /// first, ties in the order a pass over the photos meets them. Where each value's first photo
    /// sits is kept, since it orders the ties, so that an edit can patch the list.
    struct MetadataValueCounts: Equatable {
        private(set) var list: [KeywordCount] = []
        private var counts: [String: Int]
        private var first: [String: Int]

        fileprivate init(counts: [String: Int], first: [String: Int]) {
            self.counts = counts
            self.first = first
            sort()
        }

        private mutating func sort() {
            list = counts.map { KeywordCount(name: $0.key, count: $0.value) }.sorted {
                $0.count != $1.count ? $0.count > $1.count : (first[$0.name] ?? .max) < (first[$1.name] ?? .max)
            }
        }

        /// What a photo is counted under: "" for none, or for a photo the library doesn't show.
        static func value(of asset: Asset, _ keyPath: KeyPath<Asset, String>, pairing: AssetPairing) -> String {
            let raw = asset[keyPath: keyPath]
            // most photos have no value: skip them before any lookup or Foundation call
            guard !raw.isEmpty, pairing.shows(asset) else { return "" }
            return listedValue(raw)
        }

        /// `value(of:_:pairing:)` of the photo at `position` of the photos `pairing` was worked out from.
        static func value(at position: Int, of assets: [Asset], _ keyPath: KeyPath<Asset, String>,
                          pairing: AssetPairing) -> String {
            let asset = assets[position]
            let raw = asset[keyPath: keyPath]
            guard !raw.isEmpty, pairing.isShown(asset, at: position) else { return "" }
            return listedValue(raw)
        }

        /// Moves the photos at the changes' offsets from their old value to their new one, as a
        /// recount of the photos as they are now (`value(at:)` of each offset) would count them: a
        /// value on no photo leaves the list, and one whose first photo lost it moves to its next.
        /// False when the counts don't add up to the photos (they're to be recounted then).
        mutating func apply(_ changes: [(offset: Int, old: String, new: String)], photos: Int,
                                        value: (Int) -> String) -> Bool {
            var lost: [String: Int] = [:]    // a value whose first photo lost it → that photo
            var added: [String: Int] = [:]   // a value → the first photo it was put on
            for change in changes where change.old != change.new {
                if !change.old.isEmpty {
                    guard let count = counts[change.old] else { return false }
                    counts[change.old] = count - 1
                    if first[change.old] == change.offset { lost[change.old] = change.offset }
                }
                if !change.new.isEmpty {
                    counts[change.new, default: 0] += 1
                    added[change.new] = min(added[change.new] ?? .max, change.offset)
                }
            }
            for name in counts.filter({ $0.value <= 0 }).map(\.key) {
                counts[name] = nil
                first[name] = nil
                lost[name] = nil
            }
            for (name, offset) in added where lost[name] == nil {
                first[name] = min(first[name] ?? .max, offset)
            }
            // No photo before a lost first one had the value: it's first on a photo given it now,
            // or on the next photo after that one that still has it.
            var pending: [String: Int] = [:]
            for (name, offset) in lost {
                if let put = added[name], put < offset { first[name] = put } else { pending[name] = offset }
            }
            if let start = pending.values.min() {
                for position in start + 1 ..< photos {
                    let name = value(position)
                    guard let after = pending[name], position > after else { continue }
                    first[name] = position
                    pending[name] = nil
                    if pending.isEmpty { break }
                }
            }
            guard pending.isEmpty else { return false }
            sort()
            return true
        }
    }

    /// Counted in chunks on every core, each chunk's counts added up and first photos kept.
    nonisolated static func metadataCounts(_ assets: [Asset], pairing: AssetPairing, _ keyPath: KeyPath<Asset, String>,
                                           chunk: Int = 32_768) -> MetadataValueCounts {
        func count(_ range: Range<Int>) -> (counts: [String: Int], first: [String: Int]) {
            var counts: [String: Int] = [:]
            var first: [String: Int] = [:]
            for position in range {
                let value = MetadataValueCounts.value(at: position, of: assets, keyPath, pairing: pairing)
                guard !value.isEmpty else { continue }
                let known = counts.count
                counts[value, default: 0] += 1
                if counts.count != known { first[value] = position }
            }
            return (counts, first)
        }
        let parts = Chunks.map(assets.count, chunk: chunk, count)
        var (counts, first) = parts.first ?? ([:], [:])
        for part in parts.dropFirst() {
            counts.merge(part.counts, uniquingKeysWith: +)
            first.merge(part.first, uniquingKeysWith: min)
        }
        return MetadataValueCounts(counts: counts, first: first)
    }

    /// Patches a project or client list for edits that changed that field, or drops it to be
    /// recounted when it doesn't add up.
    func patch(_ cache: inout MetadataValueCounts?, _ changes: [(offset: Int, old: String, new: String)],
                       _ keyPath: KeyPath<Asset, String>) {
        guard !changes.isEmpty, var counts = cache else { return }
        cache = nil   // the only copy then, patched without copying its tables
        let photos = assets
        let pairing = assetPairing
        if counts.apply(changes, photos: photos.count, value: {
            MetadataValueCounts.value(at: $0, of: photos, keyPath, pairing: pairing)
        }) {
            cache = counts
        }
    }
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
        let counts = FolderTreeService.counts(for: items, assets: assets, pairing: assetPairing)
        folderTreeCountCache = counts
        return counts
    }

    func countForFolderTreeItem(_ item: FolderTreeItem) -> Int {
        folderTreeCounts[item.id] ?? 0
    }

    func managementDisplayText(for asset: Asset) -> String {
        switch managementMode(for: asset) {
        case .managed: return L("复制到目录库")
        case .referenced: return L("原位添加")
        }
    }

    func managementMode(for asset: Asset) -> ImportMode {
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
    }

    func countForPinnedSidebarItem(_ item: PinnedSidebarItem) -> String {
        switch item.type {
        case .folder:
            return "\(sidebarCounts.folders[item.selectionId] ?? 0)"
        case .album:
            return "\(sidebarCounts.albums[item.selectionId] ?? 0)"
        case .smart:
            return "\(sidebarCounts.smartAlbums[item.selectionId] ?? 0)"
        case .keyword:
            return "\(sidebarCounts.keywords[item.selectionId] ?? 0)"
        case .project:
            return "\(sidebarCounts.projects[item.selectionId] ?? 0)"
        case .client:
            return "\(sidebarCounts.clients[item.selectionId] ?? 0)"
        case .captureDate:
            return "\(CaptureDates.count(for: item.selectionId, in: captureDateGroups))"
        case .lib:
            return ""
        }
    }

    func countForSmartAlbum(_ album: SmartAlbum) -> Int {
        sidebarCounts.smartAlbums[album.id] ?? album.count
    }

    func countForAlbum(_ album: Album) -> Int {
        sidebarCounts.albums[album.id] ?? 0
    }

    /// What the sidebar shows beside each folder, album, keyword, project and client.
    var sidebarCounts: SidebarCounts {
        _ = listInputsVersion   // register the dependency even on a cache hit
        if let cache = sidebarCountIndexCache, cache.day == sidebarDay { return cache.counts }
        // Worked out once per change of folders, files, albums or pairing: ratings, flags,
        // keywords and other metadata edits patch it in place (applyAssetEdits).
        let index = makeSidebarCountIndex(keywordCounts: keywordCounts.counts)
        sidebarCountIndexRebuilds &+= 1
        sidebarCountIndexCache = index
        return index.counts
    }

    /// The counts as worked out afresh from every photo, leaving the sidebar's own alone (for tests).
    func recountedSidebarCounts() -> SidebarCounts {
        makeSidebarCountIndex(keywordCounts: Self.keywordCounts(of: assets, pairing: assetPairing).counts).counts
    }

    /// One pass over the photos as shown, smart albums matched in it, without copying the catalog
    /// or its ids out. Keyword counts are the ones the keyword list keeps for the same photos.
    private func makeSidebarCountIndex(keywordCounts: [String: Int]) -> SidebarCountIndex {
        let pairing = assetPairing
        let now = sidebarClock()
        let rules = smartAlbums.map { (id: $0.id, rule: SmartMatcher.Prepared($0.rule, now: now)) }
        var index = SidebarCountIndex()
        index.day = CaptureDates.startOfToday(now: now)
        index.smartRules = rules
        index.counts.keywords = keywordCounts.filter { $0.value != 0 }   // the list's patches keep emptied ones
        let tallies = Self.sidebarTallies(of: assets, pairing: pairing, rules: rules.map(\.rule))
        index.counts.folders = tallies.folders
        index.counts.projects = tallies.projects
        index.counts.clients = tallies.clients
        for (rule, count) in zip(rules, tallies.smartAlbums) {
            index.counts.smartAlbums[rule.id] = count
        }
        // the id index is dropped by every structural change: rebuilt only for albums to count
        guard !albums.isEmpty else { return index }
        let positions = assetIndex
        for album in albums {
            index.counts.albums[album.id] = album.assetIds.reduce(0) { count, id in
                guard let position = positions[id], pairing.isShown(assets[position], at: position) else { return count }
                return count + 1
            }
        }
        return index
    }

    /// The photos as shown, counted by folder, project and client, and by the smart albums each
    /// matches.
    struct SidebarTallies: Equatable {
        var folders: [String: Int] = [:]
        var projects: [String: Int] = [:]
        var clients: [String: Int] = [:]
        var smartAlbums: [Int]

        fileprivate mutating func add(_ other: SidebarTallies) {
            folders.merge(other.folders, uniquingKeysWith: +)
            projects.merge(other.projects, uniquingKeysWith: +)
            clients.merge(other.clients, uniquingKeysWith: +)
            for (offset, count) in other.smartAlbums.enumerated() { smartAlbums[offset] += count }
        }
    }

    /// Counts the photos as shown in chunks of `chunk`, on every core, each thread with its own
    /// memo of the rules' text tests; the chunks' counts add up to one pass's. On one thread,
    /// matching five smart albums against 500k photos took ~0.6 s, and the sidebar waits for it.
    nonisolated static func sidebarTallies(of assets: [Asset], pairing: AssetPairing, rules: [SmartMatcher.Prepared],
                                           chunk: Int = 16_384) -> SidebarTallies {
        let empty = SidebarTallies(smartAlbums: Array(repeating: 0, count: rules.count))
        func tally(_ range: Range<Int>, into tallies: inout SidebarTallies, memos: inout [SmartMatcher.Memo]) {
            // a run of photos in one folder is added once, not hashed photo by photo
            var folder = "", run = 0
            for position in range {
                let asset = assets[position]
                guard pairing.isShown(asset, at: position) else { continue }
                if asset.folderId != folder {
                    if run > 0 { tallies.folders[folder, default: 0] += run }
                    folder = asset.folderId
                    run = 0
                }
                run += 1
                // under their names as the lists give them: without the spaces around them
                if !asset.project.isEmpty, case let project = listedValue(asset.project), !project.isEmpty {
                    tallies.projects[project, default: 0] += 1
                }
                if !asset.client.isEmpty, case let client = listedValue(asset.client), !client.isEmpty {
                    tallies.clients[client, default: 0] += 1
                }
                for offset in rules.indices where rules[offset].matches(asset, memo: &memos[offset]) {
                    tallies.smartAlbums[offset] += 1
                }
            }
            if run > 0 { tallies.folders[folder, default: 0] += run }
        }
        let chunk = max(chunk, 1)
        let chunks = assets.isEmpty ? 0 : (assets.count - 1) / chunk + 1
        guard chunks > 1 else {
            var tallies = empty
            var memos = rules.map(SmartMatcher.Memo.init(for:))
            tally(assets.indices, into: &tallies, memos: &memos)
            return tallies
        }
        let lock = NSLock()
        var next = 0
        var total = empty
        DispatchQueue.concurrentPerform(iterations: min(chunks, ProcessInfo.processInfo.activeProcessorCount)) { _ in
            var tallies = empty
            var memos = rules.map(SmartMatcher.Memo.init(for:))
            while true {
                let index: Int? = lock.withLock {
                    guard next < chunks else { return nil }
                    next += 1
                    return next - 1
                }
                guard let index else { break }
                tally(index * chunk ..< min(assets.count, (index + 1) * chunk), into: &tallies, memos: &memos)
            }
            lock.withLock { total.add(tallies) }
        }
        return total
    }

    private func moveSelectedSourcePriority(up: Bool) {
        var ordered = orderedFolders
        guard let index = ordered.firstIndex(where: { $0.id == selection.id }) else { return }
        let target = up ? index - 1 : index + 1
        guard ordered.indices.contains(target) else { return }
        ordered.swapAt(index, target)
        sourcePriorities = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element.id, $0.offset) })
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
            guard CaptureDates.count(for: item.selectionId, in: captureDateGroups) > 0 else { return nil }
            return item
        case .lib:
            return nil
        }
    }
}
