// ============================================================
//  Tone curve editor — Lightroom's point curve
// ============================================================
import SwiftUI

/// Click the curve to add a point, drag a point to move it, double-click one to remove it.
/// The end points move up and down only. Edits preview while dragging and save on release.
struct ToneCurveEditor: View {
    let curve: ToneCurve
    let histogram: DevelopHistogram?
    let onChange: (ToneCurve) -> Void
    let onCommit: (_ undoName: String) -> Void

    @State private var channel: ToneCurve.Channel = .rgb
    /// The channel's points while a drag is in progress, so indices stay put as it moves.
    @State private var working: [CurvePoint]?
    @State private var dragged: Int?

    private static let hitRadius: CGFloat = 9

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Picker("通道", selection: $channel) {
                    ForEach(ToneCurve.Channel.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Menu {
                    Button("线性") { apply(ToneCurve.identity, name: L("线性曲线")) }
                    Button("中对比度") { apply(ToneCurve.mediumContrast, name: L("中对比度曲线")) }
                    Button("强对比度") { apply(ToneCurve.strongContrast, name: L("强对比度曲线")) }
                    Divider()
                    Button("复位全部通道") {
                        onChange(.linear)
                        onCommit(L("复位色调曲线"))
                    }
                    .disabled(curve.isLinear)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("曲线预设")
                .accessibilityLabel("曲线预设")
            }
            .controlSize(.small)
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height)
                Canvas { context, _ in draw(in: &context, side: side) }
                    .frame(width: side, height: side)
                    .contentShape(Rectangle())
                    .gesture(dragGesture(side: side))
                    .accessibilityElement()
                    .accessibilityLabel(L("色调曲线"))
                    .accessibilityValue(accessibilitySummary)
            }
            .aspectRatio(1, contentMode: .fit)
            Text("点按曲线添加控制点，拖移调整，双击删除")
                .font(.system(size: 11)).foregroundStyle(Theme.text3)
        }
    }

    private var points: [CurvePoint] { working ?? curve.editablePoints(for: channel) }

    private var tint: Color {
        switch channel {
        case .rgb: Theme.text
        case .red: .red
        case .green: .green
        case .blue: .blue
        }
    }

    private var accessibilitySummary: String {
        points.map { String(format: "%.0f→%.0f", $0.x * 255, $0.y * 255) }.joined(separator: ", ")
    }

    // ---- drawing ----
    private func draw(in context: inout GraphicsContext, side: CGFloat) {
        let frame = CGRect(x: 0, y: 0, width: side, height: side)
        context.fill(Path(roundedRect: frame, cornerRadius: 4), with: .color(Theme.surface))
        var grid = Path()
        for i in 1..<4 {
            let t = side * CGFloat(i) / 4
            grid.move(to: CGPoint(x: t, y: 0)); grid.addLine(to: CGPoint(x: t, y: side))
            grid.move(to: CGPoint(x: 0, y: t)); grid.addLine(to: CGPoint(x: side, y: t))
        }
        context.stroke(grid, with: .color(Theme.line), lineWidth: 1)
        if let bins = histogramBins, let peak = bins.dropFirst().dropLast().max(), peak > 0 {
            var shape = Path()
            shape.move(to: CGPoint(x: 0, y: side))
            for (i, value) in bins.enumerated() {
                let x = side * CGFloat(i) / CGFloat(max(bins.count - 1, 1))
                shape.addLine(to: CGPoint(x: x, y: side - side * 0.9 * CGFloat(min(1, value / peak))))
            }
            shape.addLine(to: CGPoint(x: side, y: side))
            shape.closeSubpath()
            context.fill(shape, with: .color(tint.opacity(0.12)))
        }
        var diagonal = Path()
        diagonal.move(to: CGPoint(x: 0, y: side))
        diagonal.addLine(to: CGPoint(x: side, y: 0))
        context.stroke(diagonal, with: .color(Theme.line2), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

        let current = points
        var line = Path()
        for step in 0...128 {
            let x = Double(step) / 128
            let point = view(CurvePoint(x: x, y: ToneCurve.evaluate(current, at: x)), side: side)
            if step == 0 { line.move(to: point) } else { line.addLine(to: point) }
        }
        context.stroke(line, with: .color(tint), lineWidth: 1.5)
        for (index, point) in current.enumerated() {
            let center = view(point, side: side)
            let dot = Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8))
            context.fill(dot, with: .color(index == dragged ? tint : Theme.bgPanel))
            context.stroke(dot, with: .color(tint), lineWidth: 1.5)
        }
    }

    private var histogramBins: [Double]? {
        guard let histogram else { return nil }
        switch channel {
        case .rgb: return zip(zip(histogram.red, histogram.green), histogram.blue).map { max($0.0, $0.1, $1) }
        case .red: return histogram.red
        case .green: return histogram.green
        case .blue: return histogram.blue
        }
    }

    // ---- editing ----
    private func view(_ point: CurvePoint, side: CGFloat) -> CGPoint {
        CGPoint(x: CGFloat(point.x) * side, y: (1 - CGFloat(point.y)) * side)
    }

    private func curvePoint(_ location: CGPoint, side: CGFloat) -> CurvePoint {
        CurvePoint(x: min(1, max(0, Double(location.x / side))), y: min(1, max(0, Double(1 - location.y / side))))
    }

    private func dragGesture(side: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                var current = points
                if dragged == nil {
                    let start = value.startLocation
                    let nearest = current.indices.min {
                        hypot(view(current[$0], side: side).x - start.x, view(current[$0], side: side).y - start.y)
                            < hypot(view(current[$1], side: side).x - start.x, view(current[$1], side: side).y - start.y)
                    }
                    if let nearest,
                       hypot(view(current[nearest], side: side).x - start.x,
                             view(current[nearest], side: side).y - start.y) <= Self.hitRadius {
                        dragged = nearest
                    } else {
                        // a new point on the curve at the clicked input, so a click alone changes nothing
                        let x = curvePoint(start, side: side).x
                        guard let index = current.firstIndex(where: { $0.x > x }), index > 0,
                              x - current[index - 1].x >= ToneCurve.minimumGap,
                              current[index].x - x >= ToneCurve.minimumGap else { return }
                        current.insert(CurvePoint(x: x, y: ToneCurve.evaluate(current, at: x)), at: index)
                        dragged = index
                    }
                }
                guard let index = dragged, current.indices.contains(index) else { return }
                var moved = curvePoint(value.location, side: side)
                if index == 0 || index == current.count - 1 {
                    moved.x = current[index].x   // the ends stay at black and white input
                } else {
                    moved.x = min(current[index + 1].x - ToneCurve.minimumGap,
                                  max(current[index - 1].x + ToneCurve.minimumGap, moved.x))
                }
                current[index] = moved
                working = current
                publish(current)
            }
            .onEnded { value in
                defer { working = nil; dragged = nil }
                let isClick = hypot(value.translation.width, value.translation.height) < 2
                if isClick, ClickEvent.clickCount >= 2, let index = dragged, index > 0, index < points.count - 1 {
                    var current = points
                    current.remove(at: index)
                    publish(current)
                    onCommit(L("删除曲线控制点"))
                    return
                }
                // always end the draft; an unchanged curve saves nothing
                onCommit(L("色调曲线"))
            }
    }

    private func publish(_ points: [CurvePoint]) {
        var next = curve
        next.setPoints(points, for: channel)
        onChange(next)
    }

    private func apply(_ points: [CurvePoint], name: String) {
        publish(points)
        onCommit(name)
    }
}
