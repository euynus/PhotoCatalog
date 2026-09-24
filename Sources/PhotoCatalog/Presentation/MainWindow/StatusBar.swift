// ============================================================
//  Status bar — catalog health on the left, grid controls on the right
// ============================================================
import SwiftUI

struct StatusBar: View {
    @Environment(AppState.self) var app

    var body: some View {
        HStack(spacing: 10) {
            catalogStatus
            sep
            Text(app.catalogManagementText).foregroundStyle(Theme.text3)
                .truncationMode(.middle)
            Spacer(minLength: 8)
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
            if app.isCheckingOriginals {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("正在检查原件…")
                }
                .foregroundStyle(Theme.text3)
                .accessibilityElement(children: .combine)
                .fixedSize()
            }
            Button { app.runBackup() } label: {
                Label(app.statusBackupText, systemImage: "clock.arrow.circlepath")
                    .foregroundStyle(Theme.text3)
            }
            .buttonStyle(.plain).disabled(!app.canRunCatalogMaintenance).help("立即备份目录库 (⌘B)")
            .fixedSize()
            Text(app.statusCacheText).foregroundStyle(Theme.text3).fixedSize()
            if app.view == .grid && !app.isDuplicates && !app.isPlaces {
                sep
                gridControls
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

    @ViewBuilder private var catalogStatus: some View {
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

    private var gridControls: some View {
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

    private var sep: some View { Rectangle().fill(Theme.line2).frame(width: 1, height: 12) }

    private func statusText(_ run: ImportRun) -> String {
        if run.phase == .paused {
            return run.total > 0 ? "已暂停 \(run.percent)%" : "已暂停"
        }
        return run.total > 0 ? "导入 \(run.percent)%" : "正在扫描…"
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
