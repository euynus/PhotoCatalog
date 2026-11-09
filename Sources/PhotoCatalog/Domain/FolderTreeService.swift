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
            var subfolders: [String: [(name: String, path: String)]] = [:]   // by parent, as found
            // photos share folders: each folder's path is worked out once, not once per photo
            var directories = Set<String>()
            for asset in live where asset.folderId == source.id {
                guard let localPath = asset.localPath else { continue }
                directories.insert(PathString.directory(of: localPath))
            }
            for directory in directories {
                let assetDir = normalizedPath(PathString.standardized(directory))
                // a folder found already came with every folder above it
                guard assetDir != rootPath, discovered[assetDir] == nil, isDescendant(assetDir, of: rootPath) else { continue }

                var current = rootPath
                for (index, component) in relativeComponents(from: rootPath, to: assetDir).enumerated() {
                    let parent = current
                    current = (current as NSString).appendingPathComponent(component)
                    if discovered.updateValue(index + 1, forKey: current) == nil {
                        subfolders[parent, default: []].append((component, current))
                    }
                }
            }

            for path in listingOrder(discovered.keys, presorted: depthFirst(from: rootPath, subfolders)) {
                result.append(FolderTreeItem(id: subfolderId(for: path),
                                             sourceId: source.id,
                                             name: PathString.lastComponent(path),
                                             status: source.status,
                                             depth: discovered[path] ?? 1,
                                             directoryPath: path))
            }
        }

        return result
    }

    /// The ids of the subfolders `build` lists for `assets` in `tree`'s sources (live photos in a
    /// folder under their source's own): the folders a photo leaves when it's moved or removed.
    static func subfolderIds(of assets: some Sequence<Asset>, in tree: [FolderTreeItem],
                             sourceRootPaths: [String: String]) -> Set<String> {
        let sources = Set(tree.lazy.filter { $0.directoryPath == nil }.map(\.sourceId))
        var ids = Set<String>()
        for asset in assets where !asset.deleted && !asset.isDemo && sources.contains(asset.folderId) {
            guard let rootPath = normalizedDirectory(sourceRootPaths[asset.folderId]),
                  let localPath = asset.localPath else { continue }
            let assetDir = assetDirectoryPath(localPath)
            guard assetDir != rootPath, isDescendant(assetDir, of: rootPath) else { continue }
            ids.insert(subfolderId(for: assetDir))
        }
        return ids
    }

    /// `tree` with the folders `assets` are in that it hasn't got yet, and those between them and
    /// their source, as `build` would list them with those photos among the others: a source's
    /// subfolders in order again, with its status.
    static func adding(_ assets: some Sequence<Asset>, to tree: [FolderTreeItem],
                       sourceRootPaths: [String: String]) -> [FolderTreeItem] {
        let listed = Set(tree.lazy.map(\.id))
        let sources = Set(tree.lazy.filter { $0.directoryPath == nil }.map(\.sourceId))
        var discovered: [String: [String: Int]] = [:]   // a source's folders to add → their depth
        for asset in assets where !asset.deleted && !asset.isDemo && sources.contains(asset.folderId) {
            guard let rootPath = normalizedDirectory(sourceRootPaths[asset.folderId]),
                  let localPath = asset.localPath else { continue }
            let assetDir = assetDirectoryPath(localPath)
            guard assetDir != rootPath, isDescendant(assetDir, of: rootPath),
                  !listed.contains(subfolderId(for: assetDir)) else { continue }
            var current = rootPath
            for (index, component) in relativeComponents(from: rootPath, to: assetDir).enumerated() {
                current = (current as NSString).appendingPathComponent(component)
                if !listed.contains(subfolderId(for: current)) { discovered[asset.folderId, default: [:]][current] = index + 1 }
            }
        }
        guard !discovered.isEmpty else { return tree }
        var result: [FolderTreeItem] = []
        var start = 0
        while start < tree.count {
            var end = start + 1
            while end < tree.count, tree[end].directoryPath != nil { end += 1 }
            let source = tree[start]
            result.append(source)
            if source.directoryPath == nil, let added = discovered[source.sourceId] {
                var depths = added
                var listedPaths: [String] = []
                for item in tree[start + 1 ..< end] {
                    if let path = item.directoryPath, depths.updateValue(item.depth, forKey: path) == nil {
                        listedPaths.append(path)
                    }
                }
                // the source's listed folders are in order already: the new ones are sorted in
                let presorted = listedPaths + added.keys.sorted(by: inListingOrder)
                for path in listingOrder(depths.keys, presorted: presorted) {
                    result.append(FolderTreeItem(id: subfolderId(for: path), sourceId: source.sourceId,
                                                 name: PathString.lastComponent(path), status: source.status,
                                                 depth: depths[path] ?? 1, directoryPath: path))
                }
            } else {
                result += tree[start + 1 ..< end]
            }
            start = end
        }
        return result
    }

    /// `tree` with each source's rows showing its status in `folders`.
    static func withStatuses(of folders: [Folder], in tree: [FolderTreeItem]) -> [FolderTreeItem] {
        let statuses = Dictionary(folders.map { ($0.id, $0.status) }, uniquingKeysWith: { first, _ in first })
        return tree.map { item in
            guard let status = statuses[item.sourceId], status != item.status else { return item }
            return FolderTreeItem(id: item.id, sourceId: item.sourceId, name: item.name, status: status,
                                  depth: item.depth, directoryPath: item.directoryPath)
        }
    }

    static func matches(_ asset: Asset, item: FolderTreeItem) -> Bool {
        guard asset.folderId == item.sourceId else { return false }
        guard let directoryPath = item.directoryPath else { return true }
        guard let localPath = asset.localPath else { return false }
        let assetDir = assetDirectoryPath(localPath)
        return assetDir == directoryPath || isDescendant(assetDir, of: directoryPath)
    }

    static func counts(for items: [FolderTreeItem], assets: [Asset]) -> [String: Int] {
        counts(for: items, assets: assets, pairing: .empty)
    }

    /// Each item's photos among `assets` as `pairing` shows them, counted in chunks on every core
    /// (one thread took ~0.3 s at 500k photos, and the sidebar waits for it after every import batch).
    static func counts(for items: [FolderTreeItem], assets: [Asset], pairing: AssetPairing,
                       chunk: Int = 32_768) -> [String: Int] {
        var counts = Dictionary(uniqueKeysWithValues: items.map { ($0.id, 0) })
        var rootIdsBySource: [String: [String]] = [:]
        var directoryIdsBySource: [String: [String: String]] = [:]

        for item in items {
            if let directoryPath = item.directoryPath {
                directoryIdsBySource[item.sourceId, default: [:]][directoryPath] = item.id
            } else {
                rootIdsBySource[item.sourceId, default: []].append(item.id)
            }
        }

        // photos share folders: count them per source and folder first, then walk each folder's
        // ancestors once rather than once per photo
        struct Place: Hashable { let source: String; let directory: String }
        let withSubfolders = Set(directoryIdsBySource.keys)   // a constant the threads read, not a variable
        func count(_ range: Range<Int>) -> (sources: [String: Int], places: [Place: Int]) {
            var perSource: [String: Int] = [:]
            var perPlace: [Place: Int] = [:]
            // a run of photos from one source is added once, not hashed photo by photo
            var source = "", run = 0
            for position in range {
                let asset = assets[position]
                guard pairing.isShown(asset, at: position) else { continue }
                if asset.folderId != source {
                    if run > 0 { perSource[source, default: 0] += run }
                    source = asset.folderId
                    run = 0
                }
                run += 1
                guard let localPath = asset.localPath, withSubfolders.contains(asset.folderId) else { continue }
                perPlace[Place(source: asset.folderId, directory: PathString.directory(of: localPath)), default: 0] += 1
            }
            if run > 0 { perSource[source, default: 0] += run }
            return (perSource, perPlace)
        }
        let parts = Chunks.map(assets.count, chunk: chunk, count)
        var (perSource, perPlace) = parts.first ?? ([:], [:])
        for part in parts.dropFirst() {
            perSource.merge(part.sources, uniquingKeysWith: +)
            perPlace.merge(part.places, uniquingKeysWith: +)
        }
        for (source, number) in perSource {
            for rootId in rootIdsBySource[source] ?? [] {
                counts[rootId, default: 0] += number
            }
        }
        for (place, number) in perPlace {
            guard let directoryIds = directoryIdsBySource[place.source] else { continue }
            var current = normalizedPath(PathString.standardized(place.directory))
            while true {
                if let id = directoryIds[current] {
                    counts[id, default: 0] += number
                }
                let parent = (current as NSString).deletingLastPathComponent
                if parent.isEmpty || parent == current { break }
                current = normalizedPath(parent)
            }
        }

        return counts
    }

    /// The order the tree lists a source's folders in: the Finder's order of their whole paths.
    static func inListingOrder(_ a: String, _ b: String) -> Bool {
        a.localizedStandardCompare(b) == .orderedAscending
    }

    /// `paths` in listing order, given them nearly in it. When each folder in `presorted` comes
    /// before the next, that is the order (one comparison per folder, where sorting 48,000 whole
    /// paths took ~16 and a second); otherwise they are sorted, which the runs in order speed up.
    /// Either way the answer is the sort of `paths` by `inListingOrder`, as it always was.
    static func listingOrder(_ paths: Dictionary<String, Int>.Keys, presorted: [String]) -> [String] {
        guard presorted.count == paths.count else { return paths.sorted(by: inListingOrder) }
        if zip(presorted, presorted.dropFirst()).allSatisfy({ inListingOrder($0, $1) }) { return presorted }
        return presorted.sorted(by: inListingOrder)
    }

    /// The folders under `root`, each followed by its own, siblings in the Finder's order of their
    /// names: the listing order, except where a name runs on past a sibling's (a folder "a" with
    /// subfolders before "a b"), which `listingOrder` puts right.
    static func depthFirst(from root: String, _ subfolders: [String: [(name: String, path: String)]]) -> [String] {
        func sorted(_ folders: [(name: String, path: String)]?) -> [String] {
            (folders ?? []).sorted { inListingOrder($0.name, $1.name) }.map(\.path)
        }
        var order: [String] = []
        var pending = Array(sorted(subfolders[root]).reversed())
        while let path = pending.popLast() {
            order.append(path)
            pending += sorted(subfolders[path]).reversed()
        }
        return order
    }

    private static func subfolderId(for path: String) -> String {
        subfolderPrefix + path
    }

    private static func normalizedDirectory(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return normalizedPath(PathString.standardized(path))
    }

    private static func assetDirectoryPath(_ path: String) -> String {
        normalizedPath(PathString.standardized(PathString.directory(of: path)))
    }

    /// Without a trailing slash: "/a/" → "/a"; "/" stays.
    static func normalizedPath(_ path: String) -> String {
        // most paths don't end in a slash, which the last byte tells without counting characters
        guard path.utf8.count > 1, path.utf8.last == UInt8(ascii: "/"), path.count > 1 else { return path }
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
