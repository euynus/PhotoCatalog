// ============================================================
//  Grid view — port of grid.jsx
// ============================================================
import SwiftUI
import AppKit

struct GridView: View {
    @Environment(AppState.self) var app
    let assetRevision: Int

    var body: some View {
        let _ = assetRevision
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
                            let stack = app.stackInfo(for: asset)
                            GridCell(asset: asset, size: size,
                                     selected: app.selectedIds.contains(asset.id),
                                     isPrimary: asset.id == app.primaryId,
                                     showInfo: app.showInfo,
                                     stackCount: stack?.count,
                                     stackCollapsed: stack?.collapsed == true,
                                     onToggleStack: { app.toggleStack(containing: asset.id) })
                                .equatable()
                                .onTapGesture(count: 2) { app.openLoupe(asset.id) }
                                .onTapGesture {
                                    let f = NSEvent.modifierFlags
                                    app.selectCell(asset.id, shift: f.contains(.shift),
                                                   meta: f.contains(.command))
                                }
                                // one element per photo: tap gestures alone are
                                // invisible to VoiceOver, making the grid unusable
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(Self.accessibilityLabel(asset, stack: stack))
                                .accessibilityAddTraits(app.selectedIds.contains(asset.id)
                                    ? [.isButton, .isSelected] : .isButton)
                                .accessibilityAction { app.selectCell(asset.id, shift: false, meta: false) }
                                .accessibilityAction(named: "打开放大视图") { app.openLoupe(asset.id) }
                                .accessibilityAction(named: stack?.collapsed == true ? "展开堆栈" : "折叠堆栈") {
                                    if stack != nil { app.toggleStack(containing: asset.id) }
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

    /// Spoken summary matching the cell's visible badges.
    private static func accessibilityLabel(_ asset: Asset,
                                           stack: (count: Int, collapsed: Bool)?) -> String {
        var parts = [asset.filename]
        if asset.rating > 0 { parts.append("\(asset.rating) 星") }
        switch asset.flag {
        case .pick: parts.append("精选")
        case .reject: parts.append("拒绝")
        case .none: break
        }
        if let label = asset.colorLabel { parts.append("\(label.name)色标签") }
        if asset.status == .missing { parts.append("缺失") }
        if asset.status == .offline { parts.append("离线") }
        if let stack { parts.append(stack.collapsed ? "堆栈 \(stack.count) 张（已折叠）" : "堆栈 \(stack.count) 张") }
        return parts.joined(separator: "，")
    }
}

struct GridCell: View {
    let asset: Asset
    let size: CGFloat
    let selected: Bool
    let isPrimary: Bool
    let showInfo: Bool
    let stackCount: Int?
    let stackCollapsed: Bool
    let onToggleStack: () -> Void
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
                VStack(alignment: .trailing, spacing: 5) {
                    if asset.colorLabel != nil { ColorDot(label: asset.colorLabel, size: 11) }
                    if let stackCount {
                        StackBadge(count: stackCount, collapsed: stackCollapsed, action: onToggleStack)
                    }
                }
                .padding(6)
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

// The onToggleStack closure would otherwise defeat SwiftUI's memberwise
// diffing, re-running every visible cell on any AppState publish. Compare
// exactly the asset fields the body renders (Asset.== is identity-only, so
// comparing whole assets would leave stale stars/flags after in-place edits).
extension GridCell: Equatable {
    nonisolated static func == (l: GridCell, r: GridCell) -> Bool {
        l.asset.id == r.asset.id &&
        l.asset.rating == r.asset.rating &&
        l.asset.flag == r.asset.flag &&
        l.asset.colorLabel == r.asset.colorLabel &&
        l.asset.status == r.asset.status &&
        l.asset.filename == r.asset.filename &&
        l.asset.thumb == r.asset.thumb &&
        l.asset.localPath == r.asset.localPath &&
        l.size == r.size &&
        l.selected == r.selected &&
        l.isPrimary == r.isPrimary &&
        l.showInfo == r.showInfo &&
        l.stackCount == r.stackCount &&
        l.stackCollapsed == r.stackCollapsed
    }
}

private struct StackBadge: View {
    let count: Int
    let collapsed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Icon("album", size: 10, weight: .semibold)
                Text("\(count)")
                    .font(.system(size: 9.5, weight: .bold))
                    .monospacedDigit()
            }
            .foregroundStyle(collapsed ? Theme.onAccent : Theme.text2)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(collapsed ? Theme.accent : Color.black.opacity(0.58))
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(collapsed ? 0.18 : 0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(collapsed ? "展开堆栈" : "折叠堆栈")
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
