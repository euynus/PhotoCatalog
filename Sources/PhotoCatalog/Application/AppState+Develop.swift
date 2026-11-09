import AppKit
import Foundation

@MainActor
extension AppState {
    // ----- develop: non-destructive adjustments -----
    struct DevelopDraft: Equatable { let assetId: String; var settings: DevelopSettings }
    struct DevelopAsShot: Equatable { let temperature: Double; let tint: Double }

    func recordDevelopSourceSize(_ size: CGSize, for id: String) { developSourceSizes[id] = size }

    /// The decoded photo's size before quarter turns: the space masks are stored in.
    func developSourceSize(for asset: Asset) -> CGSize {
        developSourceSizes[asset.id] ?? CGSize(width: max(asset.width, 1), height: max(asset.height, 1))
    }

    /// The frame crops are expressed in: the photo after its quarter turns.
    func developFrame(for asset: Asset, settings: DevelopSettings) -> CGSize {
        let size = developSourceSizes[asset.id] ?? CGSize(width: max(asset.width, 1), height: max(asset.height, 1))
        return DevelopGeometry.rotatedSize(size, settings.rotation)
    }

    /// Shrinks the crop to fit after a straighten or perspective change. The frame depends only
    /// on the quarter turns, so every such change refits the same way.
    func refitCrop(_ settings: inout DevelopSettings, for asset: Asset) {
        settings.crop = DevelopGeometry.refit(settings, frame: developFrame(for: asset, settings: settings))
    }

    // ----- crop tool: shape, orientation and straighten -----
    /// Picks a crop shape and reshapes the crop to the largest of it around the same center.
    func setCropAspect(_ aspect: CropAspect, for asset: Asset) {
        developCropAspect = aspect
        let shown = developSettings(for: asset.id)
        let frame = developFrame(for: asset, settings: shown)
        guard let ratio = aspect.ratio(frame: frame) else { return }
        let current = DevelopGeometry.effectiveCrop(shown, frame: frame)
        reshapeCrop(asset, aspect: DevelopGeometry.oriented(ratio: ratio, like: current, frame: frame), around: current,
                    frame: frame, undoName: L("裁剪比例"))
    }

    /// Turns the crop from landscape to portrait or back, keeping its shape and center.
    func swapCropOrientation(for asset: Asset) {
        let shown = developSettings(for: asset.id)
        let frame = developFrame(for: asset, settings: shown)
        let current = DevelopGeometry.effectiveCrop(shown, frame: frame)
        let aspect = current.height * frame.height / max(current.width * frame.width, 1e-9)
        reshapeCrop(asset, aspect: aspect, around: current, frame: frame, undoName: L("切换裁剪框横竖"))
    }

    /// The straighten slider's live preview: the angle, with the crop shrunk to fit it.
    func draftStraighten(_ angle: Double, for asset: Asset) {
        // shrink from the saved crop, so dragging back toward level grows it again
        var next = developSettings[asset.id] ?? .neutral
        next.straighten = angle
        refitCrop(&next, for: asset)
        updateDevelopDraft(next, for: asset.id)
    }

    /// The largest crop of `aspect` around the current one's center, inside the saved straighten
    /// and perspective.
    private func reshapeCrop(_ asset: Asset, aspect: Double, around current: DevelopCrop, frame: CGSize,
                             undoName: String) {
        commitDevelop(asset.id, undoName: undoName) { next in
            let perspective = DevelopGeometry.perspective(next, frame: frame)
            let largest = DevelopGeometry.inscribed(aspect: aspect, angle: next.straighten, perspective: perspective,
                                                    frame: frame)
            let crop = DevelopGeometry.move(largest, dx: current.midX - largest.midX, dy: current.midY - largest.midY,
                                            angle: next.straighten, perspective: perspective, frame: frame)
            // the whole photo's own shape is what "no crop" already means
            let isWhole = crop == DevelopGeometry.inscribed(aspect: frame.width / max(frame.height, 1),
                                                            angle: next.straighten, perspective: perspective,
                                                            frame: frame)
            next.crop = isWhole ? nil : crop
        }
    }

    /// Photos with pixels to render: a local original, or at least a local preview. Never a video.
    func canDevelop(_ asset: Asset) -> Bool {
        guard !asset.isVideo else { return false }
        if asset.status == .ready, asset.localPath != nil { return true }
        return Self.isLocalReference(asset.preview)
    }

    /// A preview or thumbnail file on disk, not a demo photo's web address. Compares bytes:
    /// `String.hasPrefix` was a real cost when checked for every photo of a large selection.
    nonisolated static func isLocalReference(_ path: String) -> Bool {
        var bytes = path.utf8.makeIterator()
        guard let first = bytes.next() else { return false }
        return !(first == UInt8(ascii: "h") && bytes.next() == UInt8(ascii: "t")
                 && bytes.next() == UInt8(ascii: "t") && bytes.next() == UInt8(ascii: "p"))
    }

    /// R: opens the crop tool (from any view) or closes it.
    func toggleCropTool() {
        if view == .develop {
            developCropping.toggle()
        } else {
            switchView(.develop)
            developCropping = view == .develop
        }
    }

    /// The photo in Develop, or every selected photo elsewhere, that can take an edit.
    var developTargetIds: [String] {
        let ids = view == .develop ? primaryId.map { [$0] } ?? [] : selectionTargetIds.sorted()
        return ids.filter { id in assetIndex[id].map { canDevelop(assets[$0]) } ?? false }
    }

    /// Menu state: stops at the first photo that can take an edit.
    var canTransformSelection: Bool {
        guard onboarded, sheet == nil, view != .analysis else { return false }
        return selectionSummary.hasDevelopable
    }


    /// ⌘[ / ⌘]: a quarter turn, stored as an adjustment — the original is never rewritten.
    func rotateSelection(clockwise: Bool) {
        let ids = developTargetIds
        guard !ids.isEmpty else { return }
        let changes = Dictionary(uniqueKeysWithValues: ids.map {
            ($0, DevelopGeometry.rotated(developSettings[$0] ?? .neutral, clockwise: clockwise))
        })
        commitDevelop(changes, undoName: clockwise ? L("向右旋转") : L("向左旋转"))
    }

    func flipSelection() {
        let ids = developTargetIds
        guard !ids.isEmpty else { return }
        let changes = Dictionary(uniqueKeysWithValues: ids.map {
            ($0, DevelopGeometry.mirrored(developSettings[$0] ?? .neutral))
        })
        commitDevelop(changes, undoName: L("水平翻转"))
    }

    /// The file Develop works from: the original, or the cached preview while it is offline.
    func developSource(for asset: Asset) -> (url: URL, isRaw: Bool)? {
        guard canDevelop(asset) else { return nil }
        if asset.status == .ready, let path = asset.localPath { return (URL(fileURLWithPath: path), asset.isRaw) }
        return (URL(fileURLWithPath: asset.preview), false)
    }

    // ----- lens blur: the photo blurred by depth (see LensBlur, DepthMap) -----
    /// Turns lens blur on (focused on the subject, see `DepthMap.defaultFocus`) or off, as one
    /// undoable step.
    func setLensBlur(_ enabled: Bool, for asset: Asset) {
        guard canDevelop(asset), let source = developSource(for: asset) else { return }
        let id = asset.id
        guard enabled else {
            commitDevelopChange([id], undoName: L("镜头模糊")) { _, settings in settings.lensBlur.enabled = false }
            return
        }
        Task { [weak self] in
            let focus = await ThumbnailRepairQueue.run(.visible) { () -> Double? in
                guard let map = DepthMap.map(for: source.url, isRaw: source.isRaw) else { return nil }
                return DepthMap.defaultFocus(map, url: source.url, isRaw: source.isRaw)
            } ?? nil
            guard let self else { return }
            guard let focus else {
                self.push("无法估计这张照片的深度", "warning")
                return
            }
            self.commitDevelopChange([id], undoName: L("镜头模糊")) { _, settings in
                settings.lensBlur.enabled = true
                settings.lensBlur.focus = (focus * 100).rounded() / 100
            }
        }
    }

    /// Sets lens blur's focus to the depth at `point` (fractions of the finished photo,
    /// top-left origin), turning it on.
    func pickLensBlurFocus(_ asset: Asset, at point: CGPoint) {
        developPickingFocus = false
        guard canDevelop(asset), let source = developSource(for: asset) else { return }
        let id = asset.id, settings = developSettings[id] ?? .neutral, size = developSourceSize(for: asset)
        Task { [weak self] in
            let map = await ThumbnailRepairQueue.run(.visible) { DepthMap.map(for: source.url, isRaw: source.isRaw) } ?? nil
            guard let self, let map else { return }
            let depth = map.depth(atFinished: point, settings: settings, sourceSize: size)
            self.commitDevelopChange([id], undoName: L("镜头模糊焦点")) { _, settings in
                settings.lensBlur.enabled = true
                settings.lensBlur.focus = (depth * 100).rounded() / 100
            }
        }
    }

    /// Sets temperature and tint so the photo renders gray at `point` (fractions of the finished
    /// photo, top-left origin).
    func pickWhiteBalance(_ asset: Asset, at point: CGPoint) {
        developPickingWhiteBalance = false
        guard let source = developSource(for: asset) else { return }
        let settings = developSettings[asset.id] ?? .neutral
        let id = asset.id
        Task { [weak self] in
            let balance = await ThumbnailRepairQueue.run(.visible) {
                DevelopAuto.whiteBalance(url: source.url, isRaw: source.isRaw, settings: settings, point: point)
            } ?? nil
            guard let self else { return }
            guard let balance else {
                self.push("这里太暗或太亮，无法判断中性色，请点选灰色或白色的区域", "info")
                return
            }
            self.commitDevelopChange([id], undoName: L("白平衡吸管")) { _, settings in
                settings.temperature = balance.temperature
                settings.tint = balance.tint
            }
        }
    }

    /// Automatic white balance for the photo in Develop, or every selected photo elsewhere,
    /// each measured on its own; only temperature and tint change.
    func autoWhiteBalance() {
        let targets = developTargetIds.compactMap { id -> (id: String, url: URL, isRaw: Bool, settings: DevelopSettings)? in
            guard let asset = assetIndex[id].map({ assets[$0] }), let source = developSource(for: asset) else { return nil }
            return (id, source.url, source.isRaw, developSettings[id] ?? .neutral)
        }
        guard !targets.isEmpty else { return }
        Task { [weak self, targets] in
            let found = await ThumbnailRepairQueue.run(.visible) {
                targets.compactMap { target in
                    DevelopAuto.autoWhiteBalance(url: target.url, isRaw: target.isRaw, settings: target.settings)
                        .map { (target.id, $0) }
                }
            } ?? []
            guard let self else { return }
            guard !found.isEmpty else {
                self.push("照片中没有足够的中性色，无法自动判断白平衡", "info")
                return
            }
            let balances = Dictionary(found, uniquingKeysWith: { $1 })
            self.commitDevelopChange(Array(balances.keys), undoName: L("自动白平衡")) { id, settings in
                guard let balance = balances[id] else { return }
                settings.temperature = balance.temperature
                settings.tint = balance.tint
            }
            if balances.count > 1 { self.push("已自动调整 \(balances.count) 张照片的白平衡", "wand") }
        }
    }

    /// The black-and-white mix chosen from the photo in Develop's colors (see `DevelopAuto.grayMix`).
    func autoGrayMix() {
        guard let asset = primary, view == .develop, let source = developSource(for: asset) else { return }
        let id = asset.id, settings = developSettings[id] ?? .neutral
        Task { [weak self] in
            let mix = await ThumbnailRepairQueue.run(.visible) {
                DevelopAuto.grayMix(url: source.url, isRaw: source.isRaw, settings: settings)
            } ?? nil
            guard let self else { return }
            guard let mix else {
                self.push("照片中的颜色太少，无法自动混合", "info")
                return
            }
            self.commitDevelopChange([id], undoName: L("自动黑白混合")) { _, settings in settings.grayMixer = mix }
        }
    }

    // ----- soft proofing: the photo in Develop as another color space or a printer shows it -----
    func toggleSoftProofing() {
        guard view == .develop else { return }
        softProofing.toggle()
        if softProofing && softProofProfiles.isEmpty { softProofProfiles = SoftProofing.profiles() }
        // a profile that's gone falls back to sRGB
        if softProofing, !softProofProfiles.contains(where: { $0.id == softProof.profile }) { softProof.profile = "sRGB" }
    }

    var canAutoTone: Bool { canTransformSelection }

    /// Automatic tone (⌘U) for the photo in Develop, or every selected photo elsewhere; each
    /// is measured on its own, and only the tone settings change.
    func autoTone() {
        let targets = developTargetIds.compactMap { id -> (id: String, url: URL, isRaw: Bool, settings: DevelopSettings)? in
            guard let asset = assetIndex[id].map({ assets[$0] }), let source = developSource(for: asset) else { return nil }
            return (id, source.url, source.isRaw, developSettings[id] ?? .neutral)
        }
        guard !targets.isEmpty else { return }
        Task { [weak self] in
            let toned = await ThumbnailRepairQueue.run(.visible) {
                targets.compactMap { target in
                    DevelopAuto.tone(url: target.url, isRaw: target.isRaw, settings: target.settings).map { (target.id, $0) }
                }
            } ?? []
            guard let self else { return }
            guard !toned.isEmpty else {
                self.push("无法读取照片，未能自动调整", "warning")
                return
            }
            // take only the tone from the measurement: edits made meanwhile stay
            let measured = Dictionary(uniqueKeysWithValues: toned)
            self.commitDevelopChange(Array(measured.keys), undoName: L("自动色调")) { id, settings in
                guard let auto = measured[id] else { return }
                settings.exposure = auto.exposure
                settings.contrast = auto.contrast
                settings.highlights = auto.highlights
                settings.shadows = auto.shadows
                settings.whites = auto.whites
                settings.blacks = auto.blacks
            }
            if measured.count > 1 { self.push("已自动调整 \(measured.count) 张照片的色调", "wand") }
        }
    }

    /// Levels the photo from the horizon Vision finds in it.
    /// Upright: sets the photo's verticals upright (and, for Auto, its horizontals parallel)
    /// with the Transform sliders and the straighten angle.
    func autoUpright(_ asset: Asset, mode: Upright.Mode) {
        guard let source = developSource(for: asset) else { return }
        let settings = developSettings[asset.id] ?? .neutral
        let id = asset.id
        Task { [weak self] in
            let found = await ThumbnailRepairQueue.run(.visible) {
                DevelopRenderer.uprightCorrection(url: source.url, isRaw: source.isRaw, settings: settings, mode: mode)
            } ?? nil
            guard let self else { return }
            guard let found else {
                self.push("照片中没有足够的竖直线条，无法自动校正透视", "info")
                return
            }
            let asset = self.assetIndex[id].map { self.assets[$0] }
            self.commitDevelopChange([id], undoName: mode == .auto ? L("自动透视") : L("垂直透视")) { _, settings in
                settings = found.applied(to: settings)
                if let asset { self.refitCrop(&settings, for: asset) }
            }
        }
    }

    func autoStraighten(_ asset: Asset) {
        guard let source = developSource(for: asset) else { return }
        let settings = developSettings[asset.id] ?? .neutral
        let id = asset.id
        Task { [weak self] in
            let angle = await ThumbnailRepairQueue.run(.visible) {
                DevelopRenderer.horizonAngle(url: source.url, isRaw: source.isRaw, settings: settings)
            } ?? nil
            guard let self else { return }
            guard let angle, abs(angle) <= DevelopGeometry.maxStraighten else {
                self.push("未找到可用于拉直的地平线", "info")
                return
            }
            let asset = self.assetIndex[id].map { self.assets[$0] }
            self.commitDevelopChange([id], undoName: L("自动拉直")) { _, settings in
                settings.straighten = (angle * 10).rounded() / 10
                if let asset { self.refitCrop(&settings, for: asset) }
            }
        }
    }


    /// Returns every selected photo (or the one in Develop) to as shot.
    func resetDevelopSelection() {
        let ids = developTargetIds.filter { developSettings[$0] != nil }
        guard !ids.isEmpty else { return }
        // each photo back to its RAW defaults, or as shot
        commitDevelop(Dictionary(uniqueKeysWithValues: ids.map { id in
            (id, assetIndex[id].map { defaultDevelopSettings(for: assets[$0]) } ?? .neutral)
        }), undoName: L("复位修图调整"))
    }

    var canResetDevelopSelection: Bool {
        canTransformSelection && selectionSummary.hasDevelopEdit
    }

    /// Applies a transfer as one undoable step; returns how many photos it reached.
    @discardableResult
    func applyDevelopTransfer(_ transfer: DevelopTransfer, to ids: [String], undoName: String) -> Int {
        var changes: [String: DevelopSettings] = [:]
        for id in ids {
            guard let index = assetIndex[id] else { continue }
            let asset = assets[index]
            var next = transfer.applied(to: developSettings[id] ?? .neutral, targetIsRaw: asset.isRaw)
            // a crop from another photo may reach past this one's straightened edges
            refitCrop(&next, for: asset)
            changes[id] = next
        }
        guard !changes.isEmpty else { return 0 }
        commitDevelop(changes, undoName: undoName)
        return changes.count
    }

    func recordDevelopHistogram(_ histogram: DevelopHistogram, for id: String) {
        if developHistogram?.assetId != id || developHistogram?.histogram != histogram {
            developHistogram = (id, histogram)
        }
    }

    func recordAsShotWhiteBalance(_ id: String, temperature: Double, tint: Double) {
        let value = DevelopAsShot(temperature: temperature, tint: tint)
        if developAsShot[id] != value { developAsShot[id] = value }
    }

    /// Changes whenever a photo's saved adjustments change; image views key their loads on it.
    /// Made again only when the settings differ from those it was last made from.
    func developFingerprint(for id: String) -> String? {
        guard let settings = developSettings[id] else {
            if developFingerprintCache[id] != nil { developFingerprintCache[id] = nil }
            return nil
        }
        if let cached = developFingerprintCache[id], cached.settings == settings { return cached.fingerprint }
        let fingerprint = settings.fingerprint
        developFingerprintCache[id] = (settings, fingerprint)
        return fingerprint
    }

    func developSettings(for id: String) -> DevelopSettings {
        if let draft = developDraft, draft.assetId == id { return draft.settings }
        return developSettings[id] ?? .neutral
    }

    func updateDevelopDraft(_ settings: DevelopSettings, for id: String) {
        developDraft = DevelopDraft(assetId: id, settings: settings)
    }

    /// Saves the photo's draft (a drag's live preview) as one undo step; false when there's
    /// none, or it is another photo's.
    @discardableResult
    func commitDevelopDraft(for id: String, undoName: String) -> Bool {
        guard let draft = developDraft, draft.assetId == id else { return false }
        commitDevelop([id: draft.settings], undoName: undoName)
        return true
    }

    /// Drops the photo's draft, so a drag that ends without saving leaves no preview behind.
    func discardDevelopDraft(for id: String) {
        if developDraft?.assetId == id { developDraft = nil }
    }

    /// Saves adjustments for each id (persisted and undoable; neutral clears the photo's edit).
    /// Each changed photo gets a history step named `undoName`; undoing takes it away again.
    func commitDevelop(_ settings: [String: DevelopSettings], undoName: String,
                       history change: DevelopHistoryChange = .append) {
        // a drag on another photo carries on
        if let draft = developDraft, settings[draft.assetId] != nil { developDraft = nil }
        let before = Dictionary(uniqueKeysWithValues: settings.keys.map { ($0, developSettings[$0] ?? .neutral) })
        guard before != settings else { return }
        let changed = settings.filter { before[$0.key] != $0.value }
        // each changed photo's settings encoded once, for both the settings and the history rows
        var json: [String: String] = [:]
        do {
            if let store {
                json = try DevelopHistoryStep.json(changed.filter { !$0.value.isNeutral })
                try store.saveDevelopSettings(settings, json: json)
            }
        } catch {
            push("保存调整失败，更改未写入目录库", "warning")
            return
        }
        for (id, value) in settings { developSettings[id] = value.isNeutral ? nil : value }
        let recorded = recordDevelopHistory(changed, name: undoName, change: change, json: json)
        // undo takes away only the steps this edit stored; redo appends anew and keeps its own,
        // except where the undo couldn't take the step away (it is still there)
        let opposite: DevelopHistoryChange
        switch change {
        case .append: opposite = .revert(recorded)
        case .appendSkipping(let kept): opposite = .revert(recorded.union(kept))
        case .revert(let ids): opposite = .appendSkipping(Set(changed.keys).intersection(ids).subtracting(recorded))
        }
        registerUndoStep(undoName) { $0.commitDevelop(before, undoName: undoName, history: opposite) }
    }

    /// Saves a change to one photo's saved settings (not its draft) as one undo step.
    func commitDevelop(_ id: String, undoName: String, _ change: (inout DevelopSettings) -> Void) {
        var next = developSettings[id] ?? .neutral
        change(&next)
        commitDevelop([id: next], undoName: undoName)
    }

    /// The spot tool's mode picker: sets the brush's mode and switches the selected spot's. Heal
    /// and clone trade places; a remove spot is made by painting, not by switching, so choosing
    /// remove, or another mode for a remove spot, only deselects it.
    func setSpotMode(_ mode: SpotRemoval.Mode, for asset: Asset) {
        developSpotBrush.mode = mode
        let shown = developSettings(for: asset.id)
        let index = shown.spots.firstIndex { $0.id == developSelectedSpotId }
        guard let index, mode != .remove, shown.spots[index].mode != .remove else {
            if mode == .remove || index.map({ shown.spots[$0].mode == .remove }) == true {
                developSelectedSpotId = nil
            }
            return
        }
        guard (developSettings[asset.id] ?? .neutral).spots.indices.contains(index) else { return }
        commitDevelop(asset.id, undoName: L("污点模式")) { $0.spots[index].mode = mode }
    }

    /// Saves a change background work made (a spot's source found, a subject masked, auto tone
    /// measured) to each photo's saved settings — and, when the user is mid-drag on one of
    /// them, to the drag as well, so neither the change nor the drag is lost on release.
    func commitDevelopChange(_ ids: [String], undoName: String, _ change: (String, inout DevelopSettings) -> Void) {
        var next: [String: DevelopSettings] = [:]
        for id in ids {
            var settings = developSettings[id] ?? .neutral
            change(id, &settings)
            next[id] = settings
        }
        var draft = developDraft
        if var dragging = draft, next[dragging.assetId] != nil {
            change(dragging.assetId, &dragging.settings)
            draft = dragging
        }
        commitDevelop(next, undoName: undoName)
        developDraft = draft
    }
}
