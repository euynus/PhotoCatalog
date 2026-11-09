import CoreGraphics
import Foundation
import ImageIO
import Observation
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
        let savedLimit = PreferenceSnapshot(keys: ["pc_cacheLimitMB"])
        defer { savedLimit.restore() }
        app.importFolder(photos)
        CheckWait.until(30) { !app.importing && app.assets.filter { !$0.isDemo }.count == count }

        // as after a prune: nothing cached
        let thumbnails = store.cacheURL.appendingPathComponent("Thumbnails")
        let previews = store.cacheURL.appendingPathComponent("Previews")
        let previewBytes = files(in: previews).reduce(Int64(0)) { $0 + $1.size }
        check(files(in: previews).count == count, "cache: import made a preview of every photo")
        for file in files(in: store.cacheURL) { try? fm.removeItem(at: file.url) }

        // unset, the limit follows the catalog and is never under 2 GB
        app.cacheLimitMB = 0
        check(UserDefaults.app.object(forKey: "pc_cacheLimitMB") == nil && app.effectiveCacheLimitMB >= 2_048,
              "cache: no chosen limit means the automatic one, at least 2 GB")

        // room for the thumbnails and about half the previews
        app.cacheLimitMB = Int((previewBytes / 2) >> 20) + 2
        let limit = Int64(app.cacheLimitMB) << 20
        @MainActor func backfill() {
            app.runsBackgroundMaintenance = true
            app.backfillThumbnails()
            CheckWait.until(backgroundPass) { !app.isBackfilling }
            // a pass still running would be read as finished below, and taken for the next pass
            check(!app.isBackfilling, "cache: the background pass ends within \(Int(backgroundPass)) s")
            CheckWait.until(2) { false }   // the prune after the pass
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

        // the next launch's pass finds the cache full and makes nothing, and paces itself by what it
        // makes: a run of cached photos goes through without a pause and a Task Center update every
        // 8 photos (which kept a cached 14,000-photo catalog's pass going for over 35 s). The
        // updates are counted, not timed: each update mid-pass is followed by its 10 ms pause, and
        // those 100 ms are less than the background lane's own delays on a busy Mac.
        let before = Dictionary(uniqueKeysWithValues: files(in: store.cacheURL).map { ($0.url.path, $0.modified) })
        app.configureTaskHistory()
        let publishes = TaskListPublishes(app)
        app.runsBackgroundMaintenance = true
        let generation = app.backfillGeneration
        app.backfillThumbnails()
        check(app.backfillGeneration != generation, "cache: the second pass starts")
        CheckWait.until(backgroundPass, poll: 0.002) { !app.isBackfilling }
        // from the update saying it runs, the second: not the 750 ms it waits for the window first
        let elapsed = publishes.times.count > 1 ? Date().timeIntervalSince(publishes.times[1]) : .infinity
        let published = publishes.times.count
        CheckWait.until(2) { false }   // the prune after the pass
        app.runsBackgroundMaintenance = false
        let after = Dictionary(uniqueKeysWithValues: files(in: store.cacheURL).map { ($0.url.path, $0.modified) })
        check(before == after, "cache: a second pass makes and deletes nothing")
        // queued, running and done, and at most one update on the way (8 before: one every 8 photos)
        check(published <= 4, "cache: a pass over cached photos updates the Task Center a few times (\(published), "
              + (elapsed.isFinite ? "\(Int(elapsed * 1000)) ms" : "never ran") + ")")

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

        // a lower limit chosen while a pass makes previews, newest photos first: the prunes then
        // and at the end of the pass keep the newest photos' previews, which the pass wrote first
        for file in files(in: previews) { try? fm.removeItem(at: file.url) }
        app.cacheLimitMB = Int(limit >> 20)
        app.runsBackgroundMaintenance = true
        app.backfillThumbnails()
        CheckWait.until(backgroundPass) { !app.isBackfilling || files(in: previews).count >= 3 }
        let lower = Int64(Int((thumbnailBytes + previewBytes / 4) >> 20) + 1) << 20
        app.cacheLimitMB = Int(lower >> 20)
        app.enforceCacheLimitIfNeeded()
        CheckWait.until(backgroundPass) { !app.isBackfilling }
        CheckWait.until(2) { false }   // the prune after the pass
        app.runsBackgroundMaintenance = false
        let kept = Set(files(in: previews).map { $0.url.deletingPathExtension().lastPathComponent })
        let byDate = real.sorted { $0.date > $1.date }
        check(!kept.isEmpty && kept.contains(byDate[0].id) && !kept.contains(byDate[count - 1].id)
              && files(in: store.cacheURL).reduce(Int64(0)) { $0 + $1.size } <= lower,
              "cache: a prune while the pass runs keeps the newest photos' previews (\(kept.count) kept)")
    }

    private struct CachedFile {
        let url: URL
        let size: Int64
        let modified: Date
    }

    /// The cache files in `folder`, less one being written (`.tmp-…`, not a cached image yet).
    private static func files(in folder: URL) -> [CachedFile] {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey]
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys)
        return (enumerator?.compactMap { $0 as? URL } ?? []).compactMap { url in
            guard !url.lastPathComponent.hasPrefix(".tmp-"),
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
            return CachedFile(url: url, size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast)
        }
    }

    /// How long a background pass is waited for, in seconds: on a loaded Mac one took over a minute.
    private static let backgroundPass: TimeInterval = 180

    /// When `app` set its task list (`backgroundTasks`), each time from when this is made.
    @MainActor
    private final class TaskListPublishes {
        private(set) var times: [Date] = []
        private weak var app: AppState?

        init(_ app: AppState) {
            self.app = app
            observe()
        }

        private func observe() {
            guard let app else { return }
            withObservationTracking { _ = app.backgroundTasks } onChange: { [weak self] in
                // called as the list is set, on the main thread: watching again at once misses
                // no later update
                MainActor.assumeIsolated {
                    self?.times.append(Date())
                    self?.observe()
                }
            }
        }
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
