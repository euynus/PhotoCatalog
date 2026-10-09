// ============================================================
//  ZoomablePhoto — cached preview first, full resolution when zoomed
// ============================================================
import SwiftUI
import AppKit
import ImageIO

struct ZoomablePhoto: View {
    /// Optional, as Thumb's: a view SwiftUI updates after taking its hosting view out of the
    /// window no longer finds the app state, and then draws the canvas alone.
    @Environment(AppState.self) private var app: AppState?
    let asset: Asset
    let zoom: ImageZoom?
    let onZoomChange: (ImageZoom?) -> Void

    @StateObject private var preview = ThumbLoader()
    @StateObject private var placeholder = ThumbLoader()
    @StateObject private var full = FullResolutionLoader()

    /// The loader's image once it holds this photo; until then a decode already in the cache (a
    /// prefetched neighbor), so an arrow key shows the next photo in the same frame instead of
    /// after the load task has had its turn on a busy main thread.
    private func previewImage(_ app: AppState) -> CGImage? {
        let maxPixel = ThumbnailService.Kind.preview2048.maxPixel
        let key = app.verifiedImageSource(for: asset, requestedSource: asset.preview, kind: .preview2048).map {
            ThumbLoader.key($0, maxPixel: maxPixel, cacheGeneration: app.thumbnailCacheGeneration)
        }
        return Self.previewImage(for: asset.id, verifiedKey: key, loader: preview)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    @MainActor
    static func previewImage(for assetId: String, verifiedKey: String?, loader: ThumbLoader) -> NSImage? {
        if let verifiedKey {
            if loader.loadedKey == verifiedKey, let image = loader.image { return image }
            return ThumbLoader.cachedImage(forKey: verifiedKey)
        }
        return loader.owner == assetId ? loader.image : nil
    }

    @MainActor
    static func loadPreview(_ source: String, for assetId: String, cacheGeneration: Int, loader: ThumbLoader) {
        guard !Task.isCancelled else { return }
        // Ownership changes with the load, never while the new source is still resolving.
        // Loading the same key is a no-op, but a new owner must still redraw the view.
        if loader.owner != assetId { loader.objectWillChange.send() }
        loader.owner = assetId
        loader.load(source, maxPixel: ThumbnailService.Kind.preview2048.maxPixel, cacheGeneration: cacheGeneration)
    }

    /// The photo's thumbnail, scaled up, while its preview loads: a preview pruned from the cache is
    /// made again from the original, which on a RAW takes a few hundred milliseconds, and the canvas
    /// was blank until then. The filmstrip's decode of it is usually in the cache already. Only for
    /// unadjusted photos: an adjusted one's thumbnail can be cropped, and its preview sizes the view.
    private func placeholderImage(_ app: AppState) -> CGImage? {
        guard let source = placeholderSource(app) else { return nil }
        let generation = app.thumbnailCacheGeneration
        let image = Self.placeholderDecodeSizes.lazy
            .compactMap { ThumbLoader.cachedImage(forKey: ThumbLoader.key(source, maxPixel: $0, cacheGeneration: generation)) }
            .first ?? (placeholder.owner == asset.id ? placeholder.image : nil)
        return image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// The filmstrip's decode size first, then the one this view loads itself.
    private static let placeholderDecodeSizes = [264, ThumbnailService.Kind.thumb512.maxPixel]

    private func placeholderSource(_ app: AppState) -> String? {
        guard !asset.thumb.isEmpty, app.developSettings[asset.id]?.isNeutral ?? true else { return nil }
        return asset.thumb
    }

    /// Adjusted photos render their edit at full size; unadjusted paired RAWs read the camera
    /// JPEG, which decodes an order of magnitude faster and shows the same focus.
    private func fullRequest(_ app: AppState) -> FullResolutionLoader.Request? {
        let settings = app.developSettings[asset.id]
        if let settings, !settings.isNeutral {
            guard asset.status == .ready, let path = asset.localPath else { return nil }
            return .init(path: path, isRaw: asset.isRaw, settings: settings)
        }
        let jpeg = app.companions(of: asset).first { $0.status == .ready && $0.localPath != nil }
        if let path = jpeg?.localPath { return .init(path: path, isRaw: false, settings: nil) }
        guard asset.status == .ready, let path = asset.localPath else { return nil }
        return .init(path: path, isRaw: asset.isRaw, settings: nil)
    }

    private func fullImage(_ app: AppState) -> CGImage? { full.image(for: fullRequest(app)) }

    private func pixelSize(_ app: AppState) -> CGSize {
        if let fullImage = fullImage(app) { return CGSize(width: fullImage.width, height: fullImage.height) }
        let preview = previewImage(app)
        if let preview, app.developSettings[asset.id]?.hasGeometry == true, asset.width > 0, asset.height > 0 {
            // a rotated or cropped preview renders the whole photo at 2048 px on the long edge first
            let longEdge = CGFloat(max(asset.width, asset.height))
            let factor = longEdge / min(CGFloat(ThumbnailService.Kind.preview2048.maxPixel), longEdge)
            return CGSize(width: CGFloat(preview.width) * factor, height: CGFloat(preview.height) * factor)
        }
        var size = CGSize(width: asset.width, height: asset.height)
        let shown = preview ?? placeholderImage(app)
        if size.width <= 0 || size.height <= 0 {
            return CGSize(width: shown?.width ?? 1, height: shown?.height ?? 1)
        }
        if let shown, shown.width != shown.height,
           (shown.width > shown.height) != (size.width > size.height) {
            size = CGSize(width: size.height, height: size.width)   // metadata in sensor orientation
        }
        return size
    }

    var body: some View {
        if let app {
            photo(app)
        } else {
            Theme.canvas
        }
    }

    private func photo(_ app: AppState) -> some View {
        ZoomableImageView(image: fullImage(app) ?? previewImage(app) ?? placeholderImage(app), pixelSize: pixelSize(app),
                          zoom: zoom, onZoomChange: onZoomChange)
            .overlay(alignment: .topTrailing) {
                if let zoom { zoomBadge(zoom, app) }
            }
            .task(id: "\(asset.id)|\(asset.preview)|\(app.previewMaxPixel)|\(app.thumbnailCacheGeneration)|"
                  + (app.developFingerprint(for: asset.id) ?? "")) {
                let generation = app.thumbnailCacheGeneration
                let resolved = await app.visibleImageSource(for: asset, requestedSource: asset.preview,
                                                            kind: .preview2048)
                Self.loadPreview(resolved, for: asset.id, cacheGeneration: generation, loader: preview)
            }
            .task(id: "\(asset.id)|\(app.thumbnailCacheGeneration)") {
                // the thumbnail to show until the preview is in, unless that's already there
                guard previewImage(app) == nil, placeholderImage(app) == nil, let source = placeholderSource(app) else { return }
                placeholder.owner = asset.id
                placeholder.load(source, maxPixel: ThumbnailService.Kind.thumb512.maxPixel,
                                 cacheGeneration: app.thumbnailCacheGeneration)
            }
            .task(id: zoom == nil ? nil : fullRequest(app)) {
                guard zoom != nil else { return }
                await full.load(fullRequest(app))
            }
    }

    private func zoomBadge(_ zoom: ImageZoom, _ app: AppState) -> some View {
        HStack(spacing: 6) {
            if fullImage(app) == nil && full.isLoading(fullRequest(app)) {
                ProgressView().controlSize(.mini)
                Text("正在载入原图…")
            } else if fullImage(app) == nil {
                Image(systemName: "exclamationmark.triangle")
                Text("原件不可用 · 显示预览")
            }
            Text("\(Int((zoom.scale * 100).rounded()))%").monospacedDigit()
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Theme.canvasText)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.black.opacity(0.55), in: Capsule())
        .padding(10)
        .allowsHitTesting(false)
    }
}

/// Decodes an original at full resolution off the Swift cooperative pool (RAW decodes can
/// otherwise deadlock it) and keeps the last couple in memory for stepping back and forth.
@MainActor
final class FullResolutionLoader: ObservableObject {
    /// A file to show at full size, with the develop settings to render (nil = as decoded).
    struct Request: Hashable, Sendable {
        let path: String
        let isRaw: Bool
        let settings: DevelopSettings?
        var key: String { settings.map { "\(path)|\($0.fingerprint)" } ?? path }
    }

    @Published private var loaded: (key: String, image: CGImage)?
    @Published private var loadingKey: String?
    private static let cache: NSCache<NSString, ImageBox> = {
        let cache = NSCache<NSString, ImageBox>()
        cache.countLimit = 2   // ~100 MB each at 24 MP
        return cache
    }()

    /// Only the image produced for `request`, so a new photo or edit never shows the previous one.
    func image(for request: Request?) -> CGImage? {
        guard let request, let loaded, loaded.key == request.key else { return nil }
        return loaded.image
    }

    func isLoading(_ request: Request?) -> Bool { request != nil && loadingKey == request?.key }

    func load(_ request: Request?) async {
        guard let request, loaded?.key != request.key else { return }
        let key = request.key
        if let cached = Self.cache.object(forKey: key as NSString) {
            loaded = (key, cached.image)
            return
        }
        loadingKey = key
        let decoded = await ThumbnailRepairQueue.run(.visible) {
            let url = URL(fileURLWithPath: request.path)
            let image: CGImage? = if let settings = request.settings {
                DevelopRenderer.Source(url: url, isRaw: request.isRaw, maxPixel: nil)?
                    .image(settings).flatMap(DevelopRenderer.render)
            } else {
                Self.decodeFullResolution(url)
            }
            return image.map(ImageBox.init)
        } ?? nil
        if loadingKey == key { loadingKey = nil }
        guard !Task.isCancelled, let decoded else { return }
        Self.cache.setObject(decoded, forKey: key as NSString)
        loaded = (key, decoded.image)
    }

    nonisolated static func decodeFullResolution(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return DisplayBitmap.converting(image) ?? image
    }
}

final class ImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
