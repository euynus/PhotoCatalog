// ============================================================
//  Duplicate detection view — port of DuplicatesView()
// ============================================================
import SwiftUI

/// The groups worth showing: look-alikes only from `similarMinScore`, everything else as found.
func shownDuplicateGroups(_ groups: [DuplicateGroup], similarMinScore: Double) -> [DuplicateGroup] {
    groups.filter { $0.method != "perceptualHash" || $0.score >= similarMinScore }
}

func duplicateReclaimMegabytes(_ groups: [DuplicateGroup]) -> Double {
    groups.reduce(0) { total, group in
        total + group.items.dropFirst().reduce(0) { $0 + $1.fileMB }
    }
}

struct DuplicatesView: View {
    @Environment(AppState.self) var app

    /// Identical files and similar photos apart: a burst's frames can look alike without being
    /// copies, so they shouldn't sit among the copies to delete.
    enum Kind: Hashable { case exact, similar }
    @State private var kind: Kind?
    /// How alike two photos must look to count: a burst's frames sit around 85%.
    @AppStorage("pc_similarMinScore") private var minScore = 0.9
    @State private var keep: [String: String] = [:]
    @State private var resolved: [String: String] = [:]

    private var exactGroups: [DuplicateGroup] { app.duplicateGroups.filter { $0.method == "contentHash" } }
    /// Look-alikes at the chosen similarity, and the likely copies (same name or quick hash, size
    /// and minute), which have no similarity of their own to filter by.
    private var similarGroups: [DuplicateGroup] {
        shownDuplicateGroups(app.duplicateGroups, similarMinScore: minScore).filter { $0.method != "contentHash" }
    }
    /// The tab chosen, else identical files when there are any.
    private var shownKind: Kind { kind ?? (exactGroups.isEmpty && !similarGroups.isEmpty ? .similar : .exact) }
    private var groups: [DuplicateGroup] { shownKind == .exact ? exactGroups : similarGroups }

    private var fileCount: Int { groups.reduce(0) { $0 + $1.items.count } }
    private var reclaim: Double { duplicateReclaimMegabytes(groups) }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                head
                if groups.isEmpty {
                    ContentUnavailableView {
                        Label(shownKind == .exact ? "没有完全相同的文件" : "没有相似的照片", systemImage: "checkmark.circle")
                    } description: {
                        Text(shownKind == .exact ? "内容完全相同的文件会分组显示在这里。" : "看起来几乎一样的照片会分组显示在这里。")
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
            Picker("重复类型", selection: Binding(get: { shownKind }, set: { kind = $0 })) {
                Text("完全相同 · \(exactGroups.count) 组").tag(Kind.exact)
                Text("相似 · \(similarGroups.count) 组").tag(Kind.similar)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if shownKind == .similar {
                HStack(spacing: 10) {
                    Picker("最低相似度", selection: $minScore) {
                        Text(verbatim: "85%").tag(0.84)
                        Text(verbatim: "90%").tag(0.9)
                        Text(verbatim: "95%").tag(0.95)
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    Text("相似的照片可能是连拍中不同的帧，不一定是副本；处理前请逐组确认。")
                        .font(.system(size: 12)).foregroundStyle(Theme.text3)
                }
            }
            FlowRow(spacing: 18, lineSpacing: 6) {
                summaryItem("\(groups.count)", L("组"))
                summaryItem("\(fileCount)", L("个文件"))
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
        let columnCount = max(1, min(g.items.count, Int((width - 12) / 192)))
        let itemWidth = min(240, (width - 24 - CGFloat(columnCount - 1) * 12) / CGFloat(columnCount))
        return VStack(spacing: 0) {
            HStack {
                HStack(spacing: 7) {
                    Icon(exact ? "copy" : "compare", size: 14)
                    Text(exact ? "完全相同" : g.method == "suspected" ? "疑似副本" : "相似度 \(Int(g.score * 100))%")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(exact ? Theme.redSoft : Theme.yellow)
                Spacer()
                if !exact && !isResolved {
                    Button { app.compareDuplicateGroup(g) } label: {
                        Label("比较", systemImage: "rectangle.split.2x1")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("在比较视图中并排查看这一组")
                }
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
                            previewHeight: min(150, max(110, itemWidth * 0.62)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Theme.canvas)

            if !isResolved {
                FlowRow(spacing: 10, lineSpacing: 8) {
                    Text("保留 1 张，其余：").foregroundStyle(Theme.text3)
                        .padding(.vertical, 5)
                    ghostButton("minus", L("从目录库移除"), small: true) {
                        if app.resolveDuplicateGroup(g, keepId: keptId, action: .removeFromCatalog) {
                            resolved[g.id] = "removed"
                        }
                    }
                    ghostButton("trash", L("移到废纸篓"), danger: true, small: true) {
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
            VStack(alignment: .leading, spacing: 3) {
                Text(it.filename).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    .truncationMode(.middle).help(it.localPath ?? it.filename)
                Text("\(fileSizeText(megabytes: it.fileMB)) · \(it.width)×\(it.height)")
                    .font(.system(size: 11)).foregroundStyle(Theme.text2)
                    .lineLimit(1)
                Text("\(DateFmt.shortCapture(it.date)) · \(it.camera)")
                    .font(.system(size: 11)).foregroundStyle(Theme.text3)
                    .lineLimit(1).truncationMode(.tail)
                    .help("\(DateFmt.shortCapture(it.date)) · \(it.camera) · \(it.folderName)")
                if !resolved {
                    Button { keep[groupId] = it.id } label: {
                        Label(kept ? "已保留" : "保留这张",
                              systemImage: kept ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(kept ? Theme.accent : Theme.text2)
                            .font(.system(size: 12))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 3)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(kept)
                    .accessibilityLabel(kept ? "已保留：\(it.filename)" : "保留这张：\(it.filename)")
                } else if kept {
                    Label("已保留", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(8)
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
