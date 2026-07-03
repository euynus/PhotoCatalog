// ============================================================
//  MainView — the app-root layout (toolbar / body / status)
// ============================================================
import SwiftUI

struct MainView: View {
    @Environment(AppState.self) var app

    var body: some View {
        let assetRevision = app.assetRenderVersion
        VStack(spacing: 0) {
            Titlebar()
            if app.filterOpen { FilterBar() }
            HStack(spacing: 0) {
                Sidebar(assetRevision: assetRevision)
                ContentColumn(assetRevision: assetRevision)
                if app.showInspector && !app.isDuplicates {
                    InspectorView(asset: app.primary, assetRevision: assetRevision)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            StatusBar()
        }
        .background(Theme.bgContent)
        .overlay {
            // the animation makes SheetBackdrop's .transition(.opacity) real —
            // app.sheet is never set inside withAnimation, so sheets popped in
            ZStack { sheets }
                .animation(.easeOut(duration: 0.18), value: app.sheet)
        }
    }

    @ViewBuilder private var sheets: some View {
        if app.sheet == "import" {
            SheetBackdrop { ImportSheet() }
        } else if app.sheet == "smart" {
            SheetBackdrop { SmartAlbumBuilder() }
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
    @State private var infoHover = false
    @State private var dirHover = false

    var body: some View {
        HStack {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(app.selection.name)
                    .font(.system(size: 15, weight: .bold)).tracking(-0.1)
                    .foregroundStyle(Theme.text)
                Text("\(app.list.count) 张"
                     + (app.selectedIds.count > 1 ? " · 已选 \(app.selectedIds.count)" : ""))
                    .font(.system(size: 12)).foregroundStyle(Theme.text3)
            }
            Spacer()
            HStack(spacing: 12) {
                if app.view == .grid {
                    Button { app.showInfo.toggle() } label: {
                        HStack(spacing: 5) {
                            Icon(app.showInfo ? "eye" : "info", size: 14)
                            Text(app.showInfo ? "隐藏信息" : "显示信息").font(.system(size: 12))
                        }
                        .foregroundStyle(infoHover ? Theme.text : Theme.text2)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(infoHover ? Theme.surface : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .onHover { infoHover = $0 }
                }
                sortControl
            }
        }
        .padding(.horizontal, 16)
        .frame(height: Theme.contentHeadH)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var sortControl: some View {
        HStack(spacing: 6) {
            Icon("sort", size: 14).foregroundStyle(Theme.text3)
            Menu {
                ForEach(Sort.Field.allCases, id: \.self) { f in
                    Button(f.label) { var s = app.sort; s.field = f; app.setSort(s) }
                }
            } label: {
                Text(app.sort.field.label).font(.system(size: 12.5)).foregroundStyle(Theme.text2)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Button {
                var s = app.sort; s.descending.toggle(); app.setSort(s)
            } label: {
                Text(app.sort.descending ? "↓" : "↑")
                    .font(.system(size: 14)).foregroundStyle(dirHover ? Theme.text : Theme.text2)
                    .frame(width: 22, height: 22)
                    .background(dirHover ? Theme.surface : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .onHover { dirHover = $0 }
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
