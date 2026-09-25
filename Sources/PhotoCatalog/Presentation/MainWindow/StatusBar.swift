// ============================================================
//  Status bar — catalog health on the left, grid controls on the right
// ============================================================
import SwiftUI

/// Split into small views so each part re-renders only for what it shows —
/// a rating or a thumbnail-size drag no longer rebuilds the whole bar.
struct StatusBar: View {
    @Environment(AppState.self) var app

    var body: some View {
        HStack(spacing: 10) {
            CatalogStatusLabel()
            SelectionCountLabel()
            StatusSeparator()
            ManagementModeLabel()
            Spacer(minLength: 8)
            ImportProgressLabel()
            ExportProgressLabel()
            OriginalsCheckLabel()
            MaintenanceLabels()
            if app.view == .grid && !app.isDuplicates && !app.isPlaces {
                StatusSeparator()
                GridControls()
            }
        }
        .font(.system(size: 11))
        .labelStyle(StatusLabelStyle())
        .lineLimit(1)
        .foregroundStyle(Theme.text2)
        .padding(.horizontal, 12)
        .frame(height: Theme.statusbarH)
        .background(Theme.bgTitlebar)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

private struct StatusSeparator: View {
    var body: some View { Rectangle().fill(Theme.line2).frame(width: 1, height: 12) }
}

private struct CatalogStatusLabel: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if app.hasCatalogPreview {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini).tint(Theme.accent)
                Text("正在载入完整目录…")
            }
            .fixedSize()
        } else {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
                Text("\(app.statusAssetCount.formatted()) 张资产")
            }
            .help("目录库就绪")
            .accessibilityElement(children: .combine)
            .fixedSize()
        }
    }
}

private struct SelectionCountLabel: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let count = app.selectedIds.count
        if count > 0 {
            Text("已选 \(count.formatted())")
                .foregroundStyle(Theme.accent)
                .fixedSize()
        }
    }
}

private struct ManagementModeLabel: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Text(app.catalogManagementText).foregroundStyle(Theme.text3)
            .truncationMode(.middle)
    }
}

private struct ImportProgressLabel: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if let run = app.importRun, run.phase.isActive {
            Button { app.sheet = "import" } label: {
                HStack(spacing: 5) {
                    if run.total > 0 {
                        ProgressView(value: Double(run.processed + run.failed), total: Double(run.total))
                            .tint(Theme.accent)
                            .frame(width: 54)
                    } else {
                        ProgressView().controlSize(.mini).tint(Theme.accent)
                    }
                    Text(statusText(run))
                }
                .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .fixedSize()
        }
    }

    private func statusText(_ run: ImportRun) -> String {
        if run.phase == .paused {
            return run.total > 0 ? L("已暂停 \(run.percent)%") : L("已暂停")
        }
        return run.total > 0 ? L("导入 \(run.percent)%") : L("正在扫描…")
    }
}

private struct ExportProgressLabel: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if let progress = app.renderedExportProgress {
            HStack(spacing: 5) {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .tint(Theme.accent)
                    .frame(width: 54)
                Text(L("导出 \(progress.done)/\(progress.total)") + (progress.queued > 0 ? L(" · 队列 \(progress.queued)") : ""))
                    .monospacedDigit()
                Button { app.cancelRenderedExport() } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.text3)
                .help("取消导出")
                .accessibilityLabel("取消导出")
            }
            .foregroundStyle(Theme.accent)
            .fixedSize()
        }
    }
}

private struct OriginalsCheckLabel: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if app.isCheckingOriginals {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("正在检查原件…")
            }
            .foregroundStyle(Theme.text3)
            .accessibilityElement(children: .combine)
            .fixedSize()
        }
    }
}

private struct MaintenanceLabels: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Button { app.runBackup() } label: {
            Label(app.statusBackupText, systemImage: "clock.arrow.circlepath")
                .foregroundStyle(Theme.text3)
        }
        .buttonStyle(.plain).disabled(!app.canRunCatalogMaintenance).help("立即备份目录库 (⌘B)")
        .fixedSize()
        Text(app.statusCacheText).foregroundStyle(Theme.text3).fixedSize()
    }
}

private struct GridControls: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        return HStack(spacing: 6) {
            Button { app.toggleGridInfo() } label: {
                Image(systemName: app.showInfo ? "text.below.photo.fill" : "text.below.photo")
                    .font(.system(size: 12))
                    .foregroundStyle(app.showInfo ? Theme.accent : Theme.text3)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(app.showInfo ? "隐藏缩略图信息 (I)" : "显示缩略图信息 (I)")
            .accessibilityLabel(app.showInfo ? "隐藏缩略图信息" : "显示缩略图信息")
            Image(systemName: "photo").font(.system(size: 9)).foregroundStyle(Theme.text3)
                .accessibilityHidden(true)
            Slider(value: $app.thumbSize, in: 108...280)
                .controlSize(.mini)
                .frame(width: 96)
                .accessibilityLabel("缩略图大小")
                .help("调整缩略图大小 (⌘+ / ⌘−)")
            Image(systemName: "photo").font(.system(size: 13)).foregroundStyle(Theme.text3)
                .accessibilityHidden(true)
        }
        .fixedSize()
    }
}

private struct StatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 11))
            configuration.title
        }
    }
}
