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
        HStack(spacing: 12) {
            // leading padding clears the real macOS traffic-light controls
            Color.clear.frame(width: 62, height: 1)

            HStack(spacing: 8) {
                Icon("aperture", size: 22, weight: .medium)
                    .foregroundStyle(Theme.accent)
                Text("PhotoCatalog")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                separator
                Text(app.catalogDisplayName)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(app.catalogDisplayName)

            Spacer(minLength: 16)
            searchField
            separator
            rightGroup
        }
        .padding(.horizontal, 14)
        .frame(height: Theme.titlebarH)
        .background(Theme.bgTitlebar)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var rightGroup: some View {
        HStack(spacing: 6) {
            Button { app.addFolder() } label: {
                Label("导入", systemImage: "square.and.arrow.down")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .foregroundStyle(Theme.onAccent)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.rSm))
            }
            .buttonStyle(.plain)
            .help("导入 / 添加文件夹")
            .accessibilityLabel("导入 / 添加文件夹")
            ToolButton(icon: "export", label: "导出选中原件",
                       disabled: !app.canExportOriginalSelection,
                       action: { app.exportSelection() })
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
            TextField("搜索照片、关键词…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .focused($searchFocused)
                .accessibilityLabel("搜索")
            if !searchText.isEmpty {
                Button { searchText = ""; app.setSearch("") } label: {
                    Icon("close", size: 12, weight: .bold).foregroundStyle(Theme.text3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 9)
        .frame(width: 240, height: 30)
        .background(Theme.surface)
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

    private var separator: some View {
        Rectangle().fill(Theme.line2).frame(width: 1, height: 18).padding(.horizontal, 3)
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
                .frame(width: 32, height: 32)
                .foregroundStyle(hover ? Theme.text : Theme.text2)
                .background(hover ? Theme.surfaceHi : .clear)
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
