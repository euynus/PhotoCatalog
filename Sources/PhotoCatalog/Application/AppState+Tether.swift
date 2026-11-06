import AppKit
import Foundation

@MainActor
extension AppState {
    // ---------- tethered capture ----------
    /// A running tethered session, as its bar shows it.
    struct TetherStatus: Equatable {
        var folder: URL
        var sourceName: String
        var canCapture: Bool
        var shots = 0
        var lastName: String?
        var failed = 0
        var working = false
    }

    func showTether() {
        guard sheet == nil, onboarded else { return }
        startDeviceBrowsing()
        sheet = "tether"
    }

    /// Starts a session with `settings`, taking shots from `camera`, or with none from the
    /// settings' watched folder.
    @discardableResult
    func startTether(_ settings: TetherSettings, camera: CameraDevice?) -> Bool {
        if let camera { return startTether(settings, source: CameraTetherSource(device: camera)) }
        guard !settings.watchedFolderPath.isEmpty else {
            push("请选择相机或要监视的文件夹", "warning")
            return false
        }
        let watched = URL(fileURLWithPath: settings.watchedFolderPath)
        FileAccessService.reach(watched)
        return startTether(settings, source: FolderTetherSource(folder: watched))
    }

    /// Starts a session taking shots from `source`. The session's folder is cataloged in place
    /// (referenced), whatever the import mode, since each shot is already where it belongs.
    @discardableResult
    func startTether(_ settings: TetherSettings, source: any TetherSource) -> Bool {
        guard tether == nil else {
            push("联机拍摄已在进行", "warning")
            return false
        }
        guard !importing else {
            push("已有导入任务正在运行", "warning")
            return false
        }
        guard !refusesImportWhileCatalogLoads() else { return false }
        openOrCreateCatalog()
        guard let coordinator, store != nil else { return false }
        FileAccessService.reach(URL(fileURLWithPath: settings.destinationPath))
        let folder = URL(fileURLWithPath: settings.destinationPath).appendingPathComponent(settings.folderName(), isDirectory: true)
            .standardizedFileURL
        if !settings.watchedFolderPath.isEmpty, source is FolderTetherSource {
            // shots moved into the folder being watched would come round again
            let watched = URL(fileURLWithPath: settings.watchedFolderPath).standardizedFileURL.path
            guard !Self.path(folder.path, isIn: watched) else {
                push("会话文件夹不能在监视的文件夹里", "warning")
                return false
            }
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            push(verbatim: L("无法创建会话文件夹：\(error.localizedDescription)"), "warning")
            return false
        }
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        tetherNamer = TetherNamer(session: settings.folderName(), naming: settings.naming, existing: existing)
        tetherPreset = settings.presetId.isEmpty ? nil : allDevelopPresets.first { $0.id == settings.presetId }
        let folderNames = Dictionary(folders.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        tetherRoot = sourceRootPathsById
            .filter { Self.path(folder.path, isIn: URL(fileURLWithPath: $0.value).standardizedFileURL.path) }
            .max { $0.value.count < $1.value.count }
            .map { ($0.key, folderNames[$0.key] ?? URL(fileURLWithPath: $0.value).lastPathComponent) }
        tetherFolderRegistered = tetherRoot != nil || sourceRootPathsById[coordinator.sourceId(forFolder: folder)] != nil
        tetherQueue = []
        guard source.start(onShot: { [weak self] in self?.enqueueTetherShot($0) },
                           onEnd: { [weak self] in self?.endTether(reason: $0) }) else {
            push("无法开始联机拍摄", "warning")
            return false
        }
        tetherSettings = settings
        tetherSource = source
        tether = TetherStatus(folder: folder, sourceName: source.name, canCapture: source.canCapture)
        return true
    }

    func captureTether() { tetherSource?.capture() }

    /// The preset the session's next shots get ("" for none).
    func setTetherPreset(_ id: String) {
        tetherSettings.presetId = id
        tetherPreset = id.isEmpty ? nil : allDevelopPresets.first { $0.id == id }
    }

    /// Ends the session (`reason`: why, when it wasn't asked to). Its folder is watched from now
    /// on, like any imported folder.
    func endTether(reason: String? = nil) {
        guard let status = tether else { return }
        tetherSource?.stop()
        tetherSource = nil
        tetherQueue = []
        tether = nil
        if status.shots > 0, tetherRoot == nil, !watchedRoots.contains(status.folder) {
            watchedRoots.append(status.folder)
            refreshWatcher()
        }
        push(verbatim: (reason.map { $0 + " · " } ?? "") + L("联机拍摄已结束：\(status.shots) 张"), reason == nil ? "check" : "warning")
    }

    private func enqueueTetherShot(_ shot: TetherShot) {
        tetherQueue.append(shot)
        processTetherQueue()
    }

    /// One shot at a time, in the order they came: put in the session's folder under its name,
    /// imported, shown.
    private func processTetherQueue() {
        guard var status = tether, !status.working, !tetherQueue.isEmpty, let coordinator else { return }
        let shot = tetherQueue.removeFirst()
        let target = status.folder.appendingPathComponent(tetherNamer.name(for: shot.originalName))
        status.working = true
        tether = status
        let folder = status.folder, root = tetherRoot, catalog = store
        let vision = visionEnabled, previewSize = previewMaxPixel, readXMP = readXMPSidecar
        Task { [weak self] in
            let imported = await Task.detached(priority: .userInitiated) { () -> [Asset]? in
                do { try shot.deliver(target) } catch { return nil }
                // a shot is a new photo, even where a removed (trashed) one was
                return coordinator.importFiles([target], from: folder, mode: .referenced, autoTag: vision,
                                               readSidecar: readXMP, previewMaxPixel: previewSize,
                                               sourceRootId: root?.id, folderName: root?.name,
                                               reusingRemovedIds: false)
            }.value
            // its catalog was closed meanwhile (and the session with it): the shot stays in the
            // session's folder, out of whichever catalog is open now
            guard let self, self.store === catalog else { return }
            if self.tether?.folder == folder { self.tether?.working = false }
            if let imported, !imported.isEmpty {
                self.addTetheredShots(imported, folder: folder, name: target.lastPathComponent)
            } else {
                if self.tether?.folder == folder { self.tether?.failed += 1 }
                self.push(verbatim: L("未能导入 \(shot.originalName)"), "warning")
            }
            self.processTetherQueue()
        }
    }

    /// A shot's photos into the catalog, with the session's keywords and preset, and on screen.
    private func addTetheredShots(_ imported: [Asset], folder: URL, name: String) {
        guard let store, let coordinator else { return }
        let known = Set(assets.map(\.id))
        let fresh = ImportPostActionService.apply(to: imported.filter { !known.contains($0.id) }, actions: ImportPostActions(
            keywords: ImportPostActionService.normalizeKeywords(tetherSettings.keywords), colorLabel: nil,
            author: importAuthor, copyright: importCopyright))
        guard let newest = fresh.last else { return }
        // the session's folder becomes a source folder of its own, saved with its first shot
        let root = tetherFolderRegistered ? nil : SourceRootRecord(
            id: coordinator.sourceId(forFolder: folder), displayName: folder.lastPathComponent, pathHint: folder.path,
            bookmarkData: FileAccessService.createBookmark(for: folder), managementMode: ImportMode.referenced.rawValue,
            status: "online", volumeIdentifier: VolumeMonitor.volumeIdentifier(for: folder))
        do {
            try store.upsert(fresh, addingSourceRoot: root)
        } catch {
            push("联机拍摄的照片未能保存到目录库", "warning")
            return
        }
        if let root {
            tetherFolderRegistered = true
            sourceManagementModesById[root.id] = root.managementMode
            setSourceFolder(id: root.id, name: root.displayName, path: root.pathHint, status: root.status)
        }
        appendAssets(fresh)
        recordSidecarBaselines(fresh)
        applyImportDevelopSettings(to: fresh, preset: tetherPreset)
        recomputeDuplicates()
        var first = false
        if var status = tether, status.folder == folder {
            first = status.shots == 0
            status.shots += 1
            status.lastName = name
            tether = status
        }
        // the newest shot on screen, as in Lightroom (not from under a dialog)
        guard sheet == nil else { return }
        if selection.type != .folder || selection.id != newest.folderId {
            select(Selection(type: .folder, id: newest.folderId, name: newest.folderName))
        }
        // a JPEG shot with a RAW shows on the RAW's tile, already selected
        if list.contains(where: { $0.id == newest.id }) { setPrimary(newest.id) }
        if first, view == .grid { switchView(.loupe) }
    }
}
