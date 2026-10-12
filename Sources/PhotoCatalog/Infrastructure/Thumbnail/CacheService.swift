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

    /// Prunes to the limit `maxBytes` gives for the cache's size as found.
    static func prune(_ cacheURL: URL, maxBytes limit: (Int64) -> Int64) -> CachePruneReport {
        let files = cacheFiles(in: cacheURL)
        let before = files.reduce(Int64(0)) { $0 + $1.size }
        let maxBytes = limit(before)
        guard maxBytes > 0, before > maxBytes else {
            return CachePruneReport(beforeBytes: before, afterBytes: before, removedFiles: 0, maxBytes: maxBytes)
        }

        var current = before
        var removed = 0
        let fm = FileManager.default
        // previews go first and thumbnails last: the grid needs a thumbnail for every photo,
        // while a preview is only wanted when one photo is opened, and is remade then
        for file in files.sorted(by: { ($0.evictionRank, $0.modifiedAt) < ($1.evictionRank, $1.modifiedAt) })
        where current > maxBytes {
            do {
                try fm.removeItem(at: file.url)
                current -= file.size
                removed += 1
            } catch {
                continue
            }
        }
        return CachePruneReport(beforeBytes: before, afterBytes: max(0, current), removedFiles: removed,
                                maxBytes: maxBytes)
    }

    private static func cacheFiles(in cacheURL: URL) -> [CacheFile] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: cacheURL, includingPropertiesForKeys: keys) else {
            return []
        }
        // the enumerator hands back resolved paths (/tmp → /private/tmp)
        let root = cacheURL.resolvingSymlinksInPath().path
        return enumerator.compactMap { item -> CacheFile? in
            guard let url = item as? URL,
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { return nil }
            let relative = url.path.hasPrefix(root) ? url.path.dropFirst(root.count) : Substring(url.path)
            return CacheFile(url: url,
                             size: Int64(values.fileSize ?? 0),
                             modifiedAt: values.contentModificationDate ?? .distantPast,
                             evictionRank: relative.contains("/Thumbnails/") ? 2 : relative.hasPrefix("/Edited/") ? 1 : 0)
        }
    }
}

private struct CacheFile {
    let url: URL
    let size: Int64
    let modifiedAt: Date
    /// Which files a prune removes first: previews (and anything else), then developed
    /// previews, then thumbnails, plain or developed.
    let evictionRank: Int
}
