import AppKit
import Foundation

@MainActor
extension AppState {
    /// Q: opens the spot tool (from any view) or closes it; false when the photo can't be edited.
    @discardableResult
    func toggleSpotTool() -> Bool {
        guard let primary, canDevelop(primary) else { return false }
        if view != .develop { switchView(.develop) }
        guard view == .develop else { return false }
        developSpotting.toggle()
        return true
    }

    /// Heals a spot at `target` (source-photo fractions) of `radius`, taking the replacement
    /// from the best-matching place nearby.
    func addSpot(at target: CGPoint, radius: Double, to assetId: String) {
        guard let asset = assetIndex[assetId].map({ assets[$0] }), let source = developSource(for: asset) else { return }
        let brush = developSpotBrush
        let distortion = developSettings[assetId]?.distortion ?? 0
        Task { [weak self] in
            let from = await ThumbnailRepairQueue.run(.visible) {
                SpotFinder.source(for: target, radius: radius, url: source.url, isRaw: source.isRaw, distortion: distortion)
            } ?? nil
            guard let self else { return }
            var spot = SpotRemoval(target: target, source: from ?? CGPoint(x: min(1, target.x + radius * 2.5), y: target.y),
                                   radius: radius)
            spot.mode = brush.mode
            spot.feather = brush.feather
            spot.opacity = brush.opacity
            self.developSelectedSpotId = spot.id
            self.commitDevelopChange([assetId], undoName: L("污点去除")) { _, settings in settings.spots.append(spot) }
        }
    }

    /// Smart remove: fills the area painted over (`stroke`, in source-photo fractions) with what
    /// the photo's surroundings suggest, made by the bundled inpainting model before the spot is
    /// added, so every render finds it ready.
    func addRemoval(_ stroke: BrushStroke, to assetId: String) {
        guard !developRemoving, stroke.pointCount > 0, let asset = assetIndex[assetId].map({ assets[$0] }),
              let source = developSource(for: asset) else { return }
        let points = (0..<stroke.pointCount).map(stroke.point)
        let center = CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
                             y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
        // the circle that holds every dab, for picking the spot out on the photo
        let frame = developSourceSize(for: asset)
        let longEdge = max(frame.width, frame.height)
        let reach = points.map { hypot(($0.x - center.x) * frame.width, ($0.y - center.y) * frame.height) / longEdge }.max() ?? 0
        var spot = SpotRemoval(target: center, source: center, radius: Double(reach) + stroke.radius)
        spot.mode = .remove
        spot.strokes = [stroke]
        spot.opacity = developSpotBrush.opacity
        var next = developSettings[assetId] ?? .neutral
        next.spots.append(spot)
        let index = next.spots.count - 1
        developRemoving = true
        Task { [weak self, next, spot] in
            let fill = await ThumbnailRepairQueue.run(.visible) {
                GenerativeFill.fill(for: index, settings: next, url: source.url, isRaw: source.isRaw)
            } ?? nil
            guard let self else { return }
            self.developRemoving = false
            guard fill != nil else {
                self.push("原件不可用，无法移除", "warning")
                return
            }
            self.developSelectedSpotId = spot.id
            self.commitDevelopChange([assetId], undoName: L("移除")) { _, settings in settings.spots.append(spot) }
        }
    }

    func deleteSpot(_ id: String, from assetId: String) {
        var next = developSettings[assetId] ?? .neutral
        guard let index = next.spots.firstIndex(where: { $0.id == id }) else { return }
        next.spots.remove(at: index)
        if developSelectedSpotId == id { developSelectedSpotId = next.spots.last?.id }
        commitDevelop([assetId: next], undoName: L("删除污点"))
    }

    /// Finds the photo's subject or sky and adds it as a mask, or says there's none.
    func addAutomaticMask(_ kind: LocalAdjustment.Kind) {
        guard kind.isAutomatic, developDetectingMask == nil, view == .develop, let asset = primary,
              let source = developSource(for: asset) else { return }
        developMasking = true
        developMaskCreation = nil
        developDetectingMask = kind
        let id = asset.id
        Task { [weak self] in
            let lookup = await ThumbnailRepairQueue.run(.visible) {
                SemanticMasks.lookup(kind, url: source.url, isRaw: source.isRaw)
            } ?? .unreadable
            guard let self else { return }
            self.developDetectingMask = nil
            guard let found = self.maskResult(lookup, notFound: kind == .subject ? L("没有找到明显的主体") : L("没有找到天空"))
            else { return }
            var mask = LocalAdjustment(kind: kind)
            mask.center = found.centroid
            mask.exposure = kind == .sky ? -0.3 : 0.3   // a visible start, as with the gradients
            self.developMaskCreation = nil
            self.developSelectedMaskId = mask.id
            self.commitDevelopChange([id], undoName: L("添加\(mask.kind.title)")) { _, settings in
                settings.masks.append(mask)
            }
        }
    }

    /// Finds the people in the photo and adds a mask of `part` of all of them, or says what
    /// wasn't there.
    func addPeopleMask(_ part: PersonPart) {
        guard developDetectingMask == nil, view == .develop, let asset = primary,
              let source = developSource(for: asset) else { return }
        developMasking = true
        developMaskCreation = nil
        developDetectingMask = .person
        let id = asset.id
        Task { [weak self] in
            let (lookup, count) = await ThumbnailRepairQueue.run(.visible) {
                (PeopleMasks.lookup(part, person: nil, url: source.url, isRaw: source.isRaw),
                 PeopleMasks.analysis(url: source.url, isRaw: source.isRaw)?.count)
            } ?? (.unreadable, nil)
            guard let self else { return }
            self.developDetectingMask = nil
            if let count { self.developPeopleCounts[id] = count }
            guard let result = self.maskResult(lookup, notFound: Self.peopleNotFound(count)) else { return }
            var mask = LocalAdjustment(kind: .person)
            mask.part = part
            mask.center = result.centroid
            mask.exposure = 0.3   // a visible start, as with the other masks
            self.developSelectedMaskId = mask.id
            self.commitDevelopChange([id], undoName: L("添加\(mask.title)")) { _, settings in
                settings.masks.append(mask)
            }
        }
    }

    /// Points a people mask at another part, or another person (nil: everyone), once the photo
    /// is seen to show it.
    func setPeopleMask(_ maskId: String, part: PersonPart, person: Int?) {
        guard let asset = primary, let source = developSource(for: asset),
              let mask = developSettings[asset.id]?.masks.first(where: { $0.id == maskId && $0.kind == .person }),
              mask.part != part || mask.person != person else { return }
        let id = asset.id
        Task { [weak self] in
            let (lookup, count) = await ThumbnailRepairQueue.run(.visible) {
                (PeopleMasks.lookup(part, person: person, url: source.url, isRaw: source.isRaw),
                 PeopleMasks.analysis(url: source.url, isRaw: source.isRaw)?.count)
            } ?? (.unreadable, nil)
            guard let self, let result = self.maskResult(lookup, notFound: Self.peopleNotFound(count)) else { return }
            self.commitDevelopChange([id], undoName: L("更改人物蒙版")) { _, settings in
                guard let index = settings.masks.firstIndex(where: { $0.id == maskId }) else { return }
                settings.masks[index].part = part
                settings.masks[index].person = person
                settings.masks[index].center = result.centroid
            }
        }
    }

    /// Looks at the photo's people when a people mask is shown without knowing how many there are.
    func loadPeopleCount(for asset: Asset) {
        guard developPeopleCounts[asset.id] == nil, let source = developSource(for: asset) else { return }
        let id = asset.id
        Task { [weak self] in
            let count = await ThumbnailRepairQueue.run(.visible) {
                PeopleMasks.analysis(url: source.url, isRaw: source.isRaw)?.count
            } ?? nil
            if let count { self?.developPeopleCounts[id] = count }
        }
    }

    /// Finds `category` of the landscape in the photo and adds it as a mask, or says it isn't
    /// there.
    func addLandscapeMask(_ category: LandscapeCategory) {
        guard developDetectingMask == nil, view == .develop, let asset = primary,
              let source = developSource(for: asset) else { return }
        developMasking = true
        developMaskCreation = nil
        developDetectingMask = .landscape
        let id = asset.id
        Task { [weak self] in
            let lookup = await ThumbnailRepairQueue.run(.visible) {
                SceneSegmentation.lookup(category, url: source.url, isRaw: source.isRaw)
            } ?? .unreadable
            guard let self else { return }
            self.developDetectingMask = nil
            guard let result = self.maskResult(lookup, notFound: L("照片中没有找到\(category.title)")) else { return }
            var mask = LocalAdjustment(kind: .landscape)
            mask.landscape = category
            mask.center = result.centroid
            mask.exposure = 0.3   // a visible start, as with the other masks
            self.developSelectedMaskId = mask.id
            self.commitDevelopChange([id], undoName: L("添加\(mask.title)")) { _, settings in
                settings.masks.append(mask)
            }
        }
    }

    /// Points a landscape mask at another category, once the photo is seen to show it.
    func setLandscapeMask(_ maskId: String, category: LandscapeCategory) {
        guard let asset = primary, let source = developSource(for: asset),
              let mask = developSettings[asset.id]?.masks.first(where: { $0.id == maskId && $0.kind == .landscape }),
              mask.landscape != category else { return }
        let id = asset.id
        Task { [weak self] in
            let lookup = await ThumbnailRepairQueue.run(.visible) {
                SceneSegmentation.lookup(category, url: source.url, isRaw: source.isRaw)
            } ?? .unreadable
            guard let self, let result = self.maskResult(lookup, notFound: L("照片中没有找到\(category.title)")) else { return }
            self.commitDevelopChange([id], undoName: L("更改景观蒙版")) { _, settings in
                guard let index = settings.masks.firstIndex(where: { $0.id == maskId }) else { return }
                settings.masks[index].landscape = category
                settings.masks[index].center = result.centroid
            }
        }
    }

    /// The mask found, or nil after saying why there's none: `notFound` says what wasn't there.
    private func maskResult(_ lookup: SemanticMasks.Lookup, notFound: String) -> SemanticMasks.Result? {
        switch lookup {
        case .found(let result): return result
        case .notFound: push(verbatim: notFound, "info")
        case .unreadable: push("原件不可用", "warning")
        }
        return nil
    }

    /// Selects the object `prompt` (a box or a click on the photo as shown) picks out as a new
    /// mask, or, with `maskId`, gives that object mask the new prompt (more clicks, or a new box).
    /// `decoded`: the prompt is already in the photo as decoded (see `ObjectPrompt`).
    func selectObject(_ prompt: ObjectPrompt, maskId: String? = nil, decoded: Bool = false) {
        guard !prompt.isEmpty, developDetectingMask == nil, view == .develop, let asset = primary,
              let source = developSource(for: asset) else { return }
        // picked on the photo with its manual distortion correction; looked for, and kept, in the
        // photo as decoded
        let prompt = decoded ? prompt : prompt.inPhotoAsDecoded(distortion: developSettings[asset.id]?.distortion ?? 0,
                                                                 sourceSize: developSourceSize(for: asset))
        developDetectingMask = .object
        let id = asset.id
        Task { [weak self] in
            let lookup = await ThumbnailRepairQueue.run(.visible) {
                ObjectSelection.lookup(prompt, url: source.url, isRaw: source.isRaw)
            } ?? .unreadable
            guard let self else { return }
            self.developDetectingMask = nil
            guard let result = self.maskResult(lookup, notFound: L("这里没有找到物体")) else { return }
            if let maskId {
                self.commitDevelopChange([id], undoName: L("修改物体蒙版")) { _, settings in
                    guard let index = settings.masks.firstIndex(where: { $0.id == maskId }) else { return }
                    settings.masks[index].prompt = prompt
                    settings.masks[index].center = result.centroid
                }
                return
            }
            var mask = LocalAdjustment(kind: .object)
            mask.prompt = prompt
            mask.center = result.centroid
            mask.exposure = 0.3   // a visible start, as with the other masks
            self.developMaskCreation = nil
            self.developSelectedMaskId = mask.id
            self.commitDevelopChange([id], undoName: L("添加\(mask.title)")) { _, settings in
                settings.masks.append(mask)
            }
        }
    }

    /// A click on the selected object mask (on the photo as shown): adds the place to the object,
    /// or with `include` false leaves it out.
    func addObjectPoint(_ point: CGPoint, include: Bool, maskId: String) {
        guard let asset = primary, let settings = developSettings[asset.id],
              let mask = settings.masks.first(where: { $0.id == maskId && $0.kind == .object }) else { return }
        let decoded = DevelopGeometry.distortionSource(point, distortion: settings.distortion, sourceSize: developSourceSize(for: asset))
        selectObject(mask.prompt.adding(decoded, include: include), maskId: maskId, decoded: true)
    }

    /// Why a people mask came back empty: no one in the photo, or not this part of them.
    private static func peopleNotFound(_ count: Int?) -> String {
        count == 0 ? L("没有找到人物") : L("照片中看不到这个部位")
    }

    /// [ and ]: a smaller or larger brush.
    func resizeBrush(by delta: Double) {
        developBrush.size = min(100, max(1, developBrush.size + delta))
    }

    /// M / ⇧M / K or the panel's buttons: arms a new gradient or the brush, opening Develop and
    /// the masking tool; false when the photo can't be edited.
    @discardableResult
    func armMask(_ kind: LocalAdjustment.Kind) -> Bool {
        guard let primary, canDevelop(primary) else { return false }
        if view != .develop { switchView(.develop) }
        guard view == .develop else { return false }
        developMasking = true
        developMaskCreation = developMaskCreation == kind ? nil : kind
        return true
    }

    /// Saves `mask` as the photo's newest mask and selects it.
    func addMask(_ mask: LocalAdjustment, to assetId: String) {
        var next = developSettings[assetId] ?? .neutral
        next.masks.append(mask)
        developMaskCreation = nil
        developSelectedMaskId = mask.id
        commitDevelop([assetId: next], undoName: L("添加\(mask.kind.title)"))
    }

    /// A color or luminance range mask over the whole photo; a color range starts by sampling.
    func addRangeMask(_ kind: LocalAdjustment.Kind) {
        guard kind.isRange, view == .develop, let asset = primary, canDevelop(asset) else { return }
        developMasking = true
        var mask = LocalAdjustment(kind: kind)
        mask.exposure = 0.3   // a visible start, as with the gradients
        addMask(mask, to: asset.id)
        developPickingRangeColor = kind == .colorRange
    }

    /// Narrows a mask to a tone or color range (nil: the whole mask again); a color range starts
    /// by sampling.
    func setMaskRange(_ kind: MaskRange.Kind?, maskId: String, assetId: String) {
        var next = developSettings[assetId] ?? .neutral
        guard let index = next.masks.firstIndex(where: { $0.id == maskId }), !next.masks[index].kind.isRange,
              next.masks[index].range?.kind != kind else { return }
        next.masks[index].range = kind.map { MaskRange(kind: $0) }
        commitDevelop([assetId: next], undoName: kind == nil ? L("移除范围") : L("限定范围"))
        developPickingRangeColor = kind == .color
    }

    /// The range of mask `maskId` changed by `change`, previewed (`commit: false`) or saved.
    func changeMaskRange(maskId: String, assetId: String, commit: Bool, undoName: String,
                         _ change: (inout MaskRange) -> Void) {
        var next = developSettings[assetId] ?? .neutral
        guard let index = next.masks.firstIndex(where: { $0.id == maskId }), var range = next.masks[index].range
        else { return }
        change(&range)
        next.masks[index].range = range
        if commit { commitDevelop([assetId: next], undoName: undoName) } else { updateDevelopDraft(next, for: assetId) }
    }

    /// A click while sampling: the color at `point` (source fractions) joins the range. The
    /// oldest sample makes way past the limit.
    func addRangeSample(_ point: CGPoint, maskId: String, assetId: String) {
        changeMaskRange(maskId: maskId, assetId: assetId, commit: true, undoName: L("颜色取样")) { range in
            range.samples.append(point)
            if range.samples.count > MaskRange.maxSamples { range.samples.removeFirst() }
        }
    }

    func deleteMask(_ id: String, from assetId: String) {
        var next = developSettings[assetId] ?? .neutral
        guard let index = next.masks.firstIndex(where: { $0.id == id }) else { return }
        let removed = next.masks.remove(at: index)
        if developSelectedMaskId == id { developSelectedMaskId = next.masks.last?.id }
        commitDevelop([assetId: next], undoName: L("删除\(removed.title)"))
    }
}
