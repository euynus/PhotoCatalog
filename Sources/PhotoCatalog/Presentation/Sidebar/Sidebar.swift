// ============================================================
//  Sidebar — port of sidebar.jsx
// ============================================================
import SwiftUI

struct Sidebar: View {
    @Environment(AppState.self) var app

    private var ready: [Asset] { app.assets.filter { !$0.deleted } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                librarySection
                favoriteSection
                folderSection
                albumSection
                smartSection
                projectSection
                clientSection
                keywordSection
            }
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 20)
        }
        .frame(width: Theme.sidebarW)
        .background(Theme.bgSidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
    }

    // ---- sections ----
    @ViewBuilder
    private var favoriteSection: some View {
        if !app.pinnedSidebarFavorites.isEmpty {
            SidebarSection(title: "收藏夹") {
                ForEach(app.pinnedSidebarFavorites) { item in
                    row(pinnedIcon(item), pinnedColor(item), item.name,
                        app.countForPinnedSidebarItem(item),
                        item.type, item.selectionId, item.name)
                }
            }
        }
    }

    private var librarySection: some View {
        let c = app.libraryCounts
        return SidebarSection(title: "资料库") {
            row("photos", nil, "全部照片", "\(c.all)", .lib, "all", "全部照片")
            row("clock", nil, "最近导入", "\(c.recent)", .lib, "recent", "最近导入")
            row("star", nil, "未评分", "\(c.unrated)", .lib, "unrated", "未评分")
            row("flag", nil, "精选", "\(c.picks)", .lib, "picks", "精选")
            row("reject", nil, "被拒绝", "\(c.rejected)", .lib, "rejected", "被拒绝")
            row("offline", Theme.yellow, "缺失 / 离线", "\(c.missingOffline)", .lib, "missing", "缺失 / 离线")
            row("copy", Theme.purple, "重复文件",
                "\(app.duplicateGroups.count) 组", .lib, "duplicates", "重复文件")
            row("map", Theme.green, "地点", "\(c.places)", .lib, "places", "地点")
            if c.people > 0 {
                row("camera", Theme.albumBlue, "人物", "\(c.people)", .lib, "people", "人物")
            }
        }
    }

    private var folderSection: some View {
        SidebarSection(title: "文件夹") {
            ForEach(app.folderTree) { f in
                let count = app.countForFolderTreeItem(f)
                row("folder", folderColor(f.status), f.name,
                    folderStatusText(f.status) ?? "\(count)", .folder, f.id, f.name,
                    indent: CGFloat(f.depth) * 14)
            }
        }
    }

    private var albumSection: some View {
        SidebarSection(title: "相册", action: {
            SBAddButton { app.createAlbumFromSelection() }
        }) {
            ForEach(app.albums) { al in
                row("album", Theme.albumBlue, al.name, "\(app.countForAlbum(al))", .album, al.id, al.name)
            }
        }
    }

    private var smartSection: some View {
        SidebarSection(title: "智能相册", action: {
            SBAddButton { app.sheet = "smart" }
        }) {
            ForEach(app.smartAlbums) { sa in
                row("sparkles", Theme.accent, sa.name, "\(app.countForSmartAlbum(sa))", .smart, sa.id, sa.name)
            }
        }
    }

    @ViewBuilder
    private var projectSection: some View {
        if !app.projectList.isEmpty {
            SidebarSection(title: "项目") {
                ForEach(app.projectList) { item in
                    row("project", Theme.purple, item.name, "\(item.count)", .project, item.name, item.name)
                }
            }
        }
    }

    @ViewBuilder
    private var clientSection: some View {
        if !app.clientList.isEmpty {
            SidebarSection(title: "客户") {
                ForEach(app.clientList) { item in
                    row("client", Theme.albumBlue, item.name, "\(item.count)", .client, item.name, item.name)
                }
            }
        }
    }

    private var keywordSection: some View {
        SidebarSection(title: "关键词") {
            ForEach(app.keywordList) { k in
                row("tag", Theme.folderGray, k.name, "\(k.count)", .keyword, k.name, k.name)
            }
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
            HStack {
                Text(title).font(.system(size: 11, weight: .bold)).tracking(0.3)
                    .foregroundStyle(Theme.text3).textCase(.uppercase)
                Spacer()
                action
            }
            .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 5)
            content
        }
    }
}

private struct SBAddButton: View {
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Icon("plus", size: 13, weight: .bold)
                .foregroundStyle(hover ? Theme.text : Theme.text3)
                .frame(width: 18, height: 18)
                .background(hover ? Theme.surface : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain).onHover { hover = $0 }.help("新建智能相册")
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
                    .foregroundStyle(active ? Theme.onAccent.opacity(0.85) : (color ?? Theme.accent))
                Text(label)
                    .font(.system(size: 13, weight: active ? .medium : .regular))
                    .lineLimit(1)
                    .foregroundStyle(active ? Theme.onAccent : Theme.text)
                Spacer(minLength: 4)
                if let count {
                    Text(count)
                        .font(.system(size: 11.5)).monospacedDigit()
                        .foregroundStyle(active ? Theme.onAccent.opacity(0.85) : Theme.text3)
                }
            }
            .padding(.horizontal, 8)
            .padding(.leading, indent)
            .frame(height: 28)
            .background(active ? Theme.accent : (hover ? Color.white(0.05) : .clear))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
