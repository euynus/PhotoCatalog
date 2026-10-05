// ============================================================
//  FileAccessService — security-scoped bookmarks (PRD §12.1)
//  Works for sandboxed builds; harmless for the non-sandboxed dev build.
// ============================================================
import Foundation

enum FileAccessService {
    static func createBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [.withSecurityScope],
                              includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func resolveBookmark(_ data: Data) -> (url: URL, isStale: Bool)? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        return (url, stale)
    }
}
