import AppKit
import Foundation

@MainActor
extension AppState {
    // ---------- batch capture-time shift (§4.2 / META-008) ----------
    func shiftCaptureTime(hours: Int, minutes: Int = 0) {
        let totalMinutes = hours * 60 + minutes
        guard totalMinutes != 0 else { return }
        let ids = targetIds
        guard !ids.isEmpty else { return }
        guard mutate(ids, undoName: L("调整拍摄时间"), {
            $0.date = $0.date.addingTimeInterval(Double(totalMinutes) * 60)
            $0.captureDateSource = "手动调整"
        }) else { return }
        let absT = abs(totalMinutes)
        push("已调整 \(ids.count) 张拍摄时间 \(totalMinutes > 0 ? "+" : "-")\(absT / 60)时\(absT % 60)分", "clock")
    }

    /// Set an absolute capture time on the selection (§4.2 / META-008).
    func setCaptureDate(_ date: Date) {
        let ids = targetIds
        guard !ids.isEmpty else { return }
        guard mutate(ids, undoName: L("设置拍摄时间"), {
            $0.date = date
            $0.captureDateSource = "手动设置"
        }) else { return }
        push("已将 \(ids.count) 张拍摄时间设为指定时间", "clock")
    }

    // ---------- XMP sidecar write (§6.5 META-007) ----------
    /// Photo → 将元数据写入文件: writes the selection's sidecars, even one another app changed
    /// (asked for, it isn't held back). It takes its turn with the automatic writes: one queued
    /// before it, with older values, is skipped rather than landing after it, and its own write
    /// isn't taken for another app's change. Reported once written; the task is for checks.
    @discardableResult
    func writeXMPForSelection() -> Task<Void, Never>? {
        let ids = targetIds
        // virtual copies share their master's sidecar and never write it
        let real = assets.filter { ids.contains($0.id) && !$0.isVirtualCopy && hasExistingOriginal($0) }
        guard !real.isEmpty else { push("仅可为已导入照片写入 XMP", "warning"); return nil }
        automaticXMPWriteSequence &+= 1
        let sequence = automaticXMPWriteSequence
        let writer = automaticXMPWriter
        let catalogURL = store?.packageURL
        xmpWriteStarted()
        return Task { [weak self, writer, real, sequence, catalogURL] in
            let result = await writer.write(real, sequence: sequence, overwritingChanges: true)
            guard let self else { return }
            if self.store?.packageURL == catalogURL { self.recordWrittenSidecars(result) }
            self.xmpWriteFinished()
            // a photo a newer write got to first has that one's values: written all the same
            let failures = result.failures + result.unavailable.count
            let count = real.count - failures
            if failures > 0 {
                self.push("已写入 \(count) 个 · \(failures) 失败", "warning")
            } else {
                self.push("已写入 \(count) 个 XMP 附属文件", "check")
            }
        }
    }

    // ---------- sidecars changed by other apps ----------
    private static let xmpCheckInterval: TimeInterval = 15

    /// Remembers sidecars as they are now: our own writes and reads never count as changes.
    func recordXMPSync(_ times: [String: Double]) {
        guard !times.isEmpty else { return }
        storeXMPSync(times)
        let settled = externallyChangedXMPIds.intersection(times.keys)
        if !settled.isEmpty { externallyChangedXMPIds.subtract(settled) }
    }

    private func storeXMPSync(_ times: [String: Double]) {
        try? store?.saveXMPSyncTimes(times)
        xmpSyncTimes.merge(times) { $1 }
        xmpSyncCount &+= 1
        for id in times.keys { xmpSyncRecordedAt[id] = xmpSyncCount }
    }

    /// Shows these photos' sidecars as changed elsewhere now, ahead of the next check: a check
    /// already under way looked before, and doesn't take them off.
    func noteChangedElsewhere(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        xmpSyncCount &+= 1
        for id in ids { xmpChangeFoundAt[id] = xmpSyncCount }
        externallyChangedXMPIds.formUnion(ids)
    }

    /// What a sidecar time worked out in the background was worked out against.
    struct XMPSyncSnapshot: Sendable {
        let count: UInt64
        let pairing: Bool
    }

    func xmpSyncSnapshot() -> XMPSyncSnapshot { XMPSyncSnapshot(count: xmpSyncCount, pairing: pairRawAndJpeg) }

    /// The part of `times`, worked out in the background from `snapshot`, that's still about the
    /// photos' sidecars as they are: not one for a sidecar switching pairing has since swapped
    /// (a RAW's JPEG, among `pairingDependent`), and not one remembered anew since.
    private func stillCurrent(_ times: [String: Double], pairingDependent: Set<String>,
                              since snapshot: XMPSyncSnapshot) -> [String: Double] {
        times.filter { id, _ in isStillCurrent(id, pairingDependent: pairingDependent.contains(id), since: snapshot) }
    }

    /// Whether what was worked out in the background from `snapshot` for photo `id` is still
    /// about its sidecar as it is (see `stillCurrent`).
    private func isStillCurrent(_ id: String, pairingDependent: Bool, since snapshot: XMPSyncSnapshot) -> Bool {
        (snapshot.pairing == pairRawAndJpeg || !pairingDependent) && (xmpSyncRecordedAt[id] ?? 0) <= snapshot.count
    }

    /// Where each new photo's sidecar stands as it joins the catalog (0: it has none), so one
    /// another app writes later — even its first — reads as a change. A photo coming back to the
    /// catalog (among `returning`) has the catalog's metadata, not its sidecar's. With a record
    /// of its sidecar, the check holds the sidecar against that as for any photo; with none (a
    /// catalog from before the record was kept), a sidecar that says otherwise than the catalog
    /// is one it hasn't taken in, and shows as changed elsewhere until it's read or written.
    func recordSidecarBaselines(_ fresh: [Asset], returning: Set<String> = []) {
        let candidates = fresh.compactMap { asset -> (id: String, path: String)? in
            guard !asset.isDemo, !asset.isVirtualCopy, let path = asset.localPath else { return nil }
            return (asset.id, path)
        }
        guard store != nil, !candidates.isEmpty else { return }
        // what the catalog says of each returning photo whose sidecar it has no record of
        let unrecorded = Dictionary(fresh.filter { returning.contains($0.id) && xmpSyncTimes[$0.id] == nil }
            .map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let catalogURL = store?.packageURL
        let snapshot = xmpSyncSnapshot()
        Task { [weak self, candidates, unrecorded, snapshot] in
            let found = await Task.detached(priority: .utility) {
                () -> (times: [String: Double], dependent: Set<String>, differing: Set<String>) in
                let choices = XMPSidecar.sidecarChoices(for: candidates.map { URL(fileURLWithPath: $0.path) })
                var times: [String: Double] = [:]
                var dependent = Set<String>()
                var differing = Set<String>()
                for (candidate, choice) in zip(candidates, choices) {
                    let sidecar = snapshot.pairing ? choice.paired : choice.unpaired
                    times[candidate.id] = XMPSidecar.modificationTime(of: sidecar) ?? 0
                    if choice.paired != choice.unpaired { dependent.insert(candidate.id) }
                    if let asset = unrecorded[candidate.id], let read = XMPSidecar.read(sidecar),
                       !XMPSidecar.agrees(read, with: asset) {
                        differing.insert(candidate.id)
                    }
                }
                return (times, dependent, differing)
            }.value
            guard let self, self.store?.packageURL == catalogURL else { return }
            let current = self.stillCurrent(found.times, pairingDependent: found.dependent, since: snapshot)
                .filter { self.xmpSyncTimes[$0.key] == nil }
            let differing = found.differing.intersection(current.keys)
            self.recordXMPSync(current.filter { !differing.contains($0.key) })
            guard !differing.isEmpty else { return }
            // recorded as none, so every check finds the sidecar changed until it's read or written
            self.storeXMPSync(Dictionary(uniqueKeysWithValues: differing.map { ($0, 0) }))
            self.noteChangedElsewhere(differing)
        }
    }

    /// Pairing decides whether a RAW's JPEG shares the RAW's sidecar or keeps its own: the photos
    /// whose sidecar that changes start from the one they use now, as on first sight, rather than
    /// looking changed elsewhere.
    func reseedSidecarBaselines(pairingWas old: Bool) {
        let candidates = xmpCheckCandidates()
        guard store != nil, !candidates.isEmpty else { return }
        let snapshot = xmpSyncSnapshot()
        let catalogURL = store?.packageURL
        Task { [weak self, candidates, snapshot] in
            let times = await Task.detached(priority: .utility) {
                Self.sidecarReseedTimes(candidates, from: old, to: snapshot.pairing)
            }.value
            guard let self, self.store?.packageURL == catalogURL else { return }
            self.applySidecarReseed(times, since: snapshot)
        }
    }

    /// The photos whose sidecar is another with pairing `now` than with `old`, and that
    /// sidecar's time (0: there's none).
    nonisolated static func sidecarReseedTimes(_ candidates: [(id: String, path: String)], from old: Bool,
                                               to now: Bool) -> [String: Double] {
        let originals = candidates.map { URL(fileURLWithPath: $0.path) }
        let before = XMPSidecar.sidecarURLs(for: originals, pairing: old)
        let after = XMPSidecar.sidecarURLs(for: originals, pairing: now)
        var times: [String: Double] = [:]
        for index in candidates.indices where before[index] != after[index] {
            times[candidates[index].id] = XMPSidecar.modificationTime(of: after[index]) ?? 0
        }
        return times
    }

    /// Takes in a re-seed worked out in the background from `snapshot` (its photos are all ones
    /// whose sidecar pairing decides), unless pairing was switched again or a photo's sidecar
    /// time was remembered anew meanwhile.
    func applySidecarReseed(_ times: [String: Double], since snapshot: XMPSyncSnapshot) {
        recordXMPSync(stillCurrent(times, pairingDependent: Set(times.keys), since: snapshot))
    }

    /// Looks at every original's sidecar in the background: one whose time moved since we last
    /// read or wrote it was changed by another app. A photo seen for the first time only sets
    /// its starting point, so nothing old is taken for a change. At most one check every few
    /// seconds; one asked for sooner runs when its turn comes. Never while a sidecar write of
    /// ours is under way: it records the times of the sidecars it rewrote only once it's done,
    /// so those would pass for another app's changes (and be read back over a later edit). The
    /// check waits, and runs once the writes are done.
    func checkExternalXMPChanges() {
        guard runsBackgroundMaintenance, store != nil else { return }
        guard xmpWritesInFlight == 0 else {
            xmpCheckAwaitsWrites = true
            return
        }
        let wait = Self.xmpCheckInterval - Date.now.timeIntervalSince(lastXMPCheck ?? .distantPast)
        guard wait <= 0, !isCheckingXMP else {
            guard !xmpCheckPending else { return }
            xmpCheckPending = true
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(wait, 1)))
                guard let self else { return }
                self.xmpCheckPending = false
                self.checkExternalXMPChanges()
            }
            return
        }
        // stops at the first original, so the list itself can be built off the main thread
        guard assets.contains(where: Self.isXMPCandidate) else { return }
        lastXMPCheck = .now
        isCheckingXMP = true
        let known = xmpSyncTimes
        let catalogURL = store?.packageURL
        let snapshot = xmpSyncSnapshot()
        // a hop of its own: the photos it's handed are let go as it ends, rather than held while
        // the sidecars are looked at (an edit meanwhile would copy every one of them)
        let listing = Task.detached(priority: .utility) { [photos = assets] in Self.xmpCheckCandidates(in: photos) }
        Task { [weak self, known, snapshot] in
            let candidates = await listing.value
            let found = await Task.detached(priority: .utility) {
                Self.findChangedSidecars(candidates, known: known, pairing: snapshot.pairing)
            }.value
            guard let self else { return }
            self.isCheckingXMP = false
            guard self.store?.packageURL == catalogURL else { return }
            // a write that began while it looked may have rewritten sidecars it saw: it's done
            // again once the writes are
            guard self.xmpWritesInFlight == 0 else {
                self.xmpCheckAwaitsWrites = true
                return
            }
            self.applyExternalXMPCheck(seeded: found.seeded, changed: found.changed,
                                       pairingDependent: found.pairingDependent, since: snapshot,
                                       readingInBackground: true)
        }
    }

    /// The photos whose sidecars the check looks at, among the catalog's now.
    func xmpCheckCandidates() -> [(id: String, path: String)] { Self.xmpCheckCandidates(in: assets) }

    /// The photos whose sidecars the check looks at: every original the catalog owns.
    nonisolated static func xmpCheckCandidates(in assets: [Asset]) -> [(id: String, path: String)] {
        assets.compactMap { asset -> (id: String, path: String)? in
            guard isXMPCandidate(asset), let path = asset.localPath else { return nil }
            return (asset.id, path)
        }
    }

    /// Whether the check looks at this photo's sidecar: an original the catalog owns.
    nonisolated static func isXMPCandidate(_ asset: Asset) -> Bool {
        !asset.deleted && !asset.isDemo && !asset.isVirtualCopy && asset.localPath != nil
    }

    /// Sidecars whose time moved from their starting point (changed, with the time found), and
    /// first sightings (seeded). Older counts too: a sidecar put back from a backup or synced
    /// in with its old date is still another version.
    /// Also the photos whose sidecar `pairing` decided (a RAW's JPEG, the RAW).
    nonisolated static func findChangedSidecars(_ candidates: [(id: String, path: String)], known: [String: Double],
                                                pairing: Bool = XMPSidecar.pairsRawAndJpeg)
        -> (seeded: [String: Double], changed: [String: Double], pairingDependent: Set<String>) {
        var seeded: [String: Double] = [:]
        var changed: [String: Double] = [:]
        var dependent = Set<String>()
        let choices = XMPSidecar.sidecarChoices(for: candidates.map { URL(fileURLWithPath: $0.path) })
        for (candidate, choice) in zip(candidates, choices) {
            if choice.paired != choice.unpaired { dependent.insert(candidate.id) }
            guard let time = XMPSidecar.modificationTime(of: pairing ? choice.paired : choice.unpaired) else { continue }
            if let baseline = known[candidate.id] {
                if abs(time - baseline) > 1 { changed[candidate.id] = time }
            } else {
                seeded[candidate.id] = time
            }
        }
        return (seeded, changed, dependent)
    }

    /// Takes in a check; one worked out in the background from `snapshot` leaves alone the
    /// photos whose sidecar it no longer describes (see `stillCurrent`). Changed sidecars read
    /// automatically are read before it returns, unless `readingInBackground`.
    func applyExternalXMPCheck(seeded: [String: Double], changed: [String: Double],
                               pairingDependent: Set<String> = [], since snapshot: XMPSyncSnapshot? = nil,
                               readingInBackground: Bool = false) {
        let snapshot = snapshot ?? xmpSyncSnapshot()
        let seeded = stillCurrent(seeded, pairingDependent: pairingDependent, since: snapshot)
        let changed = stillCurrent(changed, pairingDependent: pairingDependent, since: snapshot)
        // the check looked at a snapshot: a sidecar we wrote or read meanwhile has moved on
        let fresh = seeded.filter { xmpSyncTimes[$0.key] == nil }
        if !fresh.isEmpty { storeXMPSync(fresh) }
        var live = Set(changed.filter { id, time in
            guard let index = assetIndex[id], !assets[index].deleted else { return false }
            return xmpSyncTimes[id].map { abs(time - $0) > 1 } ?? true
        }.keys)
        // a change an automatic write found since the check started is one it couldn't see
        live.formUnion(externallyChangedXMPIds.filter { (xmpChangeFoundAt[$0] ?? 0) > snapshot.count })
        if externallyChangedXMPIds != live { externallyChangedXMPIds = live }
        // taken in the background, so not something ⌘Z should take back
        guard autoReadChangedXMP, !live.isEmpty else { return }
        if readingInBackground {
            readChangedSidecarsInBackground(live)
        } else {
            readMetadataFromFiles(live, undoable: false)
        }
    }

    /// For checks: a photo's sidecar time as of our last read or write.
    func xmpSyncTime(for id: String) -> Double? { xmpSyncTimes[id] }

    /// For checks: the sidecar check, run now and to completion.
    func checkExternalXMPChangesNow() {
        let candidates = xmpCheckCandidates()
        let found = Self.findChangedSidecars(candidates, known: xmpSyncTimes, pairing: pairRawAndJpeg)
        applyExternalXMPCheck(seeded: found.seeded, changed: found.changed)
    }

    /// 照片 → 从文件读取元数据: takes the sidecars' metadata for the selection (or `ids`) over
    /// the catalog's — what another app last wrote wins. Undoable unless read in the background;
    /// the sidecars aren't rewritten.
    @discardableResult
    func readMetadataFromFiles(_ ids: Set<String>? = nil, undoable: Bool = true) -> Int {
        let targets = Self.readSidecars(readableOriginals(ids ?? targetIds))
        guard !targets.isEmpty else {
            if ids == nil { push("所选照片旁没有 XMP 附属文件", "info") }
            return 0
        }
        return takeInSidecars(targets, undoable: undoable)
    }

    /// The background check's automatic read: the sidecars are read and parsed off the main
    /// actor, then taken in (see `takeInBackgroundRead`). The task is for checks.
    @discardableResult
    func readChangedSidecarsInBackground(_ ids: Set<String>) -> Task<Void, Never>? {
        let located = readableOriginals(ids)
        guard !located.isEmpty else { return nil }
        let snapshot = xmpSyncSnapshot()
        let catalogURL = store?.packageURL
        return Task { [weak self, located, snapshot] in
            let read = await Task.detached(priority: .utility) {
                Self.readSidecars(located, pairing: snapshot.pairing)
            }.value
            guard let self, self.store?.packageURL == catalogURL else { return }
            self.takeInBackgroundRead(read, since: snapshot)
        }
    }

    /// Takes in sidecars read in the background from `snapshot`, but not for a photo removed
    /// meanwhile, nor a sidecar read or written again since (see `stillCurrent`). Not undoable,
    /// as no background read is.
    func takeInBackgroundRead(_ read: [SidecarRead], since snapshot: XMPSyncSnapshot) {
        let current = read.filter { target in
            guard let index = assetIndex[target.id], !assets[index].deleted else { return false }
            return isStillCurrent(target.id, pairingDependent: target.pairingDependent, since: snapshot)
        }
        if !current.isEmpty { takeInSidecars(current, undoable: false) }
    }

    /// A photo's sidecar as read, with its time and whether RAW+JPEG pairing decides which
    /// sidecar is the photo's.
    struct SidecarRead: Sendable {
        let id: String
        let sidecar: SidecarMetadata
        /// Taken before the read, so a sidecar changed while it's read is still found changed.
        let time: Double?
        let pairingDependent: Bool
    }

    /// The originals among `ids` with a sidecar of their own: a virtual copy's is its master's.
    private func readableOriginals(_ ids: Set<String>) -> [(id: String, path: String)] {
        ids.compactMap { id -> (id: String, path: String)? in
            guard let index = assetIndex[id], !assets[index].isVirtualCopy, let path = assets[index].localPath else { return nil }
            return (id, path)
        }
    }

    /// Reads the sidecars of `located` originals, the ones there are; off the main actor.
    nonisolated static func readSidecars(_ located: [(id: String, path: String)],
                                         pairing: Bool = XMPSidecar.pairsRawAndJpeg) -> [SidecarRead] {
        let choices = XMPSidecar.sidecarChoices(for: located.map { URL(fileURLWithPath: $0.path) })
        return zip(located, choices).compactMap { photo, choice -> SidecarRead? in
            let url = pairing ? choice.paired : choice.unpaired
            let time = XMPSidecar.modificationTime(of: url)
            return XMPSidecar.read(url).map {
                SidecarRead(id: photo.id, sidecar: $0, time: time, pairingDependent: choice.paired != choice.unpaired)
            }
        }
    }

    /// Takes the sidecars read over the catalog's metadata and remembers their times.
    @discardableResult
    private func takeInSidecars(_ targets: [SidecarRead], undoable: Bool) -> Int {
        let byId = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0.sidecar) })
        guard mutate(Set(byId.keys), undoName: undoable ? L("从文件读取元数据") : nil, writingSidecars: false, { asset in
            if let sidecar = byId[asset.id] { XMPSidecar.apply(sidecar, to: &asset, replacingKeywords: true) }
        }) else { return 0 }
        var times: [String: Double] = [:]
        for target in targets { times[target.id] = target.time }
        recordXMPSync(times)
        push("已从 \(targets.count) 个 XMP 附属文件读取元数据", "refresh")
        return targets.count
    }

    var canReadMetadataFromFiles: Bool { onboarded && sheet == nil && canOperateOnSelectedOriginals }

    // ---------- editing in another app ----------
    var externalEditorName: String? {
        externalEditorPath.map { FileManager.default.displayName(atPath: $0).replacingOccurrences(of: ".app", with: "") }
    }

    @discardableResult
    func chooseExternalEditor() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L("选择")
        panel.message = L("选择用来编辑照片的应用，例如 Photoshop、Affinity Photo 或 Pixelmator Pro")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        externalEditorPath = url.path
        return url
    }

    /// ⌥⌘E: edits each selected photo in the external editor — as a 16-bit TIFF copy with its
    /// develop settings and metadata, `<name>-编辑.tif` beside the original, added to the
    /// catalog with the original's rating, labels and keywords and stacked with it. The
    /// original is never touched; the editor's saves come back through folder watching.
    func editInExternalEditor() {
        let ids = selectionTargetIds
        let targets = list.filter { ids.contains($0.id) && hasExistingOriginal($0) }
        guard !targets.isEmpty else {
            push("所选照片没有可访问的原件", "warning")
            return
        }
        let saved = externalEditorPath.map { URL(fileURLWithPath: $0) }
        guard let editor = saved.flatMap({ FileManager.default.fileExists(atPath: $0.path) ? $0 : nil })
                ?? chooseExternalEditor(),
              let coordinator, let store else { return }
        // the TIFF goes beside its original, so the original's folder must take a new file
        let all = externalEditJobs(targets)
        let jobs = all.filter { FileManager.default.isWritableFile(atPath: $0.folder.path) }
        if jobs.count < all.count {
            push("\(all.count - jobs.count) 张照片所在的文件夹是只读的，无法在原件旁生成 TIFF", "warning")
        }
        guard !jobs.isEmpty else { return }
        push("正在为 \(editor.deletingPathExtension().lastPathComponent) 准备 \(jobs.count) 张 TIFF…", "export")
        let catalogURL = store.packageURL
        let previewSize = previewMaxPixel
        // the album the copies join is the one open now, not whichever is open when they're done
        let albumId = selection.type == .album ? selection.id : nil
        Task { [weak self, jobs, coordinator] in
            // RAW decodes stay off the cooperative pool (RawCamera deadlocks there)
            let made = await ThumbnailRepairQueue.run(.visible) {
                Self.renderEditedCopies(jobs, coordinator: coordinator, previewMaxPixel: previewSize)
            } ?? []
            guard let self, self.store?.packageURL == catalogURL else { return }
            self.finishExternalEdit(made, editor: editor, expected: jobs.count, albumId: albumId)
        }
    }

    typealias ExternalEditJob = (item: RenderedExportItem, folder: URL, source: Asset)

    /// One TIFF to render per photo, beside its original.
    func externalEditJobs(_ targets: [Asset]) -> [ExternalEditJob] {
        targets.compactMap { asset -> ExternalEditJob? in
            guard let path = asset.localPath, !asset.isVideo else { return nil }
            let original = URL(fileURLWithPath: path)
            let item = RenderedExportItem(assetId: asset.id, sourcePath: path, isRaw: asset.isRaw,
                                          develop: developSettings[asset.id] ?? .neutral,
                                          originalSize: CGSize(width: asset.width, height: asset.height),
                                          baseName: original.deletingPathExtension().lastPathComponent
                                              + EditedVersions.suffix,
                                          date: asset.date, camera: asset.camera, title: asset.title,
                                          caption: asset.caption, keywords: asset.keywords, rating: asset.rating,
                                          author: asset.author, copyright: asset.copyright,
                                          gps: RenderedExportItem.location(of: asset), gpsAltitude: asset.gpsAltitude)
            return (item, original.deletingLastPathComponent(), asset)
        }
    }

    /// Renders each job as a 16-bit Adobe RGB TIFF with full metadata and reads it in as a new
    /// photo. Off the main thread.
    nonisolated static func renderEditedCopies(_ jobs: [ExternalEditJob], coordinator: ImportCoordinator,
                                               previewMaxPixel: Int) -> [(url: URL, source: Asset, asset: Asset?)] {
        var settings = ExportSettings()
        settings.format = .tiff
        settings.sixteenBit = true
        settings.colorSpace = .adobeRGB
        settings.metadata = .all
        settings.collision = .uniqueName
        return jobs.compactMap { job in
            guard case .written(let url) = RenderedExportService.export(job.item, sequence: 1, settings: settings,
                                                                        to: job.folder, names: ExportNames())
            else { return nil }
            let imported = coordinator.importFiles([url], from: job.folder, readSidecar: false,
                                                   previewMaxPixel: previewMaxPixel, reusingRemovedIds: false).first
            return (url, job.source, imported)
        }
    }

    /// Adds the rendered copies to the catalog beside their originals (and to album `albumId`)
    /// and opens them in `editor` (nil: only adds them).
    @discardableResult
    func finishExternalEdit(_ made: [(url: URL, source: Asset, asset: Asset?)], editor: URL?, expected: Int,
                            albumId: String? = nil) -> (importedIDs: Set<String>, errorMessage: String?) {
        var fresh: [Asset] = []
        var importError: String?
        for result in made {
            guard let imported = result.asset else { continue }
            // folder watching may have seen the new file first: the copy is that entry
            var copy = assetIndex[imported.id].map { assets[$0] } ?? imported
            guard !copy.deleted else { continue }
            let source = result.source
            // the copy files with its original and carries what the catalog knows about it
            copy.folderId = source.folderId
            copy.folderName = source.folderName
            copy.date = source.date
            copy.rating = source.rating
            copy.flag = source.flag
            copy.colorLabel = source.colorLabel
            copy.keywords = source.keywords
            copy.title = source.title
            copy.caption = source.caption
            copy.location = source.location
            copy.gps = source.gps
            copy.gpsAltitude = source.gpsAltitude
            copy.project = source.project
            copy.client = source.client
            fresh.append(copy)
        }
        if !fresh.isEmpty {
            guard let store else {
                let message = L("目录库已关闭，副本未加入目录库")
                push(verbatim: message, "warning")
                return ([], message)
            }
            do {
                try store.upsert(fresh)
            } catch {
                push("外部编辑的副本未能加入目录库", "warning")
                return ([], L("副本未能加入目录库：\(error.localizedDescription)"))
            }
            // in place of the entry folder watching made of it, else after the others
            let index = assetIndex
            replaceInPlace(fresh.compactMap { copy in index[copy.id].map { (offset: $0, asset: copy) } })
            let added = fresh.filter { index[$0.id] == nil }
            if !added.isEmpty { appendAssets(added) }
            recordSidecarBaselines(fresh)
            if let albumId, let index = albums.firstIndex(where: { $0.id == albumId }) {
                var album = albums[index]
                let members = Set(album.assetIds)
                album.assetIds.append(contentsOf: fresh.map(\.id).filter { !members.contains($0) })
                if saveManualAlbum(album, sortOrder: index) {
                    albums[index] = album
                } else {
                    importError = L("副本已加入目录库，但相册未能保存")
                }
            }
            selectedIds = Set(fresh.map(\.id))
            setPrimary(fresh[0].id)
            recomputeDuplicates()
        }
        let result = (importedIDs: Set(fresh.map(\.id)), errorMessage: importError)
        let urls = made.map(\.url)
        guard !urls.isEmpty else {
            push("无法生成用于外部编辑的 TIFF", "warning")
            return (result.importedIDs, L("无法生成用于外部编辑的 TIFF"))
        }
        guard let editor else { return result }
        NSWorkspace.shared.open(urls, withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        if urls.count < expected {
            push(verbatim: L("已在外部编辑器中打开 \(urls.count) 张") + L(" · \(expected - urls.count) 失败"), "warning")
        }
        return result
    }

    var canEditInExternalEditor: Bool { canOperateOnSelectedOriginals && onboarded && sheet == nil }
}
