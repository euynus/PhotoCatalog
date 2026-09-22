// ============================================================
//  Sidebar — port of sidebar.jsx
// ============================================================
import SwiftUI

struct Sidebar: View {
    @Environment(AppState.self) var app
    let assetRevision: Int

    var body: some View {
        let _ = assetRevision
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    librarySection
                    filterSection
                    if !app.hasCatalogPreview {
                        folderSection
                        collectionSection
                    }
                }
                .padding(.bottom, 8)
            }
            managementSection
        }
        .frame(minWidth: Theme.sidebarMinW,
               idealWidth: Theme.sidebarW,
               maxWidth: Theme.sidebarMaxW,
               maxHeight: .infinity)
        .background(Theme.bgSidebar)
    }

    // ---- sections ----
    @ViewBuilder
    private var favoriteSection: some View {
        if !app.pinnedSidebarFavorites.isEmpty {
            Text("收藏夹").font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.text2)
                .padding(.horizontal, 8).padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
            ForEach(app.pinnedSidebarFavorites) { item in
                row(pinnedIcon(item), pinnedColor(item), item.name,
                    app.countForPinnedSidebarItem(item),
                    item.type, item.selectionId, item.name)
            }
        }
    }

    private var librarySection: some View {
        let c = app.libraryCounts
        let pending = app.hasCatalogPreview ? "…" : nil
        return SidebarSection(title: "浏览") {
            row("photos", nil, "全部照片", "\(c.all)", .lib, "all", "全部照片")
            row("clock", nil, "最近导入", pending ?? "\(c.recent)", .lib, "recent", "最近导入")
            row("map", Theme.green, "地点", pending ?? "\(c.places)", .lib, "places", "地点")
            if app.hasCatalogPreview || c.people > 0 {
                row("camera", Theme.albumBlue, "人物", pending ?? "\(c.people)", .lib, "people", "人物")
            }
        }
    }

    private var filterSection: some View {
        let c = app.libraryCounts
        let pending = app.hasCatalogPreview ? "…" : nil
        return SidebarSection(title: "筛选") {
            row("star", nil, "未评分", pending ?? "\(c.unrated)", .lib, "unrated", "未评分")
            row("flag", nil, "精选", pending ?? "\(c.picks)", .lib, "picks", "精选")
            row("reject", nil, "被拒绝", pending ?? "\(c.rejected)", .lib, "rejected", "被拒绝")
            if !app.hasCatalogPreview {
                projectSection
                clientSection
                keywordSection
            }
        }
    }

    private var managementSection: some View {
        let c = app.libraryCounts
        let pending = app.hasCatalogPreview ? "…" : nil
        return SidebarSection(title: "管理") {
            row("offline", Theme.yellow, "缺失 / 离线", pending ?? "\(c.missingOffline)",
                .lib, "missing", "缺失 / 离线")
            row("copy", Theme.purple, "重复文件",
                pending ?? "\(app.duplicateGroups.count) 组", .lib, "duplicates", "重复文件")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var folderSection: some View {
        if !app.folderTree.isEmpty {
            SidebarSection(title: "文件夹") {
                ForEach(app.folderTree) { f in
                    let count = app.countForFolderTreeItem(f)
                    row("folder", folderColor(f.status), f.name,
                        folderStatusText(f.status) ?? "\(count)", .folder, f.id, f.name,
                        indent: CGFloat(f.depth) * 12)
                }
            }
        }
    }

    private var collectionSection: some View {
        SidebarSection(title: "收藏与集合", action: {
            Menu {
                Button { app.createAlbumFromSelection() } label: {
                    Label("新建相册", systemImage: "rectangle.stack.badge.plus")
                }
                Button { app.showNewSmartAlbumBuilder() } label: {
                    Label("新建智能相册", systemImage: "sparkles")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("新建相册或智能相册")
            .accessibilityLabel("新建相册或智能相册")
        }) {
            favoriteSection
            albumSection
            smartSection
        }
    }

    @ViewBuilder
    private var albumSection: some View {
        if !app.albums.isEmpty {
            Text("相册").font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.text2)
                .padding(.horizontal, 8).padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
            ForEach(app.albums) { al in
                row("album", Theme.albumBlue, al.name, "\(app.countForAlbum(al))", .album, al.id, al.name)
                    .contextMenu {
                        Button { app.renameAlbum(al.id) } label: {
                            Label("重命名相册…", systemImage: "pencil")
                        }
                        Button(role: .destructive) { app.deleteAlbum(al.id) } label: {
                            Label("删除相册…", systemImage: "trash")
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private var smartSection: some View {
        if !app.smartAlbums.isEmpty {
            Text("智能相册").font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.text2)
                .padding(.horizontal, 8).padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
            ForEach(app.smartAlbums) { sa in
                row("sparkles", Theme.accent, sa.name, "\(app.countForSmartAlbum(sa))", .smart, sa.id, sa.name)
                    .contextMenu {
                        Button { app.editSmartAlbum(sa.id) } label: {
                            Label("编辑智能相册…", systemImage: "slider.horizontal.3")
                        }
                        Button(role: .destructive) { app.deleteSmartAlbum(sa.id) } label: {
                            Label("删除智能相册…", systemImage: "trash")
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private var projectSection: some View {
        if !app.projectList.isEmpty {
            DisclosureGroup("项目") {
                ForEach(app.projectList) { item in
                    row("project", Theme.purple, item.name, "\(item.count)", .project, item.name, item.name)
                }
            }
            .font(.system(size: 13)).tint(Theme.text2)
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var clientSection: some View {
        if !app.clientList.isEmpty {
            DisclosureGroup("客户") {
                ForEach(app.clientList) { item in
                    row("client", Theme.albumBlue, item.name, "\(item.count)", .client, item.name, item.name)
                }
            }
            .font(.system(size: 13)).tint(Theme.text2)
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var keywordSection: some View {
        if !app.keywordList.isEmpty {
            DisclosureGroup("关键词") {
                ForEach(app.keywordList) { k in
                    row("tag", Theme.folderGray, k.name, "\(k.count)", .keyword, k.name, k.name)
                }
            }
            .font(.system(size: 13)).tint(Theme.text2)
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
    }

    // ---- row builder ----
    private func row(_ icon: String, _ color: Color?, _ label: String, _ count: String,
                     _ type: Selection.Kind, _ id: String, _ name: String,
                     indent: CGFloat = 0) -> some View {
        let active = app.selection.type == type && app.selection.id == id
        return SidebarRow(icon: icon, color: color, label: label, count: count,
                          active: active, indent: indent) {
            app.select(Selection(type: type, id: id, name: name))
        }
    }

    private func folderColor(_ status: String) -> Color {
        switch status {
        case "offline":
            return Theme.yellow
        case "missing", "permissionLost", "error":
            return Theme.redSoft
        case "scanning":
            return Theme.accent
        default:
            return Theme.folderGray
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
        case .lib: return "star"
        }
    }

    private func pinnedColor(_ item: PinnedSidebarItem) -> Color? {
        switch item.type {
        case .folder: return Theme.folderGray
        case .album: return Theme.albumBlue
        case .smart: return Theme.accent
        case .keyword: return Theme.folderGray
        case .project: return Theme.purple
        case .client: return Theme.albumBlue
        case .lib: return nil
        }
    }
}

struct SidebarSection<Content: View, Action: View>: View {
    let title: String
    private let action: Action
    private let content: Content
    @State private var expanded = true

    init(title: String, @ViewBuilder content: () -> Content) where Action == EmptyView {
        self.title = title
        self.action = EmptyView()
        self.content = content()
    }
    init(title: String, @ViewBuilder action: () -> Action,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.action = action()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 10)
                        Text(title).font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .frame(height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityValue(expanded ? "已展开" : "已折叠")
                .accessibilityAddTraits(.isHeader)
                action
            }
            .foregroundStyle(Theme.text2)
            .padding(.horizontal, 12)
            .background(Theme.surfaceHi.opacity(0.5))
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
            if expanded {
                VStack(alignment: .leading, spacing: 0) { content }
                    .padding(.horizontal, 6).padding(.vertical, 4)
            }
        }
    }
}

struct SidebarRow: View {
    let icon: String
    var color: Color?
    let label: String
    var count: String?
    let active: Bool
    var indent: CGFloat = 0
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Icon(icon, size: 16)
                    .frame(width: 18)
                    .foregroundStyle(color ?? Theme.text2)
                Text(label)
                    .font(.system(size: 13, weight: active ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 4)
                if let count {
                    Text(count)
                        .font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(Theme.text3)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(minWidth: 24, alignment: .trailing)
                }
            }
            .padding(.horizontal, 8)
            // ponytail: cap deep-folder indentation at 24pt; a tree outline can replace this if depth must stay visible.
            .padding(.leading, min(indent, 24))
            .frame(height: 32)
            .background(active ? Theme.surfacePress : (hover ? Theme.surfaceHi : .clear))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(alignment: .leading) {
                if active {
                    Rectangle().fill(Theme.accent).frame(width: 2)
                        .padding(.vertical, 7)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityValue(count ?? "")
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}
