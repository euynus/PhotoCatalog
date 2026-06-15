// ============================================================
//  Import / scan progress — port of ImportSheet()
// ============================================================
import SwiftUI

struct ImportSheet: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            if let run = app.importRun {
                head(run)
                source(run)
                progress(run)
                stats(run)
                if run.failures.isEmpty {
                    wall(run)
                } else {
                    failureList(run)
                }
                foot(run)
            } else {
                idleHead
                idleBody
                idleFoot
            }
        }
        .frame(width: 560)
        .background(Color(hex: "#232325"))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line2, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.7), radius: 60, y: 40)
    }

    private var idleHead: some View {
        HStack {
            HStack(spacing: 9) {
                Icon("importIcon", size: 17).foregroundStyle(Theme.accent)
                Text("导入照片文件夹")
                    .font(.system(size: 14.5, weight: .semibold))
            }
            Spacer()
            sheetClose { app.sheet = nil }
        }
        .padding(.horizontal, 18).padding(.vertical, 15)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var idleBody: some View {
        VStack(spacing: 16) {
            Icon("folder", size: 34).foregroundStyle(Theme.text3)
                .frame(width: 68, height: 68)
                .background(Color.black.opacity(0.22))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Text("尚未选择源文件夹")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text2)
            Button { app.addFolder() } label: {
                HStack(spacing: 8) {
                    Icon("folder", size: 14)
                    Text("选择文件夹…").font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(Theme.onAccent)
                .padding(.horizontal, 18).padding(.vertical, 9)
                .background(Theme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .padding(18)
    }

    private var idleFoot: some View {
        HStack {
            Text("当前导入模式：\(app.importMode.displayName)")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.text3)
            Spacer()
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
        .background(Color.black.opacity(0.18))
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func head(_ run: ImportRun) -> some View {
        HStack {
            HStack(spacing: 9) {
                Icon("importIcon", size: 17).foregroundStyle(Theme.accent)
                Text(title(for: run.phase))
                    .font(.system(size: 14.5, weight: .semibold))
            }
            Spacer()
            sheetClose { app.sheet = nil }
        }
        .padding(.horizontal, 18).padding(.vertical, 15)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func source(_ run: ImportRun) -> some View {
        HStack(spacing: 9) {
            Icon("folder", size: 15).foregroundStyle(Theme.text2)
            Text(run.sourcePath)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(run.mode.displayName).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.accent)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(Theme.accentSoft).clipShape(Capsule())
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func progress(_ run: ImportRun) -> some View {
        HStack(spacing: 12) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surface)
                    Capsule().fill(Theme.importFill)
                        .frame(width: geo.size.width * CGFloat(run.percent) / 100)
                        .animation(.easeOut(duration: 0.2), value: run.percent)
                }
            }
            .frame(height: 7)
            Text(progressLabel(run)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                .frame(width: 50, alignment: .trailing)
        }
        .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 6)
    }

    private func stats(_ run: ImportRun) -> some View {
        HStack(spacing: 8) {
            stat(run.scanned.formatted(), "已扫描", nil)
            stat(run.pending.formatted(), "待处理", nil)
            stat(run.imported.formatted(), "成功", Theme.accent)
            stat(run.skipped.formatted(), "跳过（重复）", Theme.yellow)
            stat(run.failed.formatted(), "失败", Theme.redSoft)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private func stat(_ n: String, _ label: String, _ color: Color?) -> some View {
        VStack(spacing: 3) {
            Text(n).font(.system(size: 17, weight: .semibold)).monospacedDigit()
                .foregroundStyle(color ?? Theme.text)
            Text(label).font(.system(size: 10)).foregroundStyle(Theme.text3)
        }
        .frame(maxWidth: .infinity)
        .padding(9)
        .background(Color.black.opacity(0.24))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func wall(_ run: ImportRun) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if run.recentAssets.isEmpty {
                Text(run.phase == .complete ? "没有新的缩略图" : "缩略图将在导入时逐步出现…")
                    .font(.system(size: 12)).foregroundStyle(Theme.text4)
                    .frame(maxWidth: .infinity).padding(.top, 40)
            } else {
                FlowRow(spacing: 4, lineSpacing: 4) {
                    ForEach(run.recentAssets) { a in
                        Thumb(asset: a, radius: 3).frame(width: 56, height: 38)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 120, alignment: .topLeading)
        .clipped()
        .padding(.horizontal, 18).padding(.bottom, 14)
    }

    private func failureList(_ run: ImportRun) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Icon("warning", size: 13).foregroundStyle(Theme.redSoft)
                Text("失败文件")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.text2)
                Spacer()
                Text(run.failures.count.formatted())
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.redSoft)
            }
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(run.failures) { failure in
                        failureRow(failure)
                    }
                }
            }
            .scrollContentBackground(.visible)
        }
        .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 150, alignment: .topLeading)
        .padding(.horizontal, 18).padding(.bottom, 14)
    }

    private func failureRow(_ failure: ImportFailure) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Icon("warning", size: 12).foregroundStyle(Theme.redSoft)
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(failure.filename)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(failure.reason)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.redSoft)
                    .lineLimit(1)
                Text(failure.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.text4)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(Color.black.opacity(0.22))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func foot(_ run: ImportRun) -> some View {
        HStack(spacing: 9) {
            if run.phase.isActive {
                HStack(spacing: 6) {
                    if run.failed > 0 {
                        Icon("warning", size: 13).foregroundStyle(Theme.redSoft)
                        Text("\(run.failed) 个文件失败 · 可稍后重试").foregroundStyle(Theme.redSoft)
                    } else {
                        Text(activeDetail(run)).foregroundStyle(Theme.text3)
                    }
                }
                .font(.system(size: 11.5))
                .frame(maxWidth: .infinity, alignment: .leading)
                ghostButton(nil, "后台运行") { app.sheet = nil }
            } else if run.phase == .complete {
                HStack(spacing: 6) {
                    Icon(run.failed > 0 ? "warning" : "check", size: 14, weight: .bold)
                        .foregroundStyle(run.failed > 0 ? Theme.redSoft : Theme.accent)
                    Text("已导入 \(run.imported.formatted()) 张 · \(run.skipped.formatted()) 张跳过 · \(run.failed.formatted()) 张失败")
                }
                .font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                .frame(maxWidth: .infinity, alignment: .leading)
                if !run.failures.isEmpty {
                    ghostButton("refresh", "重试失败", small: true) { app.retryFailedImport() }
                }
                Button { app.sheet = nil; app.push("导入完成", "check") } label: {
                    Text("完成").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 17).padding(.vertical, 8)
                        .background(Theme.accent).clipShape(RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain)
            } else {
                HStack(spacing: 6) {
                    Icon("warning", size: 14).foregroundStyle(Theme.redSoft)
                    Text(run.errorMessage ?? "导入失败")
                }
                .font(.system(size: 11.5)).foregroundStyle(Theme.redSoft)
                .frame(maxWidth: .infinity, alignment: .leading)
                if !run.failures.isEmpty {
                    ghostButton("refresh", "重试失败", small: true) { app.retryFailedImport() }
                }
                ghostButton(nil, "关闭") { app.sheet = nil }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
        .background(Color.black.opacity(0.18))
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func title(for phase: ImportPhase) -> String {
        switch phase {
        case .scanning: return "正在扫描文件夹…"
        case .importing: return "正在导入照片…"
        case .complete: return "导入完成"
        case .failed: return "导入失败"
        }
    }

    private func progressLabel(_ run: ImportRun) -> String {
        run.total == 0 && run.phase.isActive ? "扫描中" : "\(run.percent)%"
    }

    private func activeDetail(_ run: ImportRun) -> String {
        guard run.total > 0 else { return "正在扫描源文件夹…" }
        return "正在处理 \((run.processed + run.failed).formatted()) / \(run.total.formatted()) 个文件"
    }
}

// shared sheet helpers
@MainActor
func sheetClose(_ action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Icon("close", size: 15).foregroundStyle(Theme.text2)
            .frame(width: 26, height: 26).background(Theme.surface).clipShape(Circle())
    }.buttonStyle(.plain)
}

@MainActor
func ghostButton(_ icon: String?, _ label: String, danger: Bool = false, small: Bool = false,
                 action: @escaping () -> Void) -> some View {
    Button(action: action) {
        HStack(spacing: 6) {
            if let icon { Icon(icon, size: small ? 13 : 14) }
            Text(label).font(.system(size: small ? 12 : 12.5))
        }
        .foregroundStyle(danger ? Theme.redSoft : Theme.text)
        .padding(.horizontal, small ? 10 : 15).padding(.vertical, small ? 5 : 8)
        .background(danger ? Theme.red.opacity(0.001) : Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }.buttonStyle(.plain)
}
