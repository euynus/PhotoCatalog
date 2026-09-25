// ============================================================
//  PathString — file-path arithmetic without touching the disk
// ============================================================
import Foundation

/// String-only path helpers for catalog-wide loops. `URL(fileURLWithPath:)` stats every path
/// to learn whether it is a directory — a system call per photo, seconds at 500k photos.
/// Catalog paths are absolute and already standardized, so plain string work is exact.
enum PathString {
    /// "/a/b/c.jpg" → "/a/b"; "/c.jpg" → "/".
    static func directory(of path: String) -> String {
        let trimmed = trimmingTrailingSlashes(path)
        guard let slash = trimmed.lastIndex(of: "/") else { return "." }
        return slash == trimmed.startIndex ? "/" : String(trimmed[..<slash])
    }

    /// "/a/b/c.jpg" → "c.jpg".
    static func lastComponent(_ path: String) -> String {
        let trimmed = trimmingTrailingSlashes(path)
        guard let slash = trimmed.lastIndex(of: "/") else { return trimmed }
        return String(trimmed[trimmed.index(after: slash)...])
    }

    /// "/a/b/c.JPG" → ("/a/b/c", "JPG"); no extension → (path, "").
    static func splitExtension(_ path: String) -> (stem: Substring, ext: Substring) {
        let nameStart = path.lastIndex(of: "/").map { path.index(after: $0) } ?? path.startIndex
        // a leading dot names a hidden file, not an extension
        guard let dot = path[nameStart...].lastIndex(of: "."), dot > nameStart else { return (path[...], "") }
        return (path[..<dot], path[path.index(after: dot)...])
    }

    /// Lexical standardization ("//", "/./", "/../" resolved) like `URL.standardized`, with a
    /// fast path for paths that are already clean — which catalog paths almost always are.
    static func standardized(_ path: String) -> String {
        let clean = !path.contains("//") && !path.contains("/./") && !path.contains("/../")
            && !path.hasSuffix("/.") && !path.hasSuffix("/..")
        guard clean else {
            return trimmingTrailingSlashes(URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL.path)
        }
        // drop the /private of macOS's /var, /tmp and /etc firmlinks, as URL standardization
        // does for paths that exist — always, so both sides of a path comparison agree
        for firmlink in ["/private/var", "/private/tmp", "/private/etc"]
        where path == firmlink || path.hasPrefix(firmlink + "/") {
            return trimmingTrailingSlashes(String(path.dropFirst("/private".count)))
        }
        return trimmingTrailingSlashes(path)
    }

    private static func trimmingTrailingSlashes(_ path: String) -> String {
        var result = Substring(path)
        while result.count > 1, result.hasSuffix("/") { result = result.dropLast() }
        return String(result)
    }
}
