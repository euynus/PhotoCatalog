import AppKit
import Foundation

@MainActor
extension AppState {
    // ---------- people: faces found on device, grouped and named ----------
    /// Off the cooperative pool (originals without a preview may be RAWs), a few photos at a
    /// time: on 217 photos four at once took 2.5 s instead of 6.7 s, finding the same faces.
    private static let faceQueue = DispatchQueue(label: "PhotoCatalog.faces", qos: .utility)
    nonisolated static let faceWorkers = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2))

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
        faceAssetIds = Set(loaded.map(\.assetId))
        // photos whose faces an earlier method read count as not analysed, so the next analysis
        // reads them again (keeping their names)
        faceOutdatedAssetIds = Set(loaded.filter { !$0.vector.isEmpty && !FaceClustering.isComparable($0) }.map(\.assetId))
        faceScannedAssetIds = ((try? store.loadFaceScannedAssetIds()) ?? []).subtracting(faceOutdatedAssetIds)
        faceScanVersion &+= 1
        allFaceClusters = []
        facesRevision &+= 1
        refreshFaceClusters()
    }

    func clearFaces() {
        faceAnalysisGeneration &+= 1
        faceAnalysis = nil
        faces = [:]
        faceAssetIds = []
        faceScannedAssetIds = []
        faceOutdatedAssetIds = []
        faceScanVersion &+= 1
        allFaceClusters = []
        facesRevision &+= 1
    }

    /// Whether People shows a face: its photo is in the catalog, not removed from it. Faces in
    /// removed photos are kept, so undoing the removal brings them back.
    private var faceIsShown: (FaceRecord) -> Bool {
        let index = assetIndex
        let assets = assets
        return { face in index[face.assetId].map { !assets[$0].deleted } ?? false }
    }

    /// Named people, most photographed first.
    var people: [PersonSummary] {
        _ = facesRevision
        let structure = structureVersion   // removing a photo, or undoing that, changes who shows
        if let cache = peopleCache, cache.revision == facesRevision, cache.structure == structure {
            return cache.people
        }
        let shown = faceIsShown
        var byPerson: [String: [FaceRecord]] = [:]
        for face in faces.values where shown(face) {
            if let person = face.person { byPerson[person, default: []].append(face) }
        }
        let result = byPerson.map { name, faces in
            let best = faces.max { ($0.confirmed ? 1 : 0, $0.quality) < ($1.confirmed ? 1 : 0, $1.quality) }!
            return PersonSummary(name: name, faceIds: faces.map(\.id),
                                 photoCount: Set(faces.filter(\.confirmed).map(\.assetId)).count,
                                 coverFaceId: best.id, unconfirmed: faces.filter { !$0.confirmed }.count)
        }
        .sorted { ($0.photoCount, $1.name) > ($1.photoCount, $0.name) }
        peopleCache = (facesRevision, structure, result)
        return result
    }

    /// Unnamed faces in likely-one-person groups, in the order grouped, without the faces in
    /// photos removed from the catalog.
    var faceClusters: [FaceCluster] {
        let clusters = allFaceClusters
        let structure = structureVersion   // both read even on a cache hit, to register them
        if let cache = faceClustersCache, cache.structure == structure { return cache.clusters }
        let shown = faceIsShown
        let result = clusters.compactMap { cluster -> FaceCluster? in
            let rest = cluster.faceIds.filter { faces[$0].map(shown) ?? false }
            return rest.isEmpty ? nil : FaceCluster(id: rest.contains(cluster.id) ? cluster.id : rest[0], faceIds: rest)
        }
        faceClustersCache = (structure, result)
        return result
    }

    /// Photos not yet analysed (a RAW's paired JPEG is covered by the RAW).
    var faceUnscannedCount: Int { faceAnalysisCounts.unscanned }

    var faceScannedCount: Int {
        _ = facesRevision
        return faceScannedAssetIds.count
    }

    /// Photos among the unanalysed whose faces an earlier, less accurate method read.
    var faceOutdatedCount: Int { faceAnalysisCounts.outdated }

    /// Whether the analysis has still to look at a photo: not a demo photo, not a virtual copy
    /// (its faces are its master's, and scanning it would list each face twice), not analysed yet.
    func needsFaceAnalysis(_ a: Asset) -> Bool {
        !a.isDemo && !a.isVirtualCopy && !faceScannedAssetIds.contains(a.id)
    }

    /// Both counts in one pass over the photos as shown, again only when the scans, the photos'
    /// structure (removed, back, virtual copies, demo photos) or the pairing changed: a naming or
    /// a rating on the People overview counted every photo twice (~0.1 s each at 500k photos).
    private var faceAnalysisCounts: (unscanned: Int, outdated: Int) {
        // read on a hit too, to register them
        _ = facesRevision
        let (structure, pairs) = (structureVersion, pairRawAndJpeg)
        if let cache = faceAnalysisCountsCache, cache.scan == faceScanVersion, cache.structure == structure,
           cache.pairs == pairs {
            return (cache.unscanned, cache.outdated)
        }
        let pairing = assetPairing
        let outdated = faceOutdatedAssetIds
        var counts = (unscanned: 0, outdated: 0)
        for (position, a) in assets.enumerated() where pairing.isShown(a, at: position) {
            if needsFaceAnalysis(a) { counts.unscanned += 1 }
            if !outdated.isEmpty, !a.isVirtualCopy, outdated.contains(a.id) { counts.outdated += 1 }
        }
        faceAnalysisCountsCache = (faceScanVersion, structure, pairs, counts.unscanned, counts.outdated)
        return counts
    }

    func face(_ id: String) -> FaceRecord? { faces[id] }

    func asset(id: String) -> Asset? { assetIndex[id].map { assets[$0] } }

    /// A person's photos in the grid, through their `人物/名字` keyword.
    func showPhotos(of person: String) {
        select(Selection(type: .keyword, id: FaceClustering.keyword(for: person), name: person))
        view = .grid
    }

    /// Re-groups unnamed faces off the main thread (those in removed photos too, so they're in
    /// their group again when the removal is undone).
    private func refreshFaceClusters() {
        let unnamed = faces.values.filter { $0.person == nil }
        let revision = facesRevision
        Task.detached(priority: .utility) { [weak self] in
            let clusters = FaceClustering.clusters(unnamed)
            await MainActor.run { [weak self] in
                guard let self, self.facesRevision == revision else { return }
                self.allFaceClusters = clusters
            }
        }
    }

    /// Looks for faces in every photo not analysed yet — from the cached preview, else the
    /// original — then names new faces that closely match someone already named.
    func startFaceAnalysis() {
        guard faceAnalysis == nil, store != nil else { return }
        // a virtual copy's faces are its master's: scanning it would list each face twice
        let pending = presentedAssets().filter(needsFaceAnalysis)
        guard !pending.isEmpty else { return }
        faceAnalysisGeneration &+= 1
        let generation = faceAnalysisGeneration
        faceAnalysis = (0, pending.count)
        let inputs = pending.map { asset in
            (id: asset.id, preview: asset.preview.hasPrefix("http") ? "" : asset.preview, original: asset.localPath ?? "",
             isRaw: asset.isRaw)
        }
        Self.faceQueue.async { [weak self] in
            // two dozen photos at a time, a few of them at once, each two dozen saved before the next
            for start in stride(from: 0, to: inputs.count, by: 24) {
                let chunk = Array(inputs[start..<min(start + 24, inputs.count)])
                let lock = NSLock()
                var next = 0
                var batch: [String: [FaceRecord]] = [:]
                DispatchQueue.concurrentPerform(iterations: min(Self.faceWorkers, chunk.count)) { _ in
                    while true {
                        let index: Int? = lock.withLock {
                            guard next < chunk.count else { return nil }
                            next += 1
                            return next - 1
                        }
                        guard let index else { return }
                        let input = chunk[index]
                        let source = FaceService.analysisSource(preview: input.preview, original: input.original,
                                                                isRaw: input.isRaw)
                        let detected = source.flatMap { source in
                            autoreleasepool { FaceService.faces(in: source.url, embeddedPreview: source.embeddedPreview) }
                        }
                        guard let detected else { continue }   // an unreadable photo stays unscanned for a later try
                        let records = detected.enumerated().map { offset, face in
                            FaceRecord(id: "\(input.id)-f\(offset)", assetId: input.id, box: face.box,
                                       quality: face.quality, vector: face.vector)
                        }
                        lock.withLock { batch[input.id] = records }
                    }
                }
                let done = start + chunk.count
                let keepGoing = DispatchQueue.main.sync {
                    MainActor.assumeIsolated { self?.recordFaceScans(batch, done: done, generation: generation) ?? false }
                }
                if !keepGoing { return }
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
    private func recordFaceScans(_ found: [String: [FaceRecord]], done: Int, generation: Int) -> Bool {
        guard generation == faceAnalysisGeneration, let store else { return false }
        // a photo analysed again replaces its faces, keeping their names
        var scans = found
        let again = Set(found.keys).intersection(faceOutdatedAssetIds)
        let earlier = again.isEmpty ? [:] : Dictionary(grouping: faces.values.filter { again.contains($0.assetId) }, by: \.assetId)
        for assetId in again {
            scans[assetId] = FaceClustering.carryNames(from: earlier[assetId] ?? [], to: found[assetId] ?? [])
        }
        do {
            try store.saveFaceScans(scans)
        } catch {
            push("保存人脸分析结果失败", "warning")
            faceAnalysis = nil
            return false
        }
        for face in earlier.values.joined() { faces[face.id] = nil }
        var withFaces = faceAssetIds
        for (assetId, found) in scans {
            faceScannedAssetIds.insert(assetId)
            faceOutdatedAssetIds.remove(assetId)
            for face in found { faces[face.id] = face }
            if found.isEmpty { withFaces.remove(assetId) } else { withFaces.insert(assetId) }
        }
        faceScanVersion &+= 1
        faceAssetIds = withFaces
        faceAnalysis?.done = done
        facesRevision &+= 1
        // groups fill in as the analysis goes, not only at the end
        if done / 240 != (done - scans.count) / 240 { refreshFaceClusters() }
        return true
    }

    private func finishFaceAnalysis(generation: Int) {
        guard generation == faceAnalysisGeneration else { return }
        faceAnalysis = nil
        let shown = faces.values.filter(faceIsShown)
        let unnamed = shown.filter { $0.person == nil }
        let matches = FaceClustering.matches(for: unnamed, named: shown)
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
        applyFaceNames(Dictionary(uniqueKeysWithValues: ids.map { ($0, (name, true)) }), undoName: L("命名人物"))
    }

    /// Confirms a person's suggested faces (all of them, or just `ids`).
    func confirmFaces(of person: String, ids: [String]? = nil) {
        let targets = ids ?? faces.values.filter { $0.person == person && !$0.confirmed }.map(\.id)
        applyFaceNames(Dictionary(uniqueKeysWithValues: targets.map { ($0, (person, true)) }), undoName: L("确认人物"))
    }

    /// "Not this person": the face goes back to the unnamed groups, and the photo loses the
    /// person's keyword unless another face in it is the same person.
    func removeFaceFromPerson(_ id: String) {
        guard let face = faces[id], face.person != nil else { return }
        setFaceStates([id: (nil, false)], undoName: L("不是此人"))
        refreshFaceClusters()
    }

    /// Person names on faces, plus the matching `人物/…` keywords on their photos; one undo step.
    /// Faces in photos removed from the catalog are left as they are, as their photos' keywords are.
    private func applyFaceNames(_ changes: [String: (String, Bool)], undoName: String?) {
        let shown = faceIsShown
        let changes = changes.filter { faces[$0.key].map(shown) ?? false }
        guard !changes.isEmpty else { return }
        setFaceStates(changes.mapValues { (person: Optional($0.0), confirmed: $0.1) }, undoName: undoName)
        allFaceClusters = allFaceClusters.compactMap { cluster in
            let rest = cluster.faceIds.filter { changes[$0] == nil }
            return rest.isEmpty ? nil : FaceCluster(id: rest.contains(cluster.id) ? cluster.id : rest[0], faceIds: rest)
        }
    }

    private typealias FaceStates = [String: (person: String?, confirmed: Bool)]
    /// The person keywords a face step added to and removed from each photo.
    private typealias PersonKeywordChanges = [String: (added: [String], removed: [String])]

    /// Writes face names and keeps photo keywords in step: a photo carries `人物/名字` exactly
    /// when one of its faces is named so.
    private func setFaceStates(_ changes: FaceStates, undoName: String?) {
        guard let store else { return }
        let before = faceStates(changes.keys)
        guard let touched = writeFaceStates(changes, to: store) else { return }
        let keywords = syncPersonKeywords(for: touched.assetIds, names: touched.names)
        registerFaceUndo(restoring: before, keywords: keywords, takingBack: true, undoName: undoName)
    }

    /// Undo and redo of a face step: the faces as they were, and the keyword changes the step
    /// made taken back (or made again). Matching keywords to the faces afresh instead took a
    /// person keyword off a photo that had it before the step.
    private func replayFaceStep(_ states: FaceStates, keywords: PersonKeywordChanges, takingBack: Bool,
                                undoName: String) {
        guard let store else { return }
        let before = faceStates(states.keys)
        guard writeFaceStates(states, to: store) != nil else { return }
        // a photo removed from the catalog since keeps the keywords it had
        let live = Set(keywords.keys.filter { asset(id: $0).map { !$0.deleted } ?? false })
        if !live.isEmpty {
            mutate(live) { asset in
                guard let change = keywords[asset.id] else { return }
                let (add, remove) = takingBack ? (change.removed, change.added) : (change.added, change.removed)
                asset.keywords = KeywordService.normalize(asset.keywords.filter { !remove.contains($0) } + add)
            }
        }
        registerFaceUndo(restoring: before, keywords: keywords, takingBack: !takingBack, undoName: undoName)
        refreshFaceClusters()
    }

    private func registerFaceUndo(restoring states: FaceStates, keywords: PersonKeywordChanges, takingBack: Bool,
                                  undoName: String?) {
        guard let undoName, let undoManager else { return }
        UndoSteps.register(on: undoManager) {
            undoManager.registerUndo(withTarget: self) { app in
                MainActor.assumeIsolated {
                    app.replayFaceStep(states, keywords: keywords, takingBack: takingBack, undoName: undoName)
                }
            }
            undoManager.setActionName(undoName)
        }
    }

    private func faceStates(_ ids: some Sequence<String>) -> FaceStates {
        Dictionary(uniqueKeysWithValues: ids.compactMap { id in
            faces[id].map { (id, (person: $0.person, confirmed: $0.confirmed)) }
        })
    }

    /// Saves face names and sets them in memory. Returns the photos the faces are in and the
    /// names involved, or nil when they couldn't be saved.
    private func writeFaceStates(_ changes: FaceStates, to store: CatalogStore)
        -> (assetIds: Set<String>, names: Set<String>)? {
        do {
            try store.setFacePeople(changes)
        } catch {
            push("保存人物失败", "warning")
            return nil
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
        return (touchedAssets, names)
    }

    /// Makes the `人物/名字` keywords of `names` match the confirmed faces on each photo (and
    /// its paired JPEG). Suggestions wait for confirmation, and only these names are touched,
    /// so person keywords typed by hand survive. Returns the keywords it changed.
    private func syncPersonKeywords(for assetIds: Set<String>, names: Set<String>) -> PersonKeywordChanges {
        guard !names.isEmpty else { return [:] }
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
            // a photo removed from the catalog keeps the keywords it had
            guard let index = assetIndex[id], !assets[index].deleted else { return false }
            let keywords = assets[index].keywords
            let current = Set(keywords).intersection(managed)
            let orphanedRoot = keywords.contains(root) && !keywords.contains { $0.hasPrefix(root + "/") }
            return orphanedRoot || current != Set((wanted[id] ?? []).map(FaceClustering.keyword))
        })
        guard !changed.isEmpty else { return [:] }
        let before = Dictionary(uniqueKeysWithValues: changed.compactMap { id in
            assetIndex[id].map { (id, assets[$0].keywords) }
        })
        // keywords follow the faces; the face edit carries the undo (`mutate` without a name registers none)
        mutate(changed) { asset in
            var keywords = asset.keywords.filter { !managed.contains($0) }
            keywords += (wanted[asset.id] ?? []).sorted().map(FaceClustering.keyword)
            // the bare 人物 parent goes once nothing sits under it
            if !keywords.contains(where: { $0.hasPrefix(root + "/") }) { keywords.removeAll { $0 == root } }
            asset.keywords = KeywordService.normalize(keywords)
        }
        var made: PersonKeywordChanges = [:]
        for (id, old) in before {
            guard let new = asset(id: id)?.keywords, new != old else { continue }
            made[id] = (new.filter { !old.contains($0) }, old.filter { !new.contains($0) })
        }
        return made
    }

    /// Keeps face names in step when a `人物/…` keyword is renamed or deleted from the sidebar.
    /// Faces in photos removed from the catalog keep their names, as the photos keep the keyword.
    private func syncFacesAfterKeywordChange(old: String, new: String?, undoName: String) {
        let shown = faceIsShown
        guard let oldPerson = FaceClustering.person(fromKeyword: old) else {
            // renaming or deleting the whole 人物 branch touches every person
            guard old == FaceClustering.keywordRoot else { return }
            var changes: [String: (person: String?, confirmed: Bool)] = [:]
            for face in faces.values where shown(face) {
                guard let person = face.person else { continue }
                let renamed = new.flatMap { FaceClustering.person(fromKeyword: $0 + "/" + person) }
                changes[face.id] = (renamed, renamed == nil ? false : face.confirmed)
            }
            if !changes.isEmpty { setFaceStates(changes, undoName: undoName) }
            return
        }
        let newPerson = new.flatMap(FaceClustering.person(fromKeyword:))
        var changes: [String: (person: String?, confirmed: Bool)] = [:]
        for face in faces.values where face.person == oldPerson && shown(face) {
            changes[face.id] = (newPerson, newPerson == nil ? false : face.confirmed)
        }
        guard !changes.isEmpty else { return }
        // in the keyword edit's undo step (`asOneUndoStep`), so undo restores both together
        setFaceStates(changes, undoName: undoName)
        if newPerson == nil { refreshFaceClusters() }
    }

    func renamePerson(_ old: String, to new: String) {
        let name = FaceClustering.cleanName(new)
        guard !name.isEmpty, name != old else { return }
        let oldKeyword = FaceClustering.keyword(for: old), newKeyword = FaceClustering.keyword(for: name)
        // someone only suggested, or whose keyword was taken off every photo, has no photo to
        // rename the keyword on: their faces are renamed alone
        guard photoIds(withKeyword: oldKeyword).isEmpty else {
            renameKeyword(oldKeyword, to: newKeyword)
            return
        }
        syncFacesAfterKeywordChange(old: oldKeyword, new: newKeyword, undoName: L("重命名关键词"))
    }

    func deletePerson(_ name: String) {
        let keyword = FaceClustering.keyword(for: name)
        guard photoIds(withKeyword: keyword).isEmpty else {
            deleteKeyword(keyword)
            return
        }
        syncFacesAfterKeywordChange(old: keyword, new: nil, undoName: L("删除关键词"))
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
        guard !ids.isEmpty, asOneUndoStep({
            guard mutate(ids, undoName: L("重命名关键词"), {
                $0.keywords = KeywordService.replacing(old, with: target, in: $0.keywords)
            }) else { return false }
            syncFacesAfterKeywordChange(old: old, new: target, undoName: L("重命名关键词"))
            return true
        }) else { return false }
        if selection.type == .keyword, KeywordService.isWithin(selection.id, old) {
            let renamed = target + selection.id.dropFirst(old.count)
            select(Selection(type: .keyword, id: renamed, name: renamed))
        }
        push("已将「\(old)」重命名为「\(target)」· \(ids.count) 张照片", "tag")
        return true
    }

    /// Runs `body`, whose undo registrations are one step: a keyword edit and the face names it
    /// carries along. Outside an event (after a modal alert, say) each registration would be a
    /// step of its own, and one ⌘Z took back only the face names.
    private func asOneUndoStep(_ body: () -> Bool) -> Bool {
        guard let undoManager else { return body() }
        var done = false
        UndoSteps.register(on: undoManager) { done = body() }
        return done
    }

    /// Removes a keyword and its sub-keywords from every photo.
    @discardableResult
    func deleteKeyword(_ keyword: String) -> Bool {
        let ids = photoIds(withKeyword: keyword)
        guard !ids.isEmpty, asOneUndoStep({
            guard mutate(ids, undoName: L("删除关键词"), {
                $0.keywords = KeywordService.replacing(keyword, with: nil, in: $0.keywords)
            }) else { return false }
            syncFacesAfterKeywordChange(old: keyword, new: nil, undoName: L("删除关键词"))
            return true
        }) else { return false }
        if selection.type == .keyword, KeywordService.isWithin(selection.id, keyword) {
            select(Selection(type: .lib, id: "all", name: L("全部照片")))
        }
        push("已从 \(ids.count) 张照片中删除关键词「\(keyword)」", "tag")
        return true
    }

    /// Asks for a new name; typing an existing keyword merges into it.
    func promptRenameKeyword(_ keyword: String) {
        let alert = NSAlert()
        alert.messageText = L("重命名关键词「\(keyword)」")
        alert.informativeText = L("用于 \(photoIds(withKeyword: keyword).count) 张照片，下级关键词一并更新。输入已有的关键词即合并。")
        let field = NSTextField(string: keyword)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: L("重命名"))
        alert.addButton(withTitle: L("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != keyword else { return }
        if !renameKeyword(keyword, to: name) { push("无法重命名为「\(name)」", "warning") }
    }

    func confirmDeleteKeyword(_ keyword: String) {
        guard confirmDestructiveAction(L("删除关键词「\(keyword)」？"),
                                       L("将从 \(photoIds(withKeyword: keyword).count) 张照片中移除它及其下级关键词。可以撤销。"),
                                       L("删除")) else { return }
        deleteKeyword(keyword)
    }

    func removeSelected() {
        // a master's virtual copies go with it: they have nothing left to point at
        let ids = targetIds.union(virtualCopyIds(of: targetIds))
        guard !ids.isEmpty else { return }
        let photoCount = selectionTargetIds.count
        guard mutate(ids, undoName: L("从目录库移除"), { $0.deleted = true }) else { return }
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
        let real = selectedRealAssetsWithOriginals(copiesStandForMaster: false)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("移除照片")
        alert.informativeText = L("将 \(selectionTargetIds.count) 张照片从目录库移除。原件默认保留。")
        alert.addButton(withTitle: L("从目录库移除"))
        if !real.isEmpty { alert.addButton(withTitle: L("移到废纸篓")) }
        alert.addButton(withTitle: L("取消"))
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            removeSelected()
        } else if !real.isEmpty, response == .alertSecondButtonReturn {
            performTrashOriginals(real)
        }
    }

    func trashSelectedOriginals() {
        let real = selectedRealAssetsWithOriginals(copiesStandForMaster: false)
        guard !real.isEmpty else {
            push("仅可将已导入照片的原件移到废纸篓", "warning")
            return
        }

        guard confirmDestructiveAction(L("移到废纸篓"), L("将 \(real.count) 个磁盘原件移到废纸篓，并从目录库移除对应记录。"),
                                       L("移到废纸篓")) else { return }
        performTrashOriginals(real)
    }

    /// Move the given originals to the Trash and remove their catalog records (no extra prompt).
    private func performTrashOriginals(_ real: [Asset]) {
        guard let trashCatalogURL = store?.packageURL else {
            push("无目录库", "warning")
            return
        }
        // copies in the selection as confirmed go too, not those selected by the time it's done
        let selectedCopies = targetIds.filter { id in assetIndex[id].map { assets[$0].isVirtualCopy } ?? false }
        Task { [weak self, real, trashCatalogURL, selectedCopies] in
            let result = await Task.detached(priority: .userInitiated) {
                OriginalFileOperationService.trashOriginals(real)
            }.value

            guard let self,
                  self.applyTrashedOriginals(result, expectedCatalogURL: trashCatalogURL,
                                             selectedCopies: selectedCopies) else {
                if !result.trashedIds.isEmpty {
                    let rolledBack = await Task.detached(priority: .userInitiated) {
                        OriginalFileOperationService.rollBackTrash(result.locations)
                    }.value
                    self?.push(verbatim: L("移到废纸篓未完成")
                               + (rolledBack > 0 ? L(" · 已回滚 \(rolledBack) 个原件") : L(" · 回滚失败"))
                               + L(" · 目录库保存失败"),
                               "warning")
                }
                return
            }
        }
    }

    @discardableResult
    func applyTrashedOriginals(_ result: OriginalTrashReport, expectedCatalogURL: URL? = nil,
                               selectedCopies: Set<String> = []) -> Bool {
        guard !result.trashedIds.isEmpty else {
            push(verbatim: L("已移到废纸篓 0 张")
                 + (result.failed > 0 ? L(" · \(result.failed) 失败") : ""),
                 result.failed > 0 ? "warning" : "check")
            return true
        }
        if let expectedCatalogURL, store?.packageURL != expectedCatalogURL { return false }
        // the trashed files' virtual copies, and any copies selected with them, leave the catalog too
        let removed = result.trashedIds.union(virtualCopyIds(of: result.trashedIds)).union(selectedCopies)
        guard mutate(removed, { $0.deleted = true }) else { return false }
        trashedOriginalIds.formUnion(result.trashedIds)
        purgeCacheFiles(forAssetIds: removed)
        selectedIds.subtract(removed)
        ensurePrimaryValid()
        recomputeDuplicates()
        push(verbatim: L("已移到废纸篓 \(result.trashedIds.count) 张")
             + (result.failed > 0 ? L(" · \(result.failed) 失败") : ""),
             result.failed > 0 ? "warning" : "check")
        return true
    }
}
