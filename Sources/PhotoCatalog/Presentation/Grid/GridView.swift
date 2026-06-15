// ============================================================
//  Grid view — port of grid.jsx
// ============================================================
import SwiftUI
import AppKit

struct GridView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        let list = app.list
        if list.isEmpty {
            VStack(spacing: 10) {
                Icon("photos", size: 46).foregroundStyle(Theme.text4)
                Text("没有符合条件的照片").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text2)
                Text("调整筛选条件或选择其他集合").font(.system(size: 12.5))
                    .foregroundStyle(Theme.text3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { geo in
                let size = app.thumbSize
                let gap = max(8, size * 0.06)
                let avail = geo.size.width - 36
                let cols = max(1, Int((avail + gap) / (size + gap)))
                let columns = Array(repeating: GridItem(.fixed(size), spacing: gap, alignment: .topLeading),
                                    count: cols)
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: gap) {
                        ForEach(list) { asset in
                            GridCell(asset: asset, size: size,
                                     selected: app.selectedIds.contains(asset.id),
                                     isPrimary: asset.id == app.primaryId,
                                     showInfo: app.showInfo)
                                .onTapGesture(count: 2) { app.openLoupe(asset.id) }
                                .onTapGesture {
                                    let f = NSEvent.modifierFlags
                                    app.selectCell(asset.id, shift: f.contains(.shift),
                                                   meta: f.contains(.command))
                                }
                        }
                    }
                    .padding(18)
                }
                .onAppear { app.gridWidth = avail }
                .onChange(of: avail) { app.gridWidth = avail }
            }
        }
    }
}

struct GridCell: View {
    let asset: Asset
    let size: CGFloat
    let selected: Bool
    let isPrimary: Bool
    let showInfo: Bool
    @State private var hover = false

    private var frameHeight: CGFloat { (size * 0.72).rounded() }

    var body: some View {
        VStack(spacing: 6) {
            frame
            if showInfo { foot }
        }
        .padding(5)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(borderColor, lineWidth: 1.5))
        .frame(width: size)
        .onHover { hover = $0 }
    }

    private var background: Color {
        if selected { return Theme.accentSoft }
        if hover { return Color.white(0.035) }
        return .clear
    }
    private var borderColor: Color {
        if isPrimary { return Theme.accent }
        if selected { return Theme.accent.opacity(0.5) }
        return .clear
    }

    private var frame: some View {
        Thumb(asset: asset, radius: 3, dim: asset.status == .missing)
            .frame(height: frameHeight)
            .overlay(alignment: .topLeading) {
                HStack(spacing: 4) {
                    if asset.isRaw { TypeBadge(asset: asset, small: true) }
                    StatusBadge(status: asset.status)
                }.padding(5)
            }
            .overlay(alignment: .topTrailing) {
                if asset.colorLabel != nil { ColorDot(label: asset.colorLabel, size: 11).padding(6) }
            }
            .overlay(alignment: .bottomLeading) {
                if asset.flag != .none {
                    FlagPill(flag: asset.flag, size: 14)
                        .shadow(color: .black.opacity(0.6), radius: 1, y: 1)
                        .padding(.leading, 6).padding(.bottom, 5)
                }
            }
            .overlay {
                if asset.status == .missing {
                    ZStack {
                        CautionHatch()
                        VStack(spacing: 4) {
                            Icon("missing", size: 20)
                            Text("缺失").font(.system(size: 11))
                        }.foregroundStyle(.white.opacity(0.5))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var foot: some View {
        VStack(alignment: .leading, spacing: 2) {
            StarsView(value: asset.rating, size: 11, dim: asset.rating == 0)
                .frame(height: 12, alignment: .leading)
            Text(asset.filename)
                .font(.system(size: 10.5)).monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(selected || isPrimary ? Theme.text2 : Theme.text3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
    }
}

/// 45° "caution tape" hatch for the missing-original overlay
/// (CSS: repeating-linear-gradient(45deg, rgba(0,0,0,.2) 0 8px, rgba(0,0,0,.34) 8px 16px)).
struct CautionHatch: View {
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.2)))
            let band: CGFloat = 8
            var offset: CGFloat = -size.height
            while offset < size.width {
                var p = Path()
                p.move(to: CGPoint(x: offset, y: 0))
                p.addLine(to: CGPoint(x: offset + band, y: 0))
                p.addLine(to: CGPoint(x: offset + band + size.height, y: size.height))
                p.addLine(to: CGPoint(x: offset + size.height, y: size.height))
                p.closeSubpath()
                ctx.fill(p, with: .color(.black.opacity(0.34)))
                offset += band * 2
            }
        }
    }
}
