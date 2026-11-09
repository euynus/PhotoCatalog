import AppKit
import Foundation

@MainActor
extension AppState {
    // ----- core data -----
    /// Review and metadata effects can occur together, including on different photos in
    /// one edit. Neither invalidates structural indexes, pairing, or date/folder trees.
    struct AssetEditScope: OptionSet {
        let rawValue: Int
        static let review = Self(rawValue: 1 << 0)
        static let metadata = Self(rawValue: 1 << 1)
        static let structure = Self(rawValue: 1 << 2)
        static let any: Self = [.review, .metadata, .structure]
    }
    var assetIndex: [String: Int] {
        _ = listInputsVersion   // register the dependency even on a cache hit
        if let cache = assetIndexCache { return cache }
        let map = Self.positionsById(assets)
        assetIndexCache = map
        return map
    }

    /// Each photo's position by id (the last one's, should an id repeat).
    nonisolated static func positionsById(_ assets: [Asset]) -> [String: Int] {
        var map = [String: Int](minimumCapacity: assets.count)
        for (i, a) in assets.enumerated() { map[a.id] = i }
        return map
    }

    /// In debug builds, for a catalog small enough: that an id index kept through a change of the
    /// photos is the one building it again gives.
    private func assertAssetIndexCurrent() {
        assert(assets.count > 20_000 || assetIndexCache.map { $0 == Self.positionsById(assets) } ?? true,
               "a kept id index gives each photo's position")
    }
    struct ListSignature: Equatable {
        let inputsVersion: Int
        let selection: Selection
        let filters: Filters
        let search: String
        var sort: Sort
        var collapsed: Set<String>
        let recentDays: Int
        let captureDay: Date

        /// Whether `other` lists the same photos before stacks fold: only which are folded differs.
        func hasPhotosBeforeFolding(of other: ListSignature) -> Bool {
            var unfolded = self
            unfolded.collapsed = other.collapsed
            return unfolded == other
        }

        /// Whether `other` lists the same photos in some order: only the sort and which stacks are
        /// folded differ.
        func hasPhotosBeforeSorting(of other: ListSignature) -> Bool {
            var unsorted = self
            unsorted.sort = other.sort
            return unsorted.hasPhotosBeforeFolding(of: other)
        }
    }

    func isRemovedForGood(_ asset: Asset) -> Bool {
        // a folder added again since is a source again (its id comes from its path)
        (removedSourceIds.contains(asset.folderId) && sourceRootPathsById[asset.folderId] == nil)
            || trashedOriginalIds.contains(asset.masterId ?? asset.id)
    }

    /// The photos as a change made to a copy of them left them (duplicates resolved). Such a change
    /// edits photos where they are, perhaps adding some after them: it goes in as edits in place
    /// and an append, which carry on what's derived from every photo. Anything else is a new set
    /// of photos, all of it worked out again. (Changes that know their photos' places make the
    /// edits themselves, without copying the catalog: `replaceInPlace`.)
    func replaceAssetsForMutation(_ updated: [Asset]) {
        guard let edits = Self.editsInPlace(from: assets, to: updated) else {
            nextAssetEditScope = .any
            assets = updated
            didMutateAssets()
            return
        }
        replaceInPlace(edits)
        if updated.count > assets.count { appendAssets(Array(updated[assets.count...])) }
    }

    /// Photos changed where they are (by position) written back, with all their changes' effects.
    func replaceInPlace(_ edits: [(offset: Int, asset: Asset)]) {
        guard !edits.isEmpty else { return }
        applyAssetEdits(edits, scope: edits.reduce(into: AssetEditScope()) {
            $0.formUnion(Self.editScope(from: assets[$1.offset], to: $1.asset))
        })
    }

    /// Where the photos with these ids are, in order: looked up in the id index while every photo's
    /// id is its own (as it is but for a photo listed twice), else found in a pass. A pass over
    /// 500k photos' ids, hashing each, took ~0.1 s on the main thread.
    func positions(of ids: Set<String>) -> [Int] {
        guard !ids.isEmpty else { return [] }
        let index = assetIndex
        guard index.count == assets.count else { return assets.indices.filter { ids.contains(assets[$0].id) } }
        return ids.compactMap { index[$0] }.sorted()
    }

    /// The photos `updated` changed in place, by position, when it has each of `photos` where it
    /// was (perhaps with more photos after them); nil when it hasn't. A photo left alone shares
    /// its stored values with the one it was copied from. Compared in chunks on every core.
    nonisolated private static func editsInPlace(from photos: [Asset], to updated: [Asset],
                                                 chunk: Int = 65_536) -> [(offset: Int, asset: Asset)]? {
        guard updated.count >= photos.count else { return nil }
        func edits(_ range: Range<Int>) -> [(offset: Int, asset: Asset)]? {
            var found: [(offset: Int, asset: Asset)] = []
            for position in range where !updated[position].sharesStorage(with: photos[position]) {
                guard updated[position].id == photos[position].id else { return nil }
                found.append((position, updated[position]))
            }
            return found
        }
        let chunks = photos.isEmpty ? 0 : (photos.count - 1) / chunk + 1
        guard chunks > 1 else { return edits(photos.indices) }
        let lock = NSLock()
        var parts = [[(offset: Int, asset: Asset)]?](repeating: [], count: chunks)
        DispatchQueue.concurrentPerform(iterations: chunks) { index in
            let part = edits(index * chunk ..< min(photos.count, (index + 1) * chunk))
            lock.withLock { parts[index] = part }
        }
        var found: [(offset: Int, asset: Asset)] = []
        for part in parts {
            guard let part else { return nil }
            found += part
        }
        return found
    }

    /// New photos added in one mutation, in place: `assets + new` copied the catalog for each
    /// import batch, tethered shot or virtual copy. What's worked out from every photo is carried
    /// on to the new ones rather than worked out again (at 500k photos, about a second on the main
    /// thread per import batch): the id index, the pairing, the library, keyword, project, client,
    /// camera and lens counts, the sidebar's counts, the capture-date tree, the folder tree and its
    /// counts. Earlier photos a new RAW hides, or a second RAW of their name shows again, are
    /// counted out or back in. What can't be carried on exactly is worked out again, as after any
    /// structural change; the photo list, stacks and the rest always are.
    func appendAssets(_ new: [Asset]) {
        let start = assets.count
        // taken out of their caches, so that each is the only copy and changes in place
        var index = assetIndexCache
        var carried: AssetPairing? = pairRawAndJpeg
            ? assetPairingCache.flatMap { $0.version == structureVersion ? $0.pairing : nil } : .empty
        let library = isLoadingCatalog ? nil : libraryCountsCache
        var keywords = keywordCountsCache
        var projects = projectCountsCache, clients = clientCountsCache
        var cameras = gearCountsCache?.cameras, lenses = gearCountsCache?.lenses
        var sidebar = sidebarCountIndexCache.flatMap { $0.day == sidebarDay ? $0 : nil }
        let dates = captureDateGroupsCache, tree = folderTreeCache, treeCounts = folderTreeCountCache
        (assetIndexCache, assetPairingCache, libraryCountsCache, keywordCountsCache) = (nil, nil, nil, nil)
        (projectCountsCache, clientCountsCache, gearCountsCache, sidebarCountIndexCache) = (nil, nil, nil, nil)
        (captureDateGroupsCache, folderTreeCache, folderTreeCountCache) = (nil, nil, nil)
        nextAssetEditScope = .any
        letGoOfListCaches()
        assets.append(contentsOf: new)   // drops all else that's derived
        defer {
            didMutateAssets()
            assertDerivedCachesCurrent()
        }

        if index != nil {
            for position in start ..< assets.count { index?[assets[position].id] = position }
            assetIndexCache = index
        }
        // the folders come from every live photo's file, shown or not: those new photos are in
        // that the tree hasn't got are put in it
        let grown = tree.map { FolderTreeService.adding(assets[start...], to: $0, sourceRootPaths: sourceRootPathsById) }
        folderTreeCache = grown
        // the rest counts the photos as shown, so it's carried on only with the pairing
        var flipped: [Int] = []
        if pairRawAndJpeg {
            guard let changed = carried?.append(assets, from: start) else { return }
            flipped = changed
        }
        let pairing = carried ?? .empty
        carried = nil   // `pairing` the only copy
        if pairRawAndJpeg { assetPairingCache = (structureVersion, pairing) }
        carryStacks(appendedFrom: start, flipped: flipped)
        // the photos shown now and not before, or the other way round: the new ones shown, and
        // earlier ones that a new RAW hides or a second RAW of their name shows again
        var changes = flipped.map { (position: $0, shown: pairing.isShown(assets[$0], at: $0)) }
        for position in start ..< assets.count where pairing.isShown(assets[position], at: position) {
            changes.append((position, true))
        }

        if var counts = library {
            let (cutoff, faces) = (recentCutoff, faceAssetIds)
            for position in start ..< assets.count where !assets[position].deleted { counts.countFile(assets[position]) }
            for change in changes {
                counts.count(assets[change.position], recentCutoff: cutoff, withFaces: faces, change.shown ? 1 : -1)
            }
            libraryCountsCache = counts
        }
        if keywords != nil, Self.carry(&keywords!, changes, of: assets, from: start) { keywordCountsCache = keywords }
        let photos = assets
        func carry(_ counts: inout MetadataValueCounts?, _ keyPath: KeyPath<Asset, String>) {
            // as an edit from no value to the photo's, or from its value to none
            let moves = changes.compactMap { change -> (offset: Int, old: String, new: String)? in
                let raw = photos[change.position][keyPath: keyPath]
                let value = raw.isEmpty ? "" : listedValue(raw)
                guard !value.isEmpty else { return nil }
                return change.shown ? (change.position, "", value) : (change.position, value, "")
            }
            let carried = moves.isEmpty || counts?.apply(moves, photos: photos.count, value: {
                MetadataValueCounts.value(at: $0, of: photos, keyPath, pairing: pairing)
            }) == true
            if !carried { counts = nil }
        }
        carry(&projects, \.project)
        carry(&clients, \.client)
        (projectCountsCache, clientCountsCache) = (projects, clients)
        carry(&cameras, \.camera)
        carry(&lenses, \.lens)
        if let cameras, let lenses { gearCountsCache = (cameras, lenses) }
        if sidebar != nil {
            var memos = sidebar?.smartRules.map { SmartMatcher.Memo(for: $0.rule) } ?? []
            for change in changes { sidebar?.count(assets[change.position], change.shown ? 1 : -1, memos: &memos) }
            if !albums.isEmpty, !changes.isEmpty {
                let moved = Dictionary(changes.map { (assets[$0.position].id, $0.shown ? 1 : -1) }, uniquingKeysWith: +)
                for album in albums {
                    let change = album.assetIds.reduce(0) { $0 + (moved[$1] ?? 0) }
                    if change != 0 { sidebar?.counts.albums[album.id, default: 0] += change }
                }
            }
            sidebarCountIndexCache = sidebar
        }
        if var days = dates?.days {
            for change in changes {
                guard let day = CaptureDates.day(of: assets[change.position].date) else { continue }
                let count = days[day, default: 0] + (change.shown ? 1 : -1)
                days[day] = count == 0 ? nil : count
            }
            captureDateGroupsCache = changes.isEmpty ? dates : (days, CaptureDates.groups(dayCounts: days))
        }
        if let grown, var counts = treeCounts {
            Self.list(newFolders: grown, in: &counts)
            let shown = changes.filter(\.shown).map { assets[$0.position] }
            let hidden = changes.filter { !$0.shown }.map { assets[$0.position] }
            for (id, number) in FolderTreeService.counts(for: grown, assets: shown) where number != 0 {
                counts[id, default: 0] += number
            }
            for (id, number) in FolderTreeService.counts(for: grown, assets: hidden) where number != 0 {
                counts[id, default: 0] -= number
            }
            folderTreeCountCache = counts
        }
    }

    /// Lets go of the photo list's caches before photos are added or changed (the list is worked out
    /// again after it): a list that is the photos' own array would have them copied whole by the
    /// change, and any other is freed off the main thread (at 500k photos, ~6 ms).
    private func letGoOfListCaches() {
        let photos = assets.withUnsafeBufferPointer { $0.baseAddress }
        let lists = [listCache?.value, uncollapsedListCache?.value].compactMap { $0 }
            .filter { list in list.withUnsafeBufferPointer { $0.baseAddress } != photos }
        (listCache, uncollapsedListCache) = (nil, nil)
        matchingPositionsCache = nil   // positions in the photos as they were
        if !lists.isEmpty { DispatchQueue.global(qos: .utility).async { withExtendedLifetime(lists) {} } }
    }

    /// Folder counts with a count (none yet) for each folder a grown tree put in, as counting
    /// again gives every folder one.
    nonisolated private static func list(newFolders tree: [FolderTreeItem], in counts: inout [String: Int]) {
        guard tree.count != counts.count else { return }
        for item in tree where counts[item.id] == nil { counts[item.id] = 0 }
    }

    /// An import batch's photos into the catalog shown (and into the import's album): new ones
    /// added after the others, returning ones in place of their removed copies, still in memory
    /// when they were removed this session (one removed earlier is added after the others too).
    func addImportBatch(_ fresh: [Asset], revivedIds: Set<String>, album: (id: String, name: String)?) {
        let positions = revivedIds.isEmpty ? [:] : assetIndex
        let returning = revivedIds.isEmpty ? []
            : fresh.compactMap { photo in revivedIds.contains(photo.id) ? positions[photo.id].map { (offset: $0, asset: photo) } : nil }
        if let (albumId, albumName) = album {
            // none in the counts yet: new photos, and removed ones coming back
            albumsGainOnlyPhotosToCome = returning.allSatisfy { assets[$0.offset].deleted }
            if let index = albums.firstIndex(where: { $0.id == albumId }) {
                // a returning photo may still be in the album from before
                let added = revivedIds.isEmpty ? fresh.map(\.id)
                    : fresh.map(\.id).filter { !albums[index].assetIds.contains($0) }
                albums[index].assetIds.append(contentsOf: added)
            } else {
                albums.append(Album(id: albumId, name: albumName, assetIds: fresh.map(\.id)))
            }
        }
        guard !returning.isEmpty else { return appendAssets(fresh) }
        let edits = returning.sorted { $0.offset < $1.offset }
        replaceInPlace(edits)
        let replaced = Set(edits.map(\.asset.id))
        let added = fresh.filter { !replaced.contains($0.id) }
        if !added.isEmpty { appendAssets(added) }
    }

    /// Counts the keywords of photos now shown in, and of photos no longer shown out, as a pass
    /// over the photos would count them; false when that moves where a pass first meets a keyword
    /// (to an earlier photo, or past one no longer shown), which takes counting again. Photos from
    /// `start` on are new, after all the others.
    nonisolated private static func carry(_ tally: inout KeywordTally, _ changes: [(position: Int, shown: Bool)],
                                          of assets: [Asset], from start: Int) -> Bool {
        for change in changes {
            for keyword in assets[change.position].keywords {
                if change.shown {
                    if let first = tally.first[keyword] {
                        guard first <= change.position, (tally.counts[keyword] ?? 0) > 0 else { return false }
                    } else {
                        guard change.position >= start else { return false }
                        tally.order.append(keyword)
                        tally.first[keyword] = change.position
                    }
                    tally.counts[keyword, default: 0] += 1
                } else {
                    guard tally.first[keyword] != change.position, let count = tally.counts[keyword], count > 1 else {
                        return false
                    }
                    tally.counts[keyword] = count - 1
                }
            }
        }
        return true
    }

    /// In debug builds, for a catalog small enough: that what's derived from every photo, as
    /// carried on through a change, is what working it out again gives.
    private func assertDerivedCachesCurrent() {
        assert(assets.count > 20_000 || cachesDifferingFromRecount().isEmpty,
               "carried on through a change, unlike a recount: \(cachesDifferingFromRecount())")
    }

    /// The caches of what's derived from every photo held now, by the names
    /// `cachesDifferingFromRecount` gives them (for checks: what a change carried on).
    var heldDerivedCaches: [String] {
        var held: [String] = []
        if assetIndexCache != nil { held.append("index") }
        if pairRawAndJpeg, let cache = assetPairingCache, cache.version == structureVersion { held.append("pairing") }
        if libraryCountsCache != nil { held.append("library") }
        if keywordCountsCache != nil { held.append("keywords") }
        if projectCountsCache != nil { held.append("projects") }
        if clientCountsCache != nil { held.append("clients") }
        if gearCountsCache != nil { held += ["cameras", "lenses"] }
        if let index = sidebarCountIndexCache, index.day == sidebarDay { held.append("sidebar") }
        if captureDateGroupsCache != nil { held.append("dates") }
        if folderTreeCache != nil { held.append("folder tree") }
        if folderTreeCountCache != nil { held.append("folder counts") }
        return held
    }

    /// The caches of what's derived from every photo that differ from working it out again, by
    /// name: none, when all that a change carried on is what a recount gives (for checks).
    func cachesDifferingFromRecount() -> [String] {
        var differing: [String] = []
        let pairing = pairRawAndJpeg ? AssetPairing.rawJpeg(assets) : .empty
        if pairRawAndJpeg, let cache = assetPairingCache, cache.version == structureVersion, cache.pairing != pairing {
            differing.append("pairing")
        }
        if let index = assetIndexCache, index != Self.positionsById(assets) { differing.append("index") }
        if let counts = libraryCountsCache, !isLoadingCatalog {
            var recount = Self.libraryCounts(assets, pairing: pairing, recentCutoff: recentCutoff, withFaces: faceAssetIds)
            recount.recent = counts.recent   // counted against the time it was counted at
            if recount != counts { differing.append("library") }
        }
        if let tally = keywordCountsCache {
            let recount = Self.keywordCounts(of: assets, pairing: pairing)
            if tally.order != recount.order || tally.counts != recount.counts || tally.first != recount.first {
                differing.append("keywords")
            }
        }
        let lists: [(String, MetadataValueCounts?, KeyPath<Asset, String>)] = [
            ("projects", projectCountsCache, \.project), ("clients", clientCountsCache, \.client),
            ("cameras", gearCountsCache?.cameras, \.camera), ("lenses", gearCountsCache?.lenses, \.lens),
        ]
        for (name, cache, keyPath) in lists {
            if let cache, cache != Self.metadataCounts(assets, pairing: pairing, keyPath) { differing.append(name) }
        }
        if let index = sidebarCountIndexCache, index.day == sidebarDay, index.counts != recountedSidebarCounts() {
            differing.append("sidebar")
        }
        if let dates = captureDateGroupsCache {
            let days = CaptureDates.dayCounts(assets, pairing: pairing)
            if dates.days != days || dates.groups != CaptureDates.groups(dayCounts: days) { differing.append("dates") }
        }
        let tree = FolderTreeService.build(sourceFolders: orderedFolders, assets: assets, sourceRootPaths: sourceRootPathsById)
        if let cache = folderTreeCache, cache != tree { differing.append("folder tree") }
        if let counts = folderTreeCountCache, counts != FolderTreeService.counts(for: tree, assets: assets, pairing: pairing) {
            differing.append("folder counts")
        }
        return differing
    }

    /// Writes edited copies back at their offsets in one mutation (one didSet, no array copy).
    /// Review edits also patch the library and sidebar counts and — when the current collection,
    /// filters and sort ignore review fields, or the edits only take photos out — the cached list,
    /// instead of rescanning and re-sorting every asset. Structural edits carry what's derived on
    /// through them.
    func applyAssetEdits(_ edits: [(offset: Int, asset: Asset)], scope: AssetEditScope) {
        guard !scope.contains(.structure) else {
            // a photo back in the catalog (undo, imported again) keeps cache files still to be deleted
            let returning = edits.filter { assets[$0.offset].deleted && !$0.asset.deleted }.map(\.asset.id)
            if !returning.isEmpty { cachePurges.cancel(returning) }
            return applyStructuralEdits(edits, scope: scope)
        }
        var patchedCounts: LibraryCounts?
        var patchedKeywords: KeywordTally?
        var dropsKeywordCounts = false
        var patchedSidebar: SidebarCountIndex?
        var projectChanges: [(offset: Int, old: String, new: String)] = []
        var clientChanges: [(offset: Int, old: String, new: String)] = []
        var listBefore: ListSignature?
        let pairing = assetPairing
        // Matching each edited photo before and after against every smart album: past half
        // the library, recounting it (once, when the sidebar next reads) is the cheaper way.
        if var index = sidebarCountIndexCache, index.day == sidebarDay, edits.count * 2 <= assets.count {
            var memos = index.smartRules.map { SmartMatcher.Memo(for: $0.rule) }
            for edit in edits where pairing.shows(edit.asset) {
                index.move(from: assets[edit.offset], to: edit.asset, memos: &memos)
            }
            patchedSidebar = index
        }
        patchedCounts = libraryCountsCache.map { counts in
            edits.reduce(into: counts) { counts, edit in
                guard !pairing.isHiddenCompanion(edit.asset.id) else { return }
                if scope.contains(.review) {
                    counts.applyReviewChange(from: assets[edit.offset], to: edit.asset)
                }
                if scope.contains(.metadata) {
                    counts.applyMetadataChange(from: assets[edit.offset], to: edit.asset)
                }
            }
        }
        let membershipCanChange = (scope.contains(.review) && listDependsOnReviewFields)
            || (scope.contains(.metadata) && listDependsOnMetadataFields)
        if !membershipCanChange { listBefore = currentListSignature }
        // A review key that only takes photos out (rated out of Unrated, a filter or a smart album)
        // takes them out of the cached list instead of working it out again from every photo.
        var listRemoval: (before: ListSignature, leaving: Set<String>, staying: [Asset])?
        if membershipCanChange, scope == .review, let moves = reviewListMoves(edits) {
            if moves.leaving.isEmpty {
                listBefore = currentListSignature
            } else {
                listRemoval = (currentListSignature, moves.leaving, moves.staying)
            }
        }
        if scope.contains(.metadata) {
            patchedKeywords = keywordCountsCache.flatMap { cache -> KeywordTally? in
                var patched = cache
                let changes = edits.filter { pairing.shows($0.asset) }.map {
                    (offset: $0.offset, old: assets[$0.offset].keywords, new: $0.asset.keywords)
                }
                return Self.patchKeywords(&patched, changes) ? patched : nil
            }
            if patchedKeywords == nil { dropsKeywordCounts = keywordCountsCache != nil }
            // the project and client lists move only with a project or client: a title, keyword
            // or location edit keeps them as they are
            for edit in edits {
                let old = assets[edit.offset]
                if old.project != edit.asset.project {
                    projectChanges.append((edit.offset, MetadataValueCounts.value(of: old, \.project, pairing: pairing),
                                           MetadataValueCounts.value(of: edit.asset, \.project, pairing: pairing)))
                }
                if old.client != edit.asset.client {
                    clientChanges.append((edit.offset, MetadataValueCounts.value(of: old, \.client, pairing: pairing),
                                          MetadataValueCounts.value(of: edit.asset, \.client, pairing: pairing)))
                }
            }
        }
        nextAssetEditScope = scope
        // the photos stay where they are: the id index outlives the edit
        let index = assetIndexCache
        assert(edits.allSatisfy { assets[$0.offset].id == $0.asset.id }, "an edit keeps its photo's id")
        assets.withUnsafeMutableBufferPointer { buffer in
            for edit in edits { buffer[edit.offset] = edit.asset }
        }
        assetIndexCache = index
        assertAssetIndexCurrent()
        if let patchedCounts { libraryCountsCache = patchedCounts }
        if let patchedKeywords { keywordCountsCache = patchedKeywords } else if dropsKeywordCounts { keywordCountsCache = nil }
        if let patchedSidebar { sidebarCountIndexCache = patchedSidebar }
        patch(&projectCountsCache, projectChanges, \.project)
        patch(&clientCountsCache, clientChanges, \.client)
        if let listBefore { patchListCaches(with: edits, validFor: listBefore) }
        if let listRemoval {
            removeFromListCaches(listRemoval.leaving, staying: listRemoval.staying, validFor: listRemoval.before)
        }
        didMutateAssets()
    }

    /// How review edits move photos through a list that depends on review fields: the photos they
    /// take out, and the edited photos that stay in. Nil when one comes in, or when the list can't
    /// be told this way: a search, a sort by rating (the order moves), Recently Imported (its
    /// cutoff moves with the clock, so the cached list may hold photos the test now leaves out),
    /// the collection gone.
    private func reviewListMoves(_ edits: [(offset: Int, asset: Asset)]) -> (leaving: Set<String>, staying: [Asset])? {
        guard sort.field != .rating, search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !(selection.type == .lib && selection.id == "recent"),
              let makeTest = listTest(now: sidebarClock()) else { return nil }
        let test = makeTest()
        var leaving = Set<String>()
        var staying: [Asset] = []
        for edit in edits {
            let (was, isIn) = (test(assets[edit.offset]), test(edit.asset))
            if isIn && !was { return nil }
            if was && !isIn { leaving.insert(edit.asset.id) } else if was { staying.append(edit.asset) }
        }
        return (leaving, staying)
    }

    /// Takes photos review edits moved out of the list out of its photos before folding, and
    /// writes the edited photos that stay in where they are, in one pass. The next read of `list`
    /// folds stacks again (and the grid takes it as a new list). Their order can't have moved.
    private func removeFromListCaches(_ leaving: Set<String>, staying: [Asset], validFor before: ListSignature) {
        let after = currentListSignature
        guard let matching = uncollapsedListCache, matching.signature == before else { return }
        // the index and the hint are of the folded list: the index answers for the photos before
        // folding only when nothing is folded (the hint is checked where it points)
        let positions = before.collapsed.isEmpty ? listPositionsCache.flatMap { $0.signature == before ? $0.positions : nil }
            : nil
        let hint = listPositionHint
        (listCache, uncollapsedListCache) = (nil, nil)   // the one array they share, taken out
        let edited = Dictionary(staying.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        var places: [(position: Int, asset: Asset?)] = []   // without an asset: the photo leaves
        let ids = leaving.union(edited.keys)
        if let positions {
            for id in ids { if let position = positions[id] { places.append((position, edited[id])) } }
        } else {
            let scanned = matching.value.withUnsafeBufferPointer { photos in
                Self.locate(ids, in: photos, hint: hint) { places.append(($1, edited[$0])) }
            }
            listPatchScannedPhotos += scanned
        }
        places.sort { $0.position < $1.position }
        var kept: [Asset] = []
        kept.reserveCapacity(matching.value.count)
        var start = 0
        for (position, asset) in places {
            kept.append(contentsOf: matching.value[start..<position])
            if let asset { kept.append(asset) }
            start = position + 1
        }
        kept.append(contentsOf: matching.value[start...])
        uncollapsedListCache = (after, kept)
        listDepartedIds = (after, leaving)
    }

    /// Edits of photos where they are that move what's derived from every photo: a file renamed,
    /// moved, relinked, read again or gone offline, a photo removed or back, a capture time changed
    /// (Move to Trash, Remove from Catalog, Rename, Move to Folder, Locate, a drive unplugged or
    /// back, a rescan's changed files, removed photos imported again, and undo and redo of those).
    /// What's derived is carried on through them, as `appendAssets` carries it on to new photos,
    /// rather than worked out again from every photo on the next redraw (~0.4 s at 500k photos):
    /// the id index stays; the pairing pairs again only the names the photos had and have now;
    /// the library, keyword, project, client, camera and lens counts, the sidebar's counts and the
    /// capture days take each photo out as it was shown and in as it's shown now, with the other
    /// photos the change hid behind a RAW or showed again; the folder tree gains the folders photos
    /// went to. What can't be carried on exactly — the photo a keyword is first met on changed, a
    /// folder left empty, no pairing of these photos — is worked out again; the photo list and
    /// stacks always are.
    private func applyStructuralEdits(_ edits: [(offset: Int, asset: Asset)], scope: AssetEditScope) {
        let old = edits.map { assets[$0.offset] }
        carryStructuralEdits(edits, old: old, scope: scope)
        // The photos as they were are let go of on another thread, the last to hold them once the
        // carry's own lists are gone: freeing a drive's 50,000 took ~20 ms of the main thread.
        DispatchQueue.global(qos: .utility).async { withExtendedLifetime(old) {} }
    }

    private func carryStructuralEdits(_ edits: [(offset: Int, asset: Asset)], old: [Asset], scope: AssetEditScope) {
        // taken out of their caches, so that each is the only copy and changes in place
        let index = assetIndexCache
        var carried: AssetPairing? = pairRawAndJpeg
            ? assetPairingCache.flatMap { $0.version == structureVersion ? $0.pairing : nil } : .empty
        let library = isLoadingCatalog ? nil : libraryCountsCache
        var keywords = keywordCountsCache
        var projects = projectCountsCache, clients = clientCountsCache
        var cameras = gearCountsCache?.cameras, lenses = gearCountsCache?.lenses
        var sidebar = sidebarCountIndexCache.flatMap { $0.day == sidebarDay ? $0 : nil }
        let dates = captureDateGroupsCache, tree = folderTreeCache, treeCounts = folderTreeCountCache
        (assetIndexCache, assetPairingCache, libraryCountsCache, keywordCountsCache) = (nil, nil, nil, nil)
        (projectCountsCache, clientCountsCache, gearCountsCache, sidebarCountIndexCache) = (nil, nil, nil, nil)
        (captureDateGroupsCache, folderTreeCache, folderTreeCountCache) = (nil, nil, nil)
        // shown before: not removed, and not a JPEG behind its RAW
        let wasShown = carried.map { pairing in zip(edits, old).map { pairing.isShown($1, at: $0.offset) } }
        nextAssetEditScope = scope
        assert(edits.allSatisfy { assets[$0.offset].id == $0.asset.id }, "an edit keeps its photo's id")
        letGoOfListCaches()
        assets.withUnsafeMutableBufferPointer { buffer in
            for edit in edits { buffer[edit.offset] = edit.asset }
        }   // which drops all else that's derived, the photo list's caches with it
        defer {
            didMutateAssets()
            assertDerivedCachesCurrent()
        }
        // the photos stay where they are: the id index outlives the change
        assetIndexCache = index
        assertAssetIndexCurrent()

        // The folders come from every live photo's file, shown or not: those the photos are in now
        // are put in the tree, and each they've left must still have photos in it (or the tree is
        // made again). Without counts to tell, that's when the photos are in every folder they were.
        let roots = sourceRootPathsById
        let grown = tree.map { FolderTreeService.adding(edits.lazy.map(\.asset), to: $0, sourceRootPaths: roots) }
        let left = grown.map { FolderTreeService.subfolderIds(of: old, in: $0, sourceRootPaths: roots) } ?? []
        func keepFoldersUncounted() {
            guard let grown,
                  left.isSubset(of: FolderTreeService.subfolderIds(of: edits.lazy.map(\.asset), in: grown, sourceRootPaths: roots))
            else { return }
            folderTreeCache = grown
        }
        // the rest counts the photos as shown, so it's carried on only with the pairing
        guard carried != nil, let wasShown else { return keepFoldersUncounted() }
        var flipped: [Int] = []
        if pairRawAndJpeg {
            guard let changed = carried?.replace(zip(edits, old).map { ($0.offset, $1) }, in: assets) else {
                return keepFoldersUncounted()
            }
            flipped = changed
        }
        let pairing = carried ?? .empty
        carried = nil   // `pairing` the only copy
        if pairRawAndJpeg { assetPairingCache = (structureVersion, pairing) }
        // the photos shown before or now: the changed ones, and others that a change hid behind a
        // RAW or showed again (a RAW removed or renamed, a JPEG renamed next to one)
        var changes: [(position: Int, old: Asset, wasShown: Bool, new: Asset, shown: Bool)] = []
        for (number, edit) in edits.enumerated() {
            let shown = pairing.isShown(edit.asset, at: edit.offset)
            if shown || wasShown[number] { changes.append((edit.offset, old[number], wasShown[number], edit.asset, shown)) }
        }
        for position in flipped {
            let photo = assets[position]
            let shown = pairing.isShown(photo, at: position)
            changes.append((position, photo, !shown, photo, shown))
        }
        // (Stacks are worked out again, dropped by the didSet; a carry for them, from `changes`,
        // would go here.)

        // A photo shown before and after (a status, a path, a capture time changed) only moves
        // where what it's counted by changed: a drive unplugged changes no count but missing/offline.
        if var counts = library {
            let (cutoff, faces) = (recentCutoff, faceAssetIds)
            for (before, edit) in zip(old, edits) {
                if !before.deleted { counts.countFile(before, -1) }
                if !edit.asset.deleted { counts.countFile(edit.asset) }
            }
            for change in changes where !(change.wasShown && change.shown && LibraryCounts.countAlike(change.old, change.new)) {
                if change.wasShown { counts.count(change.old, recentCutoff: cutoff, withFaces: faces, -1) }
                if change.shown { counts.count(change.new, recentCutoff: cutoff, withFaces: faces) }
            }
            libraryCountsCache = counts
        }
        let keywordChanges = changes.compactMap { change -> (offset: Int, old: [String], new: [String])? in
            let (before, after) = (change.wasShown ? change.old.keywords : [], change.shown ? change.new.keywords : [])
            return before == after ? nil : (change.position, before, after)
        }
        if keywords != nil, Self.patchKeywords(&keywords!, keywordChanges) { keywordCountsCache = keywords }
        let photos = assets
        // the changes that can move a project, client, camera or lens (a status or path changes none)
        let valueChanges = changes.filter {
            $0.wasShown != $0.shown || $0.old.project != $0.new.project || $0.old.client != $0.new.client
                || $0.old.camera != $0.new.camera || $0.old.lens != $0.new.lens
        }
        func carry(_ counts: inout MetadataValueCounts?, _ keyPath: KeyPath<Asset, String>, _ field: (Asset) -> String) {
            func value(_ photo: Asset, shown: Bool) -> String {
                let raw = field(photo)
                return shown && !raw.isEmpty ? listedValue(raw) : ""
            }
            let moves = valueChanges.compactMap { change -> (offset: Int, old: String, new: String)? in
                let (before, after) = (value(change.old, shown: change.wasShown), value(change.new, shown: change.shown))
                return before == after ? nil : (change.position, before, after)
            }
            let kept = moves.isEmpty || counts?.apply(moves, photos: photos.count, value: {
                MetadataValueCounts.value(at: $0, of: photos, keyPath, pairing: pairing)
            }) == true
            if !kept { counts = nil }
        }
        // the fields read directly: through a key path, a drive's 50,000 photos took ~0.1 s
        carry(&projects, \.project) { $0.project }
        carry(&clients, \.client) { $0.client }
        (projectCountsCache, clientCountsCache) = (projects, clients)
        carry(&cameras, \.camera) { $0.camera }
        carry(&lenses, \.lens) { $0.lens }
        if let cameras, let lenses { gearCountsCache = (cameras, lenses) }
        // matching each photo against every smart album, out and in: past half the library,
        // recounting it (once, when the sidebar next reads) is the cheaper way
        if sidebar != nil, changes.count * 2 <= assets.count {
            var memos = sidebar?.smartRules.map { SmartMatcher.Memo(for: $0.rule) } ?? []
            var moved: [String: Int] = [:]
            for change in changes {
                if change.wasShown, change.shown {
                    sidebar?.move(from: change.old, to: change.new, memos: &memos)
                    continue
                }
                if change.wasShown { sidebar?.count(change.old, -1, memos: &memos) }
                if change.shown { sidebar?.count(change.new, 1, memos: &memos) }
                moved[change.new.id, default: 0] += change.shown ? 1 : -1
            }
            if !moved.isEmpty {
                for album in albums {
                    let change = album.assetIds.reduce(0) { $0 + (moved[$1] ?? 0) }
                    if change != 0 { sidebar?.counts.albums[album.id, default: 0] += change }
                }
            }
            sidebarCountIndexCache = sidebar
        }
        if let dates {
            var days = dates.days
            var moved = false
            for change in changes {
                let before = change.wasShown ? CaptureDates.day(of: change.old.date) : nil
                let after = change.shown ? CaptureDates.day(of: change.new.date) : nil
                guard before != after else { continue }
                moved = true
                for (day, sign) in [(before, -1), (after, 1)] {
                    guard let day else { continue }
                    let count = days[day, default: 0] + sign
                    days[day] = count == 0 ? nil : count
                }
            }
            captureDateGroupsCache = moved ? (days, CaptureDates.groups(dayCounts: days)) : dates
        }
        guard let grown else { return }
        guard var counts = treeCounts else { return keepFoldersUncounted() }
        Self.list(newFolders: grown, in: &counts)
        // a photo shown before and now, in the same file, is counted where it was
        let moved = changes.filter {
            !($0.wasShown && $0.shown && $0.old.folderId == $0.new.folderId && $0.old.localPath == $0.new.localPath)
        }
        let leaving = moved.filter(\.wasShown).map(\.old), arriving = moved.filter(\.shown).map(\.new)
        for (id, number) in FolderTreeService.counts(for: grown, assets: arriving) where number != 0 {
            counts[id, default: 0] += number
        }
        for (id, number) in FolderTreeService.counts(for: grown, assets: leaving) where number != 0 {
            counts[id, default: 0] -= number
        }
        // a folder with no photo shown in it may still have a JPEG behind a RAW elsewhere: made again
        guard left.allSatisfy({ (counts[$0] ?? 0) > 0 }) else { return }
        folderTreeCache = grown
        folderTreeCountCache = counts
    }

    /// Moves photos' keywords from those a pass counted them with (`old`: none for a photo not
    /// shown) to those it counts now (`new`, none for a photo no longer shown), as a pass over the
    /// photos would count them: false when that moves where a pass first meets a keyword, which
    /// takes counting again.
    nonisolated private static func patchKeywords(_ tally: inout KeywordTally,
                                                  _ changes: [(offset: Int, old: [String], new: [String])]) -> Bool {
        var added: [String: (offset: Int, index: Int)] = [:]   // new keywords → where first met
        for change in changes where change.old != change.new {
            // The photo a pass first meets a keyword on orders the list's ties. A change to
            // that photo's keywords, or a keyword put on a photo before it, moves a keyword
            // there: recounted then, rather than patched out of the order a recount gives.
            if (change.old + change.new).contains(where: { (tally.first[$0] ?? -1) >= change.offset }) { return false }
            for keyword in change.old { tally.counts[keyword, default: 0] -= 1 }
            for (index, keyword) in change.new.enumerated() {
                if tally.first[keyword] == nil,
                   added[keyword].map({ (change.offset, index) < ($0.offset, $0.index) }) ?? true {
                    added[keyword] = (change.offset, index)
                }
                tally.counts[keyword, default: 0] += 1
            }
        }
        // a keyword new to the photos goes where a pass first meets it (on a photo no other
        // keyword is first met on, or it would have been recounted above)
        for (keyword, place) in added.sorted(by: { ($0.value.offset, $0.value.index) < ($1.value.offset, $1.value.index) }) {
            let at = tally.order.firstIndex { (tally.first[$0] ?? .max) > place.offset } ?? tally.order.endIndex
            tally.order.insert(keyword, at: at)
            tally.first[keyword] = place.offset
        }
        return true
    }

    /// All effects of an edit, not just the broadest category of changed fields.
    nonisolated static func editScope(from old: Asset, to new: Asset) -> AssetEditScope {
        if old.filename != new.filename || old.folderId != new.folderId || old.folderName != new.folderName
            || old.date != new.date || old.status != new.status || old.importedAt != new.importedAt
            || old.deleted != new.deleted || old.localPath != new.localPath || old.faces != new.faces
            || old.hasICCProfile != new.hasICCProfile || old.fileMB != new.fileMB
            || old.fileModifiedAt != new.fileModifiedAt || old.fileCreatedAt != new.fileCreatedAt
            || old.captureDateSource != new.captureDateSource || old.contentHash != new.contentHash
            || old.quickHash != new.quickHash || old.isDemo != new.isDemo || old.perceptualHash != new.perceptualHash
            || old.masterId != new.masterId || old.copyName != new.copyName
            // what the file says of itself: a photo read again brings it with new hashes, but a
            // photo replaced in place is taken as an edit, so none of it may pass unseen
            || old.type != new.type || old.isRaw != new.isRaw || old.camera != new.camera || old.lens != new.lens
            || old.width != new.width || old.height != new.height || old.orientation != new.orientation
            || old.focal != new.focal || old.aperture != new.aperture || old.shutter != new.shutter
            || old.iso != new.iso || old.colorSpace != new.colorSpace || old.duration != new.duration
            || old.thumb != new.thumb || old.preview != new.preview || old.ori != new.ori || old.pid != new.pid {
            return .any
        }
        var scope = AssetEditScope()
        if old.rating != new.rating || old.flag != new.flag || old.colorLabel != new.colorLabel {
            scope.insert(.review)
        }
        if old.keywords != new.keywords || old.title != new.title || old.caption != new.caption
            || old.author != new.author || old.copyright != new.copyright || old.makerNotes != new.makerNotes
            || old.project != new.project || old.client != new.client || old.location != new.location
            || old.gps.0 != new.gps.0 || old.gps.1 != new.gps.1 || old.gpsAltitude != new.gpsAltitude {
            scope.insert(.metadata)
        }
        return scope
    }

    /// Whether the current list's membership or order can move with a metadata edit.
    private var listDependsOnMetadataFields: Bool {
        if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || filters.gps != "any" { return true }
        if [.keyword, .project, .client, .smart].contains(selection.type) { return true }
        return selection.type == .lib && selection.id == "places"
    }

    private var listDependsOnReviewFields: Bool {
        if filters.minRating > 0 || filters.flag != "any" || filters.color != "any" { return true }
        if sort.field == .rating || selection.type == .smart { return true }
        return selection.type == .lib && ["unrated", "picks", "rejected"].contains(selection.id)
    }

    /// Replaces edited assets inside list caches that were current before the edit.
    private func patchListCaches(with edits: [(offset: Int, asset: Asset)], validFor before: ListSignature) {
        let after = currentListSignature
        // Usual case, nothing collapsed: both caches are one array. Patch it in place by
        // position (O(edits)) after dropping the caches' references so no copy is forced.
        if collapsedStackIds.isEmpty, var visible = listCache, visible.signature == before,
           uncollapsedListCache?.signature == before {
            // the index when this list has one, or is worth building for a batch (from the
            // cached list, not via `list`, whose key already moved on); a few edits scan
            let positions = listPositionsCache.flatMap { $0.signature == before ? $0.positions : nil }
                ?? (edits.count > Self.listScanLimit ? Self.positions(of: visible.value) : nil)
            let hint = listPositionHint
            let shows = listShows
            listCache = nil
            uncollapsedListCache = nil
            let scanned = visible.value.withUnsafeMutableBufferPointer { buffer in
                if let positions {
                    for edit in edits {
                        if let position = positions[edit.asset.id] { buffer[position] = edit.asset }
                    }
                    return 0
                }
                // a JPEG behind its RAW (a rating reaches both) or a removed photo is in no list:
                // looking for it walked every photo
                let pending = edits.lazy.filter { shows($0.asset) }
                return Self.locate(pending.map(\.asset.id), in: UnsafeBufferPointer(buffer), hint: hint) { id, position in
                    if let edit = pending.first(where: { $0.asset.id == id }) { buffer[position] = edit.asset }
                }
            }
            listPatchScannedPhotos += scanned
            listCache = (after, visible.value)
            uncollapsedListCache = (after, visible.value)
            if let positions { listPositionsCache = (after, positions) }
            return
        }
        let edited = Dictionary(edits.map { ($0.asset.id, $0.asset) }, uniquingKeysWith: { $1 })
        func patch(_ list: inout [Asset]) {
            listPatchScannedPhotos += list.count
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
}
