// ============================================================
//  ThumbnailService — thumbnail/preview generation with a sharded
//  on-disk cache (PRD §6.6, §12.5).
//  Quick Look is preferred for RAW; Image I/O is the fallback for
//  common bitmap formats and files Quick Look cannot render.
// ============================================================
import Foundation
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers
import CryptoKit

private final class ThumbnailImageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedImage: CGImage?

    func set(_ image: CGImage?) {
        lock.lock()
        storedImage = image
        lock.unlock()
    }

    func image() -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        return storedImage
    }
}

// @unchecked Sendable: stateless aside from the (Sendable) store; writes go to
// per-asset cache files, so background generation is safe.
final class ThumbnailService: @unchecked Sendable {
    let store: CatalogStore
    init(store: CatalogStore) { self.store = store }

    private static let quickLookPreferredExtensions: Set<String> = [
        "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "dng", "pef", "srw", "raw",
    ]

    enum Kind: Sendable {
        case thumb256, thumb512, preview1600, preview2048

        var maxPixel: Int {
            switch self {
            case .thumb256: return 256
            case .thumb512: return 512
            case .preview1600: return 1600
            case .preview2048: return 2048
            }
        }

        var isPreview: Bool {
            self == .preview1600 || self == .preview2048
        }

        var isThumbnail: Bool {
            self == .thumb256 || self == .thumb512
        }

        var baseURL: (CatalogStore) -> URL {
            switch self {
            case .thumb256: return { $0.thumb256URL }
            case .thumb512: return { $0.thumb512URL }
            case .preview1600: return { $0.preview1600URL }
            case .preview2048: return { $0.preview2048URL }
            }
        }
    }

    static func previewKind(maxPixel: Int) -> Kind {
        maxPixel <= 1600 ? .preview1600 : .preview2048
    }

    static func previewKind(forCachePath path: String, fallbackMaxPixel: Int) -> Kind {
        if path.contains("/Previews/1600/") { return .preview1600 }
        if path.contains("/Previews/2048/") { return .preview2048 }
        return previewKind(maxPixel: fallbackMaxPixel)
    }

    /// Sharded path: <base>/ab/cd/<assetId>.jpg
    func cachePath(assetId: String, kind: Kind) -> URL {
        let digest = SHA256.hash(data: Data(assetId.utf8)).compactMap { String(format: "%02x", $0) }.joined()
        let a = String(digest.prefix(2))
        let b = String(digest.dropFirst(2).prefix(2))
        return kind.baseURL(store)
            .appendingPathComponent(a).appendingPathComponent(b)
            .appendingPathComponent("\(assetId).jpg")
    }

    /// Where a developed rendering lives; the settings fingerprint in the name means an edit
    /// never reuses an older render, and clearing the edit falls back to the untouched cache.
    func editedCachePath(assetId: String, kind: Kind, settings: DevelopSettings) -> URL {
        let plain = cachePath(assetId: assetId, kind: kind)
        let shard = plain.deletingLastPathComponent()
        let relative = shard.path.replacingOccurrences(of: store.cacheURL.path, with: "")
        return store.cacheURL.appendingPathComponent("Edited")
            .appendingPathComponent(relative)
            .appendingPathComponent("\(assetId)-\(settings.fingerprint).jpg")
    }

    /// Returns the developed rendering at the kind's size, rendering it from `source`
    /// (the original, or a cached preview when the original is unavailable) if missing.
    @discardableResult
    func ensureEdited(from source: URL, isRaw: Bool, settings: DevelopSettings, assetId: String,
                      kind: Kind) -> URL? {
        let out = editedCachePath(assetId: assetId, kind: kind, settings: settings)
        if FileManager.default.fileExists(atPath: out.path) { return out }
        try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let rendered = autoreleasepool {
            DevelopRenderer.Source(url: source, isRaw: isRaw, maxPixel: kind.maxPixel, interactive: false)?
                .image(settings)
                .flatMap(DevelopRenderer.render)
        }
        return rendered.flatMap { writeJPEG($0, to: out) }
    }

    /// Return an existing cached representation or regenerate it from the original.
    @discardableResult
    func ensureCached(from original: URL, assetId: String, kind: Kind) -> URL? {
        ensureCached(from: original, fallbackPreview: nil, assetId: assetId, kind: kind)
    }

    /// Use the modification time already stored in the catalog so displaying a valid cache
    /// never needs to stat an original on a slow or disconnected external volume.
    @discardableResult
    func ensureCached(from original: URL, fallbackPreview: URL?,
                      catalogModificationDate: Date?, assetId: String, kind: Kind) -> URL? {
        ensureCached(from: original, fallbackPreview: fallbackPreview, assetId: assetId, kind: kind) {
            Self.cacheIsStale(cache: $0, originalModificationDate: catalogModificationDate)
        }
    }

    /// Return an existing cached representation or regenerate it, using an existing preview
    /// first when repairing broken RAW thumbnails and the original may be unavailable.
    @discardableResult
    func ensureCached(from original: URL, fallbackPreview: URL?, assetId: String, kind: Kind) -> URL? {
        ensureCached(from: original, fallbackPreview: fallbackPreview, assetId: assetId, kind: kind) {
            Self.cacheIsStale(cache: $0, original: original)
        }
    }

    private func ensureCached(from original: URL, fallbackPreview: URL?, assetId: String, kind: Kind,
                              cacheIsStale: (URL) -> Bool) -> URL? {
        let out = cachePath(assetId: assetId, kind: kind)
        if FileManager.default.fileExists(atPath: out.path),
           !cacheIsStale(out),
           !cachedRepresentationNeedsRegeneration(at: out, original: original, kind: kind) {
            return out
        }

        // generate() now writes atomically, so we don't pre-delete `out`: if regeneration
        // fails (offline RAW, Quick Look timeout), the prior displayable file stays in place
        // instead of being left dangling and counted as missing.
        if kind.isThumbnail,
           let fallbackPreview,
           FileManager.default.fileExists(atPath: fallbackPreview.path),
           !Self.imageIsUniformBlack(at: fallbackPreview) {
            if let repaired = generate(from: fallbackPreview, assetId: assetId, kind: kind) {
                return repaired
            }
        }

        return generate(from: original, assetId: assetId, kind: kind)
    }

    func cachedRepresentationNeedsRegeneration(at cached: URL, original: URL, kind: Kind) -> Bool {
        guard Self.prefersQuickLook(for: original) else { return false }
        // A uniformly black JPEG is empty 8×8 blocks — ~3 KB plus header at 512 px — so a file
        // well above that bound has real content and needs no decode. The check runs for every
        // visible RAW cell and every backfilled asset on each launch.
        if let size = try? cached.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > Self.maxUniformBlackBytes(for: kind) {
            return false
        }
        return Self.imageIsUniformBlack(at: cached)
    }

    /// ~3× the size of an all-black JPEG at the kind's largest (square) dimensions.
    static func maxUniformBlackBytes(for kind: Kind) -> Int {
        kind.maxPixel * kind.maxPixel / 28 + 4_096
    }

    /// A cached thumbnail is stale once the original is modified after it was generated
    /// (e.g. an in-place edit). Compares file modification times (THM-004).
    static func cacheIsStale(cache: URL, original: URL) -> Bool {
        let originalDate = try? original.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        return cacheIsStale(cache: cache, originalModificationDate: originalDate)
    }

    static func cacheIsStale(cache: URL, originalModificationDate: Date?) -> Bool {
        guard let originalDate = originalModificationDate,
              let cacheDate = try? cache.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate else { return false }
        return originalDate > cacheDate
    }

    /// Generate one cached representation; returns its file URL (or nil on failure).
    @discardableResult
    func generate(from original: URL, assetId: String, kind: Kind) -> URL? {
        let out = cachePath(assetId: assetId, kind: kind)
        try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)

        let prefersQuickLook = Self.prefersQuickLook(for: original)
        if prefersQuickLook,
           let written = quickLookThumbnail(from: original, maxPixel: kind.maxPixel)
            .flatMap({ writeJPEG($0, to: out) }) {
            if !Self.imageIsUniformBlack(at: written) { return written }
            try? FileManager.default.removeItem(at: written)
        }

        if let written = imageIOThumbnail(from: original, maxPixel: kind.maxPixel)
            .flatMap({ writeJPEG($0, to: out) }) {
            return written
        }

        guard !prefersQuickLook else { return nil }
        return quickLookThumbnail(from: original, maxPixel: kind.maxPixel)
            .flatMap { writeJPEG($0, to: out) }
    }

    private static func prefersQuickLook(for original: URL) -> Bool {
        let ext = original.pathExtension.lowercased()
        if quickLookPreferredExtensions.contains(ext) { return true }
        return UTType(filenameExtension: ext)?.conforms(to: .rawImage) ?? false
    }

    private func quickLookThumbnail(from original: URL, maxPixel: Int) -> CGImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: original,
            size: CGSize(width: maxPixel, height: maxPixel),
            scale: 1,
            representationTypes: [.thumbnail]
        )
        let image = ThumbnailImageBox()
        let semaphore = DispatchSemaphore(value: 0)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            image.set(representation?.cgImage)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 15) == .success else { return nil }
        return image.image()
    }

    private func imageIOThumbnail(from original: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(original as CFURL, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }

    private func writeJPEG(_ cg: CGImage, to out: URL) -> URL? {
        // Encode to a unique temp sibling, then atomically move it into place, so concurrent
        // generators and UI readers only ever observe a complete file — never a half-written one,
        // and never a corrupt cache left behind by a crash mid-encode.
        let fm = FileManager.default
        let tmp = out.deletingLastPathComponent()
            .appendingPathComponent(".tmp-\(UUID().uuidString)-\(out.lastPathComponent)")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? fm.removeItem(at: tmp)
            return nil
        }
        do {
            if fm.fileExists(atPath: out.path) {
                _ = try fm.replaceItemAt(out, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: out)
            }
            return out
        } catch {
            try? fm.removeItem(at: tmp)
            return nil
        }
    }

    private static func imageIsUniformBlack(at url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary) else { return true }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 32,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return true }

        let width = cg.width
        let height = cg.height
        let bytesPerPixel = 4
        var data = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        guard let context = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * bytesPerPixel,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return true }

        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        var index = 0
        while index < data.count {
            if data[index] > 2 || data[index + 1] > 2 || data[index + 2] > 2 {
                return false
            }
            index += bytesPerPixel
        }
        return true
    }

    /// Generate both thumbnail sizes + the configured loupe preview.
    /// The original is decoded once for the preview (important for slow RAW); the smaller
    /// sizes are then downscaled from that preview JPEG, falling back to the original if the
    /// preview couldn't be produced.
    func generateAll(from original: URL, assetId: String, previewMaxPixel: Int = 2048) -> (thumb: URL?, preview: URL?) {
        let preview = generate(from: original, assetId: assetId, kind: Self.previewKind(maxPixel: previewMaxPixel))
        let source = preview ?? original
        let thumb = generate(from: source, assetId: assetId, kind: .thumb512)
        _ = generate(from: source, assetId: assetId, kind: .thumb256)
        return (thumb, preview)
    }
}
