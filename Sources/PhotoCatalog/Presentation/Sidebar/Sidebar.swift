// ============================================================
//  Sidebar — native source list (library, collections, dates, folders)
// ============================================================
import SwiftUI

/// List-selection identity for a sidebar row. Names can change (album rename)
/// without moving the highlight, so only kind + id participate in equality.
struct SidebarTag: Hashable {
    let selection: Selection

    static func == (l: SidebarTag, r: SidebarTag) -> Bool {
        l.selection.type == r.selection.type && l.selection.id == r.selection.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(selection.type)
        hasher.combine(selection.id)
    }
}

struct Sidebar: View {
    @Environment(AppState.self) var app
    let assetRevision: Int

    @AppStorage("pc_sidebarLibraryExpanded") private var libraryExpanded = true
    @AppStorage("pc_sidebarReviewExpanded") private var reviewExpanded = true
    @AppStorage("pc_sidebarCollectionsExpanded") private var collectionsExpanded = true
    @AppStorage("pc_sidebarDatesExpanded") private var datesExpanded = true
    @AppStorage("pc_sidebarFoldersExpanded") private var foldersExpanded = true
    @AppStorage("pc_sidebarTagsExpanded") private var tagsExpanded = false
    @AppStorage("pc_sidebarMaintenanceExpanded") private var maintenanceExpanded = true

    var body: some View {
        let _ = assetRevision
        List(selection: selection) {
            Section("资料库", isExpanded: $libraryExpanded) { librarySection }
            Section("筛选", isExpanded: $reviewExpanded) { reviewSection }
            if !app.cardVolumes.isEmpty {
                Section("设备") { deviceSection }
            }
            if !app.hasCatalogPreview {
                Section(isExpanded: $collectionsExpanded) {
                    collectionSection
                } header: {
                    collectionHeader
                }
                if !app.captureDateGroups.isEmpty {
                    Section("拍摄日期", isExpanded: $datesExpanded) {
                        OutlineGroup(app.captureDateGroups, children: \.childBuckets) { bucket in
                            dateRow(bucket)
                        }
                    }
                }
                if !app.folderTree.isEmpty {
                    Section("文件夹", isExpanded: $foldersExpanded) {
                        OutlineGroup(FolderNode.build(app.folderTree), children: \.children) { node in
                            folderRow(node.item)
                        }
                    }
                }
                if hasTags {
                    Section("标签", isExpanded: $tagsExpanded) { tagSection }
                }
            }
            Section("管理", isExpanded: $maintenanceExpanded) { maintenanceSection }
        }
        .listStyle(.sidebar)
    }

    private var selection: Binding<SidebarTag?> {
        Binding(
            get: { SidebarTag(selection: app.selection) },
            set: { tag in
                guard let tag, tag != SidebarTag(selection: app.selection) else { return }
                app.select(tag.selection)
            })
    }

    private var pendingBadge: Text? { app.hasCatalogPreview ? Text("…") : nil }

    // ---- sections ----
    @ViewBuilder
    private var librarySection: some View {
        let c = app.libraryCounts
        row("photos", "全部照片", .lib, "all", badge: Text(c.all.formatted()))
        row("clock", "最近导入", .lib, "recent", badge: pendingBadge ?? Text(c.recent.formatted()))
        row("map", "地点", .lib, "places", badge: pendingBadge ?? Text(c.places.formatted()))
        if app.hasCatalogPreview || c.people > 0 {
            row("person.crop.rectangle", "人物", .lib, "people", badge: pendingBadge ?? Text(c.people.formatted()))
        }
    }

    @ViewBuilder
    private var reviewSection: some View {
        let c = app.libraryCounts
        row("star", "未评分", .lib, "unrated", badge: pendingBadge ?? Text(c.unrated.formatted()))
        row("flag", "精选", .lib, "picks", badge: pendingBadge ?? Text(c.picks.formatted()))
        row("reject", "被拒绝", .lib, "rejected", badge: pendingBadge ?? Text(c.rejected.formatted()))
    }

    /// Mounted memory cards: click to import, the eject button to unmount.
    private var deviceSection: some View {
        ForEach(app.cardVolumes) { card in
            HStack(spacing: 6) {
                Button { app.showCardImport(card) } label: {
                    Label(card.name, systemImage: "sdcard")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("从「\(card.name)」导入照片")
                Button { app.ejectCard(card) } label: { Image(systemName: "eject") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.text3)
                    .help("推出")
                    .accessibilityLabel("推出 \(card.name)")
            }
        }
    }

    @ViewBuilder
    private var maintenanceSection: some View {
        let c = app.libraryCounts
        row("offline", "缺失 / 离线", .lib, "missing",
            tint: c.missingOffline > 0 ? Theme.yellow : nil,
            badge: pendingBadge ?? Text(c.missingOffline.formatted()))
        row("copy", "重复文件", .lib, "duplicates",
            badge: pendingBadge ?? Text("\(app.duplicateGroups.count.formatted()) 组"))
    }

    private var collectionHeader: some View {
        HStack(spacing: 4) {
            Text("相册")
            Spacer(minLength: 0)
            Menu {
                Button { app.createAlbumFromSelection() } label: {
                    Label("新建相册", systemImage: "rectangle.stack.badge.plus")
                }
                Button { app.showNewSmartAlbumBuilder() } label: {
                    Label("新建智能相册", systemImage: "sparkles")
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("新建相册或智能相册")
            .accessibilityLabel("新建相册或智能相册")
        }
    }

    @ViewBuilder
    private var collectionSection: some View {
        ForEach(app.pinnedSidebarFavorites) { item in
            row(pinnedIcon(item), item.name, item.type, item.selectionId,
                badge: Text(app.countForPinnedSidebarItem(item)))
        }
        ForEach(app.albums) { album in
            row("album", album.name, .album, album.id, badge: Text(app.countForAlbum(album).formatted()))
                .contextMenu {
                    Button { app.renameAlbum(album.id) } label: {
                        Label("重命名相册…", systemImage: "pencil")
                    }
                    Button(role: .destructive) { app.deleteAlbum(album.id) } label: {
                        Label("删除相册…", systemImage: "trash")
                    }
                }
        }
        ForEach(app.smartAlbums) { smart in
            row("sparkles", smart.name, .smart, smart.id,
                badge: Text(app.countForSmartAlbum(smart).formatted()))
                .contextMenu {
                    Button { app.editSmartAlbum(smart.id) } label: {
                        Label("编辑智能相册…", systemImage: "slider.horizontal.3")
                    }
                    Button(role: .destructive) { app.deleteSmartAlbum(smart.id) } label: {
                        Label("删除智能相册…", systemImage: "trash")
                    }
                }
        }
        if app.pinnedSidebarFavorites.isEmpty && app.albums.isEmpty && app.smartAlbums.isEmpty {
            Text("用 + 新建相册或智能相册")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var hasTags: Bool {
        !app.projectList.isEmpty || !app.clientList.isEmpty || !app.keywordList.isEmpty
    }

    @ViewBuilder
    private var tagSection: some View {
        if !app.projectList.isEmpty {
            DisclosureGroup("项目") {
                ForEach(app.projectList) { item in
                    row("project", item.name, .project, item.name, badge: Text(item.count.formatted()))
                }
            }
        }
        if !app.clientList.isEmpty {
            DisclosureGroup("客户") {
                ForEach(app.clientList) { item in
                    row("client", item.name, .client, item.name, badge: Text(item.count.formatted()))
                }
            }
        }
        if !app.keywordList.isEmpty {
            DisclosureGroup("关键词") {
                ForEach(app.keywordList) { item in
                    row("tag", item.name, .keyword, item.name, badge: Text(item.count.formatted()))
                }
            }
        }
    }

    private func dateRow(_ bucket: CaptureDateBucket) -> some View {
        Text(bucket.label)
            .lineLimit(1)
            .badge(Text(bucket.count.formatted()))
            .tag(SidebarTag(selection: Selection(type: .captureDate, id: bucket.id, name: bucket.id)))
            .help(bucket.id)
            .accessibilityLabel("拍摄日期 \(bucket.id)")
            .accessibilityValue("\(bucket.count) 张照片")
    }

    private func folderRow(_ folder: FolderTreeItem) -> some View {
        let status = folderStatusText(folder.status)
        return row("folder", folder.name, .folder, folder.id,
                   tint: folderColor(folder.status),
                   badge: Text(status ?? app.countForFolderTreeItem(folder).formatted()))
    }

    // ---- row builder ----
    private func row(_ icon: String, _ label: String, _ type: Selection.Kind, _ id: String,
                     tint: Color? = nil, badge: Text?) -> some View {
        Label {
            Text(label).lineLimit(1)
        } icon: {
            Image(systemName: IconName.map[icon] ?? icon)
                .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.tint))
        }
        .badge(badge)
        .tag(SidebarTag(selection: Selection(type: type, id: id, name: label)))
        .help(label)
    }

    private func folderColor(_ status: String) -> Color? {
        switch status {
        case "offline": return Theme.yellow
        case "missing", "permissionLost", "error": return Theme.redSoft
        default: return nil
        }
    }

    private func folderStatusText(_ status: String) -> String? {
        switch status {
        case "offline": return "离线"
        case "missing": return "缺失"
        case "permissionLost": return "需授权"
        case "scanning": return "扫描中"
        case "error": return "错误"
        default: return nil
        }
    }

    private func pinnedIcon(_ item: PinnedSidebarItem) -> String {
        switch item.type {
        case .folder: return "folder"
        case .album: return "album"
        case .smart: return "sparkles"
        case .keyword: return "tag"
        case .project: return "project"
        case .client: return "client"
        case .captureDate: return "calendar"
        case .lib: return "star"
        }
    }
}

private extension CaptureDateBucket {
    var childBuckets: [CaptureDateBucket]? { children.isEmpty ? nil : children }
}

/// The folder tree arrives flattened (depth-first with depths); OutlineGroup
/// needs it nested so deep folders collapse instead of indenting off-screen.
private struct FolderNode: Identifiable {
    let item: FolderTreeItem
    var children: [FolderNode]?
    var id: String { item.id }

    static func build(_ items: [FolderTreeItem]) -> [FolderNode] {
        var index = 0
        func level(_ depth: Int) -> [FolderNode] {
            var nodes: [FolderNode] = []
            while index < items.count, items[index].depth >= depth {
                let item = items[index]
                index += 1
                let children = level(item.depth + 1)
                nodes.append(FolderNode(item: item, children: children.isEmpty ? nil : children))
            }
            return nodes
        }
        return level(items.first?.depth ?? 0)
    }
}
