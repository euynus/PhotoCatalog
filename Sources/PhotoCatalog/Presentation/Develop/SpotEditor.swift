// ============================================================
//  Spot editor — click specks away, move and resize spots
// ============================================================
import SwiftUI
import AppKit

/// The finished photo with its spots drawn over it. A click heals the speck under it (a drag
/// outward sets the size first); a spot's circle moves it, its rim resizes it, and the
/// selected spot's source circle moves where it copies from.
struct SpotEditor: View {
    @Environment(AppState.self) private var app
    let asset: Asset
    let image: CGImage?
    let settings: DevelopSettings
    let sourceSize: CGSize

    @State private var drag: SpotDrag?
    @State private var hover: CGPoint?
    /// A spot being sized by a drag, before it's added: center and rim on screen.
    @State private var sizing: (center: CGPoint, rim: CGPoint)?

    private static let rimTolerance: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            if let image {
                let display = CropEditor.fitted(CGSize(width: image.width, height: image.height), in: proxy.size)
                let mapper = MaskMapper(display: display, settings: settings, sourceSize: sourceSize)
                ZStack(alignment: .topLeading) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: display.width, height: display.height)
                        .offset(x: display.minX, y: display.minY)
                    SpotOverlay(spots: settings.spots, selectedId: app.developSelectedSpotId, mapper: mapper)
                    if let sizing {
                        let radius = hypot(sizing.rim.x - sizing.center.x, sizing.rim.y - sizing.center.y)
                        Circle().strokeBorder(.white, lineWidth: 1.5)
                            .frame(width: radius * 2, height: radius * 2)
                            .position(sizing.center)
                            .allowsHitTesting(false)
                    } else if let hover, target(at: hover, mapper) == nil {
                        let radius = mapper.screenLength(ofSourceLength: app.developSpotBrush.radius)
                        Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1.2)
                            .frame(width: radius * 2, height: radius * 2)
                            .shadow(color: .black.opacity(0.6), radius: 1)
                            .position(hover)
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .clipped()
                .contentShape(Rectangle())
                .gesture(gesture(mapper))
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hover = location
                        cursor(at: location, mapper).set()
                    case .ended:
                        hover = nil
                        NSCursor.arrow.set()
                    }
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(12)
        .overlay(alignment: .bottom) {
            Text("点按污点修复 · 向外拖动设定大小 · 拖动圆圈移动，拖动边缘调整大小 · [ ] 画笔大小 · Delete 删除 · Esc 完成")
                .font(.system(size: 11))
                .foregroundStyle(Theme.canvasText2)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(.black.opacity(0.45), in: Capsule())
                .padding(.bottom, 10)
                .allowsHitTesting(false)
        }
    }

    // ---- hit testing ----
    private func target(at point: CGPoint, _ mapper: MaskMapper) -> SpotDrag.Target? {
        func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
        if let spot = settings.spots.first(where: { $0.id == app.developSelectedSpotId }) {
            let center = mapper.screen(spot.target), radius = mapper.screenLength(ofSourceLength: spot.radius)
            let d = distance(point, center)
            if abs(d - radius) <= Self.rimTolerance { return .resize(spot.id) }
            if d < radius { return .moveTarget(spot.id) }
            let source = mapper.screen(spot.source)
            if distance(point, source) < radius { return .moveSource(spot.id) }
        }
        for spot in settings.spots.reversed() {
            let radius = max(mapper.screenLength(ofSourceLength: spot.radius), Self.rimTolerance)
            if distance(point, mapper.screen(spot.target)) <= radius { return .select(spot.id) }
        }
        return nil
    }

    private func cursor(at point: CGPoint, _ mapper: MaskMapper) -> NSCursor {
        switch target(at: point, mapper) {
        case .resize: .crosshair
        case .moveTarget, .moveSource, .select: .openHand
        case nil: .crosshair
        }
    }

    // ---- editing ----
    private func gesture(_ mapper: MaskMapper) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if drag == nil {
                    let saved = app.developSettings[asset.id] ?? .neutral
                    let hit = target(at: value.startLocation, mapper)
                    let id: String? = switch hit {
                    case .resize(let id), .moveTarget(let id), .moveSource(let id), .select(let id): id
                    case nil: nil
                    }
                    drag = SpotDrag(target: hit, start: saved.spots.first { $0.id == id })
                }
                guard let drag, hypot(value.translation.width, value.translation.height) >= 2 else { return }
                guard let start = drag.start else {
                    if drag.target == nil { sizing = (value.startLocation, value.location) }
                    return
                }
                var spot = start
                func shifted(_ source: CGPoint) -> CGPoint {
                    let screen = mapper.screen(source)
                    return mapper.source(CGPoint(x: screen.x + value.translation.width, y: screen.y + value.translation.height))
                }
                switch drag.target {
                case .resize:
                    spot.radius = max(0.002, mapper.sourceLength(from: mapper.screen(start.target), to: value.location))
                case .moveTarget, .select:
                    spot.target = shifted(start.target)
                case .moveSource:
                    spot.source = shifted(start.source)
                case nil:
                    return
                }
                var next = app.developSettings[asset.id] ?? .neutral
                guard let index = next.spots.firstIndex(where: { $0.id == spot.id }) else { return }
                next.spots[index] = spot
                app.developSelectedSpotId = spot.id
                app.updateDevelopDraft(next, for: asset.id)
            }
            .onEnded { value in
                defer { drag = nil; sizing = nil }
                guard let drag else { return }
                let moved = hypot(value.translation.width, value.translation.height) >= 2
                switch drag.target {
                case nil:
                    // a new spot: the brush's size, or as big as the drag
                    let radius = moved ? max(0.002, mapper.sourceLength(from: value.startLocation, to: value.location))
                                       : app.developSpotBrush.radius
                    app.addSpot(at: mapper.source(value.startLocation), radius: radius, to: asset.id)
                case .select(let id) where !moved:
                    app.developSelectedSpotId = id
                default:
                    guard moved, let draft = app.developDraft, draft.assetId == asset.id else { return }
                    app.commitDevelop([asset.id: draft.settings], undoName: L("编辑污点"))
                }
            }
    }
}

struct SpotDrag {
    enum Target: Equatable {
        case resize(String), moveTarget(String), moveSource(String), select(String)
    }

    let target: Target?
    /// The spot as the drag began (none when the drag makes a new one).
    let start: SpotRemoval?
}

/// Every spot's circle; the selected one also shows its source and the line between them.
private struct SpotOverlay: View {
    let spots: [SpotRemoval]
    let selectedId: String?
    let mapper: MaskMapper

    var body: some View {
        Canvas { context, _ in
            for spot in spots {
                let center = mapper.screen(spot.target)
                let radius = max(mapper.screenLength(ofSourceLength: spot.radius), 3)
                let circle = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                    width: radius * 2, height: radius * 2))
                let selected = spot.id == selectedId
                context.stroke(circle, with: .color(.black.opacity(0.45)), lineWidth: selected ? 3 : 2.5)
                context.stroke(circle, with: .color(.white.opacity(selected ? 1 : 0.7)), lineWidth: selected ? 1.5 : 1)
                guard selected else { continue }
                let source = mapper.screen(spot.source)
                let from = Path(ellipseIn: CGRect(x: source.x - radius, y: source.y - radius,
                                                  width: radius * 2, height: radius * 2))
                context.stroke(from, with: .color(.white), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                // a line from the source's edge to the spot's, pointing the way the patch travels
                let dx = center.x - source.x, dy = center.y - source.y, length = hypot(dx, dy)
                if length > radius * 2 {
                    var line = Path()
                    line.move(to: CGPoint(x: source.x + dx / length * radius, y: source.y + dy / length * radius))
                    line.addLine(to: CGPoint(x: center.x - dx / length * radius, y: center.y - dy / length * radius))
                    context.stroke(line, with: .color(.white.opacity(0.8)), lineWidth: 1)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
