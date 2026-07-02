// ============================================================
//  Titlebar / toolbar
// ============================================================
import SwiftUI

struct Titlebar: View {
    @Environment(AppState.self) var app
    @FocusState private var searchFocused: Bool
    // Local echo of app.search — committed debounced so each keystroke doesn't
    // pay a synchronous full-library filter + sort.
    @State private var searchText = ""

    var body: some View {
        ZStack {
            // left + right groups
            HStack(spacing: 10) {
                // leading padding clears the real macOS traffic-light controls
                Color.clear.frame(width: 62, height: 1)

                ToolButton(icon: "importIcon", label: "导入 / 添加文件夹",
                           action: { app.addFolder() }) {
                    Text("导入").font(.system(size: 12.5, weight: .medium))
                }

                Spacer()

                rightGroup
            }
            .padding(.horizontal, 14)

            // absolutely-centered catalog name
            HStack(spacing: 7) {
                Icon("aperture", size: 14).foregroundStyle(Theme.accent)
                Text("PhotoCatalog Library")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.text2)
            }
        }
        .frame(height: Theme.titlebarH)
        .background(Theme.titlebarGradient)
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.04)).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.45)).frame(height: 1) }
    }

    private var rightGroup: some View {
        HStack(spacing: 4) {
            Segmented(
                options: [
                    SegOption(value: "grid", icon: "grid", title: "网格 (G)"),
                    SegOption(value: "loupe", icon: "loupe", title: "单张 (E)"),
                    SegOption(value: "compare", icon: "compare", title: "比较 (C)"),
                ],
                value: app.view.rawValue,
                onChange: { app.switchView(ViewMode(rawValue: $0) ?? .grid) })

            separator

            ZStack(alignment: .topTrailing) {
                ToolButton(icon: "filter", label: "筛选",
                           active: app.filterOpen || app.filters.activeCount > 0,
                           action: { app.filterOpen.toggle() })
                if app.filters.activeCount > 0 {
                    Text("\(app.filters.activeCount)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(minWidth: 14, minHeight: 14)
                        .background(Theme.accent).clipShape(Capsule())
                        .offset(x: -2, y: 2)
                }
            }

            searchField
            if app.canSaveCurrentFilter {
                ToolButton(icon: "sparkles", label: "保存筛选为智能相册",
                           action: { app.saveCurrentFilterAsSmartAlbum() })
            }

            sizeSlider

            separator

            if app.canPinCurrentSelection {
                ToolButton(icon: "star",
                           label: app.isCurrentSelectionPinned ? "取消固定" : "固定到收藏夹",
                           active: app.isCurrentSelectionPinned,
                           action: { app.togglePinCurrentSelection() })
            }
            if app.canPromoteSelectedSource {
                ToolButton(icon: "chevronU", label: "提高源优先级",
                           action: { app.promoteSelectedSource() })
            }
            if app.canDemoteSelectedSource {
                ToolButton(icon: "chevronD", label: "降低源优先级",
                           action: { app.demoteSelectedSource() })
            }
            if app.canReauthorizeSelectedSource {
                ToolButton(icon: "link", label: "重新授权源",
                           action: { app.reauthorizeSelectedSource() })
            }
            if app.canRemoveSelectedSource {
                ToolButton(icon: "trash", label: "移除源索引",
                           danger: true,
                           action: { app.removeSelectedSource() })
            }
            ToolButton(icon: "album", label: "加入相册",
                       disabled: !app.canApplySelectionToAlbum,
                       action: { app.addSelectionToAlbum() })
            if app.canRemoveSelectionFromCurrentAlbum {
                ToolButton(icon: "minus", label: "从相册移除",
                           danger: true,
                           action: { app.removeSelectionFromCurrentAlbum() })
            }
            ToolButton(icon: "export", label: "导出选中原件", action: { app.exportSelection() })
            ToolButton(icon: "gear", label: "设置", action: { app.sheet = "settings" })
            ToolButton(icon: "inspector", label: "显示简介 (⌘I)", active: app.showInspector,
                       action: { app.showInspector.toggle() })
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Icon("search", size: 14).foregroundStyle(Theme.text3)
            TextField("搜索", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .focused($searchFocused)
            if !searchText.isEmpty {
                Button { searchText = ""; app.setSearch("") } label: {
                    Icon("close", size: 12, weight: .bold).foregroundStyle(Theme.text3)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(width: 190, height: 30)
        .background(Color.black.opacity(0.28))
        .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
        .focusRing(searchFocused, radius: Theme.rSm)
        .onAppear { searchText = app.search }
        .onChange(of: app.search) { if app.search != searchText { searchText = app.search } }
        .task(id: searchText) {
            // the do/catch matters: .task(id:) cancels on each keystroke and a
            // swallowed CancellationError would still commit the stale text
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            if app.search != searchText { app.setSearch(searchText) }
        }
        .onChange(of: app.searchFocusToken) { searchFocused = true }
    }

    private var sizeSlider: some View {
        @Bindable var app = app   // the slider binding needs the Bindable projection
        return HStack(spacing: 6) {
            Icon("photos", size: 13).foregroundStyle(Theme.text3)
            Slider(value: $app.thumbSize, in: 108...280)
                .frame(width: 76)
                .controlSize(.mini)
                .tint(Theme.surfaceHi)
        }
        .padding(.horizontal, 4)
    }

    private var separator: some View {
        Rectangle().fill(Theme.line2).frame(width: 1, height: 22).padding(.horizontal, 5)
    }
}
