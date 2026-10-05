// ============================================================
//  FileAccessService — security-scoped bookmarks (PRD §12.1)
//  Works for sandboxed builds; harmless for the non-sandboxed dev build.
// ============================================================
import AppKit
import Foundation

extension NSOpenPanel {
    /// Asks for one folder, which may be made in the panel; nil when cancelled.
    @MainActor static func chooseFolder(prompt: String? = nil, message: String? = nil, start: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if let prompt { panel.prompt = prompt }
        if let message { panel.message = message }
        if let start { panel.directoryURL = start }
        return panel.runModal() == .OK ? panel.url : nil
    }
}

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
