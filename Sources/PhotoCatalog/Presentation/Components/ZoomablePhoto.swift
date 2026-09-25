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

    /// The paired camera JPEG decodes an order of magnitude faster than the RAW at full size
    /// and shows the same focus, so zooming a paired RAW reads the JPEG.
    private var fullSource: String? {
        let jpeg = app.companions(of: asset).first { $0.status == .ready && $0.localPath != nil }
        if let path = jpeg?.localPath { return path }
        return asset.status == .ready ? asset.localPath : nil
    }

    private var fullImage: CGImage? { full.image(for: fullSource) }

    private var pixelSize: CGSize {
        if let fullImage { return CGSize(width: fullImage.width, height: fullImage.height) }
        let preview = previewImage
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
            .task(id: "\(asset.id)|\(asset.preview)|\(app.previewMaxPixel)|\(app.thumbnailCacheGeneration)") {
                let generation = app.thumbnailCacheGeneration
                let resolved = await app.visibleImageSource(for: asset, requestedSource: asset.preview,
                                                            kind: .preview2048)
                guard !Task.isCancelled else { return }
                preview.load(resolved, maxPixel: ThumbnailService.Kind.preview2048.maxPixel,
                             cacheGeneration: generation)
            }
            .task(id: zoom == nil ? nil : fullSource) {
                guard zoom != nil else { return }
                await full.load(fullSource)
            }
    }

    private func zoomBadge(_ zoom: ImageZoom) -> some View {
        HStack(spacing: 6) {
            if fullImage == nil && full.isLoading(fullSource) {
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
    @Published private var loaded: (path: String, image: CGImage)?
    @Published private var loadingPath: String?
    private static let cache: NSCache<NSString, ImageBox> = {
        let cache = NSCache<NSString, ImageBox>()
        cache.countLimit = 2   // ~100 MB each at 24 MP
        return cache
    }()

    /// Only the image decoded for `path`, so a new photo never shows the previous one.
    func image(for path: String?) -> CGImage? {
        guard let path, let loaded, loaded.path == path else { return nil }
        return loaded.image
    }

    func isLoading(_ path: String?) -> Bool { path != nil && loadingPath == path }

    func load(_ path: String?) async {
        guard let path, loaded?.path != path else { return }
        if let cached = Self.cache.object(forKey: path as NSString) {
            loaded = (path, cached.image)
            return
        }
        loadingPath = path
        let decoded = await ThumbnailRepairQueue.run(.visible) {
            Self.decodeFullResolution(URL(fileURLWithPath: path)).map(ImageBox.init)
        } ?? nil
        if loadingPath == path { loadingPath = nil }
        guard !Task.isCancelled, let decoded else { return }
        Self.cache.setObject(decoded, forKey: path as NSString)
        loaded = (path, decoded.image)
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
