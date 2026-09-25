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
        let dragging = app.developDraft?.assetId == asset.id
        let fullResolution = app.loupeZoom != nil && !dragging && !cropping
        // the crop tool draws the crop itself, so moving it never re-renders
        var rendered = settings
        if cropping { rendered.crop = nil }
        return Group {
            if let source {
                Group {
                    if cropping {
                        CropEditor(asset: asset, image: engine.wholeFrameImage(for: asset.id), settings: settings)
                    } else {
                        ZoomableImageView(image: engine.image(for: asset.id), pixelSize: pixelSize,
                                          zoom: app.loupeZoom) { app.loupeZoom = $0 }
                            .padding(app.loupeZoom == nil ? 12 : 0)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if app.developShowsOriginal { badge("修改前（按 \\ 切换）") }
                }
                .overlay(alignment: .topTrailing) {
                    if engine.isRendering(asset.id) { ProgressView().controlSize(.small).padding(14) }
                }
                .onChange(of: DevelopRenderKey(assetId: asset.id, settings: rendered, draft: dragging,
                                               fullResolution: fullResolution, wholeFrame: cropping),
                          initial: true) {
                    engine.render(assetId: asset.id, url: source.url, isRaw: source.isRaw, settings: rendered,
                                  draft: dragging, fullResolution: fullResolution,
                                  wholeFrame: cropping) { result, histogram in
                        if let temperature = result.asShotTemperature, let tint = result.asShotTint {
                            app.recordAsShotWhiteBalance(asset.id, temperature: temperature, tint: tint)
                        }
                        if let size = result.sourceSize { app.recordDevelopSourceSize(size, for: asset.id) }
                        if let histogram { app.recordDevelopHistogram(histogram, for: asset.id) }
                    }
                }
            } else {
                ContentUnavailableView("原件不可用",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text("演示照片或缺失的原件无法修图。"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

private struct DevelopRenderKey: Equatable {
    let assetId: String
    let settings: DevelopSettings
    let draft: Bool
    let fullResolution: Bool
    let wholeFrame: Bool
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
    }

    @Published private var shown: Shown?
    @Published private var renderingAssetId: String?
    private let previewWorker = DevelopRenderWorker()
    private let fullWorker = DevelopRenderWorker()
    private var token = 0
    private var histogramToken = 0

    func shown(for assetId: String) -> Shown? { shown?.assetId == assetId ? shown : nil }

    func image(for assetId: String) -> CGImage? { shown(for: assetId)?.image }

    /// Only an uncropped render: the crop tool lays its rectangle over the whole frame.
    func wholeFrameImage(for assetId: String) -> CGImage? {
        shown(for: assetId).flatMap { $0.wholeFrame ? $0.image : nil }
    }

    func isRendering(_ assetId: String) -> Bool { renderingAssetId == assetId }

    func render(assetId: String, url: URL, isRaw: Bool, settings: DevelopSettings, draft: Bool,
                fullResolution: Bool, wholeFrame: Bool,
                finished: @escaping (DevelopRenderWorker.Result, _ newestHistogram: DevelopHistogram?) -> Void) {
        token += 1
        var request = DevelopRenderWorker.Request(url: url, isRaw: isRaw,
                                                  maxPixel: fullResolution ? nil : Self.previewMaxPixel,
                                                  settings: settings, draft: draft, token: token)
        request.wholeFrame = wholeFrame
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
                                   wholeFrame: result.request.wholeFrame)
            }
        }
    }
}
