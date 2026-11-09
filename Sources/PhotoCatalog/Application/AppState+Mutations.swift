import AppKit
import Foundation

@MainActor
extension AppState {
    /// Records how to take back the step that turned `before` into `after` (the same photos, in
    /// the same order). Undoing registers the reverse, which is what redo replays.
    private func registerUndo(from before: [Asset], to after: [Asset], actionName: String?) {
        guard let actionName, !before.isEmpty else { return }
        registerUndoStep(actionName) { $0.replayStep(from: after, to: before, actionName: actionName) }
    }

    /// Registers `undo` as an undo step named `name`; nothing without a name or an undo manager.
    func registerUndoStep(_ name: String?, _ undo: @escaping @MainActor (AppState) -> Void) {
        guard let name, let undoManager else { return }
        UndoSteps.register(on: undoManager) {
            undoManager.registerUndo(withTarget: self) { app in MainActor.assumeIsolated { undo(app) } }
            undoManager.setActionName(name)
        }
    }

    /// Applies the fields a step changed from `old` to `new` onto each photo as it is now, rather
    /// than writing back a whole copy: renames, moves, trashing, offline checks, rescans and
    /// sidecar reads aren't undoable, and ⌘Z on an earlier edit must not take them back too.
    private func replayStep(from old: [Asset], to new: [Asset], actionName: String) {
        let index = assetIndex
        var edits: [(offset: Int, asset: Asset)] = []
        var current: [Asset] = [], replayedOld: [Asset] = [], replayedNew: [Asset] = []
        for (stepOld, stepNew) in zip(old, new) {
            guard let offset = index[stepNew.id] else { continue }
            // a photo removed for good since (its source, or its original, gone) stays out
            if stepOld.deleted, !stepNew.deleted, assets[offset].deleted, isRemovedForGood(assets[offset]) { continue }
            var asset = assets[offset]
            asset.takeChanges(from: stepOld, to: stepNew)
            edits.append((offset, asset))
            current.append(assets[offset])
            replayedOld.append(stepOld)
            replayedNew.append(stepNew)
        }
        guard !edits.isEmpty else { return }
        // saved (only the columns the step changes), and their sidecar writes queued
        let scope = editScope(of: edits)
        guard persistChanged(edits.map(\.asset), editing: scope) else { return }
        let deletionChanged = zip(current, edits).contains { $0.deleted != $1.asset.deleted }
        applyAssetEdits(edits, scope: scope)
        ensurePrimaryValid()
        if deletionChanged { recomputeDuplicates() }
        registerUndo(from: replayedOld, to: replayedNew, actionName: actionName)
    }

    // ---------- mutations ----------
    /// What the user selected (one id per tile).
    var selectionTargetIds: Set<String> {
        if !selectedIds.isEmpty { return selectedIds }
        if let p = primaryId { return [p] }
        return []
    }

    /// Files an edit or file operation acts on: the selection plus paired JPEG/HEIC files.
    var targetIds: Set<String> { withCompanions(selectionTargetIds) }

    var hasSelection: Bool { onboarded && !selectionTargetIds.isEmpty }   // companions only follow photos
    var canApplySelectionToAlbum: Bool { hasSelection }
    var canExportOriginalSelection: Bool { canOperateOnSelectedOriginals }
    var canExportPreviewSelection: Bool { selectedAssetsContainPreviewReference }
    var canRemoveSelectionFromCurrentAlbum: Bool { selection.type == .album && hasSelection }
    var canRemoveSelectedSource: Bool { selectedFolderIsCatalogSource }
    var canReauthorizeSelectedSource: Bool {
        selectedFolderIsCatalogSource
            && sourceManagementModesById[selection.id] != ImportMode.managed.rawValue
    }

    var selectedFolderIsCatalogSource: Bool {
        selection.type == .folder
            && store != nil
            && !DemoData.folders.contains { $0.id == selection.id }
            && folders.contains { $0.id == selection.id }
    }

    // Capability checks are read while SwiftUI builds toolbars and menus. Keep
    // them metadata-only; the action revalidates paths before touching files.
    var selectedAssetsContainLocalOriginalReference: Bool { selectionSummary.hasLocalOriginal }

    private var selectedAssetsContainPreviewReference: Bool { selectionSummary.hasPreviewReference }

    /// Apply an in-place edit to the current selection (or an explicit set).
    @discardableResult
    func mutate(_ ids: Set<String>? = nil, undoName: String? = nil, writingSidecars: Bool = true,
                _ transform: (inout Asset) -> Void) -> Bool {
        let target = ids ?? targetIds
        guard !target.isEmpty else { return false }
        // Edit copies of only the targeted photos and write them back in place, with the
        // narrowest invalidation their changes need (a keyword edit keeps pairing and trees).
        let edits = editedCopies(of: target, transform)
        guard !edits.isEmpty else { return false }
        let before = edits.map { assets[$0.offset] }
        let scope = editScope(of: edits)
        guard persistChanged(edits.map(\.asset), writingSidecars: writingSidecars, editing: scope) else { return false }
        applyAssetEdits(edits, scope: scope)
        ensurePrimaryValid()
        registerUndo(from: before, to: edits.map(\.asset), actionName: undoName)
        return true
    }

    /// Copies of the photos with these ids (those the catalog has), each changed by `transform`,
    /// in the order the photos are in.
    private func editedCopies(of ids: Set<String>,
                              _ transform: (inout Asset) -> Void) -> [(offset: Int, asset: Asset)] {
        let index = assetIndex
        return ids.compactMap { id -> (offset: Int, asset: Asset)? in
            guard let offset = index[id] else { return nil }
            var asset = assets[offset]
            transform(&asset)
            return (offset, asset)
        }.sorted { $0.offset < $1.offset }
    }

    /// What these edits change in the photos as they are now: how far their effects reach, and
    /// which columns saving them writes.
    func editScope(of edits: [(offset: Int, asset: Asset)]) -> AssetEditScope {
        // the photos read through the observed property once, not once per edit
        assets.withUnsafeBufferPointer { photos in
            edits.reduce(into: AssetEditScope()) { $0.formUnion(Self.editScope(from: photos[$1.offset], to: $1.asset)) }
        }
    }

    @discardableResult
    func mutateAsset(_ id: String, undoName: String? = nil, _ transform: (inout Asset) -> Void) -> Bool {
        mutate([id], undoName: undoName, transform)
    }

    @discardableResult
    func setRating(_ n: Int, on ids: Set<String>? = nil) -> Bool {
        guard (0...5).contains(n) else { return false }
        return mutateIndexedMetadata(ids, undoName: L("评分"), { $0.rating = n }) { store, ids in
            try store.updateRatings(n, assetIDs: ids)
        }
    }
    @discardableResult
    func setFlag(_ f: Flag, on ids: Set<String>? = nil) -> Bool {
        mutateIndexedMetadata(ids, undoName: L("旗标"), { $0.flag = f }) { store, ids in
            try store.updateFlags(f, assetIDs: ids)
        }
    }
    @discardableResult
    func setColor(_ c: ColorLabel?, on ids: Set<String>? = nil) -> Bool {
        mutateIndexedMetadata(ids, undoName: L("颜色标签"), { $0.colorLabel = c }) { store, ids in
            try store.updateColorLabels(c, assetIDs: ids)
        }
    }

    private func mutateIndexedMetadata(
        _ targets: Set<String>?,
        undoName: String,
        _ transform: (inout Asset) -> Void,
        persist: (CatalogStore, Set<String>) throws -> Void
    ) -> Bool {
        let ids = withCompanions(targets ?? selectionTargetIds)
        guard !ids.isEmpty else { return false }
        // Edit copies of only the targeted assets, persist, then write them back in place:
        // copying the whole array retained every string of every asset on each keystroke.
        let edits = editedCopies(of: ids, transform)
        guard !edits.isEmpty else { return false }
        let changed = edits.map(\.asset).filter { !$0.isDemo }
        if let store, !changed.isEmpty {
            do {
                try persist(store, Set(changed.map(\.id)))
            } catch {
                push("保存失败，更改未写入目录库", "warning")
                return false
            }
        }
        registerUndo(from: edits.map { assets[$0.offset] }, to: edits.map(\.asset), actionName: undoName)
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
            L("移除源文件夹？"),
            L("将从目录库移除「\(folderName)」的索引记录，磁盘上的原件不会被删除。"),
            L("移除索引")
        ) else { return }

        let sourceRootPath = sourceRootPathsById[folderId]
        let ids = Set(indexed.map(\.id))
        do {
            try store?.removeSourceRootAndSoftDeleteAssets(id: folderId)
        } catch {
            push("源移除失败", "warning")
            return
        }
        removedSourceIds.insert(folderId)
        if !ids.isEmpty {
            replaceInPlace(positions(of: ids).map { offset in
                var asset = assets[offset]
                asset.deleted = true
                return (offset, asset)
            })
            ensurePrimaryValid()
            purgeCacheFiles(forAssetIds: ids)
        }
        folders.removeAll { $0.id == folderId }
        sourceRootPathsById.removeValue(forKey: folderId)
        sourcePriorities.removeValue(forKey: folderId)
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
        selection = Selection(type: .lib, id: "all", name: L("全部照片"))
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
        panel.prompt = L("重新授权")
        panel.message = L("选择源文件夹以恢复访问权限")
        guard let currentPath else { return }
        let currentURL = URL(fileURLWithPath: currentPath, isDirectory: true).standardizedFileURL
        if FileManager.default.fileExists(atPath: currentURL.path) {
            panel.directoryURL = currentURL
        }
    }

    func rebaseSourceRootAssetPaths(folderId: String, oldRoot: String, newRoot: String) {
        var edits: [(offset: Int, asset: Asset)] = []
        for offset in assets.indices where assets[offset].folderId == folderId {
            guard let path = assets[offset].localPath,
                  let replacement = VolumeMonitor.pathByReplacingVolumeRoot(in: path,
                                                                             oldRoot: oldRoot,
                                                                             newRoot: newRoot),
                  FileManager.default.fileExists(atPath: replacement) else { continue }
            var asset = assets[offset]
            asset.localPath = replacement
            asset.status = .ready
            edits.append((offset, asset))
        }
        guard !edits.isEmpty, persistChanged(edits.map(\.asset)) else { return }
        carryGeneratedFills(edits.map { (assets[$0.offset], $0.asset) })
        replaceInPlace(edits)
    }

    // ----- quick collection (B) -----
    static let quickCollectionID = "quick-collection"

    var quickCollectionCount: Int {
        guard !quickCollection.isEmpty else { return 0 }   // without building the id index
        let index = assetIndex, assets = self.assets
        return quickCollection.reduce(0) { count, id in count + (index[id].map { assets[$0].deleted ? 0 : 1 } ?? 0) }
    }

    /// B: adds the selection to the quick collection, or takes it out when all of it is in.
    @discardableResult
    func toggleQuickCollection() -> Bool {
        let ids = selectionTargetIds
        guard onboarded, !ids.isEmpty else { return false }
        let removing = ids.isSubset(of: quickCollection)
        // a save that failed has said so, and left the collection as it was
        guard setQuickCollection(removing ? quickCollection.subtracting(ids) : quickCollection.union(ids),
                                 undoName: removing ? L("移出快捷收藏") : L("加入快捷收藏")) else { return true }
        if removing {
            push("已从快捷收藏移除 \(ids.count) 张", "quick")
        } else {
            push("已加入快捷收藏 \(ids.count) 张", "quick")
        }
        return true
    }

    /// Saves the quick collection as `members`, then shows it; false when the save failed, which
    /// leaves it as it was (only the photos that change are written, so one kept in memory
    /// alone would never reach the catalog).
    @discardableResult
    private func setQuickCollection(_ members: Set<String>, undoName: String) -> Bool {
        let before = quickCollection
        guard members != before else { return true }
        if let store {
            do {
                // only the photos that came or went: the others' rows stay
                try store.updateAlbumMembers(albumId: Self.quickCollectionID, name: L("快捷收藏"), sortOrder: -1,
                                             adding: members.subtracting(before),
                                             removing: before.subtracting(members))
            } catch {
                push("快捷收藏保存失败", "warning")
                return false
            }
        }
        quickCollection = members
        registerUndoStep(undoName) { $0.setQuickCollection(before, undoName: undoName) }
        return true
    }

    func createAlbumFromSelection(in setId: String? = nil) {
        guard let name = promptAlbumName(defaultName: L("新建相册")) else { return }
        let album = Album(id: "al-" + UUID().uuidString.prefix(8), name: name,
                          assetIds: orderedTargetAssetIds())
        guard saveManualAlbum(album, sortOrder: albums.count) else { return }
        albums.append(album)
        if let setId { moveToAlbumSet(album.id, setId: setId) }
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
        alert.messageText = L("加入相册")
        alert.accessoryView = popup
        alert.addButton(withTitle: L("加入"))
        alert.addButton(withTitle: L("取消"))
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
                                         messageText: L("重命名相册"),
                                         confirmTitle: L("保存")) else { return }
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
        albums[index].name = name
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
            L("删除相册？"),
            L("只会删除相册「\(album.name)」及其目录库关系，不会删除任何照片或原件。"),
            L("删除相册")
        ) else { return }
        do {
            try store?.deleteAlbum(id: id)
        } catch {
            push("相册删除失败", "warning")
            return
        }
        albums.remove(at: index)
        pinnedSidebarItems.removeAll { $0.type == .album && $0.selectionId == id }
        if selection.type == .album, selection.id == id {
            selection = Selection(type: .lib, id: "all", name: L("全部照片"))
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
            L("删除智能相册？"),
            L("只会删除智能相册「\(album.name)」及其规则，不会删除任何照片或原件。"),
            L("删除智能相册")
        ) else { return }
        do {
            try store?.deleteSmartAlbum(id: id)
        } catch {
            push("智能相册删除失败", "warning")
            return
        }
        smartAlbums.remove(at: index)
        pinnedSidebarItems.removeAll { $0.type == .smart && $0.selectionId == id }
        if smartAlbumEditingID == id {
            dismissSmartAlbumBuilder()
        }
        if selection.type == .smart, selection.id == id {
            selection = Selection(type: .lib, id: "all", name: L("全部照片"))
            ensurePrimaryValid()
        }
        push("已删除智能相册「\(album.name)」", "trash")
    }

    // ---------- album sets ----------
    /// A new album set, at the top level or inside `parentId`.
    func createAlbumSet(in parentId: String? = nil) {
        guard let name = promptAlbumName(defaultName: L("新建相册集"), messageText: L("新建相册集")) else { return }
        let set = AlbumSet(id: "as-" + UUID().uuidString.prefix(8), name: name, parentId: parentId)
        do {
            try store?.saveAlbumSet(set, sortOrder: albumSets.count)
        } catch {
            push("相册集保存失败", "warning")
            return
        }
        albumSets.append(set)
        push("已创建相册集「\(name)」", "folder")
    }

    func renameAlbumSet(_ id: String) {
        guard let index = albumSets.firstIndex(where: { $0.id == id }),
              let name = promptAlbumName(defaultName: albumSets[index].name, messageText: L("重命名相册集"),
                                         confirmTitle: L("保存")),
              name != albumSets[index].name else { return }
        var set = albumSets[index]
        set.name = name
        do {
            try store?.saveAlbumSet(set, sortOrder: index)
        } catch {
            push("相册集保存失败", "warning")
            return
        }
        albumSets[index] = set
    }

    /// Deletes a set; the albums and sets in it move up to where the set was.
    func deleteAlbumSet(_ id: String) {
        guard let index = albumSets.firstIndex(where: { $0.id == id }) else { return }
        let set = albumSets[index]
        guard confirmDestructiveAction(
            L("删除相册集？"),
            L("相册集「\(set.name)」中的相册会移到上一层，不会删除任何相册或照片。"),
            L("删除相册集")
        ) else { return }
        do {
            try store?.deleteAlbumSet(id: id)
        } catch {
            push("相册集删除失败", "warning")
            return
        }
        for i in albums.indices where albums[i].setId == id { albums[i].setId = set.parentId }
        for i in smartAlbums.indices where smartAlbums[i].setId == id { smartAlbums[i].setId = set.parentId }
        for i in albumSets.indices where albumSets[i].parentId == id { albumSets[i].parentId = set.parentId }
        albumSets.removeAll { $0.id == id }
        push("已删除相册集「\(set.name)」", "trash")
    }

    /// Files an album, smart album or set into `setId` (nil: the top level). A set can't go
    /// into itself or a set inside it.
    func moveToAlbumSet(_ itemId: String, setId: String?) {
        if let setId, albumSetDescendants(of: itemId).contains(setId) || setId == itemId { return }
        do {
            try store?.setAlbumParent(id: itemId, parentId: setId)
        } catch {
            push("移动失败，目录库未保存", "warning")
            return
        }
        if let i = albums.firstIndex(where: { $0.id == itemId }) { albums[i].setId = setId }
        if let i = smartAlbums.firstIndex(where: { $0.id == itemId }) { smartAlbums[i].setId = setId }
        if let i = albumSets.firstIndex(where: { $0.id == itemId }) { albumSets[i].parentId = setId }
    }

    /// Every set nested inside `id`, however deep.
    func albumSetDescendants(of id: String) -> Set<String> {
        var found = Set<String>()
        var frontier = [id]
        while let current = frontier.popLast() {
            for set in albumSets where set.parentId == current && found.insert(set.id).inserted {
                frontier.append(set.id)
            }
        }
        return found
    }

    /// The sets an item can move into, in sidebar order with their depth: all but the item
    /// itself and the sets inside it.
    func albumSetChoices(for itemId: String) -> [(set: AlbumSet, depth: Int)] {
        let excluded = albumSetDescendants(of: itemId).union([itemId])
        var result: [(set: AlbumSet, depth: Int)] = []
        let known = Set(albumSets.map(\.id))
        func visit(_ parentId: String?, depth: Int) {
            for set in albumSets where !excluded.contains(set.id)
                && (set.parentId == parentId || (parentId == nil && set.parentId.map { !known.contains($0) } == true)) {
                result.append((set, depth))
                visit(set.id, depth: depth + 1)
            }
        }
        visit(nil, depth: 0)
        return result
    }

    private func orderedTargetAssetIds() -> [String] {
        let ids = selectionTargetIds
        let companions = assetPairing.companionsByPrimary
        let positions = listPositions(of: ids)
        return ids.compactMap { id in positions[id].map { (id, $0) } }.sorted { $0.1 < $1.1 }
            .flatMap { [$0.0] + (companions[$0.0] ?? []) }
    }

    func saveManualAlbum(_ album: Album, sortOrder: Int) -> Bool {
        guard let store else { return true }
        do {
            try store.saveAlbum(album, sortOrder: sortOrder)
            return true
        } catch {
            push("相册保存失败", "warning")
            return false
        }
    }

    func promptAlbumName(defaultName: String, messageText: String = L("新建相册"),
                                 confirmTitle: String = L("创建")) -> String? {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = defaultName
        let alert = NSAlert()
        alert.messageText = messageText
        alert.accessoryView = field
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: L("取消"))
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
        var seen = Set<String>()   // copies share a file
        return list.filter { ids.contains($0.id) }
            .flatMap { [$0] + (companions[$0.id] ?? []).compactMap { id in assetIndex[id].map { assets[$0] } } }
            .compactMap { $0.localPath }
            .filter { seen.insert($0).inserted && fm.fileExists(atPath: $0) }
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

    /// Whether Show in Finder is offered for a photo, from what the catalog knows of its original:
    /// views ask while they draw, so no file is looked at here (the action checks it).
    func canRevealOriginal(_ asset: Asset) -> Bool {
        !asset.isDemo && asset.status == .ready && asset.localPath != nil
    }

    func revealInFinder(_ id: String) {
        guard let asset = self.asset(id: id), let path = asset.localPath else {
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
        guard let selected = asset(id: id) else { return }
        // a virtual copy's file is its master's: relocate that, and the copies follow
        let asset = fileOwners([selected])[0]
        let id = asset.id
        guard !asset.isDemo else {
            push("演示照片没有本地原件", "warning")
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("重新定位")
        panel.message = L("选择移动后的原件文件，或选择包含该原件的新文件夹。")
        guard panel.runModal() == .OK, let selected = panel.url else { return }

        guard let replacement = RelocationService.replacement(for: asset, selected: selected) else {
            push("未找到匹配的原件", "warning")
            return
        }
        FileAccessService.remember(selected, for: .originals)

        let attrs = try? FileManager.default.attributesOfItem(atPath: replacement.path)
        let size = (attrs?[.size] as? Int64) ?? 0
        let meta = MetadataReader.read(replacement)
        guard mutateAsset(id, {
            $0.localPath = replacement.path
            $0.filename = replacement.lastPathComponent
            $0.fileMB = Asset.megabytes(bytes: size)
            $0.fileModifiedAt = attrs?[.modificationDate] as? Date
            $0.fileCreatedAt = attrs?[.creationDate] as? Date
            $0.hasICCProfile = meta.hasICCProfile
            $0.gpsAltitude = meta.gpsAltitude
            $0.quickHash = HashService.quickHash(replacement, fileSize: size)
            $0.contentHash = HashService.contentHash(replacement)
            $0.status = .ready
        }) else { return }
        if let relinked = assetIndex[id].map({ assets[$0] }) {
            carryGeneratedFills([(asset, relinked)])
            var copies: [(offset: Int, asset: Asset)] = []
            carryFileChanges(from: [relinked], into: &copies)
            if !copies.isEmpty, persistChanged(copies.map(\.asset)) {
                carryGeneratedFills(copies.map { (assets[$0.offset], $0.asset) })
                replaceInPlace(copies)
            }
        }
        recomputeDuplicates()
        push("已重新定位原件", "link")
    }

    func addKeyword(_ kw: String) {
        let keywords = KeywordService.normalize(kw)
        guard !keywords.isEmpty else { return }
        mutate(undoName: L("添加关键词")) {
            for keyword in keywords where !$0.keywords.contains(keyword) {
                $0.keywords.append(keyword)
            }
        }
    }
    func removeKeyword(_ kw: String) {
        mutate(undoName: L("移除关键词")) { $0.keywords.removeAll { $0 == kw } }
    }
}
