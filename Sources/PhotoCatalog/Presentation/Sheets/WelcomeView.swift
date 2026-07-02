// ============================================================
//  Welcome / first-launch catalog creation — port of Welcome()
// ============================================================
import SwiftUI

struct WelcomeView: View {
    @Environment(AppState.self) var app

    var body: some View {
        HStack(spacing: 0) {
            left
            right
        }
        .frame(width: 760)
        .background(Color(hex: "#1f1f21"))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.line2, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.7), radius: 60, y: 40)
    }

    private var left: some View {
        VStack(alignment: .leading, spacing: 0) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.glyphGradient)
                .frame(width: 72, height: 72)
                .overlay { Icon("aperture", size: 40).foregroundStyle(Theme.onAccent) }
                .shadow(color: Theme.accent.opacity(0.3), radius: 30, y: 10)
                .padding(.bottom, 20)

            Text("PhotoCatalog").font(.system(size: 27, weight: .bold)).tracking(-0.5)
            Text("版本 1.0 · 本地优先的照片原件管理")
                .font(.system(size: 12.5)).foregroundStyle(Theme.text3).padding(.top, 6)

            VStack(spacing: 9) {
                wbtn("folder", "添加照片文件夹…", primary: true) { app.enterApp("import") }
                wbtn("plus", "新建目录库…", primary: false) { app.createCatalog() }
                wbtn("photos", "打开目录库…", primary: false) { app.openCatalog() }
            }.padding(.top, 26)

            HStack(alignment: .top, spacing: 8) {
                Icon("info", size: 13)
                Text("原件不会被修改或移动。评分、关键词、相册仅写入本地目录库。")
                    .lineSpacing(2)
            }
            .font(.system(size: 11.5)).foregroundStyle(Theme.text3).padding(.top, 24)
        }
        .padding(.horizontal, 34).padding(.vertical, 40)
        .frame(width: 320, alignment: .leading)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
    }

    private func wbtn(_ icon: String, _ label: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Hover { hover in
            Button(action: action) {
                HStack(spacing: 9) {
                    Icon(icon, size: 16); Text(label).font(.system(size: 13.5, weight: .medium))
                    Spacer()
                }
                .foregroundStyle(primary ? Theme.onAccent : Theme.text)
                .padding(.horizontal, 16).frame(height: 40)
                .background(primary ? (hover ? Theme.accent2 : Theme.accent)
                                    : (hover ? Theme.surfaceHi : Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(primary ? .clear : Theme.line2, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(.plain)
        }
    }

    private var right: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("最近打开").font(.system(size: 11, weight: .bold)).tracking(0.4)
                .foregroundStyle(Theme.text3).textCase(.uppercase).padding(.bottom, 14)
            if app.recentCatalogs.isEmpty {
                Text("还没有最近目录库")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 18)
            } else {
                ForEach(app.recentCatalogs) { catalog in
                    Hover { hover in
                        Button { app.openRecentCatalog(catalog) } label: {
                            recentRow(catalog, hover: hover)
                        }.buttonStyle(.plain)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("当前目录库").font(.system(size: 11)).foregroundStyle(Theme.text3)
                Text(app.catalogPath)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text2)
                    .lineLimit(2)
            }
            .padding(.top, 22)
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1).offset(y: -11) }
        }
        .padding(.horizontal, 28).padding(.vertical, 34)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func recentRow(_ catalog: RecentCatalog, hover: Bool) -> some View {
        HStack(spacing: 12) {
            Icon("photos", size: 18).foregroundStyle(Theme.accent)
                .frame(width: 38, height: 38).background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(catalog.name).font(.system(size: 13.5, weight: .medium))
                Text(catalog.parentPath).font(.system(size: 11.5))
                    .foregroundStyle(Theme.text3).lineLimit(1)
            }
            Spacer()
            Icon("chevronR", size: 12).foregroundStyle(hover ? Theme.text3 : Theme.text4)
        }
        .padding(11)
        .background(hover ? Color.white(0.035) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }
}
