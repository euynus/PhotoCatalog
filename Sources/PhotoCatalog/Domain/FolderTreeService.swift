// ============================================================
//  FolderTreeService — derive source folder trees from indexed originals
//  without changing the catalog schema.
// ============================================================
import Foundation

enum FolderTreeService {
    private static let subfolderPrefix = "subfolder:"

    static func build(sourceFolders: [Folder], assets: [Asset],
                      sourceRootPaths: [String: String]) -> [FolderTreeItem] {
        let live = assets.filter { !$0.deleted && !$0.isDemo }
        var result: [FolderTreeItem] = []

        for source in sourceFolders {
            result.append(FolderTreeItem(id: source.id, sourceId: source.id, name: source.name,
                                         status: source.status, depth: 0, directoryPath: nil))
            guard let rootPath = normalizedDirectory(sourceRootPaths[source.id]) else { continue }

            var discovered: [String: Int] = [:]
            for asset in live where asset.folderId == source.id {
                guard let localPath = asset.localPath else { continue }
                let assetDir = assetDirectoryPath(localPath)
                guard assetDir != rootPath, isDescendant(assetDir, of: rootPath) else { continue }

                var current = rootPath
                for (index, component) in relativeComponents(from: rootPath, to: assetDir).enumerated() {
                    current = (current as NSString).appendingPathComponent(component)
                    discovered[current] = index + 1
                }
            }

            for path in discovered.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                result.append(FolderTreeItem(id: subfolderId(for: path),
                                             sourceId: source.id,
                                             name: URL(fileURLWithPath: path).lastPathComponent,
                                             status: source.status,
                                             depth: discovered[path] ?? 1,
                                             directoryPath: path))
            }
        }

        return result
    }

    static func matches(_ asset: Asset, item: FolderTreeItem) -> Bool {
        guard asset.folderId == item.sourceId else { return false }
        guard let directoryPath = item.directoryPath else { return true }
        guard let localPath = asset.localPath else { return false }
        let assetDir = assetDirectoryPath(localPath)
        return assetDir == directoryPath || isDescendant(assetDir, of: directoryPath)
    }

    private static func subfolderId(for path: String) -> String {
        subfolderPrefix + path
    }

    private static func normalizedDirectory(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return normalizedPath(URL(fileURLWithPath: path).standardizedFileURL.path)
    }

    private static func assetDirectoryPath(_ path: String) -> String {
        normalizedPath(URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path)
    }

    private static func normalizedPath(_ path: String) -> String {
        guard path.count > 1 else { return path }
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private static func isDescendant(_ path: String, of root: String) -> Bool {
        path.hasPrefix(pathPrefix(root))
    }

    private static func relativeComponents(from root: String, to path: String) -> [String] {
        let prefix = pathPrefix(root)
        guard path.hasPrefix(prefix) else { return [] }
        return path.dropFirst(prefix.count).split(separator: "/").map(String.init)
    }

    private static func pathPrefix(_ root: String) -> String {
        root == "/" ? "/" : root + "/"
    }
}
