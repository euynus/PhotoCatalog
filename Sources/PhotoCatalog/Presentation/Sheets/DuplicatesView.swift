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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                head
                // lazy: each card kicks off thumbnail loads for every member
                LazyVStack(spacing: 14) {
                    ForEach(groups) { g in groupCard(g) }
                }
                .frame(maxWidth: 920, alignment: .leading)
            }
            .padding(.horizontal, 22).padding(.vertical, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var head: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("重复文件").font(.system(size: 18, weight: .bold))
                    Text("基于内容哈希识别完全相同文件，并用 quick hash、拍摄时间、尺寸和感知哈希识别疑似重复")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.text3)
                        .frame(maxWidth: 480, alignment: .leading).lineSpacing(2)
                }
                Spacer()
                HStack(spacing: 16) {
                    summaryItem("\(groups.count)", "组", accent: false)
                    summaryItem("\(fileCount)", "个文件", accent: false)
                    HStack(spacing: 4) {
                        Text("可释放 ≈").font(.system(size: 12.5)).foregroundStyle(Theme.text2)
                        Text(fileSizeText(megabytes: reclaim))
                            .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.accent)
                    }
                }
            }
            if app.isAutomaticSimilarityAnalysisLimited {
                HStack(spacing: 6) {
                    Icon("info", size: 13)
                    Text("目录库较大，感知相似分析未自动运行；当前显示精确重复与疑似重复。")
                        .font(.system(size: 11.5))
                }
                .foregroundStyle(Theme.yellow)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func summaryItem(_ value: String, _ label: String, accent: Bool) -> some View {
        HStack(spacing: 5) {
            Text(value).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
            Text(label).font(.system(size: 12.5)).foregroundStyle(Theme.text2)
        }
    }

    private func groupCard(_ g: DuplicateGroup) -> some View {
        let isResolved = resolved[g.id] != nil
        let keptId = keep[g.id] ?? g.items.first?.id
        let exact = g.method == "contentHash"
        return VStack(spacing: 0) {
            // head
            HStack {
                HStack(spacing: 7) {
                    Circle().fill(exact ? Theme.redSoft : Theme.yellow).frame(width: 8, height: 8)
                    Text(exact ? "精确重复 · 内容哈希一致" : "疑似重复 · 相似度 \(Int(g.score * 100))%")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(exact ? Theme.redSoft : Theme.yellow)
                }
                Spacer()
                if isResolved {
                    HStack(spacing: 5) { Icon("check", size: 13, weight: .bold); Text("已处理").font(.system(size: 11.5)) }
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 15).padding(.vertical, 11)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }

            // items
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(g.items) { it in
                        dupItem(it, kept: it.id == keptId, groupId: g.id, resolved: isResolved)
                            .frame(width: 360, alignment: .leading)
                    }
                }
                .padding(15)
            }

            // actions
            if !isResolved {
                HStack(spacing: 9) {
                    Text("保留 1 张，其余：").font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                    Spacer()
                    ghostButton(nil, "从目录库移除", small: true) {
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
                .padding(.horizontal, 15).padding(.bottom, 14)
            }
        }
        .background(Color(hex: "#1f1f21"))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Theme.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .opacity(isResolved ? 0.5 : 1)
    }

    private func dupItem(_ it: Asset, kept: Bool, groupId: String, resolved: Bool) -> some View {
        HStack(spacing: 13) {
            ZStack(alignment: .topLeading) {
                Thumb(asset: it, radius: 6, maxDecodePixel: 172).frame(width: 86, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                if kept {
                    HStack(spacing: 3) { Icon("check", size: 12, weight: .bold); Text("保留").font(.system(size: 9, weight: .bold)) }
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Theme.accent).clipShape(Capsule())
                        .padding(4)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(it.filename).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Text("\(fileSizeText(megabytes: it.fileMB)) · \(it.width)×\(it.height) · \(it.folderName)")
                    .font(.system(size: 11)).foregroundStyle(Theme.text3)
                    .lineLimit(1)
                Text("\(DateFmt.shortCapture(it.date)) · \(it.camera)")
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.text3)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if !resolved {
                Button { keep[groupId] = it.id } label: {
                    Text(kept ? "已保留" : "保留这张").font(.system(size: 11.5)).foregroundStyle(Theme.text2)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain).disabled(kept).opacity(kept ? 0.5 : 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(kept ? Theme.accentSoft : Color.black.opacity(0.18))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(kept ? Theme.accent.opacity(0.5) : .clear, lineWidth: 1.5))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}
