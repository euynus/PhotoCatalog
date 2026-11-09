// ============================================================
//  PathString — file-path arithmetic without touching the disk
// ============================================================
import Foundation

/// String-only path helpers for catalog-wide loops. `URL(fileURLWithPath:)` stats every path
/// to learn whether it is a directory — a system call per photo, seconds at 500k photos.
/// Catalog paths are absolute and already standardized, so plain string work is exact.
/// Each helper reads the path's bytes first and works through its characters only when the
/// bytes can't decide: counting characters took most of a pass over the photos.
enum PathString {
    /// "/a/b/c.jpg" → "/a/b"; "/c.jpg" → "/".
    static func directory(of path: String) -> String {
        if let slash = lastSlash(in: path) {
            return slash == 0 ? "/" : String(path[..<path.utf8.index(path.utf8.startIndex, offsetBy: slash)])
        }
        let trimmed = trimmingTrailingSlashes(path)
        guard let slash = trimmed.lastIndex(of: "/") else { return "." }
        return slash == trimmed.startIndex ? "/" : String(trimmed[..<slash])
    }

    /// "/a/b/c.jpg" → "c.jpg".
    static func lastComponent(_ path: String) -> String {
        if let slash = lastSlash(in: path) {
            return String(path[path.utf8.index(path.utf8.startIndex, offsetBy: slash + 1)...])
        }
        let trimmed = trimmingTrailingSlashes(path)
        guard let slash = trimmed.lastIndex(of: "/") else { return trimmed }
        return String(trimmed[trimmed.index(after: slash)...])
    }

    /// Where `path`'s last slash is among its bytes, when it has plain ASCII on both sides (and
    /// so is a character of its own, where the characters split the path) and the path doesn't end
    /// in a slash, as catalog paths' does: nil for other paths.
    static func lastSlash(in path: String) -> Int? {
        let slash = path.utf8.withContiguousStorageIfAvailable { bytes -> Int? in
            guard let last = bytes.last, last != UInt8(ascii: "/"),
                  let slash = bytes.lastIndex(of: UInt8(ascii: "/")),
                  bytes[slash + 1] < 0x80, slash == 0 || bytes[slash - 1] < 0x80 else { return nil }
            return slash
        }
        return slash ?? nil
    }

    /// "/a/b/c.JPG" → ("/a/b/c", "JPG"); no extension → (path, "").
    static func splitExtension(_ path: String) -> (stem: Substring, ext: Substring) {
        // scan UTF-8 bytes ("/" and "." are ASCII), not grapheme clusters
        let utf8 = path.utf8
        let nameStart = utf8.lastIndex(of: UInt8(ascii: "/")).map { utf8.index(after: $0) } ?? utf8.startIndex
        // a leading dot names a hidden file, not an extension
        guard let dot = utf8[nameStart...].lastIndex(of: UInt8(ascii: ".")), dot > nameStart else { return (path[...], "") }
        return (path[..<dot], path[path.index(after: dot)...])
    }

    /// Lexical standardization ("//", "/./", "/../" resolved) like `URL.standardized`, with a
    /// fast path for paths that are already clean — which catalog paths almost always are.
    static func standardized(_ path: String) -> String {
        // the patterns are ASCII: a path without them among its bytes has none among its characters
        if mightNeedResolving(path) {
            let clean = !path.contains("//") && !path.contains("/./") && !path.contains("/../")
                && !path.hasSuffix("/.") && !path.hasSuffix("/..")
            guard clean else {
                return trimmingTrailingSlashes(URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL.path)
            }
        }
        // drop the /private of macOS's /var, /tmp and /etc firmlinks, as URL standardization
        // does for paths that exist — always, so both sides of a path comparison agree
        if path.utf8.starts(with: "/private/".utf8) {
            for firmlink in firmlinks where path == firmlink || path.hasPrefix(firmlink + "/") {
                return trimmingTrailingSlashes(String(path.dropFirst("/private".count)))
            }
        }
        return trimmingTrailingSlashes(path)
    }

    private static let firmlinks = ["/private/var", "/private/tmp", "/private/etc"]

    /// Whether the path's bytes hold "//", "/./" or "/../", or end in "/." or "/..": what
    /// `standardized` resolves.
    private static func mightNeedResolving(_ path: String) -> Bool {
        path.utf8.withContiguousStorageIfAvailable { bytes -> Bool in
            let (slash, dot) = (UInt8(ascii: "/"), UInt8(ascii: "."))
            var index = 0
            while let found = bytes[index...].firstIndex(of: slash) {
                index = found + 1
                guard index < bytes.count else { return false }
                if bytes[index] == slash { return true }
                guard bytes[index] == dot else { continue }
                // "/." or "/.." at the end or before a slash
                var end = index + 1
                if end < bytes.count, bytes[end] == dot { end += 1 }
                if end == bytes.count || bytes[end] == slash { return true }
            }
            return false
        } ?? true
    }

    private static func trimmingTrailingSlashes(_ path: String) -> String {
        // most paths don't end in a slash, which the last byte tells without counting characters
        guard path.utf8.last == UInt8(ascii: "/") else { return path }
        var result = Substring(path)
        while result.count > 1, result.hasSuffix("/") { result = result.dropLast() }
        return String(result)
    }
}
