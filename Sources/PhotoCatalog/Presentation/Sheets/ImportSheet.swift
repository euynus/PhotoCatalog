// ============================================================
//  Import / scan progress — port of ImportSheet()
// ============================================================
import SwiftUI

struct ImportSheet: View {
    @Environment(AppState.self) var app

    var body: some View {
        VStack(spacing: 0) {
            if let run = app.importRun {
                head(run)
                ScrollView {
                    VStack(spacing: 0) {
                        source(run)
                        progress(run)
                        stats(run)
                        wall(run)
                        if !run.failures.isEmpty {
                            failureList(run)
                        }
                    }
                }
                .frame(height: run.failures.isEmpty ? 310 : 450)
                foot(run)
            } else {
                idleHead
                idleBody
                idleFoot
            }
        }
        .frame(width: 720)
        .font(.system(size: 13))
        .foregroundStyle(Theme.text)
        .background(Theme.bgPanel)
    }

    private var idleHead: some View {
        HStack {
            HStack(spacing: 9) {
                Icon("importIcon", size: 17).foregroundStyle(Theme.accent)
                Text("导入照片文件夹")
                    .font(.system(size: 17, weight: .semibold))
            }
            Spacer()
            sheetClose { app.sheet = nil }
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var idleBody: some View {
        @Bindable var app = app
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Icon("folder", size: 22).foregroundStyle(Theme.text2)
                VStack(alignment: .leading, spacing: 5) {
                    Text("来源").font(.system(size: 15, weight: .semibold))
                    Text("尚未选择源文件夹").foregroundStyle(Theme.text3)
                }
                Spacer()
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            Text("导入选项").font(.system(size: 15, weight: .semibold))
            HStack {
                Text("导入模式").foregroundStyle(Theme.text2)
                Spacer()
                Segmented(options: [
                    SegOption(value: "referenced", label: "引用式"),
                    SegOption(value: "managed", label: "托管式"),
                ], value: app.importMode.rawValue,
                   onChange: { app.importMode = ImportMode(rawValue: $0) ?? .referenced })
            }
            if app.importMode == .managed {
                HStack {
                    Text("归档规则").foregroundStyle(Theme.text2)
                    Spacer()
                    Segmented(options: [
                        SegOption(value: "date", label: "按日期"),
                        SegOption(value: "camera", label: "按相机"),
                    ], value: app.managedArchiveRule.rawValue,
                       onChange: { app.managedArchiveRule = ManagedArchiveRule(rawValue: $0) ?? .date })
                }
            }
            HStack {
                Text("重复处理").foregroundStyle(Theme.text2)
                Spacer()
                Segmented(options: [
                    SegOption(value: "groupExact", label: "分组"),
                    SegOption(value: "skipExact", label: "跳过"),
                    SegOption(value: "keep", label: "保留"),
                ], value: app.importDuplicateStrategy.rawValue,
                   onChange: {
                    app.importDuplicateStrategy = ImportDuplicateStrategy(rawValue: $0) ?? .groupExact
                })
            }
            HStack {
                Text("元数据模板").foregroundStyle(Theme.text2)
                Spacer()
                TextField("作者", text: $app.importAuthor)
                    .textFieldStyle(.roundedBorder).frame(width: 150)
                TextField("版权，如 © {year} 名字", text: $app.importCopyright)
                    .textFieldStyle(.roundedBorder).frame(width: 210)
            }
            .help("导入时写入每张照片；{year} 替换为拍摄年份")
            HStack(spacing: 24) {
                Toggle("读取 XMP sidecar", isOn: $app.readXMPSidecar)
                Toggle("Vision 分析", isOn: $app.visionEnabled)
                Spacer(minLength: 0)
            }
            .toggleStyle(.checkbox)
            .tint(Theme.accent)
        }
        .padding(18)
    }

    private var idleFoot: some View {
        HStack {
            Spacer()
            ghostButton(nil, "取消") { app.sheet = nil }
            Button { app.addFolder() } label: {
                Label("选择文件夹…", systemImage: "folder")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Theme.accentFill)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(Theme.bgSidebar)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func head(_ run: ImportRun) -> some View {
        HStack {
            HStack(spacing: 9) {
                Icon("importIcon", size: 17).foregroundStyle(Theme.accent)
                Text(title(for: run.phase))
                    .font(.system(size: 17, weight: .semibold))
            }
            Spacer()
            sheetClose { app.sheet = nil }
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func source(_ run: ImportRun) -> some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Label("来源", systemImage: "folder").foregroundStyle(Theme.text2)
                Text(run.sourcePath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(run.sourcePath)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Text("导入模式").foregroundStyle(Theme.text2)
                Text(run.mode.displayName).fontWeight(.medium)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func progress(_ run: ImportRun) -> some View {
        HStack(spacing: 12) {
            ProgressView(value: run.total == 0 && run.phase.isActive ? nil : Double(run.percent), total: 100)
                .progressViewStyle(.linear)
                .tint(Theme.accent)
                .accessibilityLabel("导入进度")
                .accessibilityValue(progressLabel(run))
            Text(progressLabel(run)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                .frame(width: 50, alignment: .trailing)
        }
        .padding(.horizontal, 18).padding(.top, 12)
    }

    private func stats(_ run: ImportRun) -> some View {
        HStack(spacing: 8) {
            stat(run.scanned.formatted(), "已扫描", nil)
            stat(run.pending.formatted(), "待处理", nil)
            stat(run.imported.formatted(), "成功", Theme.green)
            stat(run.skipped.formatted(), "跳过（重复）", Theme.yellow)
            stat(run.failed.formatted(), "失败", Theme.redSoft)
        }
        .padding(.horizontal, 18).padding(.vertical, 8)
    }

    private func stat(_ n: String, _ label: String, _ color: Color?) -> some View {
        VStack(spacing: 3) {
            Text(n).font(.system(size: 17, weight: .semibold)).monospacedDigit()
                .foregroundStyle(color ?? Theme.text)
            Text(label).font(.system(size: 13)).foregroundStyle(Theme.text3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private func wall(_ run: ImportRun) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("预览").font(.system(size: 15, weight: .semibold))
            if run.recentAssets.isEmpty {
                Text(run.phase == .complete ? "没有新的缩略图" : "缩略图将在导入时逐步出现…")
                    .font(.system(size: 13)).foregroundStyle(Theme.canvasText3)
                    .frame(maxWidth: .infinity, minHeight: 104)
                    .background(Theme.canvas)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) {
                        ForEach(run.recentAssets) { a in
                            Thumb(asset: a, radius: 2, contentMode: .fit, maxDecodePixel: 224)
                                .frame(width: 112, height: 80)
                                .help(a.filename)
                        }
                    }
                    .padding(10)
                }
                .frame(height: 104)
                .background(Theme.canvas)
            }
        }
        .padding(.horizontal, 18).padding(.bottom, 14)
    }

    private func failureList(_ run: ImportRun) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Icon("warning", size: 13).foregroundStyle(Theme.redSoft)
                Text("失败文件")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text2)
                Spacer()
                Text(run.failures.count.formatted())
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.redSoft)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(run.failures) { failure in
                        failureRow(failure)
                    }
                }
            }
            .scrollContentBackground(.visible)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: 136)
        .padding(.horizontal, 18).padding(.bottom, 14)
    }

    private func failureRow(_ failure: ImportFailure) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Icon("warning", size: 12).foregroundStyle(Theme.redSoft)
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(failure.filename)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(failure.reason)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.redSoft)
                    .fixedSize(horizontal: false, vertical: true)
                Text(failure.path)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .help("\(failure.path)\n\(failure.reason)")
    }

    private func foot(_ run: ImportRun) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if run.phase.isActive {
                HStack(spacing: 6) {
                    if run.failed > 0 {
                        Icon("warning", size: 13).foregroundStyle(Theme.redSoft)
                        Text("\(run.failed) 个文件失败 · 可稍后重试").foregroundStyle(Theme.redSoft)
                    } else {
                        Text(activeDetail(run)).foregroundStyle(Theme.text3)
                    }
                }
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 9) {
                    Spacer()
                    ghostButton(run.phase == .paused ? "play" : "pause",
                                run.phase == .paused ? "继续" : "暂停") {
                        app.toggleImportPaused()
                    }
                    ghostButton(nil, "后台运行") { app.sheet = nil }
                }
            } else if run.phase == .complete {
                HStack(spacing: 6) {
                    Icon(run.failed > 0 ? "warning" : "check", size: 14, weight: .bold)
                        .foregroundStyle(run.failed > 0 ? Theme.redSoft : Theme.green)
                    Text("已导入 \(run.imported.formatted()) 张 · \(run.skipped.formatted()) 张跳过 · \(run.failed.formatted()) 张失败")
                }
                .font(.system(size: 13)).foregroundStyle(Theme.text3)
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 9) {
                    Spacer()
                    if !run.failures.isEmpty {
                        ghostButton("refresh", "重试失败", small: true) { app.retryFailedImport() }
                    }
                    Button { app.sheet = nil; app.push("导入完成", "check") } label: {
                        Label("完成", systemImage: "checkmark")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 17).padding(.vertical, 8)
                            .background(Theme.accentFill).clipShape(RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain)
                }
            } else {
                HStack(alignment: .top, spacing: 6) {
                    Icon("warning", size: 14).foregroundStyle(Theme.redSoft)
                    Text(run.errorMessage ?? "导入失败")
                        .lineLimit(2)
                        .help(run.errorMessage ?? "导入失败")
                }
                .font(.system(size: 13)).foregroundStyle(Theme.redSoft)
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 9) {
                    Spacer()
                    if !run.failures.isEmpty {
                        ghostButton("refresh", "重试失败", small: true) { app.retryFailedImport() }
                    }
                    ghostButton(nil, "关闭") { app.sheet = nil }
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(Theme.bgSidebar)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func title(for phase: ImportPhase) -> String {
        switch phase {
        case .scanning: return "正在扫描文件夹…"
        case .importing: return "正在导入照片…"
        case .paused: return "导入已暂停"
        case .complete: return "导入完成"
        case .failed: return "导入失败"
        }
    }

    private func progressLabel(_ run: ImportRun) -> String {
        run.total == 0 && run.phase.isActive ? "扫描中" : "\(run.percent)%"
    }

    private func activeDetail(_ run: ImportRun) -> String {
        if run.phase == .paused {
            return "已暂停在 \((run.processed + run.failed).formatted()) / \(run.total.formatted()) 个文件"
        }
        guard run.total > 0 else { return "正在扫描源文件夹…" }
        return "正在处理 \((run.processed + run.failed).formatted()) / \(run.total.formatted()) 个文件"
    }
}

// shared sheet helpers
@MainActor
func sheetClose(_ action: @escaping () -> Void) -> some View {
    SheetCloseButton(action: action)
}

@MainActor
func ghostButton(_ icon: String?, _ label: String, danger: Bool = false, small: Bool = false,
                 disabled: Bool = false,
                 action: @escaping () -> Void) -> some View {
    GhostButton(icon: icon, label: label, danger: danger, small: small, disabled: disabled, action: action)
}

private struct SheetCloseButton: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Icon("close", size: 15).foregroundStyle(hover ? Theme.text : Theme.text2)
                .frame(width: 28, height: 28)
                .background(hover ? Theme.surfaceHi : Theme.bgSidebar)
                .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
        }.buttonStyle(.plain).onHover { hover = $0 }
            .help("关闭")
            .accessibilityLabel("关闭")
    }
}

private struct GhostButton: View {
    let icon: String?
    let label: String
    let danger: Bool
    let small: Bool
    let disabled: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Icon(icon, size: small ? 13 : 14) }
                Text(label).font(.system(size: 13))
            }
            .foregroundStyle(disabled ? Theme.text3 : (danger ? Theme.redSoft : Theme.text))
            .fixedSize()
            .padding(.horizontal, small ? 10 : 15).padding(.vertical, small ? 5 : 8)
            .background(disabled ? Theme.surface
                        : (danger ? Theme.red.opacity(hover ? 0.12 : 0.06)
                                  : (hover ? Theme.surfaceHi : Theme.surface)))
            .overlay(RoundedRectangle(cornerRadius: Theme.rSm)
                .strokeBorder(danger ? Theme.red.opacity(0.20) : Theme.line2, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .onHover { hover = disabled ? false : $0 }
    }
}
