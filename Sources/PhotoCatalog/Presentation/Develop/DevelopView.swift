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
            if !list.isEmpty { Filmstrip(list: list) }
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
        let dragging = app.developDraft?.assetId == asset.id
        let fullResolution = app.loupeZoom != nil && !dragging
        Group {
            if let source {
                ZoomableImageView(image: engine.image(for: asset.id), pixelSize: pixelSize,
                                  zoom: app.loupeZoom) { app.loupeZoom = $0 }
                    .padding(app.loupeZoom == nil ? 12 : 0)
                    .overlay(alignment: .topLeading) {
                        if app.developShowsOriginal { badge("修改前（按 \\ 切换）") }
                    }
                    .overlay(alignment: .topTrailing) {
                        if engine.isRendering(asset.id) { ProgressView().controlSize(.small).padding(14) }
                    }
                    .onChange(of: DevelopRenderKey(assetId: asset.id, settings: settings,
                                                   draft: dragging, fullResolution: fullResolution),
                              initial: true) {
                        engine.render(assetId: asset.id, url: source.url, isRaw: source.isRaw, settings: settings,
                                      draft: dragging, fullResolution: fullResolution) { temperature, tint in
                            app.recordAsShotWhiteBalance(asset.id, temperature: temperature, tint: tint)
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

    private var pixelSize: CGSize {
        let rendered = engine.image(for: asset.id).map { CGSize(width: $0.width, height: $0.height) }
        guard asset.width > 0, asset.height > 0 else { return rendered ?? CGSize(width: 1, height: 1) }
        var size = CGSize(width: asset.width, height: asset.height)
        if let rendered, rendered.width != rendered.height,
           (rendered.width > rendered.height) != (size.width > size.height) {
            size = CGSize(width: size.height, height: size.width)
        }
        return size
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
}

/// Owns two render workers — preview size and full resolution — so switching zoom
/// doesn't re-decode, and shows the newest finished render for the current photo.
@MainActor
final class DevelopPreviewEngine: ObservableObject {
    @Published private var shown: (assetId: String, token: Int, image: CGImage)?
    @Published private var renderingAssetId: String?
    private let previewWorker = DevelopRenderWorker()
    private let fullWorker = DevelopRenderWorker()
    private var token = 0

    func image(for assetId: String) -> CGImage? {
        shown?.assetId == assetId ? shown?.image : nil
    }

    func isRendering(_ assetId: String) -> Bool { renderingAssetId == assetId }

    func render(assetId: String, url: URL, isRaw: Bool, settings: DevelopSettings, draft: Bool,
                fullResolution: Bool, asShot: @escaping (Double, Double) -> Void) {
        token += 1
        let request = DevelopRenderWorker.Request(url: url, isRaw: isRaw, maxPixel: fullResolution ? nil : 2048,
                                                 settings: settings, draft: draft, token: token)
        renderingAssetId = assetId
        (fullResolution ? fullWorker : previewWorker).submit(request) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let temperature = result.asShotTemperature, let tint = result.asShotTint {
                    asShot(temperature, tint)
                }
                if result.request.token == self.token { self.renderingAssetId = nil }
                // a coalesced older render still beats a stale photo while dragging
                guard let image = result.image,
                      self.shown?.assetId != assetId || result.request.token >= (self.shown?.token ?? 0) else { return }
                self.shown = (assetId, result.request.token, image)
            }
        }
    }
}
