// ============================================================
//  MainView — native split view: sidebar / content / inspector
// ============================================================
import SwiftUI
import AppKit

struct MainView: View {
    @Environment(AppState.self) var app
    @Environment(\.undoManager) private var undoManager
    // Local echo of app.search — committed debounced so each keystroke doesn't
    // pay a synchronous full-library filter + sort.
    @State private var searchText = ""

    var body: some View {
        let assetRevision = app.assetRenderVersion
        NavigationSplitView(columnVisibility: Binding(
            get: { app.sidebarVisible ? .all : .detailOnly },
            set: { app.sidebarVisible = $0 != .detailOnly })) {
            Sidebar(assetRevision: assetRevision)
                .navigationSplitViewColumnWidth(min: Theme.sidebarMinW, ideal: Theme.sidebarW,
                                                max: Theme.sidebarMaxW)
        } detail: {
            ContentColumn(assetRevision: assetRevision)
                .frame(minWidth: Theme.contentMinW)
                .inspector(isPresented: inspectorPresented) {
                    Group {
                        if app.view == .develop {
                            DevelopPanel(asset: app.primary)
                        } else {
                            InspectorView(asset: app.primary, assetRevision: assetRevision)
                        }
                    }
                    .inspectorColumnWidth(min: Theme.inspectorMinW, ideal: Theme.inspectorW,
                                          max: Theme.inspectorMaxW)
                }
                .modifier(DetailTitles())
                .toolbar { MainToolbar() }
                .searchable(text: $searchText, placement: .toolbar, prompt: "搜索照片、关键词")
        }
        .disabled(app.isLoadingCatalog)
        .accessibilityHidden(app.isLoadingCatalog && !app.hasCatalogPreview)
        .sheet(isPresented: sheetPresented) { sheetContent }
        .onAppear {
            searchText = app.search
            app.undoManager = undoManager
        }
        .onChange(of: undoManager.map(ObjectIdentifier.init)) { app.undoManager = undoManager }
        .onChange(of: app.search) { if app.search != searchText { searchText = app.search } }
        .task(id: searchText) {
            // the do/catch matters: .task(id:) cancels on each keystroke and a
            // swallowed CancellationError would still commit the stale text
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            if app.search != searchText { app.setSearch(searchText) }
        }
        .onChange(of: app.searchFocusToken) { ToolbarSearchField.focus() }
        .onChange(of: app.searchBlurToken) { ToolbarSearchField.blur() }
    }

    /// Analysis and duplicate review own the full width; the user's inspector
    /// preference survives visiting them.
    private var inspectorPresented: Binding<Bool> {
        Binding(
            get: { app.showInspector && app.inspectorAvailable },
            set: { shown in
                if app.inspectorAvailable { app.showInspector = shown }
            })
    }

    private var sheetPresented: Binding<Bool> {
        Binding(get: { app.sheet != nil }, set: { if !$0 { app.sheet = nil } })
    }

    @ViewBuilder private var sheetContent: some View {
        switch app.sheet {
        case "import":
            ImportSheet()
        case "smart":
            SmartAlbumBuilder(album: app.smartAlbumEditingID.flatMap { id in
                app.smartAlbums.first { $0.id == id }
            })
        case "settings":
            SettingsSheet()
        case "renderedExport":
            let items = app.renderedExportItems()
            RenderedExportSheet(settings: app.renderedExportSettings, folder: app.renderedExportFolder,
                                sample: items.first, count: items.count)
        case "developTransfer":
            DevelopTransferSheet(mode: app.developTransferMode,
                                 fields: app.developTransferMode == .preset
                                     ? app.developPresetDefaultFields : app.developTransferFields)
        default:
            EmptyView()
        }
    }
}

extension AppState {
    var inspectorAvailable: Bool { !isDuplicates && view != .analysis }
}

/// Title and subtitle read the list count; as a modifier they update without
/// re-evaluating the split view. Selection count lives in the status bar so
/// clicking a photo doesn't re-lay out the toolbar.
private struct DetailTitles: ViewModifier {
    @Environment(AppState.self) private var app

    func body(content: Content) -> some View {
        content
            .navigationTitle(app.selection.name)
            .navigationSubtitle("\(app.catalogDisplayName) · \(app.contentAssetCount.formatted()) 张照片")
    }
}

// ---------- Content column (filters / main / status) ----------
struct ContentColumn: View {
    @Environment(AppState.self) var app
    let assetRevision: Int
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if app.filterOpen && !app.isDuplicates { FilterBar() }
            contentMain
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.canvas)
            StatusBar()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bgContent)
        .dropDestination(for: URL.self) { urls, _ in
            app.importDroppedItems(urls)
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .padding(8)
                    .overlay {
                        Label("松开以导入文件夹", systemImage: "square.and.arrow.down")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(Theme.accentFill, in: Capsule())
                    }
                    .allowsHitTesting(false)
            }
        }
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
            case .develop: DevelopView()
            case .analysis: CaptureAnalysisView()
            }
        }
    }
}

// ---------- Toolbar search focus ----------
/// SwiftUI's toolbar search field is an AppKit NSSearchToolbarItem; driving it
/// directly keeps ⌘F / click-to-blur working on macOS 14 (no `searchFocused`).
@MainActor
enum ToolbarSearchField {
    static func focus() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
              let items = window.toolbar?.items else { return }
        if let item = items.lazy.compactMap({ $0 as? NSSearchToolbarItem }).first {
            item.beginSearchInteraction()
        } else if let field = items.lazy.compactMap({ $0.view.flatMap(searchField(in:)) }).first {
            window.makeFirstResponder(field)
        }
    }

    /// Resign only the search field so an inspector edit in progress keeps focus.
    static func blur() {
        guard let window = NSApp.keyWindow,
              let editor = window.firstResponder as? NSTextView,
              editor.delegate is NSSearchField else { return }
        window.makeFirstResponder(nil)
    }

    private static func searchField(in view: NSView) -> NSSearchField? {
        if let field = view as? NSSearchField { return field }
        for sub in view.subviews { if let field = searchField(in: sub) { return field } }
        return nil
    }
}
