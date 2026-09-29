// ============================================================
//  Survey — the selection side by side, narrowed down one by one
// ============================================================
import SwiftUI

/// Lightroom's Survey view (N): every surveyed photo as large as the area allows. Click one to
/// make it active (rating and flag keys act on it), × takes a photo out, a double-click opens
/// it in the loupe.
struct SurveyView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let assets = app.surveyIds.compactMap { app.asset(id: $0) }
        VStack(spacing: 0) {
            GeometryReader { geo in
                let layout = SurveyLayout(count: assets.count, in: geo.size)
                VStack(spacing: SurveyLayout.spacing) {
                    ForEach(0..<layout.rows, id: \.self) { row in
                        HStack(spacing: SurveyLayout.spacing) {
                            ForEach(layout.indices(inRow: row, of: assets.count), id: \.self) { index in
                                SurveyCell(asset: assets[index], isActive: assets[index].id == app.primaryId,
                                           size: layout.cell)
                                    .id(assets[index].id)
                            }
                        }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .padding(12)
            footer(count: assets.count)
        }
        .background(Theme.canvas)
        .environment(\.colorScheme, .dark)
    }

    private func footer(count: Int) -> some View {
        HStack(spacing: 10) {
            Text("筛选 \(count) 张")
                .font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(Theme.canvasText2)
            Spacer(minLength: 0)
            Text("← → 切换 · 1–5 评分 · P / X 旗标 · 悬停点 × 移出 · G 返回网格")
                .font(.system(size: 11))
                .foregroundStyle(Theme.canvasText3)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(Theme.canvasSurface)
        .overlay(alignment: .top) { Rectangle().fill(Theme.canvasLine).frame(height: 1) }
    }
}

/// Columns and rows that give `count` photos the largest cells, assuming photos of about 3:2.
struct SurveyLayout: Equatable {
    static let spacing: CGFloat = 10
    let columns: Int
    let rows: Int
    let cell: CGSize

    init(count: Int, in size: CGSize, aspect: CGFloat = 1.45) {
        var best = (columns: 1, score: -CGFloat.infinity)
        for columns in 1...max(1, count) {
            let rows = Int((Double(count) / Double(columns)).rounded(.up))
            let width = (size.width - Self.spacing * CGFloat(columns - 1)) / CGFloat(columns)
            let height = (size.height - Self.spacing * CGFloat(max(rows, 1) - 1)) / CGFloat(max(rows, 1))
            // the widest photo of this shape that fits the cell
            let score = min(width, height * aspect)
            if score > best.score { best = (columns, score) }
        }
        columns = best.columns
        rows = max(1, Int((Double(count) / Double(best.columns)).rounded(.up)))
        cell = CGSize(width: max(1, (size.width - Self.spacing * CGFloat(columns - 1)) / CGFloat(columns)),
                      height: max(1, (size.height - Self.spacing * CGFloat(rows - 1)) / CGFloat(rows)))
    }

    func indices(inRow row: Int, of count: Int) -> Range<Int> {
        let start = row * columns
        return start..<min(count, start + columns)
    }
}

private struct SurveyCell: View {
    @Environment(AppState.self) private var app
    let asset: Asset
    let isActive: Bool
    let size: CGSize
    @State private var hover = false

    private static let infoHeight: CGFloat = 24

    var body: some View {
        VStack(spacing: 0) {
            Thumb(asset: asset, urlString: asset.preview.isEmpty ? nil : asset.preview, kind: .preview2048,
                  radius: 2, contentMode: .fit,
                  maxDecodePixel: Int((max(size.width, size.height) * 2).rounded(.up)))
                .frame(width: size.width - 8, height: max(1, size.height - Self.infoHeight - 8))
                .padding(4)
            HStack(spacing: 6) {
                Text(asset.filename)
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular)).monospacedDigit()
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(isActive ? Theme.canvasText : Theme.canvasText2)
                Spacer(minLength: 0)
                if asset.colorLabel != nil { ColorDot(label: asset.colorLabel, size: 9) }
                if asset.rating > 0 { StarsView(value: asset.rating, size: 9, gap: 1, filledOnly: true).fixedSize() }
                FlagPill(flag: asset.flag, size: 11)
            }
            .padding(.horizontal, 8)
            .frame(height: Self.infoHeight)
        }
        .frame(width: size.width, height: size.height)
        .background(isActive ? Theme.canvasSurfaceHi : (hover ? Theme.canvasSurface : .clear),
                    in: RoundedRectangle(cornerRadius: 4))
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(isActive ? Theme.canvasText : Theme.canvasLine, lineWidth: isActive ? 2 : 1)
        }
        .overlay(alignment: .topTrailing) {
            if hover {
                Button { app.removeFromSurvey(asset.id) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.canvasText)
                        .frame(width: 22, height: 22)
                        .background(.black.opacity(0.55), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(8)
                .help("移出筛选")
                .accessibilityLabel("移出筛选")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if ClickEvent.clickCount >= 2 {
                app.openLoupe(asset.id)
            } else {
                TextEditing.end()
                app.activateInSurvey(asset.id)
            }
        }
        .onHover { hover = $0 }
        .contextMenu {
            PhotoContextMenu(asset: asset, pairedJPEGPath: app.companions(of: asset).first?.localPath)
        }
        .help(asset.filename)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(asset.filename)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { app.activateInSurvey(asset.id) }
        .accessibilityAction(named: "移出筛选") { app.removeFromSurvey(asset.id) }
    }
}
