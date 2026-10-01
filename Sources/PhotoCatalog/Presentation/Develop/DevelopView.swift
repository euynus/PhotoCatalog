// ============================================================
//  Develop — live non-destructive rendering of the selected photo
// ============================================================
import SwiftUI
import AppKit

struct DevelopView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let list = app.list
        VStack(spacing: 0) {
            if let asset = app.primary, list.contains(where: { $0.id == asset.id }) {
                DevelopCanvas(asset: asset)
            } else {
                ContentUnavailableView("没有可修图的照片", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if !list.isEmpty { Filmstrip(photos: app.photoList, assetRevision: app.assetRenderVersion) }
        }
        .background(Theme.canvas)
        .environment(\.colorScheme, .dark)
    }
}

/// Renders the photo with its current (or in-progress) settings. Previews render at 2048 px;
/// zooming to 1:1 re-renders at full resolution once the slider is released.
private struct DevelopCanvas: View {
    @Environment(AppState.self) private var app
    let asset: Asset
    @StateObject private var engine = DevelopPreviewEngine()
    /// Renders the before side of a side-by-side comparison.
    @StateObject private var beforeEngine = DevelopPreviewEngine()

    private var source: (url: URL, isRaw: Bool)? {
        if asset.status == .ready, let path = asset.localPath { return (URL(fileURLWithPath: path), asset.isRaw) }
        // Offline or missing original: adjust the cached preview so the photo stays workable.
        if !asset.preview.isEmpty, !asset.preview.hasPrefix("http"),
           FileManager.default.fileExists(atPath: asset.preview) {
            return (URL(fileURLWithPath: asset.preview), false)
        }
        return nil
    }

    var body: some View {
        let settings = app.developShowsOriginal ? .neutral : app.developSettings(for: asset.id)
        let cropping = app.developCropping && !app.developShowsOriginal
        let masking = app.developMasking && !app.developShowsOriginal
        let overlay = masking && app.developShowsMaskOverlay ? app.developSelectedMaskId : nil
        let spotting = app.developSpotting && !app.developShowsOriginal
        let visualize = spotting && app.developVisualizeSpots
        let dragging = app.developDraft?.assetId == asset.id
        let fullResolution = app.loupeZoom != nil && !dragging && !cropping && !app.developMasking && !app.developSpotting
        // proofing shows the finished photo, not a tool's working view
        let proof = app.softProofing && !cropping && !masking && !spotting ? app.softProof : nil
        // the crop tool draws the crop itself, so moving it never re-renders
        var rendered = settings
        if cropping { rendered.crop = nil }
        return Group {
            if let source {
                Group {
                    if app.developComparing {
                        BeforeAfterPanes(before: beforeEngine.image(for: asset.id), after: engine.image(for: asset.id))
                    } else if cropping {
                        CropEditor(asset: asset, image: engine.wholeFrameImage(for: asset.id), settings: settings)
                    } else if spotting {
                        SpotEditor(asset: asset, image: engine.finishedImage(for: asset.id), settings: settings,
                                   frameSettings: engine.shown(for: asset.id)?.settings,
                                   sourceSize: app.developSourceSize(for: asset))
                            .id(asset.id)   // a new photo starts with no drag in progress
                    } else if masking {
                        MaskEditor(asset: asset, image: engine.finishedImage(for: asset.id), settings: settings,
                                   frameSettings: engine.shown(for: asset.id)?.settings,
                                   sourceSize: app.developSourceSize(for: asset))
                            .id(asset.id)
                    } else {
                        ZoomableImageView(image: engine.image(for: asset.id), pixelSize: pixelSize,
                                          zoom: app.loupeZoom, onZoomChange: { app.loupeZoom = $0 },
                                          onPick: app.developPickingWhiteBalance
                                              ? { app.pickWhiteBalance(asset, at: $0) } : nil)
                            .padding(app.loupeZoom == nil ? 12 : 0)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if app.developShowsOriginal {
                        badge(L("修改前（按 \\ 切换）"))
                    } else if app.developPickingWhiteBalance {
                        badge(L("点选照片中应为灰色或白色的地方（Esc 取消）"))
                    } else if let proof {
                        badge(L("校样预览 · \(SoftProofing.name(of: proof.profile))"))
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if engine.isRendering(asset.id) { ProgressView().controlSize(.small).padding(14) }
                }
                .onChange(of: DevelopRenderKey(assetId: asset.id, settings: rendered, draft: dragging,
                                               fullResolution: fullResolution, wholeFrame: cropping,
                                               overlayMask: overlay, visualizeSpots: visualize, proof: proof),
                          initial: true) {
                    engine.render(assetId: asset.id, url: source.url, isRaw: source.isRaw, settings: rendered,
                                  draft: dragging, fullResolution: fullResolution,
                                  wholeFrame: cropping, overlayMask: overlay,
                                  visualizeSpots: visualize, proof: proof) { result, histogram in
                        if let temperature = result.asShotTemperature, let tint = result.asShotTint {
                            app.recordAsShotWhiteBalance(asset.id, temperature: temperature, tint: tint)
                        }
                        if let size = result.sourceSize { app.recordDevelopSourceSize(size, for: asset.id) }
                        if let histogram { app.recordDevelopHistogram(histogram, for: asset.id) }
                    }
                }
                .onChange(of: app.developComparing ? BeforeKey(settings: Self.before(settings), proof: proof) : nil,
                          initial: true) { _, before in
                    guard let before else { return }
                    beforeEngine.render(assetId: asset.id, url: source.url, isRaw: source.isRaw, settings: before.settings,
                                        draft: false, fullResolution: false, wholeFrame: false, overlayMask: nil,
                                        visualizeSpots: false, proof: before.proof) { _, _ in }
                }
            } else {
                ContentUnavailableView("原件不可用",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text("演示照片或缺失的原件无法修图。"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The photo as shot, framed like `after`: its turns, perspective, straighten angle, crop
    /// and lens distortion, so the two sides line up and differ only in tone and color.
    private static func before(_ after: DevelopSettings) -> DevelopSettings {
        var before = DevelopSettings()
        before.rotation = after.rotation
        before.flipped = after.flipped
        before.perspectiveVertical = after.perspectiveVertical
        before.perspectiveHorizontal = after.perspectiveHorizontal
        before.straighten = after.straighten
        before.crop = after.crop
        before.distortion = after.distortion
        return before
    }

    /// The finished photo's size at 1:1. Previews render the uncropped photo at 2048 px on the
    /// long edge, so a cropped preview scales up by the same factor as the whole photo would.
    private var pixelSize: CGSize {
        guard let shown = engine.shown(for: asset.id) else {
            return CGSize(width: max(asset.width, 1), height: max(asset.height, 1))
        }
        let size = CGSize(width: shown.image.width, height: shown.image.height)
        guard !shown.fullResolution, asset.width > 0, asset.height > 0 else { return size }
        let longEdge = CGFloat(max(asset.width, asset.height))
        let factor = longEdge / min(CGFloat(DevelopPreviewEngine.previewMaxPixel), longEdge)
        return CGSize(width: size.width * factor, height: size.height * factor)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.canvasText)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(14)
    }
}

/// Before and after, side by side or one above the other — whichever shows the photo larger.
private struct BeforeAfterPanes: View {
    let before: CGImage?
    let after: CGImage?

    private static let gap: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            let layout = sideBySide(in: proxy.size)
                ? AnyLayout(HStackLayout(spacing: Self.gap)) : AnyLayout(VStackLayout(spacing: Self.gap))
            layout {
                pane(before, L("修改前"))
                pane(after, L("修改后"))
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .padding(12)
    }

    /// Whether the photo comes out larger side by side than one above the other.
    private func sideBySide(in size: CGSize) -> Bool {
        let aspect = after.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) } ?? 1.5
        func fitted(_ box: CGSize) -> CGFloat {
            let width = min(box.width, box.height * aspect)
            return width * width / aspect
        }
        return fitted(CGSize(width: (size.width - Self.gap) / 2, height: size.height))
            >= fitted(CGSize(width: size.width, height: (size.height - Self.gap) / 2))
    }

    private func pane(_ image: CGImage?, _ title: String) -> some View {
        ZStack(alignment: .topLeading) {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.canvasText)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(8)
        }
    }
}

private struct BeforeKey: Equatable {
    let settings: DevelopSettings
    let proof: SoftProof?
}

private struct DevelopRenderKey: Equatable {
    let assetId: String
    let settings: DevelopSettings
    let draft: Bool
    let fullResolution: Bool
    let wholeFrame: Bool
    let overlayMask: String?
    let visualizeSpots: Bool
    let proof: SoftProof?
}

/// Owns two render workers — preview size and full resolution — so switching zoom
/// doesn't re-decode, and shows the newest finished render for the current photo.
@MainActor
final class DevelopPreviewEngine: ObservableObject {
    static let previewMaxPixel = 2048

    struct Shown {
        let assetId: String
        let token: Int
        let image: CGImage
        let fullResolution: Bool
        let wholeFrame: Bool
        /// What the render was made with: its crop and turns place masks and spots on it.
        let settings: DevelopSettings
    }

    @Published private var shown: Shown?
    @Published private var renderingAssetId: String?
    private let previewWorker = DevelopRenderWorker()
    private let fullWorker = DevelopRenderWorker()
    private var token = 0
    private var histogramToken = 0

    func shown(for assetId: String) -> Shown? { shown?.assetId == assetId ? shown : nil }

    func image(for assetId: String) -> CGImage? { shown(for: assetId)?.image }

    /// Only a finished (cropped) render: masks are drawn over the photo as it will look.
    func finishedImage(for assetId: String) -> CGImage? {
        shown(for: assetId).flatMap { $0.wholeFrame ? nil : $0.image }
    }

    /// Only an uncropped render: the crop tool lays its rectangle over the whole frame.
    func wholeFrameImage(for assetId: String) -> CGImage? {
        shown(for: assetId).flatMap { $0.wholeFrame ? $0.image : nil }
    }

    func isRendering(_ assetId: String) -> Bool { renderingAssetId == assetId }

    func render(assetId: String, url: URL, isRaw: Bool, settings: DevelopSettings, draft: Bool,
                fullResolution: Bool, wholeFrame: Bool, overlayMask: String? = nil, visualizeSpots: Bool = false,
                proof: SoftProof? = nil,
                finished: @escaping (DevelopRenderWorker.Result, _ newestHistogram: DevelopHistogram?) -> Void) {
        token += 1
        var request = DevelopRenderWorker.Request(url: url, isRaw: isRaw,
                                                  maxPixel: fullResolution ? nil : Self.previewMaxPixel,
                                                  settings: settings, draft: draft, token: token)
        request.wholeFrame = wholeFrame
        request.overlayMask = overlayMask
        request.visualizeSpots = visualizeSpots
        request.proof = proof
        renderingAssetId = assetId
        (fullResolution ? fullWorker : previewWorker).submit(request) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if result.request.token == self.token { self.renderingAssetId = nil }
                // renders finish out of order across the two workers; keep the newest histogram
                var histogram: DevelopHistogram?
                if result.histogram != nil, result.request.token > self.histogramToken {
                    self.histogramToken = result.request.token
                    histogram = result.histogram
                }
                finished(result, histogram)
                // a coalesced older render still beats a stale photo while dragging
                guard let image = result.image,
                      self.shown?.assetId != assetId || result.request.token >= (self.shown?.token ?? 0) else { return }
                self.shown = Shown(assetId: assetId, token: result.request.token, image: image,
                                   fullResolution: result.request.maxPixel == nil,
                                   wholeFrame: result.request.wholeFrame,
                                   settings: result.request.settings)
            }
        }
    }
}
