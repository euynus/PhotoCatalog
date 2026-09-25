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
            stage
            if trayOpen { tray }
            toolbar
        }
        .background(Theme.canvas)
        .environment(\.colorScheme, .dark)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("\(assets.count) / 4 张")
                .font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(Theme.canvasText2)
                .fixedSize()
            if let winner = assets.first(where: { $0.id == app.winner }) {
                Rectangle().fill(Theme.canvasLine).frame(width: 1, height: 14)
                Label("最佳 · \(winner.filename)", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.canvasText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("最佳 · \(winner.filename)")
            }
            Spacer(minLength: 0)
            Hover { hover in
                Button { trayOpen.toggle() } label: {
                    Icon(trayOpen ? "close" : "plus", size: 13, weight: .medium)
                        .foregroundStyle(Theme.canvasText)
                        .frame(width: 28, height: 28)
                        .background(hover || trayOpen ? Theme.canvasSurfaceHi : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .fixedSize()
                .disabled(assets.count >= 4)
                .opacity(assets.count >= 4 ? 0.4 : 1)
                .help(trayOpen ? "收起待选照片" : "添加照片")
                .accessibilityLabel(trayOpen ? "收起待选照片" : "添加照片")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Theme.canvasSurface)
        .overlay(alignment: .top) { Rectangle().fill(Theme.canvasLine).frame(height: 1) }
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
                                    .strokeBorder(hover ? Theme.canvasText : Theme.canvasLine, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .help(a.filename)
                        .accessibilityLabel(a.filename)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(height: 72)
        .background(Theme.canvasSurface)
        .overlay(alignment: .top) { Rectangle().fill(Theme.canvasLine).frame(height: 1) }
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
                .padding(8)
                .background(Theme.canvas)
            foot
        }
        .background(Theme.canvas)
        .overlay(RoundedRectangle(cornerRadius: 4)
            .strokeBorder(isWinner ? Theme.canvasText : Theme.canvasLine, lineWidth: isWinner ? 2 : 1))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var foot: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(asset.filename).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.canvasText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(asset.filename)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                Hover { hover in
                    Button { app.removeFromCompare(asset.id) } label: {
                        Icon("close", size: 11, weight: .semibold)
                            .foregroundStyle(hover ? Theme.canvasText : Theme.canvasText2)
                            .frame(width: 24, height: 24)
                            .background(hover ? Theme.canvasSurfaceHi : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain).help("移出比较")
                    .accessibilityLabel("移出比较")
                }
                .fixedSize()
            }
            .frame(height: 24)
            Text(exposureSummary(asset))
                .font(.system(size: 10)).monospacedDigit().foregroundStyle(Theme.canvasText2)
                .lineLimit(1)
                .frame(height: 14, alignment: .leading)
                .help(exposureSummary(asset))
            // Each group fits the 92pt footer of a four-up stage at the 480pt minimum.
            FlowRow(spacing: 8, lineSpacing: 4) {
                StarsView(value: asset.rating, size: 11, gap: 1) { n in
                    app.mutateAsset(asset.id, scope: .review, withCompanions: true) { $0.rating = asset.rating == n ? 0 : n }
                }
                .frame(width: 80, height: 24, alignment: .leading)
                HStack(spacing: 4) {
                    miniFlag(.pick)
                    miniFlag(.reject)
                    Hover { hover in
                        Button {
                            app.winner = asset.id; app.push("已选为最佳", "check")
                        } label: {
                            Image(systemName: isWinner ? "checkmark.circle.fill" : "checkmark.circle")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(isWinner ? Theme.canvas : (hover ? Theme.canvasText : Theme.canvasText2))
                                .frame(width: 24, height: 24)
                                .background(isWinner ? Theme.canvasText : (hover ? Theme.canvasSurfaceHi : .clear))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }.buttonStyle(.plain)
                            .help(isWinner ? "已选为最佳" : "选为最佳")
                            .accessibilityLabel(isWinner ? "已选为最佳" : "选为最佳")
                            .accessibilityAddTraits(isWinner ? .isSelected : [])
                    }
                }
                .fixedSize()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(isWinner ? Theme.canvasSurfaceHi : Theme.canvasSurface)
        .overlay(alignment: .top) { Rectangle().fill(Theme.canvasLine).frame(height: 1) }
    }

    private func miniFlag(_ flag: Flag) -> some View {
        let on = asset.flag == flag
        let tint = flag == .pick ? Theme.green : Theme.red
        return Hover { hover in
            Button {
                app.mutateAsset(asset.id, scope: .review, withCompanions: true) { $0.flag = on ? .none : flag }
            } label: {
                Image(systemName: flag == .pick ? (on ? "flag.fill" : "flag")
                                                : (on ? "xmark.circle.fill" : "xmark.circle"))
                    .font(.system(size: 13))
                    .foregroundStyle(on ? tint : (hover ? Theme.canvasText2 : Theme.canvasText3))
                    .frame(width: 24, height: 24)
                    .background(Theme.canvasSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(on || hover ? Theme.canvasText3 : .clear, lineWidth: 1))
            }.buttonStyle(.plain).help(flag == .pick ? "精选" : "拒绝")
                .accessibilityLabel(flag == .pick ? "精选" : "拒绝")
                .accessibilityAddTraits(on ? .isSelected : [])
        }
    }
}
