// ============================================================
//  Status bar
// ============================================================
import SwiftUI

struct StatusBar: View {
    @Environment(AppState.self) var app

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) {
                Icon("check", size: 13, weight: .bold).foregroundStyle(Theme.accent)
                Text("目录库就绪")
            }
            Text("\(app.statusAssetCount) 张资产")
            sep
            Text("引用式管理 · 原件只读").foregroundStyle(Theme.text3)
            Spacer()
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
            }
            Button { app.runBackup() } label: {
                HStack(spacing: 5) {
                    Icon("clock", size: 12)
                    Text(app.statusBackupText)
                }.foregroundStyle(Theme.text3)
            }
            .buttonStyle(.plain).help("立即备份目录库")
            Text(app.statusCacheText).foregroundStyle(Theme.text3)
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.text2)
        .padding(.horizontal, 14)
        .frame(height: Theme.statusbarH)
        .background(Color(hex: "#232326"))
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var sep: some View { Rectangle().fill(Theme.line2).frame(width: 1, height: 12) }

    private func statusText(_ run: ImportRun) -> String {
        if run.phase == .paused {
            return run.total > 0 ? "已暂停 \(run.percent)%" : "已暂停"
        }
        return run.total > 0 ? "导入 \(run.percent)%" : "正在扫描…"
    }
}
