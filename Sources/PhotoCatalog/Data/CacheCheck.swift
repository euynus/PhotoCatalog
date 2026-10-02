import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The cache limit: the background pass makes every thumbnail, then previews for the newest
/// photos only while they fit, so a second pass (the next launch) makes nothing; a prune
/// takes previews before any thumbnail.
@MainActor
enum CacheCheck {
    static func run(_ check: (Bool, String) -> Void) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("pc-cache-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        let photos = tmp.appendingPathComponent("photos")
        try? fm.createDirectory(at: photos, withIntermediateDirectories: true)
        let count = 40
        for day in 1...count { writeImage(photos.appendingPathComponent(String(format: "IMG_%04d.jpg", day)), day: day) }
        guard let store = try? CatalogStore(packageURL: tmp.appendingPathComponent("Cache.photolibrary")) else {
            return check(false, "cache: scratch catalog")
        }
        let app = AppState.selfCheckFixture(importingInto: store)
        app.runsBackgroundMaintenance = false
        let savedLimit = UserDefaults.standard.object(forKey: "pc_cacheLimitMB")
        defer {
            if let savedLimit { UserDefaults.standard.set(savedLimit, forKey: "pc_cacheLimitMB") }
            else { UserDefaults.standard.removeObject(forKey: "pc_cacheLimitMB") }
        }
        app.importFolder(photos)
        spin { !app.importing && app.assets.filter { !$0.isDemo }.count == count }

        // as after a prune: nothing cached
        let thumbnails = store.cacheURL.appendingPathComponent("Thumbnails")
        let previews = store.cacheURL.appendingPathComponent("Previews")
        let previewBytes = files(in: previews).reduce(Int64(0)) { $0 + $1.size }
        check(files(in: previews).count == count, "cache: import made a preview of every photo")
        for file in files(in: store.cacheURL) { try? fm.removeItem(at: file.url) }

        // room for the thumbnails and about half the previews
        app.cacheLimitMB = Int((previewBytes / 2) >> 20) + 2
        let limit = Int64(app.cacheLimitMB) << 20
        @MainActor func backfill() {
            app.runsBackgroundMaintenance = true
            app.backfillThumbnails()
            spin(60) { !app.isBackfilling }
            spin(2) { false }   // the prune after the pass
            app.runsBackgroundMaintenance = false
        }
        backfill()
        let real = app.assets.filter { !$0.isDemo }
        let made = Set(files(in: previews).map { $0.url.deletingPathExtension().lastPathComponent })
        let total = files(in: store.cacheURL).reduce(Int64(0)) { $0 + $1.size }
        let service = ThumbnailService(store: store)
        check(real.allSatisfy { fm.fileExists(atPath: service.cachePath(assetId: $0.id, kind: .thumb512).path) },
              "cache: the background pass makes every thumbnail")
        check(made.count > 0 && made.count < count && total <= limit,
              "cache: previews only while they fit under the limit (\(made.count) of \(count), \(total >> 10) of \(limit >> 10) KB)")
        let newest = Set(real.sorted { $0.date > $1.date }.prefix(made.count).map(\.id))
        check(made == newest, "cache: the previews kept are the newest photos'")

        // the next launch's pass finds the cache full and makes nothing
        let before = Dictionary(uniqueKeysWithValues: files(in: store.cacheURL).map { ($0.url.path, $0.modified) })
        backfill()
        let after = Dictionary(uniqueKeysWithValues: files(in: store.cacheURL).map { ($0.url.path, $0.modified) })
        check(before == after, "cache: a second pass makes and deletes nothing")

        // a cache full of previews with thumbnails missing (as an older prune left it): the pass
        // makes the thumbnails, and the prune makes room for them from the previews
        for file in files(in: thumbnails) { try? fm.removeItem(at: file.url) }
        for asset in real {
            _ = service.ensureCached(from: URL(fileURLWithPath: asset.localPath ?? ""), assetId: asset.id, kind: .preview2048)
        }
        backfill()
        let refilled = files(in: store.cacheURL).reduce(Int64(0)) { $0 + $1.size }
        check(real.allSatisfy { fm.fileExists(atPath: service.cachePath(assetId: $0.id, kind: .thumb512).path) } && refilled <= limit
              && files(in: previews).count < count, "cache: thumbnails come back into a cache full of previews, which give way")
        let settled = Dictionary(uniqueKeysWithValues: files(in: store.cacheURL).map { ($0.url.path, $0.modified) })
        backfill()
        check(settled == Dictionary(uniqueKeysWithValues: files(in: store.cacheURL).map { ($0.url.path, $0.modified) }),
              "cache: and the pass after that makes and deletes nothing")

        // a smaller limit takes previews first, though the thumbnails are older
        let thumbnailBytes = files(in: thumbnails).reduce(Int64(0)) { $0 + $1.size }
        let previewCount = files(in: previews).count
        let report = CacheService.prune(store.cacheURL, maxBytes: thumbnailBytes + (refilled - thumbnailBytes) / 3)
        check(report.removedFiles > 0 && files(in: thumbnails).reduce(Int64(0)) { $0 + $1.size } == thumbnailBytes
              && files(in: previews).count < previewCount, "cache: a prune takes previews before thumbnails")
    }

    private struct CachedFile {
        let url: URL
        let size: Int64
        let modified: Date
    }

    private static func files(in folder: URL) -> [CachedFile] {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey]
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys)
        return (enumerator?.compactMap { $0 as? URL } ?? []).compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
            return CachedFile(url: url, size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast)
        }
    }

    private static func spin(_ timeout: Double = 30, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    /// A noisy 1200 × 800 photo (so its preview has some size), each `day` a day later than the last.
    private static func writeImage(_ url: URL, day: Int) {
        let width = 1200, height = 800
        var generator = SystemRandomNumberGenerator()
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = UInt8.random(in: 0...255, using: &generator)
            pixels[index + 1] = UInt8(truncatingIfNeeded: index / 4 / width + day * 6)
            pixels[index + 2] = UInt8.random(in: 0...255, using: &generator)
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        let taken = day <= 28 ? String(format: "2026:01:%02d 10:00:00", day) : String(format: "2026:02:%02d 10:00:00", day - 28)
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: taken],
        ] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }
}
