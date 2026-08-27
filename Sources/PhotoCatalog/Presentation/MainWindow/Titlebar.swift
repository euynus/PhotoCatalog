// ============================================================
//  Titlebar / toolbar
// ============================================================
import SwiftUI

func inspectorToggleLabel(isVisible: Bool) -> String {
    isVisible ? "隐藏简介 (⌘I)" : "显示简介 (⌘I)"
}

struct Titlebar: View {
    @Environment(AppState.self) var app
    @FocusState private var searchFocused: Bool
    // Local echo of app.search — committed debounced so each keystroke doesn't
    // pay a synchronous full-library filter + sort.
    @State private var searchText = ""

    var body: some View {
        HStack(spacing: 10) {
            // leading padding clears the real macOS traffic-light controls
            Color.clear.frame(width: 62, height: 1)

            ToolButton(icon: "importIcon", label: "导入 / 添加文件夹",
                       horizontalPadding: 8,
                       action: { app.addFolder() }) {
                Text("导入").font(.system(size: 12.5, weight: .medium))
            }

            HStack(spacing: 7) {
                Icon("aperture", size: 14).foregroundStyle(Theme.accent)
                Text(app.catalogDisplayName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.text2)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
            rightGroup
        }
        .padding(.horizontal, 14)
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
                           action: { app.toggleFilterBar() })
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
            if app.view == .grid { sizeSlider }

            separator

            CatalogActionsMenu()
            ToolButton(icon: "gear", label: "设置", action: { app.showSettings() })
            ToolButton(icon: "inspector", label: inspectorToggleLabel(isVisible: app.showInspector),
                       active: app.showInspector,
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
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
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
        .onChange(of: app.searchBlurToken) { searchFocused = false }
    }

    private var sizeSlider: some View {
        @Bindable var app = app   // the slider binding needs the Bindable projection
        return HStack(spacing: 6) {
            Icon("photos", size: 13).foregroundStyle(Theme.text3)
            Slider(value: $app.thumbSize, in: 108...280)
                .frame(width: 76)
                .controlSize(.mini)
                .tint(Theme.surfaceHi)
                .accessibilityLabel("缩略图大小")
                .help("调整缩略图大小")
        }
        .padding(.horizontal, 4)
    }

    private var separator: some View {
        Rectangle().fill(Theme.line2).frame(width: 1, height: 22).padding(.horizontal, 5)
    }
}

private struct CatalogActionsMenu: View {
    @Environment(AppState.self) private var app
    @State private var hover = false

    var body: some View {
        Menu {
            Button {
                app.addSelectionToAlbum()
            } label: {
                Label("加入相册…", systemImage: "rectangle.stack")
            }
            .disabled(!app.canApplySelectionToAlbum)

            if app.canRemoveSelectionFromCurrentAlbum {
                Button(role: .destructive) {
                    app.removeSelectionFromCurrentAlbum()
                } label: {
                    Label("从当前相册移除", systemImage: "minus.circle")
                }
            }

            Button {
                app.exportSelection()
            } label: {
                Label("导出选中原件…", systemImage: "square.and.arrow.up")
            }
            .disabled(!app.canExportOriginalSelection)

            if app.canSaveCurrentFilter || app.canPinCurrentSelection {
                Divider()
            }
            if app.canSaveCurrentFilter {
                Button {
                    app.saveCurrentFilterAsSmartAlbum()
                } label: {
                    Label("保存筛选为智能相册…", systemImage: "sparkles")
                }
            }
            if app.canPinCurrentSelection {
                Button {
                    app.togglePinCurrentSelection()
                } label: {
                    Label(app.isCurrentSelectionPinned ? "从收藏夹取消固定" : "固定到收藏夹",
                          systemImage: app.isCurrentSelectionPinned ? "star.slash" : "star")
                }
            }

            if hasSourceActions {
                Divider()
            }
            if app.canPromoteSelectedSource {
                Button {
                    app.promoteSelectedSource()
                } label: {
                    Label("提高源优先级", systemImage: "arrow.up")
                }
            }
            if app.canDemoteSelectedSource {
                Button {
                    app.demoteSelectedSource()
                } label: {
                    Label("降低源优先级", systemImage: "arrow.down")
                }
            }
            if app.canReauthorizeSelectedSource {
                Button {
                    app.reauthorizeSelectedSource()
                } label: {
                    Label("重新授权源…", systemImage: "link")
                }
            }
            if app.canRemoveSelectedSource {
                Button(role: .destructive) {
                    app.removeSelectedSource()
                } label: {
                    Label("移除源索引…", systemImage: "trash")
                }
            }
        } label: {
            Label("更多操作", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
                .font(.system(size: 16))
                .frame(width: 30, height: 30)
                .foregroundStyle(hover ? Theme.text : Theme.text2)
                .background(hover ? Theme.surface : .clear)
                .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hover = $0 }
        .help("更多操作")
        .accessibilityLabel("更多操作")
    }

    private var hasSourceActions: Bool {
        app.canPromoteSelectedSource || app.canDemoteSelectedSource
            || app.canReauthorizeSelectedSource || app.canRemoveSelectedSource
    }
}
