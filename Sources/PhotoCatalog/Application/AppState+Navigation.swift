import AppKit
import Foundation

@MainActor
extension AppState {
    // ---------- selection summary ----------
    /// What the selection holds, for enabling menus and buttons. The menu bar re-reads every
    /// item's state on each change; scanning a 500k-photo selection per item took seconds, so
    /// this is one pass per change of the selection, catalog or develop edits — and usually
    /// stops at the first photo, once every flag it can set is known.
    struct SelectionSummary: Equatable {
        /// A photo still in the catalog (location edits).
        var hasLive = false
        /// A photo with pixels to render — original or local preview (rotate, paste, presets).
        var hasDevelopable = false
        /// A developable photo carrying adjustments (reset).
        var hasDevelopEdit = false
        /// A ready local original, paired files included (open, reveal, copy/export originals).
        var hasLocalOriginal = false
        /// A ready local original among the photos themselves (rendered export).
        var hasPrimaryOriginal = false
        /// A local preview, thumbnail or original to export as a preview.
        var hasPreviewReference = false
    }
    struct SelectionSummaryKey: Equatable {
        let selection: Int
        let assets: Int
        let develop: Int
        let inDevelop: Bool
    }

    var selectionSummary: SelectionSummary {
        // read what it depends on, so views re-evaluate when those change
        _ = selectedIds.isEmpty
        _ = primaryId
        _ = developSettings.isEmpty
        let inDevelop = view == .develop
        let key = SelectionSummaryKey(selection: selectionVersion, assets: listInputsVersion,
                                      develop: developSettingsVersion, inDevelop: inDevelop)
        if let cache = selectionSummaryCache, cache.key == key { return cache.value }
        var summary = SelectionSummary()
        // local copies: an observed property read per photo paid observation bookkeeping
        // each time, which dominated a 500k-photo selection with its originals offline
        let assets = self.assets
        let developSettings = self.developSettings
        let index = assetIndex
        let companions = assetPairing.companionsByPrimary
        let targets = selectionTargetIds
        func isLocalOriginal(_ asset: Asset) -> Bool {
            !asset.deleted && !asset.isDemo && asset.status == .ready && asset.localPath != nil
        }
        func isDevelopable(_ id: String) -> Bool {
            index[id].map { !assets[$0].deleted && canDevelop(assets[$0]) } ?? false
        }
        if inDevelop {
            // Develop edits the photo on screen, whatever else is selected
            summary.hasDevelopable = primaryId.map(isDevelopable) ?? false
            summary.hasDevelopEdit = summary.hasDevelopable && primaryId.map { developSettings[$0] != nil } == true
        } else if developSettings.count < targets.count {
            // edits are usually few: look them up instead of scanning the selection for one
            summary.hasDevelopEdit = developSettings.keys.contains { targets.contains($0) && isDevelopable($0) }
        } else {
            summary.hasDevelopEdit = targets.contains { developSettings[$0] != nil && isDevelopable($0) }
        }
        for id in targets {
            guard let offset = index[id] else { continue }
            let asset = assets[offset]
            guard !asset.deleted else { continue }
            summary.hasLive = true
            let local = isLocalOriginal(asset)
            if local {
                summary.hasLocalOriginal = true
                summary.hasPrimaryOriginal = true
            } else if !summary.hasLocalOriginal,
                      companions[id]?.contains(where: { index[$0].map { isLocalOriginal(assets[$0]) } ?? false }) == true {
                summary.hasLocalOriginal = true
            }
            if !summary.hasPreviewReference, !asset.isDemo,
               local || Self.isLocalReference(asset.preview) || Self.isLocalReference(asset.thumb) {
                summary.hasPreviewReference = true
            }
            if !inDevelop, !summary.hasDevelopable, canDevelop(asset) { summary.hasDevelopable = true }
            if summary.hasLocalOriginal && summary.hasPrimaryOriginal && summary.hasPreviewReference
                && (inDevelop || summary.hasDevelopable) { break }
        }
        selectionSummaryCache = (key, summary)
        return summary
    }

    func seedInitialSelection() {
        let first = list.first
        primaryId = first?.id
        if let id = first?.id { selectedIds = [id]; anchorId = id }
    }

    // ---------- navigation ----------
    func select(_ s: Selection) {
        selection = s
        if view == .compare { view = .grid }
        ensurePrimaryValid()
    }

    func setFilters(_ f: Filters) { filters = f; ensurePrimaryValid() }
    func setSearch(_ s: String) { search = s; ensurePrimaryValid() }
    func setSort(_ s: Sort) { sort = s }

    var canSaveCurrentFilter: Bool {
        !filters.smartConditions(search: search).isEmpty
    }

    func saveCurrentFilterAsSmartAlbum() {
        let conditions = filters.smartConditions(search: search)
        guard !conditions.isEmpty else {
            push("没有可保存的筛选条件", "warning")
            return
        }
        guard let name = promptAlbumName(defaultName: defaultFilterSmartAlbumName(),
                                         messageText: L("新建智能相册")) else { return }

        let rule = SmartRule(match: "all", conditions: conditions)
        // the sidebar counts it, as the library shows the photos (a RAW's JPEG folded into it)
        saveSmart(name: name, rule: rule, count: 0)
    }

    private func defaultFilterSmartAlbumName() -> String {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty { return L("筛选 · \(q)") }
        return L("当前筛选")
    }

    func ensurePrimaryValid() {
        // Survey shows its own photos, even one a rating just took out of the list: the active one
        // stays among them (the list's first photo may not be one, and the next key edited it unseen).
        if view == .survey, let active = surveyActiveId() {
            if primaryId != active { primaryId = active }
            if selectedIds != [active] { selectedIds = [active] }
            anchorId = active
            return
        }
        let ids = list
        guard !ids.isEmpty else {
            selectedIds = []
            primaryId = nil
            anchorId = nil
            if view == .compare {
                compareIds = []
                winner = nil
            }
            return
        }
        if primaryId == nil && selectedIds.isEmpty && (view != .compare || compareIds.isEmpty) {
            // nothing to validate (e.g. a catalog just loaded): skip building the position index
            primaryId = ids[0].id
            selectedIds = [ids[0].id]
            anchorId = ids[0].id
            if view == .compare { compareIds = [ids[0].id] }
            return
        }
        var candidates = selectedIds
        if let primaryId { candidates.insert(primaryId) }
        if view == .compare {
            candidates.formUnion(compareIds)
            if let winner { candidates.insert(winner) }
        }
        let positions = listPositions(of: candidates)
        // selection must never retain assets hidden by the current collection/filter/search,
        // or batch edits (rating, flag, keyword, delete) would silently mutate off-screen photos.
        if selectedIds.contains(where: { positions[$0] == nil }) {
            selectedIds = selectedIds.filter { positions[$0] != nil }
        }
        if view == .compare {
            compareIds.removeAll { positions[$0] == nil }
            if let winner, positions[winner] == nil { self.winner = nil }
        }
        if primaryId == nil || positions[primaryId!] == nil {
            primaryId = ids[0].id
            selectedIds = [ids[0].id]
            anchorId = ids[0].id
        } else if selectedIds.isEmpty {
            selectedIds = [primaryId!]
        }
        if view == .compare, compareIds.isEmpty, let primaryId {
            compareIds = [primaryId]
        }
    }

    // ---------- selection ----------
    /// `position` when the list as last worked out shows `id` there. A click passes the position
    /// its tile was drawn at, so the next lookup of the photo needs no pass over the list; checked
    /// against that list only, so a click never works the list out again, and a stale one is dropped.
    private func checkedListPosition(_ position: Int?, of id: String) -> Int? {
        guard let position, let cache = listCache, cache.signature == currentListSignature,
              cache.value.indices.contains(position), cache.value[position].id == id else { return nil }
        return position
    }

    func selectCell(_ id: String, at position: Int? = nil, shift: Bool, meta: Bool) {
        let clicked = checkedListPosition(position, of: id)
        if shift, let anchor = anchorId {
            // with the clicked photo's place known, only the anchor is looked for (the hint
            // usually names it: it was the photo selected last)
            let positions = clicked == nil ? listPositions(of: [anchor, id]) : listPositions(of: CollectionOfOne(anchor))
            if let i1 = positions[anchor], let i2 = clicked ?? positions[id] {
                let lo = min(i1, i2), hi = max(i1, i2)
                selectedIds = Set(list[lo...hi].lazy.map(\.id))
                primaryId = id
                if let clicked { listPositionHint = (id, clicked) }
                return
            }
        }
        if meta {
            guard selectedIds.contains(id) else {
                selectedIds.insert(id)
                primaryId = id
                anchorId = id
                if let clicked { listPositionHint = (id, clicked) }
                return
            }
            selectedIds.remove(id)
            // A photo ⌘-clicked off is no longer active: left so, the inspector showed it while
            // edits went to the others (or, with none left, to it). The nearest one selected takes over.
            if let primaryId, primaryId != id, selectedIds.contains(primaryId) {
                anchorId = primaryId
                return
            }
            let positions = listPositions(of: clicked == nil ? selectedIds.union([id]) : selectedIds)
            let from = clicked ?? positions[id] ?? 0
            let byPosition = selectedIds.sorted { (positions[$0] ?? .max) < (positions[$1] ?? .max) }
            primaryId = byPosition.first { (positions[$0] ?? .max) > from } ?? byPosition.last
            anchorId = primaryId
            return
        }
        selectedIds = [id]
        primaryId = id
        anchorId = id
        if let clicked { listPositionHint = (id, clicked) }
    }

    var canChangeVisibleSelection: Bool {
        onboarded && !isLoadingCatalog && sheet == nil && view != .compare && view != .survey
    }

    @discardableResult
    func selectAllVisible() -> Bool {
        guard canChangeVisibleSelection else { return false }
        let ids = list.map(\.id)
        guard !ids.isEmpty else { return false }
        selectedIds = Set(ids)
        if primaryId == nil || !selectedIds.contains(primaryId ?? "") {
            primaryId = ids.first
        }
        anchorId = primaryId
        return true
    }

    @discardableResult
    func invertVisibleSelection() -> Bool {
        guard canChangeVisibleSelection else { return false }
        let ids = list.map(\.id)
        guard !ids.isEmpty else { return false }
        let visible = Set(ids)
        selectedIds = visible.subtracting(selectedIds)
        primaryId = ids.first { selectedIds.contains($0) }
        anchorId = primaryId
        return true
    }

    /// The post-load step of opening a catalog, for the large-catalog benchmark.
    func applyLoadedCatalogForScaleCheck(_ loaded: [Asset], from store: CatalogStore) {
        // a check's catalog: one whose albums can't be read fails the check's own assertions
        applyLoadedCatalog(loaded, from: store, collections: (try? store.loadCatalogCollections()) ?? CatalogCollections())
    }

    /// A fixture backed by a scratch catalog, for checks of catalog-persisted features. It never
    /// goes through openCatalog, which would remember the scratch catalog in preferences.
    static func selfCheckFixture(store: CatalogStore) -> AppState {
        let app = selfCheckFixture()
        app.store = store
        return app
    }

    /// A fixture that can also import into `store` (tethered capture's checks).
    static func selfCheckFixture(importingInto store: CatalogStore) -> AppState {
        let app = selfCheckFixture(store: store)
        app.coordinator = ImportCoordinator(store: store)
        return app
    }

    /// The folders watched for new and changed photos, for checks.
    var watchedFolderPaths: [String] { watchedRoots.map(\.path) }

    static func selfCheckFixture() -> AppState {
        let app = AppState(arguments: [], deferCatalogLoading: true)
        app.deferredCatalogArguments = nil
        app.isLoadingCatalog = false
        app.onboarded = true
        return app
    }

    func normalizeSelectionToVisibleList() {
        // Survey keeps its own photos, even one a rating just filtered out of the list
        guard view != .survey else { return }
        let visibleList = list
        guard !visibleList.isEmpty else {
            selectedIds = []
            primaryId = nil
            anchorId = nil
            return
        }
        let positions = listPositions(of: selectedIds.union(primaryId.map { [$0] } ?? []))
        if selectedIds.contains(where: { positions[$0] == nil }) {
            selectedIds = selectedIds.filter { positions[$0] != nil }
        }
        if let primaryId, positions[primaryId] != nil {
            if selectedIds.isEmpty { selectedIds = [primaryId] }
            anchorId = primaryId
            return
        }
        let next = selectedIds.min { (positions[$0] ?? .max) < (positions[$1] ?? .max) } ?? visibleList[0].id
        primaryId = next
        selectedIds = [next]
        anchorId = next
    }

    /// `position`: where the list shows `id`, when the caller knows (a grid tile's).
    func openLoupe(_ id: String, at position: Int? = nil) {
        let clicked = checkedListPosition(position, of: id)
        primaryId = id
        selectedIds = [id]
        if let clicked { listPositionHint = (id, clicked) }
        loupeZoom = nil
        view = .loupe
    }

    /// `position`: where the list shows `id`, when the caller knows (a filmstrip cell's).
    func setPrimary(_ id: String, at position: Int? = nil) {
        let clicked = checkedListPosition(position, of: id)
        primaryId = id
        selectedIds = [id]
        anchorId = id
        if let clicked { listPositionHint = (id, clicked) }
    }

    // ---------- compare ----------
    /// A duplicate group in Compare, among all photos: similar frames told apart at full size.
    func compareDuplicateGroup(_ group: DuplicateGroup) {
        let ids = group.items.map(\.id)
        select(Selection(type: .lib, id: "all", name: L("全部照片")))
        // a filter that hides some of the group would compare other photos in their place
        if listPositions(of: Set(ids)).count < ids.count {
            setSearch("")
            setFilters(Filters())
        }
        selectedIds = Set(ids)
        primaryId = ids.first
        enterCompare()
    }

    func enterCompare() {
        // order by display position so the chosen subset is deterministic
        let positions = listPositions(of: selectedIds)
        var ids = selectedIds.compactMap { id in positions[id].map { (id, $0) } }.sorted { $0.1 < $1.1 }.map(\.0)
        if ids.count < 2 { ids = list.prefix(3).map { $0.id } }
        compareIds = Array(ids.prefix(4))
        // align the grid selection with the compared panels so rating/flag/color shortcuts
        // act on what's on screen rather than a now-hidden grid selection
        syncCompareSelection()
        winner = nil
        view = .compare
    }

    func addToCompare(_ id: String) {
        guard compareIds.count < 4,
              !compareIds.contains(id),
              listPosition(of: id) != nil else { return }
        compareIds.append(id)
        syncCompareSelection()
    }

    func removeFromCompare(_ id: String) {
        compareIds.removeAll { $0 == id }
        syncCompareSelection()
    }

    func syncCompareSelection() {
        let ids = Set(compareIds)
        selectedIds = ids
        if let winner, !ids.contains(winner) { self.winner = nil }
        if let primaryId, ids.contains(primaryId) {
            anchorId = primaryId
            return
        }
        primaryId = compareIds.first
        anchorId = primaryId
    }

    /// Back to the library from Develop, in the view it was left in; compare and survey were
    /// of a selection that may have changed since, so they come back as the loupe.
    func returnToLibrary() {
        let last = lastLibraryView
        switchView([.compare, .survey].contains(last) ? .loupe : last)
    }

    func switchView(_ v: ViewMode) {
        if (v == .analysis || v == .develop) && isDuplicates {
            select(Selection(type: .lib, id: "all", name: L("全部照片")))
        }
        switch v {
        case .compare: enterCompare()
        case .survey: enterSurvey()
        default: view = v
        }
    }

    // ---------- survey (N) ----------
    static let surveyLimit = 30

    func enterSurvey() {
        let positions = listPositions(of: selectedIds)
        var ids = selectedIds.compactMap { id in positions[id].map { (id, $0) } }.sorted { $0.1 < $1.1 }.map(\.0)
        guard ids.count >= 2 else {
            push("选择两张或更多照片后按 N 进入筛选视图", "info")
            return
        }
        if ids.count > Self.surveyLimit {
            ids = Array(ids.prefix(Self.surveyLimit))
            push("筛选视图一次最多显示 \(String(Self.surveyLimit)) 张", "info")
        }
        let active = primaryId.flatMap { ids.contains($0) ? $0 : nil } ?? ids[0]
        surveyIds = ids
        primaryId = active
        selectedIds = [active]
        view = .survey
    }

    func activateInSurvey(_ id: String) {
        guard surveyIds.contains(id) else { return }
        primaryId = id
        selectedIds = [id]
    }

    /// Takes a photo out of the survey; the next one becomes active, and the last one leaves.
    func removeFromSurvey(_ id: String) {
        guard let index = surveyIds.firstIndex(of: id) else { return }
        surveyIds.remove(at: index)
        guard !surveyIds.isEmpty else {
            view = .grid
            return
        }
        if primaryId == id { activateInSurvey(surveyIds[min(index, surveyIds.count - 1)]) }
    }

    private func moveInSurvey(_ key: String) {
        guard let current = primaryId.flatMap({ surveyIds.firstIndex(of: $0) }) else { return }
        let next = key == "left" || key == "up" ? current - 1 : current + 1
        guard surveyIds.indices.contains(next) else { return }
        activateInSurvey(surveyIds[next])
    }

    /// The surveyed photo to keep active: the active one while it's in the catalog, else the next.
    private func surveyActiveId() -> String? {
        let live = surveyIds.filter { id in assetIndex[id].map { !assets[$0].deleted } ?? false }
        if let primaryId, live.contains(primaryId) { return primaryId }
        let start = primaryId.flatMap { surveyIds.firstIndex(of: $0) } ?? 0
        return surveyIds[start...].first(where: live.contains) ?? live.last
    }

    /// Back in the grid, the photos still in the survey are the selection — those the list shows:
    /// one a rating took out of it would be edited unseen by the next key.
    func leaveSurvey() {
        let positions = listPositions(of: Set(surveyIds))
        let remaining = surveyIds.filter { positions[$0] != nil }
        surveyIds = []
        guard view == .grid else { return }
        if !remaining.isEmpty {
            selectedIds = Set(remaining)
            if primaryId.map({ !remaining.contains($0) }) ?? true { primaryId = remaining.first }
        }
        ensurePrimaryValid()
    }

    // ---------- keyboard ----------
    /// Returns true if the key was handled.
    @discardableResult
    func handleKey(_ key: String, hasCommand: Bool, hasShift: Bool = false) -> Bool {
        if isLoadingCatalog { return true }
        // Sheets are overlays, not real modal windows — while one is open,
        // global shortcuts must not reach the photos behind the backdrop
        // (rating/flag/delete keys would silently mutate the selection).
        if sheet != nil {
            if !hasCommand && key == "escape" { return dismissTransientUI() }
            if hasCommand {
                switch key {
                case "n", "o", "f", "i", "e", "r", ",", "b", "s", "a",
                     "=", "+", "-", "0", "delete", "backspace":
                    return true
                default:
                    return false
                }
            }
            return false
        }
        if hasCommand {
            if !onboarded {
                switch key {
                case "n":
                    createCatalog()
                case "o":
                    openCatalog()
                default:
                    return false
                }
                return true
            }
            switch key {
            case "n":
                createCatalog()
            case "o":
                openCatalog()
            case "f":
                if hasShift {
                    // as the toolbar's button: no filter bar where it's disabled
                    if canFilterOrSort { toggleFilterBar() }
                } else {
                    focusSearch()
                }
            case "i":
                if hasShift {
                    addFolder()
                } else if inspectorAvailable {
                    showInspector.toggle()
                }
            case "e":
                if hasShift {
                    showRenderedExport()
                } else {
                    exportSelection()
                }
            case "r":
                rescanCurrentSource()
            case ",":
                showSettings()
            case "b":
                if hasShift {
                    restoreBackup()
                } else {
                    runBackup()
                }
            case "s":
                guard !hasShift, canSaveCurrentFilter else { return false }   // ⇧⌘S syncs settings (menu)
                saveCurrentFilterAsSmartAlbum()
            case "a":
                guard canChangeVisibleSelection else { return true }
                if hasShift {
                    guard invertVisibleSelection() else { return false }
                    push("已反选当前列表")
                } else {
                    guard selectAllVisible() else { return false }
                    push("已全选当前列表")
                }
            case "=", "+":
                adjustThumbnailSize(by: 16)
            case "-":
                adjustThumbnailSize(by: -16)
            case "0":
                resetThumbnailSize()
            case "delete", "backspace":
                guard showsSelection else { return true }
                trashSelectedOriginals()
            default:
                return false
            }
            return true
        }
        guard onboarded else { return false }

        if !showsSelection && ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "p", "x", "u", "s", "b", "delete", "backspace"].contains(key) {
            return false
        }

        switch key {
        case "escape":
            guard dismissTransientUI() else { return false }
        case "return":
            if view == .develop, developCropping || developMasking || developSpotting {
                developCropping = false
                developMasking = false
                developSpotting = false
                return true
            }
            guard let primaryId else { return false }
            openLoupe(primaryId)
        case "1", "2", "3", "4", "5", "0", "p", "x", "u", "6", "7", "8", "9":
            guard applyReviewKey(key, advance: hasShift || autoAdvance) else { return false }
        case "tab":
            togglePanels()
        case "f":
            if canFilterOrSort { toggleFilterBar() }
        case "g":
            view = .grid
        case "e", " ":
            // Space plays or pauses a video in the loupe
            if key == " ", view == .loupe, let primary, primary.isVideo, primary.status == .ready {
                videoPlaybackToggle &+= 1
                return true
            }
            view = (view == .loupe) ? .grid : .loupe
        case "c":
            enterCompare()
        case "n":
            guard view != .survey else { return true }
            switchView(.survey)
        case "z":
            guard toggleZoom() else { return false }
        case "d":
            switchView(.develop)
        case "\\":
            guard view == .develop else { return false }
            developShowsOriginal.toggle()
        case "y":
            guard view == .develop else { return false }
            developComparing.toggle()
        case "r":
            toggleCropTool()
        case "b":
            guard toggleQuickCollection() else { return false }
        case "w":
            guard view == .develop, let primary, canDevelop(primary) else { return false }
            developCropping = false
            developMasking = false
            developSpotting = false
            developPickingWhiteBalance.toggle()
        case "m":
            guard armMask(hasShift ? .radial : .linear) else { return false }
        case "k":
            guard armMask(.brush) else { return false }
        case "[", "]":
            guard view == .develop, developMasking || developSpotting else { return false }
            if developSpotting {
                developSpotBrush.size = min(100, max(1, developSpotBrush.size + (key == "[" ? -2 : 2)))
            } else {
                resizeBrush(by: key == "[" ? -5 : 5)
            }
        case "q":
            guard toggleSpotTool() else { return false }
        case "o":
            guard view == .develop, developMasking else { return false }
            developShowsMaskOverlay.toggle()
        case "a":
            switchView(.analysis)
        case "i":
            toggleGridInfo()
        case "s":
            // S proofs in Develop, as in Lightroom; elsewhere it opens or closes a stack
            if view == .develop { toggleSoftProofing() } else { toggleStackForPrimary() }
        case "up", "down", "left", "right":
            if view == .compare || !showsSelection { return false }
            if view == .survey { moveInSurvey(key); return true }
            moveSelection(key)
        case "delete", "backspace":
            // in the spot and masking tools, Delete removes the selected spot or mask, never the photo
            // (with the before view up, the tool isn't showing what it would delete: nothing happens)
            if view == .develop, developSpotting {
                if !developShowsOriginal, let id = developSelectedSpotId, let primaryId { deleteSpot(id, from: primaryId) }
                return true
            }
            if view == .develop, developMasking {
                if !developShowsOriginal, let id = developSelectedMaskId, let primaryId { deleteMask(id, from: primaryId) }
                return true
            }
            confirmDeleteSelected()
        default:
            return false
        }
        return true
    }

    /// Rating / flag / color keys. The cursor keeps its place: a photo that leaves the view
    /// (rated inside 未评分) hands over to the one that slides into its slot, and `advance`
    /// moves one further — only for a single photo in Grid or Loupe, never a batch.
    private func applyReviewKey(_ key: String, advance: Bool) -> Bool {
        guard !targetIds.isEmpty else { return false }
        let current = primaryId
        let slot = current.flatMap { listPosition(of: $0) }
        let applied: Bool
        switch key {
        case "0", "1", "2", "3", "4", "5":
            applied = applyRatingShortcut(Int(key) ?? 0)
        case "p":
            applied = setFlag(.pick)
            if applied { push("标记为精选", "flag") }
        case "x":
            applied = setFlag(.reject)
            if applied { push("标记为拒绝", "reject") }
        case "u":
            applied = setFlag(.none)
            if applied { push("已清除旗标") }
        default:
            let color: ColorLabel = ["6": .red, "7": .yellow, "8": .green][key] ?? .blue
            // as in Lightroom the key toggles: on photos that all carry the label it clears it
            let index = assetIndex, assets = self.assets
            let clears = selectionTargetIds.allSatisfy { id in index[id].map { assets[$0].colorLabel == color } ?? false }
            applied = setColor(clears ? nil : color)
            if applied {
                if clears { push("已清除颜色标签", "tag") } else { push("颜色标签：\(color.name)", "tag") }
            }
        }
        guard applied, let current, let slot, selectionTargetIds.count <= 1,
              view == .grid || view == .loupe else { return applied }
        let visibleList = list
        guard !visibleList.isEmpty else { return true }
        let next = min(visibleList.count - 1, listPosition(of: current).map { advance ? $0 + 1 : $0 } ?? slot)
        let target = visibleList[next].id
        if target != primaryId { setPrimary(target) }
        listPositionHint = (target, next)
        return true
    }

    /// Selects every rejected photo in the current view and offers to remove them.
    func confirmRemoveRejected() {
        let rejected = list.filter { $0.flag == .reject }.map(\.id)
        guard !rejected.isEmpty else {
            push("当前视图中没有被拒绝的照片", "info")
            return
        }
        selectedIds = Set(rejected)
        primaryId = rejected.first
        confirmDeleteSelected()
    }

    private func moveSelection(_ key: String) {
        let visibleList = list
        guard let primaryId, let cur = listPosition(of: primaryId) else { return }
        var cols = 1
        if view == .grid {
            // same metrics as GridView so arrow nav lands on the right row
            cols = GridMetrics(width: gridWidth ?? 800, target: thumbSize).columns
        }
        var next = cur
        switch key {
        case "right": next = min(visibleList.count - 1, cur + 1)
        case "left": next = max(0, cur - 1)
        case "down": next = min(visibleList.count - 1, cur + cols)
        case "up": next = max(0, cur - cols)
        default: break
        }
        setPrimary(visibleList[next].id)
        listPositionHint = (visibleList[next].id, next)
    }
}
