// ============================================================
//  Compare view (2–4 side by side) — port of compare.jsx
// ============================================================
import SwiftUI

struct CompareView: View {
    @Environment(AppState.self) var app
    @State private var trayOpen = false

    private var assets: [Asset] { app.compareIds.compactMap { id in app.assets.first { $0.id == id } } }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if trayOpen { tray }
            stage
        }
        .background(Theme.canvas)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("比较视图").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Spacer()
            Text("\(assets.count) / 4 张").font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.text2)
                .fixedSize()
            Hover { hover in
                Button { trayOpen.toggle() } label: {
                    HStack(spacing: 5) { Icon("plus", size: 13, weight: .bold); Text("添加照片").font(.system(size: 12)) }
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(hover ? Theme.surfaceHi : Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .fixedSize()
                .disabled(assets.count >= 4)
                .opacity(assets.count >= 4 ? 0.4 : 1)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Theme.bgPanel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var tray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(app.list.filter { !app.compareIds.contains($0.id) }.prefix(24)) { a in
                    Hover { hover in
                        Button {
                            app.addToCompare(a.id)
                            trayOpen = false
                        } label: {
                            Thumb(asset: a, radius: 2, contentMode: .fit, maxDecodePixel: 152)
                                .frame(width: 76, height: 52)
                                .background(Theme.canvas)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                .overlay(RoundedRectangle(cornerRadius: 3)
                                    .strokeBorder(hover ? Theme.accent : .clear, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                        .help(a.filename)
                        .accessibilityLabel(a.filename)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .background(Theme.canvasSurface)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.canvasLine).frame(height: 1) }
        .environment(\.colorScheme, .dark)
    }

    private var stage: some View {
        GeometryReader { geometry in
            let itemCount = assets.count + (assets.count < 2 ? 1 : 0)
            let columnCount = Self.stageColumnCount(itemCount: itemCount, size: geometry.size)
            let rowCount = (itemCount + columnCount - 1) / columnCount
            let panelHeight = max(0, (geometry.size.height - 24 - CGFloat(rowCount - 1) * 8) / CGFloat(rowCount))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 8),
                                     count: columnCount), spacing: 8) {
                ForEach(assets) { a in
                    ComparePanel(asset: a, isWinner: app.winner == a.id)
                        .frame(height: panelHeight)
                }
                if assets.count < 2 {
                    Hover { hover in
                        Button { trayOpen = true } label: {
                            VStack(spacing: 8) { Icon("plus", size: 24); Text("添加照片").font(.system(size: 12.5)) }
                                .foregroundStyle(hover ? Theme.canvasText : Theme.canvasText2)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(hover ? Theme.canvasSurface : Theme.canvas)
                                .overlay(RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(Theme.canvasLine,
                                                  style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }.buttonStyle(.plain)
                    }
                    .frame(height: panelHeight)
                }
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    nonisolated static func stageColumnCount(itemCount: Int, size: CGSize) -> Int {
        itemCount > 2 && size.height > size.width + 120 ? 2 : max(1, itemCount)
    }
}

struct ComparePanel: View {
    @Environment(AppState.self) var app
    let asset: Asset
    let isWinner: Bool
    var body: some View {
        VStack(spacing: 0) {
            Thumb(asset: asset, urlString: asset.preview, kind: .preview2048, radius: 2, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)
                .background(Theme.canvas)
            foot
        }
        .background(Theme.canvas)
        .overlay(RoundedRectangle(cornerRadius: 4)
            .strokeBorder(isWinner ? Theme.accent : Theme.canvasLine, lineWidth: isWinner ? 2 : 1))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var foot: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(asset.filename).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(asset.filename)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Hover { hover in
                        Button { app.removeFromCompare(asset.id) } label: {
                            Icon("close", size: 11, weight: .semibold)
                                .foregroundStyle(hover ? Theme.text : Theme.text2)
                                .frame(width: 24, height: 24)
                                .background(hover ? Theme.surfaceHi : .clear)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain).help("移出比较")
                        .accessibilityLabel("移出比较")
                    }
                }
                Text(exposureSummary(asset))
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.text2)
                    .lineLimit(2)
                    .frame(height: 28, alignment: .topLeading)
                    .help(exposureSummary(asset))
            }
            StarsView(value: asset.rating, size: 13, gap: 2) { n in
                app.mutateAsset(asset.id) { $0.rating = asset.rating == n ? 0 : n }
            }
            .frame(height: 20)
            HStack(spacing: 4) {
                miniFlag(.pick, "flag")
                miniFlag(.reject, "reject")
                Spacer(minLength: 0)
                Hover { hover in
                    Button {
                        app.winner = asset.id; app.push("已选为最佳", "check")
                    } label: {
                        Image(systemName: isWinner ? "checkmark.circle.fill" : "checkmark.circle")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(isWinner ? Theme.onAccent : (hover ? Theme.text : Theme.text2))
                            .frame(width: 24, height: 24)
                            .background(isWinner ? Theme.accent : (hover ? Theme.surfaceHi : Theme.surface))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }.buttonStyle(.plain)
                        .help(isWinner ? "已选为最佳" : "选为最佳")
                        .accessibilityLabel("选为最佳")
                        .accessibilityAddTraits(isWinner ? .isSelected : [])
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bgPanel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func miniFlag(_ flag: Flag, _ icon: String) -> some View {
        let on = asset.flag == flag
        let tint: Color = flag == .pick ? Theme.green : Theme.red
        let bg: Color = tint.opacity(0.12)
        return Hover { hover in
            Button {
                app.mutateAsset(asset.id) { $0.flag = on ? .none : flag }
            } label: {
                Icon(icon, size: 13).foregroundStyle(on ? tint : (hover ? Theme.text2 : Theme.text3))
                    .frame(width: 24, height: 24)
                    .background(on ? bg : (hover ? Theme.surfaceHi : Theme.surface))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }.buttonStyle(.plain).help(flag == .pick ? "精选" : "拒绝")
                .accessibilityLabel(flag == .pick ? "精选" : "拒绝")
                .accessibilityAddTraits(on ? .isSelected : [])
        }
    }
}
