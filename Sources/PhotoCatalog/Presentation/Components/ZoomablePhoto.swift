// ============================================================
//  ZoomablePhoto — cached preview first, full resolution when zoomed
// ============================================================
import SwiftUI
import AppKit
import ImageIO

struct ZoomablePhoto: View {
    @Environment(AppState.self) private var app
    let asset: Asset
    let zoom: ImageZoom?
    let onZoomChange: (ImageZoom?) -> Void

    @StateObject private var preview = ThumbLoader()
    @StateObject private var full = FullResolutionLoader()

    private var previewImage: CGImage? {
        preview.image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// Adjusted photos render their edit at full size; unadjusted paired RAWs read the camera
    /// JPEG, which decodes an order of magnitude faster and shows the same focus.
    private var fullRequest: FullResolutionLoader.Request? {
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

    private var fullImage: CGImage? { full.image(for: fullRequest) }

    private var pixelSize: CGSize {
        if let fullImage { return CGSize(width: fullImage.width, height: fullImage.height) }
        let preview = previewImage
        if let preview, app.developSettings[asset.id]?.hasGeometry == true, asset.width > 0, asset.height > 0 {
            // a rotated or cropped preview renders the whole photo at 2048 px on the long edge first
            let longEdge = CGFloat(max(asset.width, asset.height))
            let factor = longEdge / min(CGFloat(ThumbnailService.Kind.preview2048.maxPixel), longEdge)
            return CGSize(width: CGFloat(preview.width) * factor, height: CGFloat(preview.height) * factor)
        }
        var size = CGSize(width: asset.width, height: asset.height)
        if size.width <= 0 || size.height <= 0 {
            return CGSize(width: preview?.width ?? 1, height: preview?.height ?? 1)
        }
        if let preview, preview.width != preview.height,
           (preview.width > preview.height) != (size.width > size.height) {
            size = CGSize(width: size.height, height: size.width)   // metadata in sensor orientation
        }
        return size
    }

    var body: some View {
        ZoomableImageView(image: fullImage ?? previewImage, pixelSize: pixelSize,
                          zoom: zoom, onZoomChange: onZoomChange)
            .overlay(alignment: .topTrailing) {
                if let zoom { zoomBadge(zoom) }
            }
            .task(id: "\(asset.id)|\(asset.preview)|\(app.previewMaxPixel)|\(app.thumbnailCacheGeneration)|"
                  + (app.developFingerprint(for: asset.id) ?? "")) {
                let generation = app.thumbnailCacheGeneration
                let resolved = await app.visibleImageSource(for: asset, requestedSource: asset.preview,
                                                            kind: .preview2048)
                guard !Task.isCancelled else { return }
                preview.load(resolved, maxPixel: ThumbnailService.Kind.preview2048.maxPixel,
                             cacheGeneration: generation)
            }
            .task(id: zoom == nil ? nil : fullRequest) {
                guard zoom != nil else { return }
                await full.load(fullRequest)
            }
    }

    private func zoomBadge(_ zoom: ImageZoom) -> some View {
        HStack(spacing: 6) {
            if fullImage == nil && full.isLoading(fullRequest) {
                ProgressView().controlSize(.mini)
                Text("正在载入原图…")
            } else if fullImage == nil {
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
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

final class ImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
