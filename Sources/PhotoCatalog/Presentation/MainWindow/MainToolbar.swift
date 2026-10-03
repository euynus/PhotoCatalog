// ============================================================
//  Window toolbar — view mode, filtering, catalog actions
// ============================================================
import SwiftUI

func inspectorToggleLabel(isVisible: Bool) -> String {
    isVisible ? L("隐藏简介 (⌘I)") : L("显示简介 (⌘I)")
}

/// Each item is its own view so it re-renders only for the state it reads: rebuilding
/// the whole toolbar on every photo selection re-ran the segmented control's AppKit update.
struct MainToolbar: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem { ModulePicker() }
        ToolbarItem { ViewMenu() }
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

/// Library and Develop, named, as Lightroom's modules: where nearly all the work happens.
/// Back from Develop, the library opens in the view it was left in.
private struct ModulePicker: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Picker("模块", selection: Binding(get: { app.view == .develop },
                                         set: { $0 ? app.switchView(.develop) : app.returnToLibrary() })) {
            Text("图库").tag(false)
            Text("修图").tag(true)
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .disabled(app.isDuplicates)
        .help("图库 (G) · 修图 (D)")
    }
}

extension ViewMode {
    /// The library's ways of showing photos, as the view menu lists them.
    static let library: [ViewMode] = [.grid, .loupe, .compare, .survey, .analysis]

    var title: String {
        switch self {
        case .grid: L("网格")
        case .loupe: L("单张")
        case .compare: L("比较")
        case .survey: L("筛选视图")
        case .develop: L("修图")
        case .analysis: L("拍摄参数分析")
        }
    }

    var key: String {
        switch self {
        case .grid: "G"
        case .loupe: "E"
        case .compare: "C"
        case .survey: "N"
        case .develop: "D"
        case .analysis: "A"
        }
    }

    var symbol: String {
        switch self {
        case .grid: "square.grid.2x2"
        case .loupe: "photo"
        case .compare: "rectangle.split.2x1"
        case .survey: "square.grid.3x2"
        case .develop: "slider.horizontal.3"
        case .analysis: "chart.bar.xaxis"
        }
    }
}

/// The library's views behind one button that names the current one, in place of six
/// look-alike icons; the keys still switch directly.
private struct ViewMenu: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let current = app.view == .develop ? app.lastLibraryView : app.view
        Menu {
            Picker("视图", selection: Binding(get: { app.view }, set: { app.switchView($0) })) {
                ForEach(ViewMode.library, id: \.self) { mode in
                    Label("\(mode.title) (\(mode.key))", systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Section("网格") {
                Toggle("显示文件名 (I)", isOn: Binding(get: { app.showInfo }, set: { _ in app.toggleGridInfo() }))
                Toggle("缩略图填满方格", isOn: Binding(get: { app.gridFill }, set: { _ in app.toggleGridFill() }))
            }
        } label: {
            // one text run: a toolbar menu sizes an icon-and-title label a glyph short in Chinese
            Text("\(Image(systemName: current.symbol)) \(current.title)")
        }
        .fixedSize()
        .disabled(app.isDuplicates)
        .help("视图：网格 G · 单张 E · 比较 C · 筛选 N · 分析 A")
        .accessibilityLabel("视图")
        .accessibilityValue(current.title)
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
        .help("排序：\(app.sort.field.label) · \(app.sort.descending ? L("降序") : L("升序"))")
        .accessibilityValue("\(app.sort.field.label)，\(app.sort.descending ? L("降序") : L("升序"))")
    }
}

private struct ImportButton: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Menu {
            Button("导入照片文件夹…") { app.addFolder() }
            Button("从存储卡导入…") { app.showCardImport() }
        } label: {
            Label("导入", systemImage: "square.and.arrow.down")
        } primaryAction: {
            // a card waiting in the reader is what the user most likely wants to import
            if app.cardVolumes.isEmpty { app.addFolder() } else { app.showCardImport() }
        }
        .labelStyle(.titleAndIcon)
        .help(app.cardVolumes.isEmpty ? "导入 / 添加文件夹 (⇧⌘I)" : "从存储卡导入 · 按住查看更多导入方式")
    }
}

private struct ExportButton: View {
    @Environment(AppState.self) private var app

    var body: some View {
        // one control without a second arrow: originals and previews are in the 照片 menu
        Button { app.showRenderedExport() } label: {
            Label("导出", systemImage: "square.and.arrow.up")
        }
        .disabled(!app.canRenderedExport)
        .help("导出 (⇧⌘E) · 导出原件或预览图在“照片”菜单")
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
