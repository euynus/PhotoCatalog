// ============================================================
//  CacheService — thumbnail/preview cache maintenance.
// ============================================================
import Foundation

struct CachePruneReport: Sendable {
    let beforeBytes: Int64
    let afterBytes: Int64
    let removedFiles: Int

    var removedBytes: Int64 { max(0, beforeBytes - afterBytes) }
}

enum CacheService {
    static func prune(_ cacheURL: URL, maxBytes: Int64) -> CachePruneReport {
        let files = cacheFiles(in: cacheURL)
        let before = files.reduce(Int64(0)) { $0 + $1.size }
        guard maxBytes > 0, before > maxBytes else {
            return CachePruneReport(beforeBytes: before, afterBytes: before, removedFiles: 0)
        }

        var current = before
        var removed = 0
        let fm = FileManager.default
        for file in files.sorted(by: { $0.modifiedAt < $1.modifiedAt }) where current > maxBytes {
            do {
                try fm.removeItem(at: file.url)
                current -= file.size
                removed += 1
            } catch {
                continue
            }
        }
        return CachePruneReport(beforeBytes: before, afterBytes: max(0, current), removedFiles: removed)
    }

    private static func cacheFiles(in cacheURL: URL) -> [CacheFile] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: cacheURL, includingPropertiesForKeys: keys) else {
            return []
        }
        return enumerator.compactMap { item -> CacheFile? in
            guard let url = item as? URL,
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { return nil }
            return CacheFile(url: url,
                             size: Int64(values.fileSize ?? 0),
                             modifiedAt: values.contentModificationDate ?? .distantPast)
        }
    }
}

private struct CacheFile {
    let url: URL
    let size: Int64
    let modifiedAt: Date
}
