// ============================================================
//  Mask editor — draw gradients, reshape them, paint brush masks
// ============================================================
import SwiftUI
import AppKit

/// The finished photo with the masks drawn over it. With a gradient armed, a drag draws it
/// (a click places one of default size); with the brush armed or a brush mask selected, a drag
/// paints (⌥ erases); with Select Object armed, a drag boxes an object (a click picks one), and
/// with an object mask selected, clicks add parts it missed (⌥ takes extra parts out) and a drag
/// boxes it again;
/// otherwise the selected mask's handles reshape it. A click on another mask's pin selects
/// that mask. Edits preview live and save on release.
struct MaskEditor: View {
    @Environment(AppState.self) private var app
    let asset: Asset
    /// The finished render, as the photo is shown outside the tool.
    let image: CGImage?
    let settings: DevelopSettings
    /// The settings the photo on screen was rendered with: its crop and turns place the handles
    /// until a render of the current settings lands.
    var frameSettings: DevelopSettings?
    /// The decoded photo's size before quarter turns — the space masks are stored in.
    let sourceSize: CGSize

    @State private var drag: MaskDrag?
    @State private var hover: CGPoint?
    /// The box being drawn around an object, on screen.
    @State private var objectBox: CGRect?

    private static let handleRadius: CGFloat = 9

    var body: some View {
        GeometryReader { proxy in
            if let image {
                let display = CropEditor.fitted(CGSize(width: image.width, height: image.height), in: proxy.size)
                let mapper = MaskMapper(display: display, settings: frameSettings ?? settings, sourceSize: sourceSize)
                ZStack(alignment: .topLeading) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: display.width, height: display.height)
                        .offset(x: display.minX, y: display.minY)
                    MaskOverlay(masks: settings.masks, selectedId: app.developSelectedMaskId, mapper: mapper,
                                objectBox: objectBox)
                    if let hover, isPainting { brushCursor(at: hover, mapper) }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .clipped()
                .contentShape(Rectangle())
                .gesture(gesture(mapper))
                .onDisappear { discardDraft() }   // the tool closed mid-drag
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
        .overlay(alignment: .bottom) { hint }
    }

    private var hint: some View {
        let text: String = switch app.developMaskCreation {
        case .linear: L("拖动绘制线性渐变：起点处效果最强，终点处消失 · 点按放置 · Esc 取消")
        case .radial: L("从中心向外拖动绘制径向渐变 · 点按放置 · Esc 取消")
        case .brush: L("在照片上涂抹 · 按住 ⌥ 擦除 · [ ] 调整大小 · Esc 取消")
        case .object: L("拖动框选一个物体，或点按它 · Esc 取消")
        case nil, .subject, .sky, .person, .colorRange, .luminanceRange, .landscape: app.developPickingRangeColor
            ? L("点按照片选取颜色，最多 5 处 · Esc 完成取样")
            : selectedIndex.map { settings.masks[$0].kind == .object } == true && !isPainting
            ? L("点按补上漏选的部分 · 按住 ⌥ 点按去掉多选的部分 · 拖动重新框选 · Delete 删除 · Esc 完成")
            : selectedIndex.map { settings.masks[$0].kind == .brush } == true
            ? L("涂抹添加 · 按住 ⌥ 擦除 · [ ] 调整大小 · 点按圆点选择其他蒙版 · Esc 完成")
            : isPainting
            ? L("涂抹扩大蒙版 · 按住 ⌥ 从蒙版中擦除 · [ ] 调整大小 · Esc 完成")
            : L("拖动控制点调整蒙版 · 点按圆点选择蒙版 · Delete 删除 · Esc 完成")
        }
        return Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.canvasText2)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(.black.opacity(0.45), in: Capsule())
            .padding(.bottom, 10)
            .allowsHitTesting(false)
    }

    private var selectedIndex: Int? {
        settings.masks.firstIndex { $0.id == app.developSelectedMaskId }
    }

    /// Whether a drag paints: the brush is armed, or a brush mask is selected and nothing else is.
    private var isPainting: Bool {
        switch app.developMaskCreation {
        case .brush: true
        case .linear, .radial, .subject, .sky, .person, .colorRange, .luminanceRange, .object, .landscape: false
        case nil: !app.developPickingRangeColor
            && selectedIndex.map { settings.masks[$0].kind == .brush || app.developRefiningMask } == true
        }
    }

    /// The brush's outline where it would paint, and its hard core when feathered.
    private func brushCursor(at point: CGPoint, _ mapper: MaskMapper) -> some View {
        let radius = mapper.screenLength(ofSourceLength: app.developBrush.radius)
        let core = radius * (1 - app.developBrush.feather / 100)
        let erasing = app.developBrush.erase != NSEvent.modifierFlags.contains(.option)
        return ZStack {
            Circle().strokeBorder(.white.opacity(0.9), style: StrokeStyle(lineWidth: 1.2, dash: erasing ? [4, 3] : []))
                .frame(width: radius * 2, height: radius * 2)
            if core > 2 {
                Circle().strokeBorder(.white.opacity(0.45), lineWidth: 1).frame(width: core * 2, height: core * 2)
            }
            Image(systemName: erasing ? "minus" : "plus")
                .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
        }
        .shadow(color: .black.opacity(0.6), radius: 1)
        .position(point)
        .allowsHitTesting(false)
    }

    // ---- hit testing ----
    private func target(at point: CGPoint, _ mapper: MaskMapper) -> MaskDrag.Target? {
        if let kind = app.developMaskCreation { return .create(kind) }
        if app.developPickingRangeColor, let index = selectedIndex { return .sample(settings.masks[index].id) }
        if let index = selectedIndex, settings.masks[index].kind == .brush || app.developRefiningMask {
            // another mask's pin still selects it; anywhere else paints
            for mask in settings.masks.reversed() where mask.id != settings.masks[index].id
                && distance(mapper.pin(of: mask), point) <= Self.handleRadius {
                return .select(mask.id)
            }
            return .paint(settings.masks[index].id)
        }
        if let index = selectedIndex {
            let mask = settings.masks[index]
            // the handles of the selected mask win over every pin
            let handles = mapper.handles(of: mask)
            if let nearest = handles.min(by: { distance($0.point, point) < distance($1.point, point) }),
               distance(nearest.point, point) <= Self.handleRadius {
                return .handle(mask.id, nearest.handle)
            }
        }
        for mask in settings.masks.reversed() where distance(mapper.pin(of: mask), point) <= Self.handleRadius {
            return .select(mask.id)
        }
        // anywhere else on a selected object: a click adds to it, a drag boxes it again
        if let index = selectedIndex, settings.masks[index].kind == .object { return .prompt(settings.masks[index].id) }
        return nil
    }

    private func cursor(at point: CGPoint, _ mapper: MaskMapper) -> NSCursor {
        switch target(at: point, mapper) {
        case .create(.brush), .paint: .crosshair
        case .create, .sample, .prompt: .crosshair
        case .handle(_, .move), .select: .openHand
        case .handle: .pointingHand
        case nil: .arrow
        }
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    // ---- editing ----
    private func gesture(_ mapper: MaskMapper) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                hover = value.location   // hover events stop while the button is down
                if drag == nil {
                    guard let target = target(at: value.startLocation, mapper) else { return }
                    // the saved edit, not this view's copy, which can trail a commit made just before
                    let saved = app.developSettings[asset.id] ?? .neutral
                    let start = saved.masks.first { $0.id == app.developSelectedMaskId }
                    drag = MaskDrag(target: target, startMask: start, newId: UUID().uuidString)
                    beginStroke(at: value.startLocation, mapper)
                }
                if drag?.painted != nil {
                    continueStroke(to: value.location, mapper)
                    return
                }
                guard let drag, hypot(value.translation.width, value.translation.height) >= 2 else { return }
                switch drag.target {
                case .create(.object), .prompt:
                    // the object is found once the box is let go
                    objectBox = CGRect(x: min(value.startLocation.x, value.location.x), y: min(value.startLocation.y, value.location.y),
                                       width: abs(value.location.x - value.startLocation.x),
                                       height: abs(value.location.y - value.startLocation.y))
                        .intersection(mapper.display)
                case .create(let kind):
                    let mask = drawn(kind, id: drag.newId, from: value.startLocation, to: value.location, mapper)
                    preview(mask, adding: true)
                case .handle(let id, let handle):
                    guard let start = drag.startMask, start.id == id else { return }
                    preview(reshaped(start, handle: handle, translation: value.translation, to: value.location, mapper),
                            adding: false)
                case .select, .paint, .sample:
                    break
                }
            }
            .onEnded { value in
                let box = objectBox
                defer { drag = nil; objectBox = nil }
                guard let drag else { return }
                let moved = hypot(value.translation.width, value.translation.height) >= 2
                // Esc (or leaving the tool) while drawing takes the drawing back
                if case .create(let kind) = drag.target, app.developMaskCreation != kind {
                    discardDraft()
                    return
                }
                if let painted = drag.painted {
                    // a click paints a single dab
                    if case .create = drag.target {
                        app.addMask(painted, to: asset.id)
                    } else if let draft = app.developDraft, draft.assetId == asset.id {
                        let erased = painted.strokes.last?.erase == true
                        app.commitDevelop([asset.id: draft.settings], undoName: erased ? L("擦除蒙版") : L("画笔描边"))
                    }
                    return
                }
                switch drag.target {
                case .create(.object):
                    if moved, let box, let prompt = boxPrompt(box, mapper) {
                        app.selectObject(prompt)
                    } else if !moved, mapper.display.contains(value.startLocation) {
                        app.selectObject(ObjectPrompt(points: [.init(point: mapper.source(value.startLocation))]))
                    }
                case .prompt(let id):
                    if moved, let box, let prompt = boxPrompt(box, mapper) {
                        app.selectObject(prompt, maskId: id)
                    } else if !moved, mapper.display.contains(value.startLocation) {
                        app.addObjectPoint(mapper.source(value.startLocation), include: !NSEvent.modifierFlags.contains(.option),
                                           maskId: id)
                    }
                case .create(let kind):
                    // a click places a gradient of default size at the point
                    let mask = moved
                        ? app.developDraft?.settings.masks.first { $0.id == drag.newId }
                        : placed(kind, id: drag.newId, at: value.startLocation, mapper)
                    if let mask { app.addMask(mask, to: asset.id) }
                case .handle:
                    // dragged back to where it started: nothing to save, and no preview left behind
                    guard moved, let draft = app.developDraft, draft.assetId == asset.id else { discardDraft(); return }
                    app.commitDevelop([asset.id: draft.settings], undoName: L("编辑蒙版"))
                case .select(let id):
                    app.developSelectedMaskId = id
                case .sample(let id):
                    guard mapper.display.contains(value.location) else { return }
                    app.addRangeSample(mapper.source(value.location), maskId: id, assetId: asset.id)
                case .paint:
                    break
                }
            }
    }

    /// A box drawn on screen as a prompt: the source region it covers (whatever the photo's
    /// turns), nil when it's too small to mean anything.
    private func boxPrompt(_ box: CGRect, _ mapper: MaskMapper) -> ObjectPrompt? {
        guard box.width >= 4, box.height >= 4 else { return nil }
        let corners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                       CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY)].map(mapper.source)
        let xs = corners.map { min(1, max(0, $0.x)) }, ys = corners.map { min(1, max(0, $0.y)) }
        return ObjectPrompt(box: CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!))
    }

    /// Drops this photo's unsaved preview, left by a drag that ends without saving.
    private func discardDraft() {
        if app.developDraft?.assetId == asset.id { app.developDraft = nil }
    }

    /// Starts a stroke when the drag paints: on a new brush mask, or on the selected one.
    private func beginStroke(at point: CGPoint, _ mapper: MaskMapper) {
        guard let drag else { return }
        var mask: LocalAdjustment
        switch drag.target {
        case .create(.brush):
            mask = LocalAdjustment(kind: .brush)
            mask.id = drag.newId
            mask.exposure = 0.5   // a visible start, as with the gradients
        case .paint(let id):
            guard let start = drag.startMask, start.id == id else { return }
            mask = start
        default:
            return
        }
        let brush = app.developBrush
        var stroke = BrushStroke()
        stroke.radius = brush.radius
        stroke.feather = brush.feather
        stroke.density = brush.density
        // a new brush mask starts by painting: an erase stroke would leave it empty
        let creating: Bool = if case .create = drag.target { true } else { false }
        stroke.erase = !creating && brush.erase != NSEvent.modifierFlags.contains(.option)
        stroke.append(mapper.source(point))
        mask.strokes.append(stroke)
        self.drag?.painted = mask
        self.drag?.lastPaint = point
        preview(mask, adding: true)
    }

    /// Extends the stroke once the pointer has moved a fraction of the brush's size, so long
    /// strokes stay light.
    private func continueStroke(to point: CGPoint, _ mapper: MaskMapper) {
        guard var mask = drag?.painted, let last = drag?.lastPaint, !mask.strokes.isEmpty else { return }
        let spacing = max(2, mapper.screenLength(ofSourceLength: mask.strokes[mask.strokes.count - 1].radius) * 0.25)
        guard distance(point, last) >= spacing else { return }
        mask.strokes[mask.strokes.count - 1].append(mapper.source(point))
        drag?.painted = mask
        drag?.lastPaint = point
        preview(mask, adding: true)
    }

    /// Shows `mask` live: replaces the mask with its id, or appends it while it's being drawn.
    private func preview(_ mask: LocalAdjustment, adding: Bool) {
        var next = app.developSettings[asset.id] ?? .neutral
        if let index = next.masks.firstIndex(where: { $0.id == mask.id }) {
            next.masks[index] = mask
        } else if adding {
            next.masks.append(mask)
        }
        app.updateDevelopDraft(next, for: asset.id)
    }

    /// A new gradient drawn from `start` to `end` on screen. It starts with a visible effect
    /// (Lightroom's gradients start empty, which leaves nothing to see while drawing).
    private func drawn(_ kind: LocalAdjustment.Kind, id: String, from start: CGPoint, to end: CGPoint,
                       _ mapper: MaskMapper) -> LocalAdjustment {
        var mask = LocalAdjustment(kind: kind)
        mask.id = id
        mask.exposure = kind == .linear ? -0.5 : 0.5
        switch kind {
        case .linear:
            mask.start = mapper.source(start)
            mask.end = mapper.source(end)
        case .radial:
            mask.center = mapper.source(start)
            let radius = mapper.sourceLength(from: start, to: end)
            mask.radiusX = max(0.01, radius)
            mask.radiusY = max(0.01, radius)
            mask.angle = mapper.sourceAngle(ofScreenDirection: CGVector(dx: 1, dy: 0), at: start)
        case .brush, .subject, .sky, .person, .colorRange, .luminanceRange, .object, .landscape:
            break   // painted stroke by stroke, or found in the photo
        }
        return mask
    }

    /// A gradient of default size centered at a clicked point: a linear one spanning a third
    /// of the photo's height, darkening toward the top; a radial one a sixth of its long side.
    private func placed(_ kind: LocalAdjustment.Kind, id: String, at point: CGPoint,
                        _ mapper: MaskMapper) -> LocalAdjustment {
        let display = mapper.display
        switch kind {
        case .linear:
            let half = display.height / 6
            return drawn(kind, id: id, from: CGPoint(x: point.x, y: point.y - half),
                         to: CGPoint(x: point.x, y: point.y + half), mapper)
        case .radial:
            var mask = drawn(kind, id: id, from: point,
                             to: CGPoint(x: point.x + max(display.width, display.height) / 6, y: point.y), mapper)
            mask.radiusY = mask.radiusX * 0.75
            return mask
        case .brush, .subject, .sky, .person, .colorRange, .luminanceRange, .object, .landscape:
            return drawn(kind, id: id, from: point, to: point, mapper)
        }
    }

    private func reshaped(_ start: LocalAdjustment, handle: MaskHandle, translation: CGSize, to location: CGPoint,
                          _ mapper: MaskMapper) -> LocalAdjustment {
        var mask = start
        func shifted(_ source: CGPoint) -> CGPoint {
            let screen = mapper.screen(source)
            return mapper.source(CGPoint(x: screen.x + translation.width, y: screen.y + translation.height))
        }
        switch handle {
        case .move:
            mask.start = shifted(start.start)
            mask.end = shifted(start.end)
            mask.center = shifted(start.center)
        case .start:
            mask.start = mapper.source(location)
        case .end:
            mask.end = mapper.source(location)
        case .axisX(let sign):
            // the x handles set the ellipse's first axis: its length and its direction
            let center = mapper.screen(start.center)
            mask.radiusX = max(0.01, mapper.sourceLength(from: center, to: location))
            let direction = CGVector(dx: (location.x - center.x) * sign, dy: (location.y - center.y) * sign)
            mask.angle = mapper.sourceAngle(ofScreenDirection: direction, at: center)
        case .axisY:
            // the y handles set the second axis's length, measured across the first
            let center = mapper.screen(start.center)
            let axis = mapper.sourceVector(from: center, to: location)
            let a = start.angle * .pi / 180
            let across = abs(-axis.dx * sin(a) + axis.dy * cos(a))
            mask.radiusY = max(0.01, across)
        }
        return mask
    }
}

enum MaskHandle: Equatable {
    case move, start, end
    case axisX(CGFloat)   // +1 or -1: which end of the axis
    case axisY(CGFloat)
}

struct MaskDrag {
    enum Target: Equatable {
        case create(LocalAdjustment.Kind)
        case handle(String, MaskHandle)
        case select(String)
        case paint(String)
        /// A click adding a color to the mask's range.
        case sample(String)
        /// A click adding to (or leaving out of) an object mask, or a drag boxing it again.
        case prompt(String)
    }

    let target: Target
    /// The selected mask as the drag began.
    let startMask: LocalAdjustment?
    /// The id a drawn gradient or new brush mask gets.
    let newId: String
    /// The brush mask with the stroke being painted, and where its last point was added.
    var painted: LocalAdjustment?
    var lastPaint: CGPoint?
}

/// Converts between the screen, the finished photo it shows, and the source photo masks
/// are stored in.
struct MaskMapper {
    let display: CGRect
    let settings: DevelopSettings
    let sourceSize: CGSize

    private var longEdge: Double { Double(max(sourceSize.width, sourceSize.height, 1)) }

    func source(_ screen: CGPoint) -> CGPoint {
        let finished = CGPoint(x: (screen.x - display.minX) / max(display.width, 1),
                               y: (screen.y - display.minY) / max(display.height, 1))
        return DevelopGeometry.sourcePoint(fromFinished: finished, settings: settings, sourceSize: sourceSize)
    }

    func screen(_ source: CGPoint) -> CGPoint {
        let finished = DevelopGeometry.finishedPoint(fromSource: source, settings: settings, sourceSize: sourceSize)
        return CGPoint(x: display.minX + finished.x * display.width, y: display.minY + finished.y * display.height)
    }

    /// The source-pixel vector between two screen points, in fractions of the long edge.
    func sourceVector(from a: CGPoint, to b: CGPoint) -> CGVector {
        let p = source(a), q = source(b)
        return CGVector(dx: (q.x - p.x) * sourceSize.width / longEdge, dy: (q.y - p.y) * sourceSize.height / longEdge)
    }

    func sourceLength(from a: CGPoint, to b: CGPoint) -> Double {
        let v = sourceVector(from: a, to: b)
        return Double(hypot(v.dx, v.dy))
    }

    /// How long a source length (fraction of the long edge) is on screen.
    func screenLength(ofSourceLength length: Double) -> CGFloat {
        let center = CGPoint(x: display.midX, y: display.midY)
        let perHundred = sourceLength(from: center, to: CGPoint(x: center.x + 100, y: center.y))
        return CGFloat(length / max(perHundred, 1e-9) * 100)
    }

    /// The clockwise angle, in degrees, that a screen direction has on the source photo.
    func sourceAngle(ofScreenDirection direction: CGVector, at point: CGPoint) -> Double {
        let length = max(hypot(direction.dx, direction.dy), 1e-6)
        let tip = CGPoint(x: point.x + direction.dx / length * 40, y: point.y + direction.dy / length * 40)
        let v = sourceVector(from: point, to: tip)
        return Double(atan2(v.dy, v.dx)) * 180 / .pi
    }

    /// A source point `length` (fraction of the long edge) from `center` at `angle` degrees.
    func sourcePoint(from center: CGPoint, angle: Double, length: Double) -> CGPoint {
        let a = angle * .pi / 180
        return CGPoint(x: center.x + cos(a) * length * longEdge / Double(max(sourceSize.width, 1)),
                       y: center.y + sin(a) * length * longEdge / Double(max(sourceSize.height, 1)))
    }

    /// Where a mask's pin sits on screen: a radial gradient's center, a linear one's middle,
    /// a brush mask's first dab.
    func pin(of mask: LocalAdjustment) -> CGPoint {
        switch mask.kind {
        case .linear:
            let a = screen(mask.start), b = screen(mask.end)
            return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        case .radial:
            return screen(mask.center)
        case .brush:
            return screen(mask.strokes.first { $0.pointCount > 0 }?.point(0) ?? mask.center)
        case .subject, .sky, .person, .luminanceRange, .object, .landscape:
            return screen(mask.center)
        case .colorRange:
            return screen(mask.range?.samples.first ?? mask.center)
        }
    }

    func handles(of mask: LocalAdjustment) -> [(handle: MaskHandle, point: CGPoint)] {
        switch mask.kind {
        case .linear:
            return [(.move, pin(of: mask)), (.start, screen(mask.start)), (.end, screen(mask.end))]
        case .radial:
            return [
                (.move, screen(mask.center)),
                (.axisX(1), screen(sourcePoint(from: mask.center, angle: mask.angle, length: mask.radiusX))),
                (.axisX(-1), screen(sourcePoint(from: mask.center, angle: mask.angle + 180, length: mask.radiusX))),
                (.axisY(1), screen(sourcePoint(from: mask.center, angle: mask.angle + 90, length: mask.radiusY))),
                (.axisY(-1), screen(sourcePoint(from: mask.center, angle: mask.angle - 90, length: mask.radiusY))),
            ]
        case .brush, .subject, .sky, .person, .colorRange, .luminanceRange, .object, .landscape:
            return []   // painted or found, not reshaped
        }
    }
}

/// Every mask's pin, and the selected mask's outline and handles.
private struct MaskOverlay: View {
    let masks: [LocalAdjustment]
    let selectedId: String?
    let mapper: MaskMapper
    /// A box being drawn around an object.
    var objectBox: CGRect?

    var body: some View {
        Canvas { context, _ in
            if let objectBox {
                let box = Path(objectBox)
                context.stroke(box, with: .color(.black.opacity(0.5)), lineWidth: 3)
                context.stroke(box, with: .color(.white), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
            }
            for mask in masks where mask.id != selectedId {
                let pin = mapper.pin(of: mask)
                let dot = Path(ellipseIn: CGRect(x: pin.x - 5, y: pin.y - 5, width: 10, height: 10))
                context.fill(dot, with: .color(.black.opacity(0.35)))
                context.stroke(dot, with: .color(.white), lineWidth: 1.5)
            }
            guard let mask = masks.first(where: { $0.id == selectedId }) else { return }
            // outlines stop at the photo's edge; handles stay whole so they can still be grabbed
            context.drawLayer { context in
                context.clip(to: Path(mapper.display))
                outline(of: mask, in: &context)
            }
            for (handle, point) in mapper.handles(of: mask) {
                let size: CGFloat = handle == .move ? 12 : 8
                let dot = Path(ellipseIn: CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size))
                context.fill(dot, with: handle == .move ? .color(Theme.accentFill) : .color(.white))
                context.stroke(dot, with: .color(.black.opacity(0.5)), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }

    private func outline(of mask: LocalAdjustment, in context: inout GraphicsContext) {
        let line = GraphicsContext.Shading.color(.white.opacity(0.9))
        switch mask.kind {
        case .linear:
            let a = mapper.screen(mask.start), b = mapper.screen(mask.end)
            let length = max(hypot(b.x - a.x, b.y - a.y), 1e-6)
            // lines across the photo, perpendicular to the gradient, at its start, middle and end
            let across = CGVector(dx: -(b.y - a.y) / length, dy: (b.x - a.x) / length)
            let reach = hypot(mapper.display.width, mapper.display.height)
            for (t, dashed) in [(0.0, false), (0.5, true), (1.0, false)] {
                let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                var path = Path()
                path.move(to: CGPoint(x: p.x - across.dx * reach, y: p.y - across.dy * reach))
                path.addLine(to: CGPoint(x: p.x + across.dx * reach, y: p.y + across.dy * reach))
                context.stroke(path, with: line, style: StrokeStyle(lineWidth: 1, dash: dashed ? [5, 4] : []))
            }
        case .radial:
            let center = mapper.screen(mask.center)
            let x = mapper.screen(mapper.sourcePoint(from: mask.center, angle: mask.angle, length: mask.radiusX))
            let y = mapper.screen(mapper.sourcePoint(from: mask.center, angle: mask.angle + 90, length: mask.radiusY))
            let rx = hypot(x.x - center.x, x.y - center.y), ry = hypot(y.x - center.x, y.y - center.y)
            let turn = CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: atan2(x.y - center.y, x.x - center.x))
            let outline = Path(ellipseIn: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2)).applying(turn)
            context.stroke(outline, with: line, lineWidth: 1.2)
            let inner = 1 - mask.feather / 100
            if inner > 0.02 {
                let feather = Path(ellipseIn: CGRect(x: -rx * inner, y: -ry * inner,
                                                     width: rx * inner * 2, height: ry * inner * 2)).applying(turn)
                context.stroke(feather, with: .color(.white.opacity(0.55)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
        case .brush, .subject, .sky, .person, .colorRange, .luminanceRange, .object, .landscape:
            // no outline to drag: its pin, filled to show it's the selected one
            let pin = mapper.pin(of: mask)
            let dot = Path(ellipseIn: CGRect(x: pin.x - 6, y: pin.y - 6, width: 12, height: 12))
            context.fill(dot, with: .color(Theme.accentFill))
            context.stroke(dot, with: .color(.white), lineWidth: 1.5)
        }
        // an object's box and the places clicked in (green) or out (red) of it
        if mask.kind == .object {
            if let box = mask.prompt.box {
                let corners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                               CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)].map(mapper.screen)
                var outline = Path()
                outline.addLines(corners)
                outline.closeSubpath()
                context.stroke(outline, with: .color(.white.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }
            for place in mask.prompt.points {
                let p = mapper.screen(place.point)
                let dot = Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
                context.fill(dot, with: .color(place.include ? Color.green : Color.red))
                context.stroke(dot, with: .color(.white), lineWidth: 1.2)
            }
        }
        // where its colors were sampled
        for sample in mask.range?.samples ?? [] {
            let p = mapper.screen(sample)
            let ring = Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
            context.stroke(ring, with: .color(.black.opacity(0.6)), lineWidth: 3)
            context.stroke(ring, with: .color(.white), lineWidth: 1.5)
        }
    }
}
