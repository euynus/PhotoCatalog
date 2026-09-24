// ============================================================
//  Duplicate detection view — port of DuplicatesView()
// ============================================================
import SwiftUI

func duplicateReclaimMegabytes(_ groups: [DuplicateGroup]) -> Double {
    groups.reduce(0) { total, group in
        total + group.items.dropFirst().reduce(0) { $0 + $1.fileMB }
    }
}

struct DuplicatesView: View {
    @Environment(AppState.self) var app

    private var groups: [DuplicateGroup] { app.duplicateGroups }
    @State private var keep: [String: String] = [:]
    @State private var resolved: [String: String] = [:]

    private var fileCount: Int { groups.reduce(0) { $0 + $1.items.count } }
    private var reclaim: Double { duplicateReclaimMegabytes(groups) }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                head
                if groups.isEmpty {
                    ContentUnavailableView {
                        Label("没有重复文件", systemImage: "checkmark.circle")
                    } description: {
                        Text("内容完全相同或疑似重复的照片会分组显示在这里。")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        // Lazy loading avoids decoding off-screen group thumbnails.
                        LazyVStack(spacing: 16) {
                            ForEach(groups) { g in
                                groupCard(g, width: geometry.size.width - 32)
                            }
                        }
                        .padding(16)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .font(.system(size: 13))
        .foregroundStyle(Theme.text)
        .background(Theme.bgContent)
    }

    private var head: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowRow(spacing: 18, lineSpacing: 6) {
                summaryItem("\(groups.count)", "组")
                summaryItem("\(fileCount)", "个文件")
                HStack(spacing: 4) {
                    Text("可释放 ≈").foregroundStyle(Theme.text2)
                    Text(fileSizeText(megabytes: reclaim))
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent)
                }
            }
            if app.isAutomaticSimilarityAnalysisLimited {
                HStack(spacing: 6) {
                    Icon("info", size: 13)
                    Text("目录库较大，感知相似分析未自动运行；当前显示精确重复与疑似重复。")
                        .font(.system(size: 13))
                }
                .foregroundStyle(Theme.yellow)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bgPanel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func summaryItem(_ value: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(value).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
            Text(label).foregroundStyle(Theme.text2)
        }
    }

    private func groupCard(_ g: DuplicateGroup, width: CGFloat) -> some View {
        let isResolved = resolved[g.id] != nil
        let keptId = keep[g.id] ?? g.items.first?.id
        let exact = g.method == "contentHash"
        let columnCount = max(1, min(g.items.count, Int((width - 12) / 232)))
        let itemWidth = min(360, (width - 24 - CGFloat(columnCount - 1) * 12) / CGFloat(columnCount))
        return VStack(spacing: 0) {
            HStack {
                HStack(spacing: 7) {
                    Icon(exact ? "copy" : "compare", size: 14)
                    Text(exact ? "精确重复 · 内容哈希一致" : "疑似重复 · 相似度 \(Int(g.score * 100))%")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(exact ? Theme.redSoft : Theme.yellow)
                Spacer()
                if isResolved {
                    HStack(spacing: 5) { Icon("check", size: 13, weight: .bold); Text("已处理") }
                        .foregroundStyle(Theme.green)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Theme.bgSidebar)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(itemWidth), spacing: 12), count: columnCount),
                      alignment: .leading, spacing: 12) {
                ForEach(g.items) { it in
                    dupItem(it, kept: it.id == keptId, groupId: g.id, resolved: isResolved,
                            previewHeight: min(240, max(144, itemWidth * 0.75)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Theme.canvas)

            if !isResolved {
                FlowRow(spacing: 10, lineSpacing: 8) {
                    Text("保留 1 张，其余：").foregroundStyle(Theme.text3)
                        .padding(.vertical, 5)
                    ghostButton("minus", "从目录库移除", small: true) {
                        if app.resolveDuplicateGroup(g, keepId: keptId, action: .removeFromCatalog) {
                            resolved[g.id] = "removed"
                        }
                    }
                    ghostButton("trash", "移到废纸篓", danger: true, small: true) {
                        if app.resolveDuplicateGroup(g, keepId: keptId, action: .moveToTrash) {
                            resolved[g.id] = "trashed"
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Theme.bgPanel)
                .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
            }
        }
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .opacity(isResolved ? 0.65 : 1)
    }

    private func dupItem(_ it: Asset, kept: Bool, groupId: String, resolved: Bool,
                         previewHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Thumb(asset: it, radius: 0, contentMode: .fit, maxDecodePixel: 512)
                .frame(height: previewHeight)
                .background(Theme.canvasSurface)
            VStack(alignment: .leading, spacing: 6) {
                Text(it.filename).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    .truncationMode(.middle).help(it.filename)
                Text("\(fileSizeText(megabytes: it.fileMB)) · \(it.width)×\(it.height)")
                    .foregroundStyle(Theme.text2)
                    .lineLimit(1)
                Text(it.folderName)
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1).truncationMode(.middle)
                    .help(it.localPath ?? it.folderName)
                Text("\(DateFmt.shortCapture(it.date)) · \(it.camera)")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text3)
                    .lineLimit(1)
                    .help("\(DateFmt.shortCapture(it.date)) · \(it.camera)")
                if !resolved {
                    Button { keep[groupId] = it.id } label: {
                        Label(kept ? "已保留" : "保留这张",
                              systemImage: kept ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(kept ? Theme.accent : Theme.text2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(kept)
                    .accessibilityLabel("\(kept ? "已保留" : "保留这张")：\(it.filename)")
                } else if kept {
                    Label("已保留", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(kept ? Theme.accentSoft : Theme.surface)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .overlay {
            Rectangle().strokeBorder(kept ? Theme.accent : Theme.line2, lineWidth: kept ? 2 : 1)
        }
    }
}
