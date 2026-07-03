import Foundation

enum PathIdentity {
    static func aliases(forPath path: String) -> Set<String> {
        aliases(for: URL(fileURLWithPath: path))
    }

    static func aliases(for url: URL) -> Set<String> {
        var paths: Set<String> = [
            url.path,
            url.standardizedFileURL.path,
            url.resolvingSymlinksInPath().path,
        ]
        if let canonical = canonicalPath(for: url) {
            paths.insert(canonical)
        }
        return paths
    }

    private static func canonicalPath(for url: URL) -> String? {
        try? url.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath
    }
}
