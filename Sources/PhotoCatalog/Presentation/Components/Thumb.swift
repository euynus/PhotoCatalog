// ============================================================
//  Async photo loading with a neutral placeholder.
// ============================================================
import SwiftUI
import AppKit
import ImageIO

/// Bounds synchronous Image I/O work so a fast grid scroll cannot flood the
/// cooperative thread pool with decodes that are already off screen.
private actor ThumbDecodeLimiter {
    static let shared = ThumbDecodeLimiter(limit: 4)

    private let limit: Int
    private var active = 0
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var waiterOrder: [UUID] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquire(_ id: UUID) async -> Bool {
        guard !Task.isCancelled else { return false }
        if active < limit {
            active += 1
            return true
        }
        return await withCheckedContinuation { continuation in
            guard !Task.isCancelled else {
                continuation.resume(returning: false)
                return
            }
            waiterOrder.append(id)
            waiters[id] = continuation
        }
    }

    func cancel(_ id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        waiterOrder.removeAll { $0 == id }
        continuation.resume(returning: false)
    }

    func release() {
        while let id = waiterOrder.first {
            waiterOrder.removeFirst()
            if let continuation = waiters.removeValue(forKey: id) {
                continuation.resume(returning: true)
                return
            }
        }
        active = max(0, active - 1)
    }
}

/// Shared in-memory image cache so grid scrolling doesn't refetch.
@MainActor
final class ThumbLoader: ObservableObject {
    @Published var image: NSImage?
    @Published var failed = false
    // Bounded so resident memory can't grow unbounded while scrolling a large grid
    // or browsing multi-MB loupe previews (NSCache evicts by count + byte cost).
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 160
        c.totalCostLimit = 128 * 1024 * 1024
        return c
    }()
    private var task: Task<Void, Never>?
    private var loadedKey: String?

    deinit {
        task?.cancel()
    }

    static func clearCache() {
        cache.removeAllObjects()
    }

    func load(_ source: String, maxPixel: Int, cacheGeneration: Int = 0) {
        let key = "\(source)|\(maxPixel)|\(cacheGeneration)"
        // already showing / fetching this exact source
        if key == loadedKey { return }
        loadedKey = key
        task?.cancel()
        task = nil
        failed = false

        if source.isEmpty { image = nil; failed = true; return }
        if let cached = Self.cache.object(forKey: key as NSString) {
            image = cached
            return
        }
        image = nil

        task = Task { [weak self, source] in
            let decoded: NSImage?
            if source.hasPrefix("http") {
                guard let url = URL(string: source) else {
                    self?.failed = true
                    return
                }
                let data = try? await URLSession.shared.data(from: url).0
                decoded = await Self.decodeImage(data: data, maxPixel: maxPixel)
            } else {
                decoded = await Self.decodeImage(at: URL(fileURLWithPath: source), maxPixel: maxPixel)
            }
            guard !Task.isCancelled else { return }
            self?.finish(key, decoded)
        }
    }

    /// A lazy grid retains cell state after it scrolls off screen. Explicitly
    /// drop the decoded image so visited rows do not accumulate hundreds of MB.
    func cancelAndRelease() {
        task?.cancel()
        task = nil
        loadedKey = nil
        image = nil
        failed = false
    }

    /// Warm the shared cache (e.g. loupe neighbors) without touching any
    /// loader's published state — a failed warm-up stays silent.
    static func prefetch(_ source: String, maxPixel: Int, cacheGeneration: Int = 0) async {
        let key = "\(source)|\(maxPixel)|\(cacheGeneration)"
        guard !source.isEmpty, cache.object(forKey: key as NSString) == nil else { return }
        let image: NSImage?
        if source.hasPrefix("http") {
            guard let url = URL(string: source) else { return }
            let data = try? await URLSession.shared.data(from: url).0
            image = await decodeImage(data: data, maxPixel: maxPixel)
        } else {
            image = await decodeImage(at: URL(fileURLWithPath: source), maxPixel: maxPixel)
        }
        guard !Task.isCancelled, let img = image else { return }
        cache.setObject(img, forKey: key as NSString, cost: cost(of: img))
    }

    /// Decode + downsample to the display pixel budget off the main thread;
    /// kCGImageSourceShouldCacheImmediately rasterizes the bitmap inside the
    /// detached task so the render pass never pays JPEG decompression.
    private static func decodeImage(at url: URL, maxPixel: Int) async -> NSImage? {
        await decode(maxPixel: maxPixel) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, [
                kCGImageSourceShouldCache: false,
            ] as CFDictionary) else { return nil }
            return decodedImage(from: src, maxPixel: maxPixel)
        }
    }

    private static func decodeImage(data: Data?, maxPixel: Int) async -> NSImage? {
        await decode(maxPixel: maxPixel) {
            guard let data,
                  let src = CGImageSourceCreateWithData(data as CFData, [
                    kCGImageSourceShouldCache: false,
                  ] as CFDictionary) else { return nil }
            return decodedImage(from: src, maxPixel: maxPixel)
        }
    }

    private static func decode(maxPixel: Int,
                               operation: @escaping @Sendable () -> NSImage?) async -> NSImage? {
        let permitID = UUID()
        let acquired = await withTaskCancellationHandler {
            await ThumbDecodeLimiter.shared.acquire(permitID)
        } onCancel: {
            Task { await ThumbDecodeLimiter.shared.cancel(permitID) }
        }
        guard acquired else { return nil }
        guard !Task.isCancelled else {
            await ThumbDecodeLimiter.shared.release()
            return nil
        }

        let decodeTask = Task.detached(priority: .utility) {
            guard !Task.isCancelled else { return nil as NSImage? }
            return operation()
        }
        let result = await withTaskCancellationHandler {
            await decodeTask.value
        } onCancel: {
            decodeTask.cancel()
        }
        await ThumbDecodeLimiter.shared.release()
        return Task.isCancelled ? nil : result
    }

    nonisolated private static func decodedImage(from src: CGImageSource, maxPixel: Int) -> NSImage? {
        guard !Task.isCancelled else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary),
              !Task.isCancelled else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }

    private func finish(_ key: String, _ img: NSImage?) {
        guard loadedKey == key else { return }
        if let img {
            Self.cache.setObject(img, forKey: key as NSString, cost: Self.cost(of: img))
            image = img
        } else {
            failed = true
        }
    }

    private static func cost(of image: NSImage) -> Int {
        if let rep = image.representations.first, rep.pixelsWide > 0 {
            return rep.pixelsWide * rep.pixelsHigh * 4
        }
        return max(1, Int(image.size.width * image.size.height) * 4)
    }

}

/// A photo tile that fills or fits the frame it is given (caller controls sizing).
// Under @Observable, reading app.previewMaxPixel in body subscribes each tile
// to exactly that one property — the old unobserved-environment workaround
// (appStateRef) is no longer needed.
struct Thumb: View {
    @Environment(AppState.self) private var app

    let asset: Asset
    var urlString: String?
    var kind: ThumbnailService.Kind?
    var radius: CGFloat = 4
    var contentMode: ContentMode = .fill
    var dim: Bool = false
    var maxDecodePixel: Int?

    @StateObject private var loader = ThumbLoader()

    private var source: String { urlString ?? asset.thumb }
    private var cacheKind: ThumbnailService.Kind {
        kind ?? (urlString == nil || urlString == asset.thumb ? .thumb512 : .preview2048)
    }
    private var decodeMaxPixel: Int {
        min(cacheKind.maxPixel, max(64, maxDecodePixel ?? cacheKind.maxPixel))
    }
    private var loadKey: String {
        let previewConfiguration = cacheKind.isPreview ? app.previewMaxPixel : 0
        // the develop fingerprint reloads the tile when the photo's adjustments change
        return "\(asset.id)|\(source)|\(decodeMaxPixel)|\(previewConfiguration)|\(app.thumbnailCacheGeneration)|"
            + (app.developFingerprint(for: asset.id) ?? "")
    }

    var body: some View {
        ZStack {
            if let img = loader.image {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Theme.canvasSurface
                if loader.failed {
                    Icon("photos", size: 22).foregroundStyle(.white.opacity(0.35))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .opacity(dim ? 0.4 : 1)
        .task(id: loadKey) {
            let cacheGeneration = app.thumbnailCacheGeneration
            let resolved = await app.visibleImageSource(for: asset, requestedSource: source, kind: cacheKind)
            guard !Task.isCancelled else { return }
            loader.load(resolved, maxPixel: decodeMaxPixel, cacheGeneration: cacheGeneration)
        }
        .onDisappear { loader.cancelAndRelease() }
    }
}
