import XCTest
@testable import PhotoCatalog

/// The folder tree lists each source's subfolders in the order of their whole paths. Its build
/// sorts siblings by name and only checks the result, so it must list exactly what the full sort
/// did: same folders, depths and order, for every path shape.
final class FolderTreeBuildTests: XCTestCase {
    // ---- the build and adding as they were, the oracle ----

    private enum Old {
        static func build(sourceFolders: [Folder], assets: [Asset], sourceRootPaths: [String: String]) -> [FolderTreeItem] {
            let live = assets.filter { !$0.deleted && !$0.isDemo }
            var result: [FolderTreeItem] = []
            for source in sourceFolders {
                result.append(FolderTreeItem(id: source.id, sourceId: source.id, name: source.name,
                                             status: source.status, depth: 0, directoryPath: nil))
                guard let rootPath = normalizedDirectory(sourceRootPaths[source.id]) else { continue }
                var discovered: [String: Int] = [:]
                var directories = Set<String>()
                for asset in live where asset.folderId == source.id {
                    guard let localPath = asset.localPath else { continue }
                    directories.insert(PathString.directory(of: localPath))
                }
                for directory in directories {
                    let assetDir = FolderTreeService.normalizedPath(PathString.standardized(directory))
                    guard assetDir != rootPath, isDescendant(assetDir, of: rootPath) else { continue }
                    var current = rootPath
                    for (index, component) in relativeComponents(from: rootPath, to: assetDir).enumerated() {
                        current = (current as NSString).appendingPathComponent(component)
                        discovered[current] = index + 1
                    }
                }
                for path in discovered.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                    result.append(FolderTreeItem(id: "subfolder:" + path, sourceId: source.id,
                                                 name: PathString.lastComponent(path), status: source.status,
                                                 depth: discovered[path] ?? 1, directoryPath: path))
                }
            }
            return result
        }

        static func adding(_ assets: [Asset], to tree: [FolderTreeItem], sourceRootPaths: [String: String]) -> [FolderTreeItem] {
            let listed = Set(tree.lazy.map(\.id))
            let sources = Set(tree.lazy.filter { $0.directoryPath == nil }.map(\.sourceId))
            var discovered: [String: [String: Int]] = [:]
            for asset in assets where !asset.deleted && !asset.isDemo && sources.contains(asset.folderId) {
                guard let rootPath = normalizedDirectory(sourceRootPaths[asset.folderId]),
                      let localPath = asset.localPath else { continue }
                let assetDir = FolderTreeService.normalizedPath(PathString.standardized(PathString.directory(of: localPath)))
                guard assetDir != rootPath, isDescendant(assetDir, of: rootPath),
                      !listed.contains("subfolder:" + assetDir) else { continue }
                var current = rootPath
                for (index, component) in relativeComponents(from: rootPath, to: assetDir).enumerated() {
                    current = (current as NSString).appendingPathComponent(component)
                    if !listed.contains("subfolder:" + current) { discovered[asset.folderId, default: [:]][current] = index + 1 }
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
                    for item in tree[start + 1 ..< end] {
                        if let path = item.directoryPath { depths[path] = item.depth }
                    }
                    for path in depths.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                        result.append(FolderTreeItem(id: "subfolder:" + path, sourceId: source.sourceId,
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

        static func normalizedDirectory(_ path: String?) -> String? {
            guard let path, !path.isEmpty else { return nil }
            return FolderTreeService.normalizedPath(PathString.standardized(path))
        }

        static func isDescendant(_ path: String, of root: String) -> Bool { path.hasPrefix(pathPrefix(root)) }

        static func relativeComponents(from root: String, to path: String) -> [String] {
            let prefix = pathPrefix(root)
            guard path.hasPrefix(prefix) else { return [] }
            return path.dropFirst(prefix.count).split(separator: "/").map(String.init)
        }

        static func pathPrefix(_ root: String) -> String { root == "/" ? "/" : root + "/" }
    }

    // ---- fixtures ----

    private func photo(_ index: Int, in source: String, at path: String?, deleted: Bool = false, demo: Bool = false) -> Asset {
        var asset = Asset.smallPhoto("p\(index)", filename: "IMG_\(index).JPG", type: "JPG", folderId: source,
                                     folderName: source, date: Date(timeIntervalSince1970: 1_700_000_000),
                                     localPath: path ?? "", isDemo: demo)
        if path == nil { asset.localPath = nil }
        asset.deleted = deleted
        return asset
    }

    private func assertSameTree(_ folders: [Folder], _ photos: [Asset], _ roots: [String: String],
                                file: StaticString = #filePath, line: UInt = #line) {
        let expected = Old.build(sourceFolders: folders, assets: photos, sourceRootPaths: roots)
        let built = FolderTreeService.build(sourceFolders: folders, assets: photos, sourceRootPaths: roots)
        XCTAssertEqual(built, expected, file: file, line: line)
        if built != expected {
            for (a, b) in zip(built, expected) where a != b {
                XCTFail("first difference: \(a.id) ≠ \(b.id)", file: file, line: line)
                break
            }
        }
    }

    /// Names whose whole-path order isn't their order as siblings: a name that runs on past its
    /// sibling's with a space, hyphen, dot or underscore; case, accents (composed and not), width
    /// and numbers; CJK and emoji.
    private static let trickyNames = [
        "a", "a b", "a-b", "a.b", "a_b", "a (2)", "A", "á", "a\u{301}", "Ab", "ab", "aB",
        "2", "10", "02", "1", "1.5", "１０", "２", "2024", "2024-01-01", "2024 trip", "2024_x", "2024.1",
        "旅行", "旅行 2", "東京", "café", "cafe\u{301}", "Cafe", "😀", ".hidden", "~tmp", "z",
    ]

    func testHandPickedShapes() {
        let folders = [Folder(id: "s1", name: "One"), Folder(id: "s2", name: "Two", status: "offline"),
                       Folder(id: "s3", name: "Root"), Folder(id: "s4", name: "No root"), Folder(id: "s5", name: "Slash")]
        let roots = ["s1": "/Volumes/Photos", "s2": "/Users/me/Pictures/My Trips/", "s3": "/", "s5": "/Volumes/Photos/a"]
        var photos: [Asset] = []
        var index = 0
        func add(_ source: String, _ path: String?, deleted: Bool = false, demo: Bool = false) {
            photos.append(photo(index, in: source, at: path, deleted: deleted, demo: demo))
            index += 1
        }
        for name in Self.trickyNames {
            add("s1", "/Volumes/Photos/\(name)/IMG.JPG")
            add("s1", "/Volumes/Photos/\(name)/child/IMG.JPG")
            add("s1", "/Volumes/Photos/\(name)/\(name)/deeper/still/IMG.JPG")
            add("s2", "/Users/me/Pictures/My Trips/\(name)/x/IMG.JPG")
        }
        add("s1", "/Volumes/Photos/IMG.JPG")                       // in the root itself
        add("s1", "/Volumes/Other/IMG.JPG")                        // outside it
        add("s1", "/Volumes/PhotosX/IMG.JPG")                      // a sibling that starts the same
        add("s1", "/Volumes/Photos//a//double/IMG.JPG")            // unclean
        add("s1", "/Volumes/Photos/a/./dot/../dotdot/IMG.JPG")
        add("s1", nil)
        add("s1", "/Volumes/Photos/deleted/IMG.JPG", deleted: true)
        add("s1", "/Volumes/Photos/demo/IMG.JPG", demo: true)
        add("s3", "/top/IMG.JPG")
        add("s3", "/top/2/IMG.JPG")
        add("s3", "/top/10/IMG.JPG")
        add("s4", "/anywhere/IMG.JPG")
        add("s5", "/Volumes/Photos/a/b/IMG.JPG")
        add("s5", "/Volumes/Photos/a b/IMG.JPG")
        assertSameTree(folders, photos, roots)
        // the shapes that put a subfolder after its parent's sibling are among these
        let tree = FolderTreeService.build(sourceFolders: folders, assets: photos, sourceRootPaths: roots)
        let paths = tree.compactMap(\.directoryPath).filter { $0.hasPrefix("/Volumes/Photos/") }
        XCTAssertTrue(paths.contains("/Volumes/Photos/a/child"))
        XCTAssertLessThan(paths.firstIndex(of: "/Volumes/Photos/a b")!, paths.firstIndex(of: "/Volumes/Photos/a/child")!)
    }

    /// Seeded random trees of the tricky names, several sources, some of them nested in others.
    func testRandomTreesListAsTheFullSortDid() {
        var generator = SplitMix(seed: 0xf01d)
        let folders = [Folder(id: "a", name: "A"), Folder(id: "b", name: "B"), Folder(id: "c", name: "C")]
        let roots = ["a": "/Volumes/X", "b": "/Volumes/X/a", "c": "/"]
        for round in 0..<60 {
            var photos: [Asset] = []
            for index in 0..<Int.random(in: 1...150, using: &generator) {
                let source = folders.randomElement(using: &generator)!.id
                let depth = Int.random(in: 0...4, using: &generator)
                let names = (0..<depth).map { _ in Self.trickyNames.randomElement(using: &generator)! }
                let base = source == "c" ? "" : roots[source]!
                let path = ([base] + names + ["IMG_\(index).JPG"]).joined(separator: "/")
                photos.append(photo(index, in: source, at: path))
            }
            let expected = Old.build(sourceFolders: folders, assets: photos, sourceRootPaths: roots)
            XCTAssertEqual(FolderTreeService.build(sourceFolders: folders, assets: photos, sourceRootPaths: roots),
                           expected, "round \(round)")

            // the same photos arriving in two batches, the second added to the first's tree (with
            // sources nested in each other, a folder listed under one isn't added to another, as before)
            let split = photos.count / 2
            let first = Old.build(sourceFolders: folders, assets: Array(photos[..<split]), sourceRootPaths: roots)
            let rest = Array(photos[split...])
            XCTAssertEqual(FolderTreeService.adding(rest, to: first, sourceRootPaths: roots),
                           Old.adding(rest, to: first, sourceRootPaths: roots), "round \(round), adding")
        }
    }

    /// The scale catalog's shape (years of dated folders, ~48k of them at 50k photos): the
    /// siblings-by-name order is the listing order already, so `listingOrder` takes it after one
    /// comparison per folder instead of sorting every whole path.
    func testDatedFoldersNeedNoFullSort() {
        let root = "/Volumes/ScaleBench/Root3"
        var subfolders: [String: [(name: String, path: String)]] = [:]
        var all: [String] = []
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        for year in 2016...2025 {
            let yearPath = "\(root)/\(year)"
            subfolders[root, default: []].append(("\(year)", yearPath))
            all.append(yearPath)
            for day in stride(from: 0, to: 365, by: 3) {
                let name = formatter.string(from: Date(timeIntervalSince1970: Double((year - 1970) * 365 + day) * 86_400))
                guard name.hasPrefix("\(year)") else { continue }
                subfolders[yearPath, default: []].append((name, "\(yearPath)/\(name)"))
                all.append("\(yearPath)/\(name)")
            }
        }
        let presorted = FolderTreeService.depthFirst(from: root, subfolders)
        let sorted = all.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending })
        XCTAssertEqual(presorted, sorted)
    }
}

/// A seeded generator, so a failing round is the same on every run.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49eb_133b_111f
        return z ^ (z >> 31)
    }
}
