import XCTest
@testable import PhotoCatalog

/// The sidebar's Collections tree: sets, then albums, then smart albums under each parent, in the
/// catalog's order; anything filed in a set that doesn't exist at the top; sets caught in a
/// parent loop listed once.
final class CollectionNodeBuildTests: XCTestCase {
    /// The tree as it was built before each parent's contents were grouped once: every list
    /// filtered for every set. The oracle.
    private static func oldBuild(sets: [AlbumSet], albums: [Album], smart: [SmartAlbum]) -> [CollectionNode] {
        let known = Set(sets.map(\.id))
        func parent(_ id: String?) -> String? { id.flatMap { known.contains($0) ? $0 : nil } }
        var placed = Set<String>()
        func nodes(in parentId: String?) -> [CollectionNode] {
            let childSets = sets.filter { parent($0.parentId) == parentId && !placed.contains($0.id) }
            childSets.forEach { placed.insert($0.id) }
            return childSets.map { CollectionNode(item: .set($0), children: nodes(in: $0.id)) }
                + albums.filter { parent($0.setId) == parentId }.map { CollectionNode(item: .album($0), children: nil) }
                + smart.filter { parent($0.setId) == parentId }.map { CollectionNode(item: .smart($0), children: nil) }
        }
        var top = nodes(in: nil)
        for set in sets where !placed.contains(set.id) {
            placed.insert(set.id)
            top.append(CollectionNode(item: .set(set), children: nodes(in: set.id)))
        }
        return top
    }

    /// One line per node, indented by depth; a set's line ends in "/" (it has children, maybe
    /// none), an album's doesn't.
    private static func outline(_ nodes: [CollectionNode], depth: Int = 0) -> [String] {
        nodes.flatMap { node in
            [String(repeating: "  ", count: depth) + node.id + (node.children == nil ? "" : "/")]
                + outline(node.children ?? [], depth: depth + 1)
        }
    }

    private static func smartAlbum(_ id: String, in setId: String?) -> SmartAlbum {
        SmartAlbum(id: id, name: id, rule: SmartRule(conditions: []), count: 0, setId: setId)
    }

    func testNestedSetsAlbumsAndSmartAlbumsInOrder() {
        let sets = [AlbumSet(id: "trips", name: "Trips"), AlbumSet(id: "2024", name: "2024", parentId: "trips"),
                    AlbumSet(id: "work", name: "Work"), AlbumSet(id: "2023", name: "2023", parentId: "trips")]
        let albums = [Album(id: "rome", name: "Rome", assetIds: [], setId: "2024"),
                      Album(id: "loose", name: "Loose", assetIds: []),
                      Album(id: "oslo", name: "Oslo", assetIds: [], setId: "2024"),
                      Album(id: "summary", name: "Summary", assetIds: [], setId: "trips")]
        let smart = [Self.smartAlbum("best", in: "trips"), Self.smartAlbum("recent", in: nil),
                     Self.smartAlbum("raw", in: "2024")]
        let expected = [
            "set:trips/", "  set:2024/", "    album:rome", "    album:oslo", "    smart:raw", "  set:2023/",
            "  album:summary", "  smart:best", "set:work/", "album:loose", "smart:recent",
        ]
        XCTAssertEqual(Self.outline(Self.oldBuild(sets: sets, albums: albums, smart: smart)), expected)
        XCTAssertEqual(Self.outline(CollectionNode.build(sets: sets, albums: albums, smart: smart)), expected)
    }

    func testItemsFiledInAnUnknownSetShowAtTheTop() {
        let sets = [AlbumSet(id: "kept", name: "Kept"), AlbumSet(id: "orphan", name: "Orphan", parentId: "gone")]
        let albums = [Album(id: "a", name: "A", assetIds: [], setId: "gone"), Album(id: "b", name: "B", assetIds: [], setId: "kept")]
        let smart = [Self.smartAlbum("s", in: "deleted")]
        let expected = ["set:kept/", "  album:b", "set:orphan/", "album:a", "smart:s"]
        XCTAssertEqual(Self.outline(Self.oldBuild(sets: sets, albums: albums, smart: smart)), expected)
        XCTAssertEqual(Self.outline(CollectionNode.build(sets: sets, albums: albums, smart: smart)), expected)
    }

    func testAParentLoopIsListedOnce() {
        let sets = [AlbumSet(id: "a", name: "A", parentId: "b"), AlbumSet(id: "b", name: "B", parentId: "a"),
                    AlbumSet(id: "c", name: "C", parentId: "b"), AlbumSet(id: "top", name: "Top")]
        let albums = [Album(id: "in-a", name: "In A", assetIds: [], setId: "a"), Album(id: "in-b", name: "In B", assetIds: [], setId: "b")]
        let expected = ["set:top/", "set:a/", "  set:b/", "    set:c/", "    album:in-b", "  album:in-a"]
        XCTAssertEqual(Self.outline(Self.oldBuild(sets: sets, albums: albums, smart: [])), expected)
        XCTAssertEqual(Self.outline(CollectionNode.build(sets: sets, albums: albums, smart: [])), expected)
    }

    /// Random forests with loops, unknown parents, self-parents and repeated ids build the same
    /// tree as the oracle does.
    func testRandomCollectionsBuildAsTheOracleDoes() {
        var generator = SplitMix(seed: 0x5eed)
        for round in 0..<200 {
            let setCount = Int.random(in: 0...30, using: &generator)
            let ids = (0..<setCount).map { "s\($0)" } + ["missing", "s0"]
            func someParent() -> String? { Bool.random(using: &generator) ? nil : ids.randomElement(using: &generator) }
            let sets = (0..<setCount).map { _ in AlbumSet(id: "s\(Int.random(in: 0...setCount, using: &generator))", name: "", parentId: someParent()) }
            let albums = (0..<Int.random(in: 0...40, using: &generator)).map { Album(id: "a\($0)", name: "", assetIds: [], setId: someParent()) }
            let smart = (0..<Int.random(in: 0...10, using: &generator)).map { Self.smartAlbum("m\($0)", in: someParent()) }
            XCTAssertEqual(Self.outline(CollectionNode.build(sets: sets, albums: albums, smart: smart)),
                           Self.outline(Self.oldBuild(sets: sets, albums: albums, smart: smart)), "round \(round)")
        }
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
