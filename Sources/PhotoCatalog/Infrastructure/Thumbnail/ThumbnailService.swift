// ============================================================
//  ThumbnailService — Image I/O thumbnail/preview generation
//  with a sharded on-disk cache (PRD §6.6, §12.5).
//  Quick Look is preferred for RAW; Image I/O is the reliable
//  fallback used here and works for JPEG/PNG/HEIC/TIFF/RAW previews.
// ============================================================
import Foundation
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

// @unchecked Sendable: stateless aside from the (Sendable) store; writes go to
// per-asset cache files, so background generation is safe.
final class ThumbnailService: @unchecked Sendable {
    let store: CatalogStore
    init(store: CatalogStore) { self.store = store }

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

    /// Return an existing cached representation or regenerate it from the original.
    @discardableResult
    func ensureCached(from original: URL, assetId: String, kind: Kind) -> URL? {
        let out = cachePath(assetId: assetId, kind: kind)
        if FileManager.default.fileExists(atPath: out.path) { return out }
        return generate(from: original, assetId: assetId, kind: kind)
    }

    /// Generate one cached representation; returns its file URL (or nil on failure).
    @discardableResult
    func generate(from original: URL, assetId: String, kind: Kind) -> URL? {
        let out = cachePath(assetId: assetId, kind: kind)
        try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let src = CGImageSourceCreateWithURL(original as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: kind.maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out : nil
    }

    /// Generate both thumbnail sizes + the configured loupe preview.
    func generateAll(from original: URL, assetId: String, previewMaxPixel: Int = 2048) -> (thumb: URL?, preview: URL?) {
        _ = generate(from: original, assetId: assetId, kind: .thumb256)
        let thumb = generate(from: original, assetId: assetId, kind: .thumb512)
        let preview = generate(from: original, assetId: assetId, kind: Self.previewKind(maxPixel: previewMaxPixel))
        return (thumb, preview)
    }
}
