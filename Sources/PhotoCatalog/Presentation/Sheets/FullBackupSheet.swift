import SwiftUI

@MainActor
struct FullBackupSheet: View {
    @Environment(AppState.self) private var app

    private var state: FullBackupState { app.fullBackup }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    controls
                    Divider()
                    coverage
                    if state.status != .idle {
                        Divider()
                        outcome
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
            }
            Divider()
            footer
        }
        .frame(width: 680, height: 590)
        .font(.callout)
        .foregroundStyle(Theme.text)
        .background(Theme.bgPanel)
    }

    private var header: some View {
        @Bindable var state = state
        return VStack(alignment: .leading, spacing: 12) {
            Label("完整备份与恢复", systemImage: "externaldrive.badge.timemachine")
                .font(.system(size: 17, weight: .semibold))
            Picker("操作", selection: $state.operation) {
                ForEach(FullBackupState.Operation.allCases) { operation in
                    Text(operation.title).tag(operation)
                }
            }
            .pickerStyle(.segmented).labelsHidden()
            .disabled(state.isRunning)
            .onChange(of: state.operation) { state.clearResult() }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var controls: some View {
        @Bindable var state = state
        return VStack(alignment: .leading, spacing: 14) {
            if state.operation == .backup {
                pathRow(title: L("源目录库"), url: state.isRunning ? state.sourceURL : app.store?.packageURL)
            } else {
                pathRow(title: L("完整备份"), url: state.backupURL, choose: app.chooseFullBackupSource)
            }
            if state.operation != .verify {
                pathRow(title: L("目标文件夹"), url: state.destinationDirectory, choose: app.chooseFullBackupDestination)
                HStack(spacing: 12) {
                    Text(state.operation == .backup ? L("备份名称") : L("新库名称"))
                        .foregroundStyle(Theme.text2).frame(width: 86, alignment: .leading)
                    if state.operation == .backup {
                        TextField("备份名称", text: $state.backupName).textFieldStyle(.roundedBorder)
                            .onChange(of: state.backupName) { state.clearResult() }
                    } else {
                        TextField("新库名称", text: $state.restoredLibraryName).textFieldStyle(.roundedBorder)
                            .onChange(of: state.restoredLibraryName) { state.clearResult() }
                    }
                }
                if let target = state.targetURL {
                    Text(target.lastPathComponent).font(.caption).foregroundStyle(Theme.text3)
                        .lineLimit(2).textSelection(.enabled).padding(.leading, 98)
                }
            }
            if !state.isRunning, let reason = app.fullBackupUnavailableReason {
                Label(reason, systemImage: "info.circle").font(.caption).foregroundStyle(Theme.text2)
            }
        }
        .disabled(state.isRunning)
    }

    private var coverage: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("备份范围").font(.headline)
            scopeRow(L("包含内容"), value: L("目录库、当前及历史编辑、在库原片、XMP、目录库 Config、引用的 LUT 与生成式填充输出"))
            scopeRow(L("排除内容"), value: L("已删除及演示原片、缩略图与预览缓存、任务历史、全局偏好与预设列表、登录凭据、未提交的编辑草稿"))
            if state.operation == .backup {
                scopeRow(L("目录库快照"), value: L("原有 SQLite 快照仅保存目录库；完整备份另含原片与必要编辑资源"))
            } else if state.operation == .verify {
                scopeRow(L("校验"), value: L("文件清单、大小、SHA-256、目录库完整性与编辑资源覆盖；不更改备份"))
            } else {
                scopeRow(L("恢复"), value: L("仅新建目录库；不覆盖、不自动切换当前库，不恢复旧导入任务或原磁盘书签"))
            }
        }
        .font(.caption)
    }

    @ViewBuilder
    private var outcome: some View {
        switch state.status {
        case .running:
            VStack(alignment: .leading, spacing: 8) {
                Text(state.isCancelRequested ? L("正在取消并清理临时文件") : state.progressTitle)
                    .font(.headline)
                ProgressView(value: fraction).progressViewStyle(.linear).tint(Theme.accent)
                    .accessibilityLabel("完整备份任务进度")
                if let progress = state.progress, progress.totalFiles > 0 {
                    HStack {
                        Text("已处理 \(progress.completedFiles) / \(progress.totalFiles) 个文件")
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: progress.bytes, countStyle: .file))
                    }
                    .font(.caption).foregroundStyle(Theme.text2).monospacedDigit()
                }
            }
        case .completed:
            if let report = state.report {
                VStack(alignment: .leading, spacing: 8) {
                    Label(completionTitle, systemImage: "checkmark.circle").foregroundStyle(Theme.green)
                        .font(.headline)
                    Text(report.url.path).font(.caption).foregroundStyle(Theme.text2).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(report.assetCount) 个资产 · \(report.originalCount) 份原片 · \(report.sidecarCount) 份 XMP")
                    Text("\(report.configurationCount) 份配置 · \(report.lutCount) 份 LUT · \(report.fillCount) 份填充输出")
                    Text(ByteCountFormatter.string(fromByteCount: report.bytes, countStyle: .file))
                        .foregroundStyle(Theme.text2)
                }
                .font(.caption).monospacedDigit()
            }
        case .failed:
            VStack(alignment: .leading, spacing: 8) {
                Label(state.activeOperation == .verify ? L("完整备份校验失败") : L("任务失败，未发布新副本"),
                      systemImage: "exclamationmark.triangle")
                    .font(.headline).foregroundStyle(Theme.redSoft)
                if let message = state.errorMessage {
                    Text(message).font(.caption).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .cancelled:
            Label(state.activeOperation == .verify ? L("校验已取消") : L("已取消，未发布新副本"),
                  systemImage: "xmark.circle").foregroundStyle(Theme.text2)
        case .idle:
            EmptyView()
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if state.isRunning {
                Button("取消任务", systemImage: "stop.circle") { app.cancelFullBackup() }
                    .disabled(state.isCancelRequested)
            } else if state.report != nil {
                Button("在 Finder 中显示", systemImage: "folder", action: app.revealFullBackupResult)
            }
            Spacer()
            Button("关闭") { app.sheet = nil }.keyboardShortcut(.cancelAction)
            if !state.isRunning {
                Button(state.operation.title, action: app.startFullBackup)
                    .buttonStyle(.borderedProminent)
                    .disabled(app.fullBackupUnavailableReason != nil)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(Theme.bgSidebar)
    }

    private var fraction: Double? {
        guard let progress = state.progress, progress.totalFiles > 0 else { return nil }
        return Double(progress.completedFiles) / Double(progress.totalFiles)
    }

    private var completionTitle: String {
        switch state.activeOperation {
        case .backup: return L("完整备份已创建并校验")
        case .verify: return L("完整备份校验通过")
        case .restore: return L("已恢复到新目录库")
        case nil: return L("已完成")
        }
    }

    private func pathRow(title: String, url: URL?, choose: (() -> Void)? = nil) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title).foregroundStyle(Theme.text2).frame(width: 86, alignment: .leading)
            Text(url?.path ?? L("未选择"))
                .font(.caption).lineLimit(3).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled).help(url?.path ?? "")
            if let choose {
                Button("选择文件夹", systemImage: "folder", action: choose)
                    .labelStyle(.iconOnly).help("选择文件夹")
            }
        }
    }

    private func scopeRow(_ title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title).foregroundStyle(Theme.text2).frame(width: 86, alignment: .leading)
            Text(value).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
        }
    }
}
