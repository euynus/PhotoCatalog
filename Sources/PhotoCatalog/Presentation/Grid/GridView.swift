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
            GridEmptyState(selectionName: app.selection.name,
                           search: app.search,
                           activeFilterCount: app.filters.activeCount) {
                app.setSearch("")
                app.setFilters(Filters())
            }
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
                                    app.blurSearch()
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
                                .accessibilityAction {
                                    app.blurSearch()
                                    app.selectCell(asset.id, shift: false, meta: false)
                                }
                                .accessibilityAction(named: "打开放大视图") { app.openLoupe(asset.id) }
                                .accessibilityAction(named: stack?.collapsed == true ? "展开堆栈" : "折叠堆栈") {
                                    if stack != nil { app.toggleStack(containing: asset.id) }
                                }
                        }
                    }
                    .padding(18)
                }
                .environment(\.colorScheme, .dark)
                .onAppear { app.gridWidth = avail }
                .onChange(of: avail) { app.gridWidth = avail }
            }
            .background(Theme.canvas)
        }
    }

    /// Spoken summary matching the cell's visible badges.
    private static func accessibilityLabel(_ asset: Asset,
                                           stack: (count: Int, collapsed: Bool)?) -> String {
        var parts = [asset.filename, asset.isRaw ? "\(asset.type) RAW" : asset.type]
        parts.append(asset.rating > 0 ? "\(asset.rating) 星" : "未评分")
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

    var body: some View {
        VStack(spacing: 0) {
            frame
            if showInfo { foot }
        }
        .frame(width: size)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .overlay(RoundedRectangle(cornerRadius: 2)
            .strokeBorder(borderColor, lineWidth: borderWidth))
        .contentShape(Rectangle())
        .help("\(asset.filename) · \(asset.isRaw ? "RAW · " : "")\(asset.type)")
        .onHover { hover = $0 }
    }

    private var background: Color {
        selected || hover ? Theme.canvasSurfaceHi : Theme.canvasSurface
    }
    private var borderColor: Color {
        if isPrimary { return Theme.canvasText }
        if selected { return Theme.canvasText2 }
        return Theme.canvasLine
    }
    private var borderWidth: CGFloat {
        isPrimary ? 1.5 : 1
    }

    private var frame: some View {
        Thumb(asset: asset, radius: 2, contentMode: .fit, dim: asset.status == .missing,
              maxDecodePixel: Int((size * 2).rounded(.up)))
            .frame(width: size - 16, height: size - 16)
            .background(Theme.canvas)
            .padding(8)
            .overlay(alignment: .topLeading) {
                StatusBadge(status: asset.status).padding(10)
            }
            .overlay(alignment: .topTrailing) {
                VStack(alignment: .trailing, spacing: 5) {
                    if asset.colorLabel != nil { ColorDot(label: asset.colorLabel, size: 11) }
                    if let stackCount {
                        StackBadge(count: stackCount, collapsed: stackCollapsed, action: onToggleStack)
                    }
                }
                .padding(10)
            }
            .overlay(alignment: .bottomLeading) {
                if asset.flag != .none {
                    FlagPill(flag: asset.flag, size: 14)
                        .padding(3)
                        .background(Theme.canvasSurface, in: RoundedRectangle(cornerRadius: 2))
                        .padding(.leading, 10).padding(.bottom, 10)
                }
            }
            .overlay {
                if asset.status == .missing {
                    ZStack {
                        CautionHatch()
                        VStack(spacing: 4) {
                            Icon("missing", size: 20)
                            Text("缺失").font(.system(size: 11))
                        }.foregroundStyle(Theme.canvasText)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .padding(8)
                }
            }
    }

    private var foot: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(asset.filename)
                .font(.system(size: 11, weight: selected ? .medium : .regular)).monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(selected || isPrimary ? Theme.canvasText : Theme.canvasText2)
                .frame(height: 14, alignment: .leading)
                .help(asset.filename)
            HStack(spacing: 6) {
                if asset.rating > 0 {
                    StarsView(value: asset.rating, size: 9, gap: 1)
                        .fixedSize()
                }
                Spacer(minLength: 0)
                if asset.isRaw {
                    Text(asset.type)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.canvasText2)
                        .lineLimit(1)
                        .help("RAW · \(asset.type)")
                }
            }
            .frame(height: 14)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .frame(height: 40)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GridEmptyState: View {
    let selectionName: String
    let search: String
    let activeFilterCount: Int
    let onReset: () -> Void

    private var trimmedSearch: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasActiveQuery: Bool {
        !trimmedSearch.isEmpty || activeFilterCount > 0
    }

    private var title: String {
        hasActiveQuery ? "未找到照片" : "此集合中没有照片"
    }

    private var message: String {
        if !trimmedSearch.isEmpty, activeFilterCount > 0 {
            return "没有与“\(trimmedSearch)”匹配并符合当前筛选条件的照片。"
        }
        if !trimmedSearch.isEmpty {
            return "没有与“\(trimmedSearch)”匹配的照片。"
        }
        if activeFilterCount > 0 {
            return "“\(selectionName)”中没有符合当前筛选条件的照片。"
        }
        return "“\(selectionName)”当前为空。"
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: hasActiveQuery ? "line.3.horizontal.decrease.circle" : "photo.on.rectangle")
                .foregroundStyle(Theme.canvasText)
        } description: {
            Text(message)
                .foregroundStyle(Theme.canvasText2)
        } actions: {
            if hasActiveQuery {
                Button("重置搜索和筛选", systemImage: "arrow.counterclockwise", action: onReset)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .environment(\.colorScheme, .dark)
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
        l.asset.type == r.asset.type &&
        l.asset.isRaw == r.asset.isRaw &&
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
            .foregroundStyle(collapsed ? Theme.onAccent : Theme.canvasText)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(collapsed ? Theme.accent : Theme.canvasSurface)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.canvasLine, lineWidth: 1))
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
