// ============================================================
//  FileScanner — recursive enumeration + supported-type detection
//  (PRD §6.3 IMP-001, §12.2 scan rules, §12.3 supported types)
// ============================================================
import Foundation
import UniformTypeIdentifiers

enum FileScanner {
    /// Extensions we always accept as a fallback when UTType can't classify.
    private static let rawExtensions: Set<String> = [
        "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "dng", "pef", "srw", "raw",
    ]
    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "gif", "webp", "bmp",
    ]

    /// Directory / package names to skip while enumerating. Genuine library package internals
    /// are already excluded by the enumerator's .skipsPackageDescendants; a bare "Thumbnails"
    /// here would also prune an ordinary user folder of that name, silently dropping its photos.
    private static let skipNames: Set<String> = [
        ".photolibrary", ".lrdata", ".lrcat", ".Trash",
    ]

    static func isSupported(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if rawExtensions.contains(ext) || imageExtensions.contains(ext) { return true }
        if let type = UTType(filenameExtension: ext) {
            return type.conforms(to: .image) || type.conforms(to: .rawImage)
        }
        return false
    }

    /// Recursively enumerate `root`, returning supported image file URLs.
    static func scan(_ root: URL, onProgress: ((Int) -> Void)? = nil) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        guard let en = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }

        var results: [URL] = []
        for case let url as URL in en {
            let name = url.lastPathComponent
            if skipNames.contains(name) {
                en.skipDescendants()
                continue
            }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir { continue }
            if isSupported(url) {
                results.append(url)
                onProgress?(results.count)
            }
        }
        return results
    }
}
