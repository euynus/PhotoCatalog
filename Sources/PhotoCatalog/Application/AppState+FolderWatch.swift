import AppKit
import CoreServices
import Foundation

@MainActor
extension AppState {
    // ---------- FSEvents incremental watch (§12.8) ----------
    func refreshWatcher() {
        watcher?.stop()
        let paths = prioritizedWatchedRoots(watchedRoots).map { $0.path }
        guard !paths.isEmpty else { watcher = nil; return }
        let w = FileWatcher(paths: paths) { [weak self] events in self?.watchedFilesChanged(events) }
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

    /// FSEvents reported `events` in a watched folder. A batch of only sidecars and hidden files
    /// (an app's XMP save, Finder's .DS_Store, a copy's partial file) can't hold a photo the scan
    /// would take, so only the sidecars are checked. Nor can it make an original go missing: an
    /// original deleted or moved has an event of its own. (With Write XMP automatically on, each
    /// rating writes a sidecar, and the availability scan, which looks at every original, would
    /// start over for each.) Otherwise the rescan reads again only the files the batch names,
    /// unless it may have missed some (see `hashedPaths`).
    func watchedFilesChanged(_ events: [FileWatcher.Event]) {
        if !events.isEmpty && events.allSatisfy({ Self.cannotHoldPhotos($0.path, flags: $0.flags) }) {
            checkExternalXMPChanges()
        } else {
            incrementalRescan(hashing: Self.hashedPaths(for: events))
        }
    }

    /// Whether a changed path is one the folder scan never takes: a hidden file (it skips them)
    /// or a sidecar. Only the last component counts, so a folder under a hidden one still does;
    /// a folder's event, or one that may stand for changes missed, never passes.
    nonisolated static func cannotHoldPhotos(_ path: String, flags: FSEventStreamEventFlags = 0) -> Bool {
        guard flags & (missedChangeFlags | FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)) == 0 else {
            return false
        }
        let name = (path as NSString).lastPathComponent
        return name.hasPrefix(".") || (name as NSString).pathExtension.lowercased() == "xmp"
    }

    /// The paths whose files a rescan for `events` quick-hashes, the others compared by size and
    /// modification time only; nil, every file, when the batch may not name each change: events
    /// were dropped or merged into a folder's, a watched folder moved or a drive came or went, or
    /// an event is a folder's (files moved in with it have no events of their own).
    nonisolated static func hashedPaths(for events: [FileWatcher.Event]) -> Set<String>? {
        guard !events.isEmpty else { return nil }
        let itemTypes = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemIsDir
            | kFSEventStreamEventFlagItemIsSymlink | kFSEventStreamEventFlagItemIsHardlink
            | kFSEventStreamEventFlagItemIsLastHardlink)
        var paths = Set<String>()
        for event in events {
            guard event.flags & missedChangeFlags == 0,
                  event.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) == 0 else { return nil }
            // an event that doesn't say what it names is asked of the disk
            if event.flags & itemTypes == 0 {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: event.path, isDirectory: &isDirectory),
                   isDirectory.boolValue { return nil }
            }
            paths.insert(event.path)
        }
        return paths
    }

    /// Event flags that say changes may have gone unreported: the folder is to be looked at whole.
    nonisolated private static var missedChangeFlags: FSEventStreamEventFlags {
        FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged
            | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
    }

    /// Reads the watched folders for new and changed originals. `hashing` nil quick-hashes every
    /// cataloged file to find a change; a set, only the files with a path in it, the others
    /// changed when their size or modification time is.
    private func incrementalRescan(hashing: Set<String>? = nil) {
        guard let coordinator, let store else { return }
        if isIncrementalRescanning {
            // the rescan queued behind hashes every file: the events it stands for aren't kept
            needsIncrementalRescan = true
            return
        }
        isIncrementalRescanning = true
        incrementalRescanGeneration &+= 1
        let generation = incrementalRescanGeneration
        let roots = prioritizedWatchedRoots(watchedRoots)
        let snapshot = assets   // shared, not copied: filtered off the main thread
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
        let volumesById = sourceRootRecordsById(from: store).compactMapValues(\.volumeIdentifier)
        let probe = volumeProbe
        // the photos read off the main thread are let go of once read: still held while the
        // results go in, they'd be copied whole by the first change in place
        let scan = Task.detached(priority: .utility) { [coordinator, store, roots, snapshot, vision, previewSize,
                                                         readXMP, sourceInfoByPath, volumesById, probe, hashing] in
            // build the path index off the main thread (resolvingSymlinksInPath stats each asset)
            var knownAssetsByPath: [String: Asset] = [:]
            // a path belongs to the photo that owns the file, never to its virtual copies
            for asset in snapshot where !asset.deleted && !asset.isVirtualCopy {
                if let path = asset.localPath {
                    for alias in PathIdentity.aliases(forPath: path) {
                        knownAssetsByPath[alias] = asset
                    }
                }
            }
            // the paths a rescan doesn't add, each with its aliases, made once for every root (the
            // index's keys are aliases already, and an alias's aliases are among its path's)
            var knownAliases = Set(knownAssetsByPath.keys)
            // files an import skipped as exact duplicates of photos it cataloged stay out
            for path in (try? store.skippedDuplicatePaths()) ?? [] {
                knownAliases.formUnion(PathIdentity.aliases(forPath: path))
            }
            // a photo removed from the catalog stays removed: its file, there still or saved over
            // by an editor, isn't a new one (only an import brings it back); another photo saved
            // at its path is. Removed in an earlier session, it isn't in `snapshot`.
            var removedByPath: [String: [Asset]] = [:]
            var removedIds: Set<String> = []
            let removedEarlier = (try? store.removedOriginals()) ?? []
            for asset in snapshot.filter({ $0.deleted && !$0.isVirtualCopy }) + removedEarlier
            where removedIds.insert(asset.id).inserted {
                guard let path = asset.localPath else { continue }
                for alias in PathIdentity.aliases(forPath: path) { removedByPath[alias, default: []].append(asset) }
            }
            var fresh: [Asset] = []
            var changed: [Asset] = []
            // a folder watched inside another is walked by both: each file goes to the first
            var claimed: Set<String> = []
            for root in roots {
                let sourceInfo = PathIdentity.aliases(for: root).lazy.compactMap { sourceInfoByPath[$0] }.first
                // a folder whose drive isn't the one mounted at its path now (another drive
                // took that drive's name) isn't read: its files aren't the folder's
                if let id = sourceInfo?.id, let volume = volumesById[id],
                   ![.mounted, .unchecked].contains(probe.placement(of: root.path, onVolume: volume)) { continue }
                let scanned = ImportCoordinator.scanWithAliases(root).filter { $0.aliases.isDisjoint(with: claimed) }
                for file in scanned { claimed.formUnion(file.aliases) }
                for file in scanned {
                    let removed = file.aliases.flatMap { removedByPath[$0] ?? [] }
                    if removed.contains(where: { ImportCoordinator.isRemovedPhoto(file.url, removed: $0) }) {
                        knownAliases.formUnion(file.aliases)
                    }
                }
                fresh.append(contentsOf: coordinator.scanNew(in: root, knownAliases: knownAliases,
                                                             mode: .referenced, autoTag: vision,
                                                             readSidecar: readXMP,
                                                             previewMaxPixel: previewSize,
                                                             sourceRootId: sourceInfo?.id,
                                                             folderName: sourceInfo?.name, scanned: scanned))
                changed.append(contentsOf: coordinator.scanChanged(in: root,
                                                                   knownAssetsByPath: knownAssetsByPath,
                                                                   mode: .referenced,
                                                                   autoTag: vision,
                                                                   previewMaxPixel: previewSize,
                                                                   sourceRootId: sourceInfo?.id,
                                                                   folderName: sourceInfo?.name,
                                                                   scanned: scanned, hashing: hashing))
            }
            // the photo a rescan reads is never a removed one, whatever the file turned out to be
            return (fresh: fresh.filter { !removedIds.contains($0.id) }, changed: changed)
        }
        Task { [weak self, scan, store, vision] in
            let delta = await scan.value
            guard let self else { return }
            guard self.incrementalRescanGeneration == generation else { return }
            defer {
                self.isIncrementalRescanning = false
                if self.needsIncrementalRescan {
                    self.needsIncrementalRescan = false
                    self.incrementalRescan()
                }
            }
            let indexById = self.assetIndex
            var freshIds: Set<String> = []
            let trulyNew = delta.fresh.filter { indexById[$0.id] == nil && freshIds.insert($0.id).inserted }
            // read against the snapshot: what the files hold goes onto the photos as they are now,
            // so an edit made meanwhile stays and a photo removed meanwhile stays removed (each read
            // where it is: a copy of the photos held on would be copied whole by the change)
            let changedAssets = delta.changed.compactMap { refreshed -> Asset? in
                guard let index = indexById[refreshed.id] else { return nil }
                let current = self.assets[index]
                guard !current.deleted else { return nil }
                return ImportCoordinator.preservingCatalogMetadata(from: current, in: refreshed, autoTag: vision)
            }
            if !trulyNew.isEmpty || !changedAssets.isEmpty {
                // the changed files in place of what they were, the new ones after the others
                var edits = changedAssets.compactMap { asset in indexById[asset.id].map { (offset: $0, asset: asset) } }
                // the changed files' virtual copies take on their new state too
                self.carryFileChanges(from: changedAssets, into: &edits)
                // saved together, so a copy is never shown with a state the catalog didn't keep
                do {
                    try store.upsert(trulyNew + edits.map(\.asset))
                } catch {
                    self.push("重新扫描保存失败", "warning")
                    return
                }
                self.replaceInPlace(edits)
                if !trulyNew.isEmpty { self.appendAssets(trulyNew) }
                self.recordSidecarBaselines(trulyNew)
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
            self.checkExternalXMPChanges()
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
        let probe = volumeProbe
        isCheckingOriginals = true

        // the photos read off the main thread are let go of once read: still held while the
        // results go in, they'd be copied whole by the first change in place
        let worker = Task.detached(priority: .utility) { [store, snapshot, sourceRootsById, probe]
            () -> ([AssetAvailabilityUpdate]?, Bool) in
            guard let changes = AssetAvailabilityService.changes(
                in: snapshot,
                sourceRootsById: sourceRootsById,
                probe: probe
            ) else { return (nil, true) }
            guard !Task.isCancelled else { return (nil, true) }
            do {
                try store.updateAssetAvailability(changes)
                return (changes, true)
            } catch {
                return (changes, false)
            }
        }
        availabilityScanTask = Task { [weak self, worker] in
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

            self.applyAvailabilityChanges(changes)
            self.flushPendingXMPWrites()
        }
    }

    /// Puts what a check of the originals found (saved already) on the photos: each one's status
    /// and path, and its source folder's status with them.
    func applyAvailabilityChanges(_ changes: [AssetAvailabilityUpdate]) {
        // found by the id index while every photo's id is its own, else in a pass (a photo listed
        // twice gets a change for each listing, both alike)
        let index = assetIndex
        var found: [(offset: Int, change: AssetAvailabilityUpdate)] = []
        if index.count == assets.count {
            var seen = [Bool](repeating: false, count: assets.count)
            for change in changes {
                guard let offset = index[change.assetId], !seen[offset] else { continue }
                seen[offset] = true
                found.append((offset, change))
            }
        } else {
            let changesById = Dictionary(changes.map { ($0.assetId, $0) }, uniquingKeysWith: { first, _ in first })
            found = assets.indices.compactMap { offset in changesById[assets[offset].id].map { (offset, $0) } }
        }
        // read from the photos handed in (not each through the observed property), which are let go
        // of before the edits are written
        func edits(of photos: [Asset]) -> (edits: [(offset: Int, asset: Asset)], moved: [(before: Asset, after: Asset)]) {
            var edits: [(offset: Int, asset: Asset)] = [], moved: [(before: Asset, after: Asset)] = []
            for (offset, change) in found {
                let before = photos[offset]
                guard before.status != change.status || before.localPath != change.localPath else { continue }
                var asset = before
                asset.status = change.status
                asset.localPath = change.localPath
                edits.append((offset, asset))
                if before.localPath != asset.localPath { moved.append((before, asset)) }
            }
            return (edits, moved)
        }
        let (edits, moved) = edits(of: assets)
        // a drive back under another name: its photos' fills come along
        carryGeneratedFills(moved)
        replaceInPlace(edits)
        updateFolderStatusesFromAssets()
    }

    private func updateFolderStatusesFromAssets() {
        let summaries = Self.folderSummaries(assets)
        for i in folders.indices {
            // a folder with no photos keeps the status it had
            guard let status = summaries[folders[i].id]?.status else { continue }
            if folders[i].status != status {
                folders[i].status = status
            }
        }
    }

    /// Each source folder's name (its first photo's) and worst original status (offline, then
    /// missing, else online), in one pass — per-folder scans were 20M comparisons at 500k photos.
    /// Counted in chunks on every core, a run of one folder's photos looked up once: hashing every
    /// photo's folder on one thread took ~0.1 s at 500k photos after each check of the originals.
    nonisolated static func folderSummaries(_ sourceAssets: [Asset], chunk: Int = 8_192)
        -> [String: (name: String, status: String)] {
        func rank(_ status: AssetStatus) -> Int {
            switch status {
            case .offline: 2
            case .missing: 1
            case .ready: 0
            }
        }
        typealias Worst = [String: (name: String, status: AssetStatus)]
        func add(_ folder: String, _ name: String, _ status: AssetStatus, to worst: inout Worst) {
            if let current = worst[folder] {
                if rank(status) > rank(current.status) { worst[folder] = (current.name, status) }
            } else {
                worst[folder] = (name, status)
            }
        }
        func summaries(_ range: Range<Int>) -> Worst {
            var worst: Worst = [:]
            var run: (folder: String, name: String, status: AssetStatus)?
            for position in range {
                let asset = sourceAssets[position]
                guard !asset.deleted, !asset.isDemo else { continue }
                if let current = run, current.folder == asset.folderId {
                    if rank(asset.status) > rank(current.status) { run?.status = asset.status }
                } else {
                    if let run { add(run.folder, run.name, run.status, to: &worst) }
                    run = (asset.folderId, asset.folderName, asset.status)
                }
            }
            if let run { add(run.folder, run.name, run.status, to: &worst) }
            return worst
        }
        let chunks = sourceAssets.isEmpty ? 0 : (sourceAssets.count - 1) / chunk + 1
        var worst: Worst = [:]
        if chunks > 1 {
            let lock = NSLock()
            var parts = [Worst](repeating: [:], count: chunks)
            DispatchQueue.concurrentPerform(iterations: chunks) { index in
                let part = summaries(index * chunk ..< min(sourceAssets.count, (index + 1) * chunk))
                lock.withLock { parts[index] = part }
            }
            // in the catalog's order, so a folder keeps its first photo's name
            for part in parts {
                for (folder, summary) in part { add(folder, summary.name, summary.status, to: &worst) }
            }
        } else {
            worst = summaries(sourceAssets.indices)
        }
        return worst.mapValues { summary in
            (summary.name, summary.status == .offline ? "offline" : summary.status == .missing ? "missing" : "online")
        }
    }

    func startVolumeMonitor() {
        let m = VolumeMonitor { [weak self] in self?.volumesDidChange() }
        m.start()
        volumeMonitor = m
    }

    /// A drive was mounted, unmounted or renamed. Every drive change enters the app here: source
    /// folders that aren't watched (their drive was away), and watched ones whose drive is no
    /// longer at their path, are looked for again. One that's back, or on its drive under a new
    /// name, is watched there and rescanned for what changed on it meanwhile, its photos moving
    /// with it; one whose drive went away stops being watched. Then the originals' availability
    /// is checked again and memory cards are listed afresh.
    func volumesDidChange() {
        reconnectSourceRoots()
        detectMissingRealAssets()
        refreshCardVolumes()
    }

    private func reconnectSourceRoots() {
        // a catalog still loading looks for its folders once it's loaded
        guard let store, !isLoadingCatalog, let roots = try? store.loadSourceRoots() else { return }
        var watchChanged = false, cameBack = false
        for root in roots where root.managementMode == ImportMode.referenced.rawValue {
            let path = URL(fileURLWithPath: sourceRootPathsById[root.id] ?? root.pathHint).standardizedFileURL.path
            if let watched = watchedRoots.firstIndex(where: { $0.standardizedFileURL.path == path }) {
                // still on its own drive, where it was (a folder on the startup disk stays put)
                let placement = volumeProbe.placement(of: path, onVolume: root.volumeIdentifier)
                guard volumeProbe.volumeRoot(of: path) != nil,
                      (placement != .mounted && placement != .unchecked) || !FileManager.default.fileExists(atPath: path)
                else { continue }
                // its drive was renamed, unplugged, or swapped for another of its name
                watchedRoots.remove(at: watched)
                watchChanged = true
            }
            let resolved = resolveSourceRoot(root)
            applySourceRoot(root, resolved: resolved, in: store)
            if resolved.status == "online", resolved.url != nil {
                watchChanged = true
                cameBack = true
            }
        }
        for moved in movedSourceRoots {
            rebaseSourceRootAssetPaths(folderId: moved.id, oldRoot: moved.from, newRoot: moved.to)
        }
        movedSourceRoots = []
        if watchChanged { refreshWatcher() }
        if cameBack { incrementalRescan() }
    }
}
