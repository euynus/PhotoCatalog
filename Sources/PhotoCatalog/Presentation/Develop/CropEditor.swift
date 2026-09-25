// ============================================================
//  Crop & straighten tool — Lightroom's crop overlay
// ============================================================
import SwiftUI
import AppKit

/// The whole straightened frame with the crop drawn over it. Drag inside to move the crop,
/// its corners and edges to resize, and outside it to draw a line that should be level.
struct CropEditor: View {
    @Environment(AppState.self) private var app
    let asset: Asset
    /// The uncropped render (`wholeFrame`); its size is the frame crops are measured in.
    let image: CGImage?
    let settings: DevelopSettings

    @State private var drag: CropDrag?
    @State private var levelLine: (start: CGPoint, end: CGPoint)?

    var body: some View {
        GeometryReader { proxy in
            if let image {
                let frame = CGSize(width: image.width, height: image.height)
                let display = Self.fitted(frame, in: proxy.size)
                let crop = DevelopGeometry.effectiveCrop(settings, frame: frame)
                let cropRect = Self.rect(crop, in: display)
                ZStack(alignment: .topLeading) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: display.width, height: display.height)
                        .offset(x: display.minX, y: display.minY)
                    CropOverlay(display: display, crop: cropRect, active: drag != nil)
                    if let levelLine {
                        Path { path in
                            path.move(to: levelLine.start)
                            path.addLine(to: levelLine.end)
                        }
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 3]))
                    }
                    if drag != nil { sizeLabel(crop, frame: frame, below: cropRect) }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .contentShape(Rectangle())
                .gesture(gesture(display: display, frame: frame, crop: crop))
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location): Self.cursor(for: Self.kind(at: location, cropRect: cropRect)).set()
                    case .ended: NSCursor.arrow.set()
                    }
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 44)
        .overlay(alignment: .bottom) { hint }
    }

    private var hint: some View {
        Text("拖动角或边调整 · 在框外拖出一条线来拉直 · Return 完成")
            .font(.system(size: 11))
            .foregroundStyle(Theme.canvasText2)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(.black.opacity(0.45), in: Capsule())
            .padding(.bottom, 10)
            .allowsHitTesting(false)
    }

    /// Finished size in original pixels, shown while dragging.
    private func sizeLabel(_ crop: DevelopCrop, frame: CGSize, below cropRect: CGRect) -> some View {
        let longEdge = CGFloat(max(asset.width, asset.height))
        let scale = longEdge > 0 ? longEdge / max(frame.width, frame.height) : 1
        let width = Int((crop.width * frame.width * scale).rounded())
        let height = Int((crop.height * frame.height * scale).rounded())
        return Text("\(width) × \(height)")
            .font(.system(size: 11, weight: .medium)).monospacedDigit()
            .foregroundStyle(Theme.canvasText)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
            .offset(x: cropRect.minX + 6, y: cropRect.minY + 6)
            .allowsHitTesting(false)
    }

    // ---- interaction ----
    private func gesture(display: CGRect, frame: CGSize, crop: DevelopCrop) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .local)
            .onChanged { value in
                if drag == nil {
                    drag = CropDrag(kind: Self.kind(at: value.startLocation, cropRect: Self.rect(crop, in: display)),
                                    start: crop)
                }
                guard let drag else { return }
                let dx = Double(value.translation.width / max(display.width, 1))
                let dy = Double(value.translation.height / max(display.height, 1))
                let next: DevelopCrop
                switch drag.kind {
                case .level:
                    levelLine = (value.startLocation, value.location)
                    return
                case .move:
                    next = DevelopGeometry.move(drag.start, dx: dx, dy: dy, angle: settings.straighten, frame: frame)
                case .resize(let edges):
                    next = DevelopGeometry.resize(drag.start, left: edges.left, right: edges.right,
                                                  top: edges.top, bottom: edges.bottom, dx: dx, dy: dy,
                                                  ratio: lockedRatio(for: drag.start, frame: frame),
                                                  angle: settings.straighten, frame: frame)
                }
                var edit = app.developSettings[asset.id] ?? .neutral
                edit.crop = next
                app.updateDevelopDraft(edit, for: asset.id)
            }
            .onEnded { value in
                defer {
                    drag = nil
                    levelLine = nil
                }
                guard let drag else { return }
                if case .level = drag.kind {
                    straighten(along: value.startLocation, value.location, frame: frame)
                } else if let draft = app.developDraft, draft.assetId == asset.id {
                    app.commitDevelop([asset.id: draft.settings], undoName: "裁剪")
                }
            }
    }

    /// Pixel width / height the crop keeps, oriented like the crop it starts from.
    private func lockedRatio(for crop: DevelopCrop, frame: CGSize) -> Double? {
        guard let ratio = app.developCropAspect.ratio(frame: frame) else { return nil }
        let landscape = crop.width * frame.width >= crop.height * frame.height
        return landscape ? ratio : 1 / ratio
    }

    private func straighten(along start: CGPoint, _ end: CGPoint, frame: CGSize) {
        var edit = app.developSettings[asset.id] ?? .neutral
        guard let angle = DevelopGeometry.straightenLevelling(from: start, to: end, current: edit.straighten)
        else { return }
        edit.straighten = angle
        edit.crop = edit.crop.map { DevelopGeometry.fit($0, angle: angle, frame: frame) }
        app.commitDevelop([asset.id: edit], undoName: "拉直")
    }

    // ---- layout and hit testing ----
    static func fitted(_ size: CGSize, in bounds: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let width = size.width * scale, height = size.height * scale
        return CGRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
    }

    static func rect(_ crop: DevelopCrop, in display: CGRect) -> CGRect {
        CGRect(x: display.minX + crop.x * display.width, y: display.minY + crop.y * display.height,
               width: crop.width * display.width, height: crop.height * display.height)
    }

    static func kind(at point: CGPoint, cropRect r: CGRect) -> CropDrag.Kind {
        let tolerance: CGFloat = 12
        let withinX = point.x >= r.minX - tolerance && point.x <= r.maxX + tolerance
        let withinY = point.y >= r.minY - tolerance && point.y <= r.maxY + tolerance
        guard withinX && withinY else { return .level }
        let nearLeft = abs(point.x - r.minX) <= tolerance
        let nearRight = !nearLeft && abs(point.x - r.maxX) <= tolerance
        let nearTop = abs(point.y - r.minY) <= tolerance
        let nearBottom = !nearTop && abs(point.y - r.maxY) <= tolerance
        if nearLeft || nearRight || nearTop || nearBottom {
            return .resize(CropDrag.Edges(left: nearLeft, right: nearRight, top: nearTop, bottom: nearBottom))
        }
        return r.contains(point) ? .move : .level
    }

    static func cursor(for kind: CropDrag.Kind) -> NSCursor {
        switch kind {
        case .move: return .openHand
        case .level: return .crosshair
        case .resize(let edges):
            let horizontal = edges.left || edges.right, vertical = edges.top || edges.bottom
            if horizontal && vertical { return .crosshair }
            return horizontal ? .resizeLeftRight : .resizeUpDown
        }
    }
}

struct CropDrag {
    struct Edges: Equatable {
        let left: Bool
        let right: Bool
        let top: Bool
        let bottom: Bool
    }

    enum Kind: Equatable {
        case move
        case resize(Edges)
        /// A line drawn outside the crop to level the photo.
        case level
    }

    let kind: Kind
    let start: DevelopCrop
}

/// Shade outside the crop, a rule-of-thirds grid, and corner / edge handles.
private struct CropOverlay: View {
    let display: CGRect
    let crop: CGRect
    let active: Bool

    var body: some View {
        Canvas { context, _ in
            var shade = Path()
            shade.addRect(display)
            shade.addRect(crop)
            context.fill(shade, with: .color(.black.opacity(0.6)), style: FillStyle(eoFill: true))

            var grid = Path()
            for step in 1...2 {
                let x = crop.minX + crop.width * CGFloat(step) / 3
                let y = crop.minY + crop.height * CGFloat(step) / 3
                grid.move(to: CGPoint(x: x, y: crop.minY))
                grid.addLine(to: CGPoint(x: x, y: crop.maxY))
                grid.move(to: CGPoint(x: crop.minX, y: y))
                grid.addLine(to: CGPoint(x: crop.maxX, y: y))
            }
            context.stroke(grid, with: .color(.white.opacity(active ? 0.55 : 0.28)), lineWidth: 0.5)
            context.stroke(Path(crop), with: .color(.white.opacity(0.9)), lineWidth: 1)

            var handles = Path()
            let length = min(18, crop.width / 3, crop.height / 3)
            for (x, sx) in [(crop.minX, 1.0), (crop.maxX, -1.0)] {
                for (y, sy) in [(crop.minY, 1.0), (crop.maxY, -1.0)] {
                    handles.move(to: CGPoint(x: x + length * sx, y: y))
                    handles.addLine(to: CGPoint(x: x, y: y))
                    handles.addLine(to: CGPoint(x: x, y: y + length * sy))
                }
            }
            let half = length / 2
            for y in [crop.minY, crop.maxY] {
                handles.move(to: CGPoint(x: crop.midX - half, y: y))
                handles.addLine(to: CGPoint(x: crop.midX + half, y: y))
            }
            for x in [crop.minX, crop.maxX] {
                handles.move(to: CGPoint(x: x, y: crop.midY - half))
                handles.addLine(to: CGPoint(x: x, y: crop.midY + half))
            }
            context.stroke(handles, with: .color(.white), style: StrokeStyle(lineWidth: 3, lineCap: .square))
        }
        .allowsHitTesting(false)
    }
}
