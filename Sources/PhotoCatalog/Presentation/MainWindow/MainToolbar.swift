// ============================================================
//  Window toolbar — view mode, filtering, catalog actions
// ============================================================
import SwiftUI

func inspectorToggleLabel(isVisible: Bool) -> String {
    isVisible ? "隐藏简介 (⌘I)" : "显示简介 (⌘I)"
}

/// Each item is its own view so it re-renders only for the state it reads: rebuilding
/// the whole toolbar on every photo selection re-ran the segmented control's AppKit update.
struct MainToolbar: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem { ViewModePicker() }
        ToolbarItem { FilterToggle() }
        ToolbarItem { SortMenu() }
        ToolbarItem { ImportButton() }
        ToolbarItem { ExportButton() }
        ToolbarItem { CatalogActionsMenu() }
        ToolbarItem { InspectorToggle() }
    }
}

private extension AppState {
    var canFilterOrSort: Bool { !isDuplicates && view != .analysis }
}

private struct ViewModePicker: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Picker("视图", selection: Binding(get: { app.view }, set: { app.switchView($0) })) {
            Label("网格 (G)", systemImage: "square.grid.2x2").tag(ViewMode.grid)
            Label("单张 (E)", systemImage: "photo").tag(ViewMode.loupe)
            Label("比较 (C)", systemImage: "rectangle.split.2x1").tag(ViewMode.compare)
            Label("修图 (D)", systemImage: "slider.horizontal.3").tag(ViewMode.develop)
            Label("拍摄参数分析 (A)", systemImage: "chart.bar.xaxis").tag(ViewMode.analysis)
        }
        .pickerStyle(.segmented)
        .labelStyle(.iconOnly)
        .disabled(app.isDuplicates)
        .help("视图：网格 G · 单张 E · 比较 C · 修图 D · 分析 A")
    }
}

private struct FilterToggle: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let active = app.filters.activeCount
        Toggle(isOn: Binding(get: { app.filterOpen },
                             set: { if $0 != app.filterOpen { app.toggleFilterBar() } })) {
            Label(active > 0 ? "筛选（\(active) 项）" : "筛选",
                  systemImage: active > 0
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle")
        }
        .disabled(!app.canFilterOrSort)
        .help("筛选 (⇧⌘F)")
    }
}

private struct SortMenu: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Menu {
            Picker("排序方式", selection: Binding(
                get: { app.sort.field },
                set: { field in var sort = app.sort; sort.field = field; app.setSort(sort) })) {
                ForEach(Sort.Field.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
            Picker("顺序", selection: Binding(
                get: { app.sort.descending },
                set: { descending in var sort = app.sort; sort.descending = descending; app.setSort(sort) })) {
                Text("升序").tag(false)
                Text("降序").tag(true)
            }
            .pickerStyle(.inline)
        } label: {
            Label("排序", systemImage: "arrow.up.arrow.down")
        }
        .disabled(!app.canFilterOrSort)
        .help("排序：\(app.sort.field.label) · \(app.sort.descending ? "降序" : "升序")")
        .accessibilityValue("\(app.sort.field.label)，\(app.sort.descending ? "降序" : "升序")")
    }
}

private struct ImportButton: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Button { app.addFolder() } label: {
            Label("导入", systemImage: "square.and.arrow.down")
        }
        .labelStyle(.titleAndIcon)
        .help("导入 / 添加文件夹 (⇧⌘I)")
    }
}

private struct ExportButton: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Button { app.exportSelection() } label: {
            Label("导出选中原件", systemImage: "square.and.arrow.up")
        }
        .disabled(!app.canExportOriginalSelection)
        .help("导出选中原件 (⌘E)")
    }
}

private struct InspectorToggle: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Button { app.showInspector.toggle() } label: {
            Label(inspectorToggleLabel(isVisible: app.showInspector), systemImage: "sidebar.trailing")
        }
        .disabled(!app.inspectorAvailable)
        .help(inspectorToggleLabel(isVisible: app.showInspector))
    }
}

private struct CatalogActionsMenu: View {
    @Environment(AppState.self) private var app

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

            Divider()
            Button {
                app.showSettings()
            } label: {
                Label("设置…", systemImage: "gearshape")
            }
        } label: {
            Label("更多操作", systemImage: "ellipsis.circle")
        }
        .help("更多操作")
    }

    private var hasSourceActions: Bool {
        app.canPromoteSelectedSource || app.canDemoteSelectedSource
            || app.canReauthorizeSelectedSource || app.canRemoveSelectedSource
    }
}
