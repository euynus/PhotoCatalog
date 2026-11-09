import AppKit
import Foundation

@MainActor
extension AppState {
    // ---------- base collection from sidebar ----------
    /// Whether a photo can be in the list at all: not removed, and not a JPEG behind its RAW
    /// (`AssetPairing.shows`, which doesn't look a RAW up: pairing never hides one).
    /// Missing/offline is file-level: a lost JPEG must show even when its RAW is fine.
    var listShows: (Asset) -> Bool {
        let pairing = selection.type == .lib && selection.id == "missing" ? .empty : assetPairing
        return { pairing.shows($0) }
    }

    /// The selected collection's membership test, made afresh for each pass over the photos (a
    /// smart album's keeps its text answers in a memo of its own), so passes can run side by
    /// side. Nil when the collection is gone (an album deleted, a date that names no day).
    private func collectionTest(now: Date) -> (() -> (Asset) -> Bool)? {
        // Observed inputs are read once, outside the per-asset tests.
        let selection = self.selection
        /// The same test for every pass: it keeps nothing.
        func each(_ test: @escaping (Asset) -> Bool) -> () -> (Asset) -> Bool { { test } }
        switch selection.type {
        case .folder:
            if let item = folderTree.first(where: { $0.id == selection.id }) {
                return each { FolderTreeService.matches($0, item: item) }
            }
            return each { $0.folderId == selection.id }
        case .album:
            guard let al = albums.first(where: { $0.id == selection.id }) else { return nil }
            let memberIds = Set(al.assetIds)
            return each { memberIds.contains($0.id) }
        case .smart:
            guard let sa = smartAlbums.first(where: { $0.id == selection.id }) else { return nil }
            let rule = SmartMatcher.Prepared(sa.rule, now: now)
            return {
                var memo = SmartMatcher.Memo(for: rule)
                return { rule.matches($0, memo: &memo) }
            }
        case .keyword:
            return each { $0.keywords.contains(selection.id) }
        // a project or client is listed without the spaces around it, and shows what it counts
        case .project:
            return each { $0.project == selection.id || (!$0.project.isEmpty && listedValue($0.project) == selection.id) }
        case .client:
            return each { $0.client == selection.id || (!$0.client.isEmpty && listedValue($0.client) == selection.id) }
        case .captureDate:
            guard let range = CaptureDates.interval(for: selection.id) else { return nil }
            return each { CaptureDates.contains($0.date, in: range) }
        case .lib:
            switch selection.id {
            case "recent":
                let cutoff = recentCutoff
                return each { $0.importedAt > cutoff }
            case "quick":
                let members = quickCollection
                return each { members.contains($0.id) }
            case "unrated":
                return each { $0.rating == 0 && $0.flag != .reject }
            case "picks":
                return each { $0.flag == .pick }
            case "rejected":
                return each { $0.flag == .reject }
            case "missing":
                return each { $0.status == .missing || $0.status == .offline }
            case "xmpChanged":
                let changed = externallyChangedXMPIds
                return each { changed.contains($0.id) }
            case "places":
                return each { $0.hasGPS }
            case "people":
                // faces found by the People analysis, or by Vision tagging at import
                let withFaces = faceAssetIds
                return each { $0.faces > 0 || withFaces.contains($0.id) }
            default:
                return each { _ in true }
            }
        }
    }

    // ---------- apply filter bar + search + sort ----------
    /// Where each photo sits in `list`, built once per list and kept with it: membership and
    /// cursor lookups are O(1) instead of scanning every photo on each keystroke (at 500k
    /// photos those scans made a single rating take a quarter of a second).
    var listPositions: [String: Int] {
        let current = list
        // the signature `list` just used: building it again runs the calendar again
        guard let signature = listCache?.signature else { return Self.positions(of: current) }
        if let cache = listPositionsCache, cache.signature == signature { return cache.positions }
        let positions = Self.positions(of: current)
        listPositionsCache = (signature, positions)
        return positions
    }

    static func positions(of list: [Asset]) -> [String: Int] {
        var positions = [String: Int](minimumCapacity: list.count)
        for (index, asset) in list.enumerated() { positions[asset.id] = index }
        return positions
    }

    /// Up to this many ids are located with one pass over `list` rather than the index:
    /// the pass costs 13–25 ms at 500k photos, building the index ~110 ms.
    nonisolated static let listScanLimit = 8

    /// Where `id` sits in `list`: the index if this list already has one, else the hint,
    /// else one pass.
    func listPosition(of id: String) -> Int? {
        listPositions(of: CollectionOfOne(id))[id]
    }

    /// Positions in `list` of the ids it shows, the others omitted.
    func listPositions<C: Collection<String>>(of ids: C) -> [String: Int] {
        guard !ids.isEmpty else { return [:] }
        let current = list
        // the signature `list` just used: building it again runs the calendar again
        let signature = listCache?.signature
        if let index = listPositionsCache.flatMap({ $0.signature == signature ? $0.positions : nil })
            ?? (ids.count > Self.listScanLimit ? listPositions : nil) {
            var found = [String: Int](minimumCapacity: ids.count)
            for id in ids { if let position = index[id] { found[id] = position } }
            return found
        }
        var found: [String: Int] = [:]
        let hint = listPositionHint
        let departed = listDepartedIds.flatMap { $0.signature == signature ? $0.ids : nil }
        let scanned = current.withUnsafeBufferPointer { photos in
            // photos an edit just took out of this list aren't looked for
            guard let departed else { return Self.locate(ids, in: photos, hint: hint) { found[$0] = $1 } }
            return Self.locate(ids.lazy.filter { !departed.contains($0) }, in: photos, hint: hint) { found[$0] = $1 }
        }
        listPositionScannedPhotos += scanned
        if let primaryId, let position = found[primaryId] { listPositionHint = (primaryId, position) }
        return found
    }

    /// Finds `ids` in `photos`: the hint first, when it still names a wanted photo where it was,
    /// then one pass that reads only ids and stops once every id is found. Each id found is
    /// reported once, at its first place, through `found`, so a single edit's lookup builds no
    /// table. Returns how many photos the pass looked at.
    nonisolated static func locate(_ ids: some Collection<String>, in photos: UnsafeBufferPointer<Asset>,
                                   hint: (id: String, position: Int)?, found: (String, Int) -> Void) -> Int {
        guard !ids.isEmpty else { return 0 }
        var hinted: String?
        if let hint, hint.position < photos.count, photos[hint.position].id == hint.id, ids.contains(hint.id) {
            found(hint.id, hint.position)
            hinted = hint.id
        }
        // one id, as a cursor or a single edit asks: compared directly
        if ids.count == 1, let id = ids.first {
            guard hinted == nil else { return 0 }
            for position in photos.indices where photos[position].id == id {
                found(id, position)
                return position + 1
            }
            return photos.count
        }
        // a few ids are compared one by one, more are hashed
        if ids.count <= listScanLimit {
            var wanted = ids.filter { $0 != hinted }
            guard !wanted.isEmpty else { return 0 }
            for position in photos.indices {
                let id = photos[position].id
                guard wanted.contains(id) else { continue }
                found(id, position)
                wanted.removeAll { $0 == id }
                if wanted.isEmpty { return position + 1 }
            }
            return photos.count
        }
        var wanted = Set(ids)
        if let hinted { wanted.remove(hinted) }
        guard !wanted.isEmpty else { return 0 }
        for position in photos.indices {
            let id = photos[position].id
            guard wanted.remove(id) != nil else { continue }
            found(id, position)
            if wanted.isEmpty { return position + 1 }
        }
        return photos.count
    }

    var list: [Asset] {
        let signature = currentListSignature
        if let cache = listCache, cache.signature == signature { return cache.value }
        // folding a stack or opening one leaves the photos before folding as they were
        let matching: [Asset]
        if let cache = uncollapsedListCache, cache.signature.hasPhotosBeforeFolding(of: signature) {
            matching = cache.value
        } else {
            matching = computeList(for: signature)
        }
        uncollapsedListCache = (signature, matching)
        // the stacks are worked out for folded ones only
        let value = collapsedStackIds.isEmpty ? matching
            : PhotoStackService.visibleAssets(matching, stacks: photoStacks, collapsedStackIds: collapsedStackIds)
        listCache = (signature, value)
        listIdentity &+= 1
        return value
    }

    /// `list` for SwiftUI collections, with a constant-time equality (see `PhotoList`).
    var photoList: PhotoList {
        let value = list
        return PhotoList(assets: value, identity: listIdentity)
    }

    var currentListSignature: ListSignature {
        ListSignature(inputsVersion: listInputsVersion, selection: selection,
                      filters: filters, search: search, sort: sort,
                      collapsed: collapsedStackIds, recentDays: recentImportDays,
                      captureDay: sidebarDay)
    }

    func primeDefaultListCache(with loadedAssets: [Asset]) {
        guard selection.type == .lib, selection.id == "all",
              filters.isEmpty,
              search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              sort == Sort(), collapsedStackIds.isEmpty else { return }
        // as All Photographs shows them: a RAW's JPEG is behind its tile (loaded photos are live)
        let pairing = assetPairing
        let shown: [Asset]
        if pairing.isEmpty {
            shown = loadedAssets
        } else if loadedAssets.withUnsafeBufferPointer({ $0.baseAddress }) == assets.withUnsafeBufferPointer({ $0.baseAddress }) {
            // the photos the pairing was worked out from (any change since would have copied
            // them): asked by position instead of looking up every JPEG's id
            var visible: [Asset] = []
            visible.reserveCapacity(loadedAssets.count)
            for (position, asset) in loadedAssets.enumerated() where pairing.isShown(asset, at: position) {
                visible.append(asset)
            }
            shown = visible
        } else {
            shown = loadedAssets.filter(pairing.shows)
        }
        listCache = (currentListSignature, shown)
        uncollapsedListCache = (currentListSignature, shown)
        listIdentity &+= 1
    }

    private func computeList(for signature: ListSignature) -> [Asset] {
        listComputations += 1
        let sort = self.sort
        // Another order of the same photos sorts the positions the last pass found, without the
        // pass or a search of the index. Not in Recently Imported, whose cutoff moves with the clock.
        if let cache = matchingPositionsCache, cache.signature.hasPhotosBeforeSorting(of: signature),
           !(selection.type == .lib && selection.id == "recent") {
            return Self.sorted(assets, at: cache.positions, by: sort, run: listChunk)
        }
        // relative dates as the sidebar counts them
        guard let test = listTest(now: sidebarClock()) else { return [] }
        // Live, in the collection and through the filter bar: one pass split across the cores. On
        // one thread, looking up every photo's pairing alone took most of the ~0.3 s All
        // Photographs took at 500k photos, and a smart album's full-text search (which no memo
        // can answer: it searches each photo's own text) ~1.4 s.
        listFilterPasses += 1
        let positions = Self.matchingPositions(in: assets, chunk: listChunk, makeTest: test)
        matchingPositionsCache = (signature, positions)
        return Self.sorted(assets, at: positions, by: sort, run: listChunk)
    }

    /// Whether a photo is in the list before stacks fold — live, in the collection and through the
    /// filter bar — as a test made afresh for each pass over the photos (see `collectionTest`).
    /// Nil when the collection is gone.
    func listTest(now: Date) -> (() -> (Asset) -> Bool)? {
        // Snapshot observed properties: reading them inside the per-asset filter and the
        // sort comparator paid observation bookkeeping tens of thousands of times.
        let filters = self.filters
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let pairing = assetPairing
        // an index that can't answer leaves the search to the photos in memory, as for short queries
        let indexedSearchIds: Set<String>? = if q.count >= 3, let hits = store?.search(q) {
            // a hit on a hidden JPEG surfaces its RAW's tile
            Set(hits.flatMap { [$0] + (pairing.primaryByCompanion[$0].map { [$0] } ?? []) })
        } else {
            nil
        }
        let cameraQuery = filters.camera.trimmingCharacters(in: .whitespacesAndNewlines)
        let lensQuery = filters.lens.trimmingCharacters(in: .whitespacesAndNewlines)
        let dateInterval = filters.captureDateInterval(now: now)
        guard let collection = collectionTest(now: now) else { return nil }
        let live = listShows
        let filtered = !(filters.isEmpty && q.isEmpty)
        return {
            let belongs = collection()
            let search = LocalizedSearch()   // its own, for the filter bar's text tests
            return { a in
                guard live(a), belongs(a) else { return false }
                guard filtered else { return true }
                if filters.minRating > 0 && a.rating < filters.minRating { return false }
                if filters.flag != "any" && a.flag.rawValue != filters.flag { return false }
                if filters.color != "any" && a.colorLabel?.rawValue != filters.color { return false }
                if filters.type != "any" && !a.matchesType(filters.type) { return false }
                if !cameraQuery.isEmpty && !search.text(a.camera, contains: cameraQuery) { return false }
                if !lensQuery.isEmpty && !search.text(a.lens, contains: lensQuery) { return false }
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
                        if !search.text(a.searchHaystack, contains: q) { return false }
                    }
                }
                return true
            }
        }
    }

    /// The positions in `assets` of the photos a test takes, in order. Tested in chunks of
    /// `chunk` side by side on every core, each chunk with a test of its own from `makeTest`,
    /// and the chunks' positions joined in order: the positions one pass finds.
    nonisolated static func matchingPositions(in assets: [Asset], chunk: Int,
                                              makeTest: () -> (Asset) -> Bool) -> [Int] {
        // the photos through a pointer: threads reading one array retained its buffer by turns
        assets.withUnsafeBufferPointer { photos in
            Chunks.joined(Chunks.map(photos.count, chunk: chunk) { range in
                let test = makeTest()
                var found: [Int] = []
                for position in range where test(photos[position]) { found.append(position) }
                return found
            })
        }
    }

    /// A photo's sort key, by its rank among the photos sorted.
    private struct RankedKey {
        let key: Double
        let rank: Int
    }

    /// The photos at `positions` (in catalog order) sorted by `sort`, ties in catalog order.
    /// Keys are read once, side by side, into a compact array that is sorted in runs side by side
    /// and then merged: one thread sorting indices through the keys took 0.1–0.3 s at 500k photos.
    nonisolated static func sorted(_ assets: [Asset], at positions: [Int], by sort: Sort, run: Int = 16_384) -> [Asset] {
        let count = positions.count
        let descending = sort.descending
        // arrays through pointers: threads reading one array retained its buffer by turns
        return assets.withUnsafeBufferPointer { assets in
            positions.withUnsafeBufferPointer { positions in
                // the rank in `positions` of each photo in sorted order
                var order: [Int]
                if sort.field == .name {
                    let keys = concurrentMap(count, chunk: run) { FileNameSortKey(assets[positions[$0]].filename) }
                    order = Array(0..<count)
                    keys.withUnsafeBufferPointer { keys in
                        concurrentSort(&order, run: run) { i, j in
                            if keys[i] == keys[j] { return i < j }
                            return descending ? keys[j] < keys[i] : keys[i] < keys[j]
                        }
                    }
                } else {
                    let key: (Asset) -> Double = switch sort.field {
                    case .capture: { $0.date.timeIntervalSince1970 }
                    case .imported: { $0.importedAt.timeIntervalSince1970 }
                    case .rating: { Double($0.rating) }
                    case .size: { $0.fileMB }
                    case .name: { _ in 0 }
                    }
                    // descending is ascending by the negated keys: equal keys stay equal, ties by rank
                    let sign: Double = descending ? -1 : 1
                    var keyed = concurrentMap(count, chunk: run) {
                        RankedKey(key: sign * key(assets[positions[$0]]), rank: $0)
                    }
                    concurrentSort(&keyed, run: run) { $0.key < $1.key || ($0.key == $1.key && $0.rank < $1.rank) }
                    order = keyed.map(\.rank)
                }
                return order.withUnsafeBufferPointer { order in
                    concurrentMap(count, chunk: run) { assets[positions[order[$0]]] }
                }
            }
        }
    }

    /// Memory that work running side by side shares, each part of it on elements of its own.
    struct Shared<Element>: @unchecked Sendable {
        let buffer: UnsafeMutableBufferPointer<Element>
        init(_ buffer: UnsafeMutableBufferPointer<Element>) { self.buffer = buffer }
    }

    /// `transform` of each of `0..<count`, worked out in chunks side by side on every core.
    nonisolated static func concurrentMap<T>(_ count: Int, chunk: Int, _ transform: (Int) -> T) -> [T] {
        guard count > max(chunk, 1) else { return (0..<count).map(transform) }
        // one array the chunks write into, each its own elements: no per-chunk arrays to join
        return [T](unsafeUninitializedCapacity: count) { buffer, initialized in
            let memory = Shared(buffer)
            _ = Chunks.map(count, chunk: chunk) { range in
                for i in range { (memory.buffer.baseAddress! + i).initialize(to: transform(i)) }
            }
            initialized = count
        }
    }

    /// Sorts `elements` by `less`, a strict total order (ties broken, so every sort gives the one
    /// result): runs of `run` sorted side by side, then merged in pairs, each round's merges side
    /// by side. For plain values (indices, keys), which merging copies.
    nonisolated static func concurrentSort<T>(_ elements: inout [T], run: Int, by less: (T, T) -> Bool) {
        let count = elements.count
        let run = max(run, 2)
        guard count > run else {
            elements.sort(by: less)
            return
        }
        var scratch = elements
        elements.withUnsafeMutableBufferPointer { elements in
            scratch.withUnsafeMutableBufferPointer { scratch in
                let sorted = Shared(elements)
                DispatchQueue.concurrentPerform(iterations: (count - 1) / run + 1) { index in
                    var part = UnsafeMutableBufferPointer(rebasing: sorted.buffer[index * run ..< min(count, (index + 1) * run)])
                    part.sort(by: less)
                }
                var source = sorted, target = Shared(scratch)
                var width = run
                while width < count {
                    let from = source, to = target, span = width
                    DispatchQueue.concurrentPerform(iterations: (count - 1) / (2 * span) + 1) { pair in
                        merge(from.buffer, into: to.buffer, low: pair * 2 * span, middle: min(pair * 2 * span + span, count),
                              high: min(pair * 2 * span + 2 * span, count), by: less)
                    }
                    (source, target) = (target, source)
                    width *= 2
                }
                if source.buffer.baseAddress != elements.baseAddress {
                    elements.baseAddress!.update(from: source.buffer.baseAddress!, count: count)
                }
            }
        }
    }

    /// Merges the sorted `from[low..<middle]` and `from[middle..<high]` into `to[low..<high]`.
    nonisolated private static func merge<T>(_ from: UnsafeMutableBufferPointer<T>, into to: UnsafeMutableBufferPointer<T>,
                                 low: Int, middle: Int, high: Int, by less: (T, T) -> Bool) {
        // runs already in order (a list sorted as the catalog is) are copied as they are
        if middle == high || less(from[middle - 1], from[middle]) {
            (to.baseAddress! + low).update(from: from.baseAddress! + low, count: high - low)
            return
        }
        var i = low, j = middle, k = low
        while i < middle, j < high {
            if less(from[j], from[i]) {
                to[k] = from[j]
                j += 1
            } else {
                to[k] = from[i]
                i += 1
            }
            k += 1
        }
        while i < middle {
            to[k] = from[i]
            i += 1
            k += 1
        }
        while j < high {
            to[k] = from[j]
            j += 1
            k += 1
        }
    }

    var primary: Asset? {
        _ = listInputsVersion
        return primaryId.flatMap { assetIndex[$0] }.map { assets[$0] }
    }
    var isDuplicates: Bool { selection.type == .lib && selection.id == "duplicates" }
    var isPlaces: Bool { selection.type == .lib && selection.id == "places" }
    var isPeople: Bool { selection.type == .lib && selection.id == "people" }

    /// Whether the content shows the selected photos. Capture analysis, duplicate review and the
    /// people and places overviews stand in for the grid, with the selection out of sight behind them.
    var showsSelection: Bool {
        !isDuplicates && view != .analysis
            && !(view == .grid && (isPlaces || (isPeople && hasOpenCatalog)))
    }
}
