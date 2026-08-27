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
            if app.filterOpen { FilterBar() }
            HSplitView {
                Sidebar(assetRevision: assetRevision)
                ContentColumn(assetRevision: assetRevision)
                    .frame(minWidth: Theme.contentMinW)
                    .layoutPriority(1)
                if app.showInspector && !app.isDuplicates {
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
            if !app.isDuplicates { ContentHeader() }
            contentMain
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
            }
        }
    }
}

// ---------- Content header ----------
struct ContentHeader: View {
    @Environment(AppState.self) var app

    var body: some View {
        HStack {
            HStack(alignment: .center, spacing: 10) {
                Text(app.selection.name)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text("\(app.contentAssetCount) 张")
                    .font(.system(size: 12)).foregroundStyle(Theme.text3)
                if !app.selectedIds.isEmpty {
                    Label("\(app.selectedIds.count) 张已选", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .background(Theme.accentSoft)
                        .clipShape(Capsule())
                }
            }
            Spacer()
            HStack(spacing: 6) {
                if app.view == .grid {
                    ToolButton(icon: app.showInfo ? "eye" : "info",
                               label: app.showInfo ? "隐藏缩略图信息" : "显示缩略图信息",
                               active: app.showInfo,
                               action: { app.toggleGridInfo() })
                }
                sortMenu
            }
        }
        .padding(.horizontal, 16)
        .frame(height: Theme.contentHeadH)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
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
                Text(app.sort.field.label)
                    .font(.system(size: 12.5))
                Image(systemName: app.sort.descending ? "arrow.down" : "arrow.up")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(Theme.text2)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(Theme.surface.opacity(0.65))
            .overlay(RoundedRectangle(cornerRadius: Theme.rSm)
                .strokeBorder(Theme.line, lineWidth: 1))
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
            Color.black.opacity(0.5).ignoresSafeArea()
            content()
        }
        .transition(.opacity)
    }
}
