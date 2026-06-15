// ============================================================
//  Status bar
// ============================================================
import SwiftUI

struct StatusBar: View {
    @EnvironmentObject var app: AppState

    private var assetCount: Int { app.assets.filter { !$0.deleted }.count }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) {
                Icon("check", size: 13, weight: .bold).foregroundStyle(Theme.accent)
                Text("目录库就绪")
            }
            Text("\(assetCount) 张资产")
            sep
            Text("引用式管理 · 原件只读").foregroundStyle(Theme.text3)
            Spacer()
            if app.importing {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("正在导入…")
                }.foregroundStyle(Theme.accent)
            }
            Button { app.runBackup() } label: {
                HStack(spacing: 5) {
                    Icon("clock", size: 12)
                    Text("上次备份 今天 03:00")
                }.foregroundStyle(Theme.text3)
            }
            .buttonStyle(.plain).help("立即备份目录库")
            Text("缓存 2.4 GB").foregroundStyle(Theme.text3)
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.text2)
        .padding(.horizontal, 14)
        .frame(height: Theme.statusbarH)
        .background(Color(hex: "#232326"))
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var sep: some View { Rectangle().fill(Theme.line2).frame(width: 1, height: 12) }
}
