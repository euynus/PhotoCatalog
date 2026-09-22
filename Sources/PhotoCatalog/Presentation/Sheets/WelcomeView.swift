// ============================================================
//  Welcome / first-launch catalog creation — port of Welcome()
// ============================================================
import SwiftUI

struct WelcomeView: View {
    @Environment(AppState.self) var app

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Icon("aperture", size: 22).foregroundStyle(Theme.accent)
                Text("PhotoCatalog").font(.system(size: 18, weight: .semibold))
                Spacer()
                Text("版本 1.0").foregroundStyle(Theme.text3)
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .background(Theme.bgPanel)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }

            HStack(alignment: .top, spacing: 0) {
                left
                right
            }

            HStack(spacing: 12) {
                Text("当前目录库").foregroundStyle(Theme.text3)
                    .fixedSize()
                Text(app.catalogPath)
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text2)
                    .lineLimit(2).truncationMode(.middle)
                    .help(app.catalogPath)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(Theme.bgPanel)
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        }
        .frame(width: 720)
        .font(.system(size: 13))
        .foregroundStyle(Theme.text)
        .background(Theme.surface)
        .overlay(RoundedRectangle(cornerRadius: Theme.r).strokeBorder(Theme.line2, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.r))
    }

    private var left: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("目录库").font(.system(size: 15, weight: .semibold))
            VStack(spacing: 8) {
                wbtn("folder", "添加照片文件夹…", primary: true) { app.enterApp("import") }
                wbtn("plus", "新建目录库…", primary: false) { app.createCatalog() }
                wbtn("photos", "打开目录库…", primary: false) { app.openCatalog() }
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(width: 250, height: 270, alignment: .topLeading)
        .background(Theme.bgSidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
    }

    private func wbtn(_ icon: String, _ label: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Hover { hover in
            Button(action: action) {
                HStack(spacing: 9) {
                    Icon(icon, size: 15); Text(label).font(.system(size: 13, weight: .medium))
                    Spacer()
                }
                .foregroundStyle(primary ? Theme.onAccent : Theme.text)
                .padding(.horizontal, 12).frame(height: 34)
                .background(primary ? (hover ? Theme.accent2 : Theme.accent)
                                    : (hover ? Theme.surfaceHi : Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: Theme.rSm).strokeBorder(primary ? .clear : Theme.line2, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
            }.buttonStyle(.plain)
        }
    }

    private var right: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("最近打开").font(.system(size: 15, weight: .semibold))
            ScrollView {
                LazyVStack(spacing: 0) {
                    if app.recentCatalogs.isEmpty {
                        Text("还没有最近目录库")
                            .foregroundStyle(Theme.text3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 12)
                    } else {
                        ForEach(app.recentCatalogs) { catalog in
                            Hover { hover in
                                Button { app.openRecentCatalog(catalog) } label: {
                                    recentRow(catalog, hover: hover)
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: 270)
    }

    private func recentRow(_ catalog: RecentCatalog, hover: Bool) -> some View {
        HStack(spacing: 12) {
            Icon("photos", size: 17).foregroundStyle(Theme.text2)
                .frame(width: 22, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(catalog.name).font(.system(size: 13, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                Text(catalog.parentPath).font(.system(size: 12))
                    .foregroundStyle(Theme.text3).lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Icon("chevronR", size: 12).foregroundStyle(hover ? Theme.text2 : Theme.text3)
        }
        .padding(.horizontal, 8).padding(.vertical, 9)
        .background(hover ? Theme.surfaceHi : .clear)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .contentShape(Rectangle())
        .help("\(catalog.name)\n\(catalog.parentPath)")
    }
}
