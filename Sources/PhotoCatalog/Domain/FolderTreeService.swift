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
            // photos share folders: each folder's path is worked out once, not once per photo
            var directories = Set<String>()
            for asset in live where asset.folderId == source.id {
                guard let localPath = asset.localPath else { continue }
                directories.insert(PathString.directory(of: localPath))
            }
            for directory in directories {
                let assetDir = normalizedPath(PathString.standardized(directory))
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
                                             name: PathString.lastComponent(path),
                                             status: source.status,
                                             depth: discovered[path] ?? 1,
                                             directoryPath: path))
            }
        }

        return result
    }

    /// Whether `build` would make `tree` again with `assets` among the photos: none of them is in
    /// a folder under its source that the tree doesn't have yet (photos added to a folder already
    /// listed, as an import batch nearly always is, change no folder but their own counts).
    static func covers(_ assets: ArraySlice<Asset>, in tree: [FolderTreeItem], sourceRootPaths: [String: String]) -> Bool {
        struct Place: Hashable { let source: String; let directory: String }
        var sources = Set<String>()
        var places = Set<Place>()
        for item in tree {
            if let directoryPath = item.directoryPath {
                places.insert(Place(source: item.sourceId, directory: directoryPath))
            } else {
                sources.insert(item.sourceId)
            }
        }
        for asset in assets where !asset.deleted && !asset.isDemo && sources.contains(asset.folderId) {
            guard let rootPath = normalizedDirectory(sourceRootPaths[asset.folderId]),
                  let localPath = asset.localPath else { continue }
            let assetDir = normalizedPath(PathString.standardized(PathString.directory(of: localPath)))
            guard assetDir != rootPath, isDescendant(assetDir, of: rootPath) else { continue }
            // `build` lists the folder and every one between it and the source: all there when it is
            guard places.contains(Place(source: asset.folderId, directory: assetDir)) else { return false }
        }
        return true
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
                guard let localPath = asset.localPath, directoryIdsBySource[asset.folderId] != nil else { continue }
                perPlace[Place(source: asset.folderId, directory: PathString.directory(of: localPath)), default: 0] += 1
            }
            if run > 0 { perSource[source, default: 0] += run }
            return (perSource, perPlace)
        }
        var perSource: [String: Int] = [:]
        var perPlace: [Place: Int] = [:]
        let chunk = max(chunk, 1)
        let chunks = assets.isEmpty ? 0 : (assets.count - 1) / chunk + 1
        if chunks > 1 {
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: chunks) { index in
                let part = count(index * chunk ..< min(assets.count, (index + 1) * chunk))
                lock.withLock {
                    perSource.merge(part.sources, uniquingKeysWith: +)
                    perPlace.merge(part.places, uniquingKeysWith: +)
                }
            }
        } else {
            (perSource, perPlace) = count(assets.indices)
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
