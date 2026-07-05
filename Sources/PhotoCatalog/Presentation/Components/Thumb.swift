// ============================================================
//  Thumb — async remote image with deterministic gradient fallback
//  Port of the `Thumb` / `gradientFor` helpers in components.jsx.
// ============================================================
import SwiftUI
import AppKit
import ImageIO

/// HSL → Color (SwiftUI's Color(hue:…) is HSB, so we convert manually).
private func hsl(_ h: Double, _ s: Double, _ l: Double) -> Color {
    let c = (1 - abs(2 * l - 1)) * s
    let hp = h / 60
    let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
    var r = 0.0, g = 0.0, b = 0.0
    switch hp {
    case 0..<1: (r, g, b) = (c, x, 0)
    case 1..<2: (r, g, b) = (x, c, 0)
    case 2..<3: (r, g, b) = (0, c, x)
    case 3..<4: (r, g, b) = (0, x, c)
    case 4..<5: (r, g, b) = (x, 0, c)
    default: (r, g, b) = (c, 0, x)
    }
    let m = l - c / 2
    return Color(.sRGB, red: r + m, green: g + m, blue: b + m)
}

/// Deterministic placeholder gradient while a photo is loading.
func gradientFor(_ pid: Int) -> LinearGradient {
    let h0 = Double((pid * 47) % 360)
    let h1 = Double((pid * 47 + 40) % 360)
    return LinearGradient(
        colors: [hsl(h0, 0.32, 0.26), hsl(h1, 0.38, 0.16)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
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
        c.countLimit = 400
        c.totalCostLimit = 512 * 1024 * 1024   // 512 MB of decoded pixels
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
            let data: Data?
            if source.hasPrefix("http") {
                guard let url = URL(string: source) else {
                    self?.failed = true
                    return
                }
                data = try? await URLSession.shared.data(from: url).0
            } else {
                data = await Self.readImageData(at: source)
            }
            guard !Task.isCancelled else { return }
            let decoded = await Self.decodeImage(data, maxPixel: maxPixel)
            guard !Task.isCancelled else { return }
            self?.finish(key, decoded)
        }
    }

    /// Warm the shared cache (e.g. loupe neighbors) without touching any
    /// loader's published state — a failed warm-up stays silent.
    static func prefetch(_ source: String, maxPixel: Int, cacheGeneration: Int = 0) async {
        let key = "\(source)|\(maxPixel)|\(cacheGeneration)"
        guard !source.isEmpty, cache.object(forKey: key as NSString) == nil else { return }
        let data: Data?
        if source.hasPrefix("http") {
            guard let url = URL(string: source) else { return }
            data = try? await URLSession.shared.data(from: url).0
        } else {
            data = await readImageData(at: source)
        }
        guard let img = await decodeImage(data, maxPixel: maxPixel) else { return }
        cache.setObject(img, forKey: key as NSString, cost: cost(of: img))
    }

    /// Decode + downsample to the display pixel budget off the main thread;
    /// kCGImageSourceShouldCacheImmediately rasterizes the bitmap inside the
    /// detached task so the render pass never pays JPEG decompression.
    private static func decodeImage(_ data: Data?, maxPixel: Int) async -> NSImage? {
        await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let data, let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: .zero)
        }.value
    }

    private func finish(_ key: String, _ img: NSImage?) {
        guard loadedKey == key else { return }
        if let img {
            Self.cache.setObject(img, forKey: key as NSString, cost: Self.cost(of: img))
            withAnimation(.easeOut(duration: 0.3)) { image = img }
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

    private static func readImageData(at path: String) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            try? Data(contentsOf: URL(fileURLWithPath: path))
        }.value
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

    @StateObject private var loader = ThumbLoader()

    private var source: String { urlString ?? asset.thumb }
    private var cacheKind: ThumbnailService.Kind {
        kind ?? (urlString == nil || urlString == asset.thumb ? .thumb512 : .preview2048)
    }
    private var loadKey: String {
        "\(asset.id)|\(source)|\(cacheKind.maxPixel)|\(app.previewMaxPixel)|\(app.thumbnailCacheGeneration)"
    }

    var body: some View {
        ZStack {
            if let img = loader.image {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                gradientFor(asset.pid)
                if loader.failed {
                    Icon("photos", size: 22).foregroundStyle(.white.opacity(0.35))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .opacity(dim ? 0.4 : 1)
        .task(id: loadKey) {
            let resolved = await app.visibleImageSource(for: asset, requestedSource: source, kind: cacheKind)
            guard !Task.isCancelled else { return }
            loader.load(resolved, maxPixel: cacheKind.maxPixel,
                        cacheGeneration: app.thumbnailCacheGeneration)
        }
    }
}
