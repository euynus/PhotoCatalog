// ============================================================
//  Settings (PRD §17) — surfaces import mode, XMP, cache, backup,
//  health check, and batch rename.
// ============================================================
import SwiftUI

struct SettingsSheet: View {
    @EnvironmentObject var app: AppState
    @State private var renamePrefix = "IMG"

    var body: some View {
        VStack(spacing: 0) {
            head
            ScrollView { body_ }
            foot
        }
        .frame(width: 560)
        .frame(maxHeight: 620)
        .background(Color(hex: "#232325"))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line2, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.7), radius: 60, y: 40)
    }

    private var head: some View {
        HStack {
            HStack(spacing: 9) {
                Icon("gear", size: 17).foregroundStyle(Theme.accent)
                Text("设置").font(.system(size: 14.5, weight: .semibold))
            }
            Spacer()
            sheetClose { app.sheet = nil }
        }
        .padding(.horizontal, 18).padding(.vertical, 15)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var body_: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("导入") {
                row("导入模式") {
                    Segmented(options: [
                        SegOption(value: "referenced", label: "引用式"),
                        SegOption(value: "managed", label: "托管式"),
                    ], value: app.importMode.rawValue,
                       onChange: { app.importMode = ImportMode(rawValue: $0) ?? .referenced }, size: "sm")
                }
                Text(app.importMode == .managed
                     ? "托管式：导入时复制原件到目录库 Originals/YYYY/MM/DD。"
                     : "引用式：只索引，原件保留在原位置（推荐）。")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                Toggle(isOn: $app.exportWritesXMP) {
                    Text("导出时写入 XMP sidecar").font(.system(size: 12.5)).foregroundStyle(Theme.text)
                }.toggleStyle(.switch).tint(Theme.accent)
                Toggle(isOn: $app.visionEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("导入时 Vision 分析（场景标签 + 人脸）").font(.system(size: 12.5)).foregroundStyle(Theme.text)
                        Text("完全在本机进行，照片不会离开设备。").font(.system(size: 11)).foregroundStyle(Theme.text3)
                    }
                }.toggleStyle(.switch).tint(Theme.accent)
            }

            section("缩略图与缓存") {
                HStack(spacing: 9) {
                    ghostButton("refresh", "重建缩略图", small: true) { app.rebuildThumbnails() }
                    ghostButton("trash", "清理缓存", small: true) { app.clearCache() }
                }
            }

            section("维护") {
                HStack(spacing: 9) {
                    ghostButton("check", "立即备份", small: true) { app.runBackup() }
                    ghostButton("info", "运行健康检查", small: true) { app.runHealthCheck() }
                }
                if let r = app.healthReport {
                    Text(r.summary).font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(r.dbIntegrityOK ? Theme.text2 : Theme.redSoft)
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.24))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
            }

            section("批量重命名") {
                Text("对当前选中的已导入照片按「前缀_序号」重命名原件。")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                HStack(spacing: 9) {
                    TextField("前缀", text: $renamePrefix)
                        .textFieldStyle(.plain).font(.system(size: 12.5))
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(Color.black.opacity(0.28))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line2, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .frame(width: 160)
                    ghostButton(nil, "重命名选中", small: true) { app.batchRename(prefix: renamePrefix) }
                    Spacer()
                }
            }

            section("目录库") {
                Text(CatalogStore.defaultURL.path)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(18)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 11, weight: .bold)).tracking(0.3)
                .foregroundStyle(Theme.text3).textCase(.uppercase)
            content()
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label).font(.system(size: 12.5)).foregroundStyle(Theme.text2)
            Spacer()
            content()
        }
    }

    private var foot: some View {
        HStack {
            Spacer()
            Button { app.sheet = nil } label: {
                Text("完成").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 17).padding(.vertical, 8)
                    .background(Theme.accent).clipShape(RoundedRectangle(cornerRadius: 7))
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
        .background(Color.black.opacity(0.18))
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}
