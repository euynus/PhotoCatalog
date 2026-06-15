// ============================================================
//  Titlebar / toolbar
// ============================================================
import SwiftUI

struct Titlebar: View {
    @EnvironmentObject var app: AppState
    @FocusState private var searchFocused: Bool

    var body: some View {
        ZStack {
            // left + right groups
            HStack(spacing: 10) {
                // leading padding clears the real macOS traffic-light controls
                Color.clear.frame(width: 62, height: 1)

                ToolButton(icon: "importIcon", label: "导入 / 添加文件夹",
                           action: { app.sheet = "import" }) {
                    Text("导入").font(.system(size: 12.5, weight: .medium))
                }

                Spacer()

                rightGroup
            }
            .padding(.horizontal, 14)

            // absolutely-centered catalog name
            HStack(spacing: 7) {
                Icon("aperture", size: 14).foregroundStyle(Theme.accent)
                Text("PhotoCatalog Library")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.text2)
            }
        }
        .frame(height: Theme.titlebarH)
        .background(Theme.titlebarGradient)
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.04)).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.45)).frame(height: 1) }
    }

    private var rightGroup: some View {
        HStack(spacing: 4) {
            Segmented(
                options: [
                    SegOption(value: "grid", icon: "grid", title: "网格 (G)"),
                    SegOption(value: "loupe", icon: "loupe", title: "单张 (E)"),
                    SegOption(value: "compare", icon: "compare", title: "比较 (C)"),
                ],
                value: app.view.rawValue,
                onChange: { app.switchView(ViewMode(rawValue: $0) ?? .grid) })

            separator

            ZStack(alignment: .topTrailing) {
                ToolButton(icon: "filter", label: "筛选",
                           active: app.filterOpen || app.filters.activeCount > 0,
                           action: { app.filterOpen.toggle() })
                if app.filters.activeCount > 0 {
                    Text("\(app.filters.activeCount)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(minWidth: 14, minHeight: 14)
                        .background(Theme.accent).clipShape(Capsule())
                        .offset(x: -2, y: 2)
                }
            }

            searchField

            sizeSlider

            separator

            ToolButton(icon: "export", label: "导出选中原件",
                       action: { app.push("正在导出 \(max(app.selectedIds.count, 1)) 张原件…", "export") })
            ToolButton(icon: "inspector", label: "显示简介 (⌘I)", active: app.showInspector,
                       action: { app.showInspector.toggle() })
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Icon("search", size: 14).foregroundStyle(Theme.text3)
            TextField("搜索", text: Binding(get: { app.search }, set: { app.setSearch($0) }))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .focused($searchFocused)
            if !app.search.isEmpty {
                Button { app.setSearch("") } label: {
                    Icon("close", size: 12, weight: .bold).foregroundStyle(Theme.text3)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(width: 190, height: 30)
        .background(Color.black.opacity(0.28))
        .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
        .focusRing(searchFocused, radius: Theme.rSm)
        .onChange(of: app.searchFocusToken) { searchFocused = true }
    }

    private var sizeSlider: some View {
        HStack(spacing: 6) {
            Icon("photos", size: 13).foregroundStyle(Theme.text3)
            Slider(value: $app.thumbSize, in: 108...280)
                .frame(width: 76)
                .controlSize(.mini)
                .tint(Theme.surfaceHi)
        }
        .padding(.horizontal, 4)
    }

    private var separator: some View {
        Rectangle().fill(Theme.line2).frame(width: 1, height: 22).padding(.horizontal, 5)
    }
}
