// ============================================================
//  MainView — the app-root layout (toolbar / body / status)
// ============================================================
import SwiftUI

struct MainView: View {
    @Environment(AppState.self) var app

    var body: some View {
        ZStack {
            mainChrome
                .disabled(app.sheet != nil || app.isLoadingCatalog)
                .accessibilityHidden(app.sheet != nil || (app.isLoadingCatalog && !app.hasCatalogPreview))
            ZStack { sheets }
                .animation(.easeOut(duration: 0.18), value: app.sheet)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bgContent)
    }

    private var mainChrome: some View {
        let assetRevision = app.assetRenderVersion
        return VStack(spacing: 0) {
            Titlebar()
            HSplitView {
                Sidebar(assetRevision: assetRevision)
                ContentColumn(assetRevision: assetRevision)
                    .frame(minWidth: Theme.contentMinW)
                    .layoutPriority(1)
                if app.showInspector && !app.isDuplicates && app.view != .analysis {
                    InspectorView(asset: app.primary, assetRevision: assetRevision)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            StatusBar()
        }
        .background(Theme.bgContent)
    }

    @ViewBuilder private var sheets: some View {
        if app.sheet == "import" {
            SheetBackdrop { ImportSheet() }
        } else if app.sheet == "smart" {
            SheetBackdrop {
                SmartAlbumBuilder(album: app.smartAlbumEditingID.flatMap { id in
                    app.smartAlbums.first { $0.id == id }
                })
            }
        } else if app.sheet == "settings" {
            SheetBackdrop { SettingsSheet() }
        }
    }
}

// ---------- Content column (header + main) ----------
struct ContentColumn: View {
    @Environment(AppState.self) var app
    let assetRevision: Int

    var body: some View {
        VStack(spacing: 0) {
            if !app.isDuplicates {
                ContentHeader()
                if app.filterOpen { FilterBar() }
            }
            contentMain
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.canvas)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bgContent)
    }

    @ViewBuilder private var contentMain: some View {
        if app.isDuplicates {
            DuplicatesView()
        } else if app.isPlaces && app.view == .grid {
            PlacesMapView()
        } else {
            switch app.view {
            case .grid: GridView(assetRevision: assetRevision)
            case .loupe: Loupe()
            case .compare: CompareView()
            case .analysis: CaptureAnalysisView()
            }
        }
    }
}

// ---------- Content header ----------
struct ContentHeader: View {
    @Environment(AppState.self) var app

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(app.selection.name)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(app.selection.name)
                Spacer(minLength: 8)
                Text("\(app.contentAssetCount) 张照片")
                    .font(.system(size: 12)).monospacedDigit()
                    .foregroundStyle(Theme.text3)
                    .fixedSize()
                if !app.selectedIds.isEmpty {
                    Text("已选 \(app.selectedIds.count)")
                        .font(.system(size: 12, weight: .medium)).monospacedDigit()
                        .foregroundStyle(Theme.accent)
                        .fixedSize()
                }
            }
            HStack(spacing: 8) {
                Segmented(
                    options: [
                        SegOption(value: "grid", icon: "grid", title: "网格 (G)"),
                        SegOption(value: "loupe", icon: "loupe", title: "单张 (E)"),
                        SegOption(value: "compare", icon: "compare", title: "比较 (C)"),
                        SegOption(value: "analysis", icon: "analysis", title: "拍摄参数分析 (A)"),
                    ], value: app.view.rawValue,
                    onChange: { app.switchView(ViewMode(rawValue: $0) ?? .grid) }, size: "sm")
                filterButton
                if app.view != .analysis { sortMenu }
                Spacer(minLength: 0)
                if app.view == .grid {
                    ToolButton(icon: app.showInfo ? "eye" : "info",
                               label: app.showInfo ? "隐藏缩略图信息" : "显示缩略图信息",
                               active: app.showInfo,
                               action: { app.toggleGridInfo() })
                    sizeSlider
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: Theme.contentHeadH)
        .background(Theme.bgContent)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var filterButton: some View {
        ToolButton(icon: "filter", label: "筛选",
                   active: app.filterOpen || app.filters.activeCount > 0,
                   action: { app.toggleFilterBar() }) {
            if app.filters.activeCount > 0 {
                Text("\(app.filters.activeCount)")
                    .font(.system(size: 11, weight: .semibold))
            }
        }
    }

    private var sizeSlider: some View {
        @Bindable var app = app
        return Slider(value: $app.thumbSize, in: 108...280)
            .frame(width: 80)
            .controlSize(.mini)
            .tint(Theme.text2)
            .accessibilityLabel("缩略图大小")
            .help("调整缩略图大小")
    }

    private var sortMenu: some View {
        Menu {
            Section("排序方式") {
                ForEach(Sort.Field.allCases, id: \.self) { f in
                    Button {
                        var sort = app.sort
                        sort.field = f
                        app.setSort(sort)
                    } label: {
                        if app.sort.field == f {
                            Label(f.label, systemImage: "checkmark")
                        } else {
                            Text(f.label)
                        }
                    }
                }
            }
            Section("顺序") {
                sortOrderButton(descending: false, label: "升序")
                sortOrderButton(descending: true, label: "降序")
            }
        } label: {
            HStack(spacing: 6) {
                Icon("sort", size: 14)
                Text(app.sort.field.label).font(.system(size: 12))
                Image(systemName: app.sort.descending ? "arrow.down" : "arrow.up")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(Theme.text2)
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(Theme.surfaceHi.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("排序：\(app.sort.field.label) · \(app.sort.descending ? "降序" : "升序")")
        .accessibilityLabel("排序")
        .accessibilityValue("\(app.sort.field.label)，\(app.sort.descending ? "降序" : "升序")")
    }

    @ViewBuilder
    private func sortOrderButton(descending: Bool, label: String) -> some View {
        Button {
            var sort = app.sort
            sort.descending = descending
            app.setSort(sort)
        } label: {
            if app.sort.descending == descending {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
    }
}

// ---------- Reusable sheet backdrop ----------
struct SheetBackdrop<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        ZStack {
            Color.black.opacity(0.24).ignoresSafeArea()
            content()
        }
        .transition(.opacity)
    }
}
