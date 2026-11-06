import AppKit
import Foundation

@MainActor
extension AppState {
    /// Both side panels out of the way (Tab), the photo given the window's width.
    var panelsHidden: Bool { !sidebarVisible && !(showInspector && inspectorAvailable) }

    func togglePanels() {
        let anyVisible = sidebarVisible || (showInspector && inspectorAvailable)
        sidebarVisible = !anyVisible
        showInspector = !anyVisible
    }

    /// Z: fit ↔ 1:1 in Loupe and Compare; from the grid it opens the photo at 1:1.
    func toggleZoom() -> Bool {
        switch view {
        case .grid:
            guard let primaryId else { return false }
            openLoupe(primaryId)
            loupeZoom = .actualSize
        case .loupe:
            guard primary?.isVideo != true else { return true }   // a video plays at its own size
            loupeZoom = loupeZoom == nil ? .actualSize : nil
        case .compare:
            compareZoom = compareZoom == nil ? .actualSize : nil
        case .develop:
            // the crop, mask and spot tools show the whole photo; zoom would only slow them down
            guard !developCropping, !developMasking, !developSpotting, !developComparing else { return true }
            loupeZoom = loupeZoom == nil ? .actualSize : nil
        case .survey:
            guard let primaryId else { return false }
            openLoupe(primaryId)
            loupeZoom = .actualSize
        case .analysis:
            return false
        }
        return true
    }

    // ----- search focus signal (Cmd+F) -----
    func focusSearch() { searchFocusToken += 1 }

    func showSettings() { settingsRequest &+= 1 }

    /// Settings, opened at `category` (as the window names them, e.g. "ai").
    func openSettings(category: String) {
        settingsStartCategory = category
        settingsRequest &+= 1
    }

    func showNewSmartAlbumBuilder() {
        smartAlbumEditingID = nil
        sheet = "smart"
    }

    func toggleFilterBar() {
        filterOpen.toggle()
        push(filterOpen ? "已显示筛选栏" : "已隐藏筛选栏", "filter")
    }

    func toggleGridInfo() {
        showInfo.toggle()
        push(showInfo ? "已显示缩略图信息" : "已隐藏缩略图信息", showInfo ? "info" : "eye")
    }

    func toggleGridFill() {
        gridFill.toggle()
        push(gridFill ? "缩略图填满方格" : "缩略图显示完整画面", "grid")
    }

    func adjustThumbnailSize(by delta: CGFloat) {
        let next = min(280, max(108, thumbSize + delta))
        guard next != thumbSize else { return }
        thumbSize = next
    }

    func resetThumbnailSize() {
        thumbSize = 168
    }

    @discardableResult
    func dismissTransientUI() -> Bool {
        if sheet != nil {
            // Esc is the dialog's Cancel, which for Describe Photos also lets go of the photos it took
            if sheet == "describe" { invalidateDescriptionReview() }
            sheet = nil
            smartAlbumEditingID = nil
            return true
        }
        if filterOpen {
            filterOpen = false
            return true
        }
        if view == .develop, developPickingWhiteBalance {
            developPickingWhiteBalance = false
            return true
        }
        if view == .develop, developPickingFocus {
            developPickingFocus = false
            return true
        }
        if view == .develop, developCropping {
            developCropping = false
            return true
        }
        if view == .develop, developSpotting {
            developSpotting = false
            return true
        }
        if view == .develop, developPickingRangeColor {
            developPickingRangeColor = false
            return true
        }
        if view == .develop, developMaskCreation != nil {
            developMaskCreation = nil
            return true
        }
        if view == .develop, developMasking {
            developMasking = false
            return true
        }
        if view == .develop, developComparing {
            developComparing = false
            return true
        }
        if view == .loupe || view == .develop, loupeZoom != nil {
            loupeZoom = nil
            return true
        }
        if view == .compare, compareZoom != nil {
            compareZoom = nil
            return true
        }
        if view != .grid {
            view = .grid
            return true
        }
        return false
    }

    // ---------- toasts ----------
    /// A toast in the user's language (see `L`).
    func push(_ message: String.LocalizationValue, _ icon: String = "check") {
        toastCenter.push(String(localized: message), icon)
    }

    /// A toast whose text is already localized, or is the user's own content.
    func push(verbatim message: String, _ icon: String = "check") {
        toastCenter.push(message, icon)
    }

    // ---------- onboarding ----------
    func enterApp(_ action: String) {
        welcomeAnim = true
        Task { [weak self, action] in
            try? await Task.sleep(for: .seconds(0.42))
            guard let self else { return }
            UserDefaults.app.set("1", forKey: "pc_onboarded")
            self.onboarded = true
            if action == "import" { self.sheet = "import" }
        }
    }

    func saveSmart(name: String, rule: SmartRule, count: Int) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !rule.conditions.isEmpty else {
            push("智能相册需要名称和至少一个条件", "warning")
            return
        }
        if let id = smartAlbumEditingID {
            guard let index = smartAlbums.firstIndex(where: { $0.id == id }) else {
                push("智能相册不存在", "warning")
                return
            }
            let previous = smartAlbums[index]
            let album = SmartAlbum(id: id, name: name, rule: rule, count: count, setId: previous.setId)
            if let store {
                do {
                    try store.saveSmartAlbum(album, sortOrder: index)
                } catch {
                    push("智能相册保存失败", "warning")
                    return
                }
            }
            smartAlbums[index] = album
            dismissSmartAlbumBuilder()
            selection = Selection(type: .smart, id: id, name: name)
            ensurePrimaryValid()
            push("已更新智能相册「\(previous.name)」", "sparkles")
            return
        }
        let id = "sm-" + UUID().uuidString.prefix(5)
        let album = SmartAlbum(id: id, name: name, rule: rule, count: count)
        if let store {
            do {
                try store.saveSmartAlbum(album, sortOrder: smartAlbums.count)
            } catch {
                push("智能相册保存失败", "warning")
                return
            }
        }
        smartAlbums.append(album)
        dismissSmartAlbumBuilder()
        selection = Selection(type: .smart, id: id, name: name)
        ensurePrimaryValid()
        push("已创建智能相册「\(name)」", "sparkles")
    }
}
