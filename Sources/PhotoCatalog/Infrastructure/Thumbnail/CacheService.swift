// ============================================================
//  CacheService — thumbnail/preview cache maintenance.
// ============================================================
import Foundation

struct CachePruneReport: Sendable {
    let beforeBytes: Int64
    let afterBytes: Int64
    let removedFiles: Int
    /// The limit the cache was held to.
    let maxBytes: Int64
    /// Files still being written, left out of the sizes above: with them, the cache's whole size.
    let writingBytes: Int64

    var removedBytes: Int64 { max(0, beforeBytes - afterBytes) }
}

/// How large the thumbnail and preview cache may grow: the limit chosen in Settings, or one that
/// follows the catalog. A pass over the cache (a backfill, a prune) works it out once, as it
/// starts, from the cache's size then.
struct CacheLimit: Sendable {
    /// What Settings offers, in MB; the automatic limit stays inside it too.
    static let rangeMB = 256...102_400
    static let floorMB = 2_048

    /// The limit chosen in Settings, in MB; 0 for the automatic one.
    var chosenMB: Int
    var photos: Int
    var previewMaxPixel: Int
    /// The catalog, for the free space on its volume.
    var volume: URL?

    /// The limit for a cache that takes `cacheBytes` now.
    func megabytes(cacheBytes: Int64) -> Int {
        guard chosenMB <= 0 else { return chosenMB }
        return Self.automaticMB(photos: photos, previewMaxPixel: previewMaxPixel,
                                freeBytes: volume.flatMap(Self.freeBytes(on:)), cacheBytes: cacheBytes)
    }

    func bytes(cacheBytes: Int64) -> Int64 {
        Int64(megabytes(cacheBytes: cacheBytes)) * 1_048_576
    }

    /// Room for a thumbnail and a preview of every photo (about 0.5 MB together at 2048 px), so
    /// previews aren't pruned and made again from the originals each time a photo is opened; a
    /// flat 2 GB held a quarter of a 14,000-photo catalog's. Never under 2 GB, never over what
    /// Settings offers, and never over a quarter of the cache's room on its volume: the free space
    /// and what the cache takes already, so the limit doesn't shrink as the cache fills and a pass
    /// doesn't end by pruning the previews it just made. Free space unknown (reported as 0): 2 GB.
    static func automaticMB(photos: Int, previewMaxPixel: Int, freeBytes: Int64?, cacheBytes: Int64) -> Int {
        let needed = photos * (previewMaxPixel >= 2_048 ? 512 : 384) / 1_024
        guard let freeBytes, freeBytes > 0 else { return floorMB }
        let room = Int((freeBytes + max(0, cacheBytes)) / 4 / 1_048_576)
        return min(rangeMB.upperBound, max(floorMB, min(needed, room)))
    }

    /// The space free on `url`'s volume. Not the free space "for important usage": that counts
    /// what the system could purge (86 GB with 13 GB free, measured) and is 0 on other volumes.
    static func freeBytes(on url: URL) -> Int64? {
        guard let free = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity,
              free > 0 else { return nil }
        return Int64(free)
    }
}

enum CacheService {
    static func prune(_ cacheURL: URL, maxBytes: Int64) -> CachePruneReport {
        prune(cacheURL) { _ in maxBytes }
    }

    /// Prunes to the limit `maxBytes` gives for the cache's size as found. Of each kind, the files
    /// of the photos taken longest ago go first, as `captureDates` (by photo id) dates them, so a
    /// prune keeps the newest photos' previews, as the background pass makes them; files of no
    /// photo there go before those, and among the rest the oldest written go first. Not by when
    /// a file was written alone: the background pass writes the newest photos' previews first.
    /// A file of no photo there written since `orphansWrittenBefore` is a new photo's, which an
    /// import writes before it adds the photo: it counts as the newest, and is kept longest.
    static func prune(_ cacheURL: URL, captureDates: [String: Date] = [:], orphansWrittenBefore: Date? = nil,
                      maxBytes limit: (Int64) -> Int64) -> CachePruneReport {
        let (files, writingBytes) = cacheFiles(in: cacheURL)
        let before = files.reduce(Int64(0)) { $0 + $1.size }
        let maxBytes = limit(before)
        guard maxBytes > 0, before > maxBytes else {
            return CachePruneReport(beforeBytes: before, afterBytes: before, removedFiles: 0, maxBytes: maxBytes,
                                    writingBytes: writingBytes)
        }

        var current = before
        var removed = 0
        let fm = FileManager.default
        // previews go first and thumbnails last: the grid needs a thumbnail for every photo,
        // while a preview is only wanted when one photo is opened, and is remade then
        let ranked = files.map { file -> (file: CacheFile, taken: Date) in
            guard !captureDates.isEmpty else { return (file, .distantPast) }
            if let taken = captureDates[file.photoId] { return (file, taken) }
            let isNew = orphansWrittenBefore.map { file.modifiedAt >= $0 } ?? false
            return (file, isNew ? .distantFuture : .distantPast)
        }
        for (file, _) in ranked.sorted(by: {
            ($0.file.evictionRank, $0.taken, $0.file.modifiedAt) < ($1.file.evictionRank, $1.taken, $1.file.modifiedAt)
        }) where current > maxBytes {
            do {
                try fm.removeItem(at: file.url)
                current -= file.size
                removed += 1
            } catch {
                continue
            }
        }
        return CachePruneReport(beforeBytes: before, afterBytes: max(0, current), removedFiles: removed,
                                maxBytes: maxBytes, writingBytes: writingBytes)
    }

    /// The cache's size, and how much of it is plain thumbnails (`Thumbnails/`, not developed
    /// ones), in one walk. Counts every file, as `CatalogHealth.directorySize` does.
    static func usage(_ cacheURL: URL) -> (total: Int64, thumbnails: Int64) {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: cacheURL, includingPropertiesForKeys: keys) else {
            return (0, 0)
        }
        let root = enumeratedPath(of: cacheURL)
        var total: Int64 = 0, thumbnails: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            total += size
            if relativePath(url, to: root).hasPrefix("/Thumbnails/") { thumbnails += size }
        }
        return (total, thumbnails)
    }

    /// How long a file being written into the cache (`.tmp-…`, moved into place once encoded)
    /// is left to its writer; one older than that was left by a crash.
    static let writingGrace: TimeInterval = 600

    /// The cache's files, less those being written, whose sizes come back apart.
    private static func cacheFiles(in cacheURL: URL) -> (files: [CacheFile], writingBytes: Int64) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: cacheURL, includingPropertiesForKeys: keys) else {
            return ([], 0)
        }
        let root = enumeratedPath(of: cacheURL)
        let writing = Date().addingTimeInterval(-writingGrace)
        var writingBytes: Int64 = 0
        let files = enumerator.compactMap { item -> CacheFile? in
            guard let url = item as? URL,
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { return nil }
            if url.lastPathComponent.hasPrefix(".tmp-"), (values.contentModificationDate ?? .distantPast) > writing {
                writingBytes += Int64(values.fileSize ?? 0)
                return nil
            }
            let relative = relativePath(url, to: root)
            let edited = relative.hasPrefix("/Edited/")
            // "<id>.jpg", or developed "<id>-<settings fingerprint>.jpg" (the fingerprint has no "-")
            var photoId = Substring(url.deletingPathExtension().lastPathComponent)
            if edited, let dash = photoId.lastIndex(of: "-") { photoId = photoId[..<dash] }
            return CacheFile(url: url,
                             size: Int64(values.fileSize ?? 0),
                             modifiedAt: values.contentModificationDate ?? .distantPast,
                             evictionRank: relative.contains("/Thumbnails/") ? 2 : edited ? 1 : 0,
                             photoId: String(photoId))
        }
        return (files, writingBytes)
    }

    /// The cache folder's path as its enumerator hands back what's in it: links resolved, /tmp as
    /// /private/tmp. Not `resolvingSymlinksInPath`, which takes the /private off again.
    private static func enumeratedPath(of cacheURL: URL) -> String {
        (try? cacheURL.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath)
            ?? cacheURL.resolvingSymlinksInPath().path
    }

    /// `url`'s path below the cache folder `root`, starting with "/".
    private static func relativePath(_ url: URL, to root: String) -> Substring {
        url.path.hasPrefix(root) ? url.path.dropFirst(root.count) : Substring(url.path)
    }
}

private struct CacheFile {
    let url: URL
    let size: Int64
    let modifiedAt: Date
    /// Which files a prune removes first: previews (and anything else), then developed
    /// previews, then thumbnails, plain or developed.
    let evictionRank: Int
    /// The photo it shows, by id.
    let photoId: String
}
