import AppKit
import Foundation

@MainActor
extension AppState {
    // ---------- virtual copies ----------
    /// ⌘': a virtual copy of each selected photo — another catalog entry for the same original,
    /// starting from its metadata and develop settings, to take in another direction. A copy of
    /// a copy belongs to the same master. Copies made inside an album join it. Undoable.
    func createVirtualCopies() {
        let ids = selectionTargetIds
        let sources = list.filter { ids.contains($0.id) && !$0.isDemo && !$0.deleted }
        guard !sources.isEmpty else {
            push("只能为已导入的照片创建虚拟副本", "warning")
            return
        }
        // copy numbers keep counting per master, removed copies included, so a name never repeats
        var numbers: [String: Int] = [:]
        for asset in assets { if let masterId = asset.masterId { numbers[masterId, default: 0] += 1 } }
        var copies: [Asset] = []
        var settings: [String: DevelopSettings] = [:]
        for source in sources {
            let masterId = source.masterId ?? source.id
            numbers[masterId, default: 0] += 1
            let id = "v" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
            copies.append(source.virtualCopy(id: id, name: L("副本 \(numbers[masterId] ?? 1)")))
            if let edit = developSettings[source.id] { settings[id] = edit }
        }
        do {
            try store?.saveVirtualCopies(copies, developSettings: settings)
        } catch {
            push("创建虚拟副本失败，目录库未保存", "warning")
            return
        }
        for (id, edit) in settings { developSettings[id] = edit }
        appendAssets(copies)
        let copyIds = copies.map(\.id)
        if selection.type == .album, let index = albums.firstIndex(where: { $0.id == selection.id }) {
            var album = albums[index]
            album.assetIds.append(contentsOf: copyIds)
            if saveManualAlbum(album, sortOrder: index) { albums[index] = album }
        }
        selectedIds = Set(copyIds)
        setPrimary(copyIds[0])
        if let undoManager {
            UndoSteps.register(on: undoManager) {
                undoManager.registerUndo(withTarget: self) { app in
                    MainActor.assumeIsolated {
                        _ = app.mutate(Set(copyIds), undoName: L("创建虚拟副本")) { $0.deleted = true }
                        app.ensurePrimaryValid()
                    }
                }
                undoManager.setActionName(L("创建虚拟副本"))
            }
        }
        push(copies.count == 1 ? "已创建\(copies[0].copyName ?? "")" : "已创建 \(copies.count) 个虚拟副本", "copy")
    }

    var canCreateVirtualCopies: Bool { canTransformSelection }

    // ---------- batch rename (§4.2) ----------
    /// Rename selected originals from a token template ({seq}/{date}/{time}/{camera}/{original}).
    /// A plain prefix with no token becomes "<prefix>_{seq}".
    /// The photos a rename reaches, in list order and one per file (a virtual copy renames its
    /// master's file), with their originals on disk.
    func renameTargets() -> [Asset] {
        let ids = selectionTargetIds
        return fileOwners(list.filter { ids.contains($0.id) }).filter(hasExistingOriginal)
    }

    var canRenameOriginals: Bool {
        onboarded && sheet == nil && view != .analysis && canOperateOnSelectedOriginals
    }

    /// The last rename template, offered again next time.
    var renameTemplate: String {
        get { UserDefaults.app.string(forKey: "pc_renameTemplate") ?? "{original}" }
        set { UserDefaults.app.set(newValue, forKey: "pc_renameTemplate") }
    }

    /// 照片 → 重命名照片…: the rename dialog, with a preview of the new names.
    func showRenameSheet() {
        // Settings, a window of its own, offers this too: never in place of a dialog already up
        guard onboarded, sheet == nil else { return }
        let targets = renameTargets()
        guard !targets.isEmpty else {
            push("仅可重命名已导入照片", "warning")
            return
        }
        renameSheetTargets = targets
        sheet = "rename"
    }

    /// Renames the originals of `targets` (the selection's by default) from `template`,
    /// numbering from `start`; a paired JPEG takes its RAW's new name, sidecars go along, and
    /// virtual copies follow their master. The dialog asked.
    func renameOriginals(template rawTemplate: String, start: Int = 1, targets: [Asset]? = nil) {
        let trimmed = rawTemplate.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // a plain prefix numbers the photos after it
        let template = trimmed.contains("{") ? trimmed : "\(trimmed)_{seq}"
        renameTemplate = trimmed
        // the photos as they are now (a rescan may have changed them since the dialog opened)
        let chosen = (targets ?? renameTargets()).compactMap { assetIndex[$0.id].map { assets[$0] } }
            .filter { !$0.deleted && hasExistingOriginal($0) }
        guard !chosen.isEmpty else { push("仅可重命名已导入照片", "warning"); return }
        // renaming changes the folder, so it must be writable
        let real = chosen.filter { asset in
            asset.localPath.map { FileManager.default.isWritableFile(atPath: ($0 as NSString).deletingLastPathComponent) }
                ?? false
        }
        if real.count < chosen.count {
            push("\(chosen.count - real.count) 张照片所在的文件夹是只读的，无法重命名", "warning")
        }
        guard !real.isEmpty else { return }
        // a paired JPEG takes the RAW's new base name so the pair survives the rename
        let partners = Dictionary(uniqueKeysWithValues: real.map { primary in
            (primary.id, companions(of: primary).filter(hasExistingOriginal))
        }).filter { !$0.value.isEmpty }
        let fileCount = real.count + partners.values.reduce(0) { $0 + $1.count }
        let map = RenameService.renameWithTemplate(real, template: template, start: start, companions: partners)
        guard !map.isEmpty else {
            push("重命名失败", "warning")
            return
        }

        guard applyRenamedOriginals(map) else {
            let rolledBack = OriginalFileOperationService.rollBackMoves(
                map, originals: real + partners.values.flatMap { $0 })
            push(verbatim: L("重命名未完成")
                 + (rolledBack > 0 ? L(" · 已回滚 \(rolledBack) 张照片") : L(" · 回滚失败"))
                 + L(" · 目录库保存失败"),
                 "warning")
            return
        }
        let saved = map.count
        push(verbatim: L("已重命名 \(saved) 个文件") + (saved < fileCount ? L(" · \(fileCount - saved) 失败") : ""),
             saved < fileCount ? "warning" : "check")
    }

    /// Gives the photos renamed on disk (by id) their new names, their virtual copies with them,
    /// and saves them; false, and nothing changed, when the catalog couldn't be saved.
    func applyRenamedOriginals(_ map: [String: URL]) -> Bool {
        var edits = positions(of: Set(map.keys)).map { offset -> (offset: Int, asset: Asset) in
            var asset = assets[offset]
            if let url = map[asset.id] {
                asset.filename = url.lastPathComponent
                asset.localPath = url.path
            }
            return (offset, asset)
        }
        carryFileChanges(from: edits.map(\.asset), into: &edits)
        guard persistChanged(edits.map(\.asset)) else { return false }
        carryGeneratedFills(edits.map { (assets[$0.offset], $0.asset) })
        replaceInPlace(edits)
        return true
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
        panel.prompt = operation == .move ? L("移动到此处") : L("复制到此处")
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        if operation == .move { FileAccessService.remember(destination, for: .originals) }

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

    /// The selection's originals on disk, one entry per file. A virtual copy stands for its
    /// master's file where the operation reaches the file (move, copy, export); where it would
    /// destroy the file (trash), copies are left out — they're only catalog entries.
    func selectedRealAssetsWithOriginals(copiesStandForMaster: Bool = true) -> [Asset] {
        let ids = targetIds
        let selected = assets.filter { ids.contains($0.id) }
        return (copiesStandForMaster ? fileOwners(selected) : selected.filter { !$0.isVirtualCopy })
            .filter(hasExistingOriginal)
    }

    /// The photos owning the files behind `selected`, in order and each once: a virtual copy's
    /// file is its master's (the copy itself stands in only when its master is gone).
    func fileOwners(_ selected: [Asset]) -> [Asset] {
        var seen = Set<String>()
        var owners: [Asset] = []
        for asset in selected {
            var owner = asset
            if let masterId = asset.masterId, let index = assetIndex[masterId], !assets[index].deleted {
                owner = assets[index]
            }
            if seen.insert(owner.id).inserted { owners.append(owner) }
        }
        return owners
    }

    /// Live virtual copies of the given photos.
    func virtualCopyIds(of ids: Set<String>) -> Set<String> {
        guard !ids.isEmpty else { return [] }
        return Set(assets.lazy.filter { !$0.deleted && $0.masterId.map(ids.contains) == true }.map(\.id))
    }

    /// Gives each virtual copy of `masters` (photos as they are or are about to be) its master's
    /// file path, name and state: an edit beside `edits`, or a change to the copy's edit among
    /// them. Returns the copies changed.
    @discardableResult
    func carryFileChanges(from masters: [Asset], into edits: inout [(offset: Int, asset: Asset)]) -> Set<String> {
        let byId = Dictionary(masters.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        guard !byId.isEmpty else { return [] }
        var editAt: [Int: Int]?   // a position's edit among `edits`, made once there's a copy
        var changed = Set<String>()
        for offset in assets.indices {
            // a photo's master read without hashing its id: most photos are no one's copy
            guard let masterId = assets[offset].masterId, let master = byId[masterId] else { continue }
            if editAt == nil {
                editAt = Dictionary(edits.enumerated().map { ($1.offset, $0) }, uniquingKeysWith: { first, _ in first })
            }
            var copy = editAt?[offset].map { edits[$0].asset } ?? assets[offset]
            copy.filename = master.filename
            copy.localPath = master.localPath
            copy.fileMB = master.fileMB
            copy.fileModifiedAt = master.fileModifiedAt
            copy.fileCreatedAt = master.fileCreatedAt
            copy.quickHash = master.quickHash
            copy.contentHash = master.contentHash
            copy.status = master.status
            if let slot = editAt?[offset] {
                edits[slot].asset = copy
            } else {
                editAt?[offset] = edits.count
                edits.append((offset, copy))
            }
            changed.insert(copy.id)
        }
        return changed
    }

    func hasExistingOriginal(_ asset: Asset) -> Bool {
        guard !asset.deleted, !asset.isDemo, let path = asset.localPath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    func selectedAssetsWithExportablePreviews() -> [Asset] {
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
        alert.messageText = operation == .move ? L("移动原件") : L("复制原件")
        alert.informativeText = operation == .move
            ? L("将移动 \(count) 个磁盘原件，并更新目录库中的文件路径。")
            : L("将复制 \(count) 个磁盘原件，目录库中的文件路径保持不变。")
        alert.addButton(withTitle: operation == .move ? L("移动") : L("复制"))
        alert.addButton(withTitle: L("取消"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    @discardableResult
    func applyMovedOriginalLocations(_ locations: [String: URL], expectedCatalogURL: URL? = nil) -> Bool {
        guard !locations.isEmpty else { return true }
        if let expectedCatalogURL, store?.packageURL != expectedCatalogURL { return false }
        var edits = positions(of: Set(locations.keys)).map { offset -> (offset: Int, asset: Asset) in
            var asset = assets[offset]
            if let url = locations[asset.id] {
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                asset.filename = url.lastPathComponent
                asset.localPath = url.path
                asset.fileModifiedAt = attrs?[.modificationDate] as? Date
                asset.fileCreatedAt = attrs?[.creationDate] as? Date
                asset.status = .ready
            }
            return (offset, asset)
        }
        carryFileChanges(from: edits.map(\.asset), into: &edits)
        guard persistChanged(edits.map(\.asset)) else { return false }
        carryGeneratedFills(edits.map { (assets[$0.offset], $0.asset) })
        replaceInPlace(edits)
        return true
    }

    /// Photos whose file moved (each as it was and as it is now) take their generative fills
    /// along — those of their edit, history and snapshots — off the main thread. A fill left under
    /// the old path would be made again by the next render, and a full backup, which never makes
    /// one, would stop for want of it.
    func carryGeneratedFills(_ changes: [(before: Asset, after: Asset)]) {
        var moves: [(id: String, from: String, modified: Date?, to: String)] = []
        for (before, after) in changes {
            guard before.id == after.id,
                  let from = before.localPath, let to = after.localPath, from != to else { continue }
            moves.append((after.id, from, before.fileModifiedAt, to))
        }
        guard !moves.isEmpty, let store else { return }
        let edits = moves.reduce(into: [String: DevelopSettings]()) { $0[$1.id] = developSettings[$1.id] }
        let directory = generatedFillFolder
        Task.detached(priority: .utility) { [moves, edits, store, directory] in
            for move in moves {
                var settings = edits[move.id].map { [$0] } ?? []
                settings += ((try? store.loadDevelopHistory(move.id)) ?? []).map(\.settings)
                settings += ((try? store.loadDevelopSnapshots(move.id)) ?? []).map(\.settings)
                guard settings.contains(where: { $0.spots.contains { $0.mode == .remove } }) else { continue }
                GenerativeFill.carry(settings, from: move.from, modified: [move.modified],
                                     to: URL(fileURLWithPath: move.to), in: directory)
            }
        }
    }

    private func pushOriginalFileOperationReport(_ report: OriginalFileOperationReport,
                                                 operation: OriginalFileOperation,
                                                 persistenceFailed: Bool = false,
                                                 rolledBack: Int = 0) {
        if operation == .move, persistenceFailed {
            push(verbatim: L("移动未完成")
                 + (rolledBack > 0 ? L(" · 已回滚 \(rolledBack) 个原件") : L(" · 回滚失败"))
                 + L(" · 目录库保存失败"),
                 "warning")
            return
        }
        let completed = operation == .move ? report.moved : report.copied
        let done = operation == .move ? L("已移动 \(completed) 个原件") : L("已复制 \(completed) 个原件")
        push(verbatim: done
             + (report.failed > 0 ? L(" · \(report.failed) 失败") : "")
             + (report.skipped > 0 ? L(" · \(report.skipped) 跳过") : "")
             + (persistenceFailed ? L(" · 目录库保存失败") : ""),
             report.failed > 0 || persistenceFailed ? "warning" : "check")
    }
}
