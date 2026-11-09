import XCTest
@testable import PhotoCatalog

/// The whole-catalog passes split their photos into chunks worked out side by side and join the
/// parts in catalog order. Whatever the chunk (one photo, a few, the default, more than there
/// are photos), each must give exactly what one serial pass gives.
final class ChunkedPassEquivalenceTests: XCTestCase {
    /// Chunk sizes that split the small catalog everywhere: one photo, small primes, a power of two.
    private static let sweep = [1, 2, 3, 5, 7, 11, 13, 64]

    private struct Random {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func pick<T>(_ values: [T]) -> T { values[Int(next() % UInt64(values.count))] }
        mutating func chance(_ percent: UInt64) -> Bool { next() % 100 < percent }
    }

    private static let sources: [(id: String, root: String)] = [
        ("card", "/Volumes/Card/DCIM"), ("home", "/Users/me/Pictures/日本"), ("photos", "/Photos"),
    ]
    private static let subfolders = ["2026/01", "2026/02", "2026/02/Café", "2026/02/Cafe\u{301}", "旅行", "a b", ""]

    /// `count` photos in runs of one shot: a RAW alone or with its JPEG, sometimes edited copies,
    /// sometimes a burst; spread over sources and subfolders (some beyond ASCII), with keywords
    /// (Chinese, and one in NFC and NFD), projects, clients and cameras with spaces or in two
    /// Unicode forms, and removed photos, virtual copies, photos without a path, missing files.
    static func catalog(_ count: Int, seed: UInt64) -> [Asset] {
        var random = Random(state: seed)
        let start = Date(timeIntervalSince1970: 1_760_000_000)
        let keywords = ["trip", "Trip", "旅行", "家人", "café", "cafe\u{301}", "猫", "sunset", "雪"]
        let projects = ["", "", "", "Wedding", " Wedding ", "婚礼", "Café", "Cafe\u{301}"]
        let cameras = ["Canon EOS R5", "Canon EOS R5", "SONY ILCE-7M4", "", "Café Cam", "Cafe\u{301} Cam"]
        let lenses = ["", "RF 50mm", "FE 24-70", "镜头"]
        var photos: [Asset] = []
        photos.reserveCapacity(count + 8)
        var shot = 0
        var time = start.timeIntervalSince1970
        func photo(_ name: String, ext: String, raw: Bool, source: (id: String, root: String), folder: String,
                   camera: String, at seconds: TimeInterval, random: inout Random) -> Asset {
            let directory = folder.isEmpty ? source.root : source.root + "/" + folder
            let id = "p\(photos.count)"
            return Asset(id: id, pid: 0, ori: "l", thumb: "", preview: "", filename: "\(name).\(ext)", type: ext,
                         isRaw: raw, folderId: source.id, folderName: source.id,
                         date: Date(timeIntervalSince1970: seconds), width: 1, height: 1, orientation: 1,
                         camera: camera, lens: random.pick(lenses), focal: 1, aperture: 1, shutter: "", iso: 1,
                         colorSpace: "", fileMB: 1, rating: Int(random.next() % 6),
                         flag: random.pick([.none, .none, .pick, .reject]),
                         keywords: (0 ..< random.next() % 4).map { _ in random.pick(keywords) },
                         title: "", caption: "", project: random.pick(projects), client: random.pick(projects),
                         location: "", gps: random.chance(20) ? (35.6, 139.7) : (0, 0),
                         status: random.chance(3) ? .missing : random.chance(2) ? .offline : .ready,
                         importedAt: start.addingTimeInterval(Double(random.next() % 400) * 86_400),
                         deleted: random.chance(3), localPath: random.chance(1) ? nil : directory + "/\(name).\(ext)",
                         isDemo: false, faces: random.chance(10) ? 1 : 0,
                         masterId: random.chance(2) && !photos.isEmpty ? photos[0].id : nil)
        }
        while photos.count < count {
            shot += 1
            // days apart, hours apart or a burst a second apart; now and then far in the past
            time += random.pick([0.5, 1, 1, 30, 3_600, 86_400, 5 * 86_400])
            let at = random.chance(1) ? -12_000_000_000 + time : time
            let source = random.pick(sources)
            let folder = random.pick(subfolders)
            let camera = random.pick(cameras)
            let name = random.pick(["IMG_\(shot)", "img_\(shot)", "照片\(shot)", "Café\(shot)"])
            let raw = random.chance(60)
            photos.append(photo(name, ext: raw ? "CR3" : "JPG", raw: raw, source: source, folder: folder,
                                camera: camera, at: at, random: &random))
            if raw, random.chance(50) {
                photos.append(photo(name, ext: random.pick(["JPG", "jpg", "HEIC"]), raw: false, source: source,
                                    folder: folder, camera: camera, at: at + 0.5, random: &random))
            }
            if random.chance(8) {
                photos.append(photo(name + random.pick(["-Edit", "-编辑", "-Edit (2)"]), ext: "tif", raw: false,
                                    source: source, folder: folder, camera: "", at: at + 600, random: &random))
            }
        }
        return Array(photos.prefix(count))
    }

    /// The source and subfolder items of the catalog's sources, as the folder tree lists them: one
    /// item for the folder named in NFC and NFD, the two being one `String`.
    private static func folderItems() -> [FolderTreeItem] {
        sources.flatMap { source in
            [FolderTreeItem(id: source.id, sourceId: source.id, name: source.id, status: "online", depth: 0,
                            directoryPath: nil)]
                + ["2026/01", "2026/02", "2026/02/Café", "旅行", "a b"].map { folder in
                    let path = PathString.standardized(source.root + "/" + folder)
                    return FolderTreeItem(id: "subfolder:" + path, sourceId: source.id, name: folder, status: "online",
                                          depth: 1, directoryPath: path)
                }
        }
    }

    /// Photos counted as duplicates of one another: every 37th with the next two.
    private static func duplicates(_ photos: [Asset]) -> [DuplicateGroup] {
        stride(from: 0, to: photos.count - 2, by: 37).map { start in
            DuplicateGroup(id: "dup-\(start)", method: "contentHash", score: 1, items: Array(photos[start ..< start + 3]))
        }
    }

    // ---------- pairing ----------

    /// A pairing worked out in any chunk is the serial one, keys included; so is a pairing carried
    /// on to photos added after the others, whose keys start partway into the photos.
    func testPairingAtAnyChunkIsTheSerialPairing() {
        for photos in [Self.catalog(700, seed: 1), AssetPairingOracleTests.tangle(700, seed: 7)] {
            let serial = AssetPairing.rawJpeg(photos, chunk: .max)
            XCTAssertFalse(serial.isEmpty, "the photos pair")
            for chunk in Self.sweep + [photos.count, photos.count + 1] {
                XCTAssertEqual(AssetPairing.rawJpeg(photos, chunk: chunk), serial, "chunks of \(chunk)")
            }
            XCTAssertEqual(AssetPairing.rawJpeg(photos), serial, "the default chunk")
            for start in [0, 1, 250, 699, 700] {
                let before = AssetPairing.rawJpeg(Array(photos[..<start]), chunk: .max)
                var expected = before
                let expectedFlips = expected.append(photos, from: start, chunk: .max)
                XCTAssertNotNil(expectedFlips)
                XCTAssertEqual(expected, serial, "carried on from \(start)")
                for chunk in Self.sweep + [photos.count - start + 1] {
                    var carried = before
                    XCTAssertEqual(carried.append(photos, from: start, chunk: chunk), expectedFlips,
                                   "from \(start), chunks of \(chunk)")
                    XCTAssertEqual(carried, expected, "from \(start), chunks of \(chunk)")
                }
            }
        }
    }

    // ---------- sidebar counts ----------

    func testSidebarCountsAtAnyChunkAreTheSerialCounts() {
        let photos = Self.catalog(700, seed: 2)
        let pairing = AssetPairing.rawJpeg(photos)
        let cutoff = Date(timeIntervalSince1970: 1_760_000_000 + 200 * 86_400)
        let faces = Set(photos.indices.filter { $0 % 11 == 0 }.map { photos[$0].id })
        let items = Self.folderItems()

        let keywords = AppState.keywordCounts(of: photos, pairing: pairing, chunk: .max)
        XCTAssertGreaterThan(keywords.order.count, 5)
        let library = AppState.libraryCounts(photos, pairing: pairing, recentCutoff: cutoff, withFaces: faces, chunk: .max)
        let fields: [KeyPath<Asset, String>] = [\.project, \.client, \.camera, \.lens]
        let metadata = fields.map { AppState.metadataCounts(photos, pairing: pairing, $0, chunk: .max) }
        let days = CaptureDates.dayCounts(photos, pairing: pairing, chunk: .max)
        let folders = FolderTreeService.counts(for: items, assets: photos, pairing: pairing, chunk: .max)
        XCTAssertGreaterThan(folders.values.filter { $0 > 0 }.count, 10, "photos in most folders")

        for chunk in Self.sweep + [photos.count, photos.count + 1] {
            let counted = AppState.keywordCounts(of: photos, pairing: pairing, chunk: chunk)
            XCTAssertEqual(counted.order, keywords.order, "keyword order, chunks of \(chunk)")
            XCTAssertEqual(counted.counts, keywords.counts, "keyword counts, chunks of \(chunk)")
            XCTAssertEqual(counted.first, keywords.first, "keywords' first photos, chunks of \(chunk)")
            XCTAssertEqual(AppState.libraryCounts(photos, pairing: pairing, recentCutoff: cutoff, withFaces: faces,
                                                  chunk: chunk), library, "library, chunks of \(chunk)")
            for (field, expected) in zip(fields, metadata) {
                XCTAssertEqual(AppState.metadataCounts(photos, pairing: pairing, field, chunk: chunk), expected,
                               "\(field), chunks of \(chunk)")
            }
            XCTAssertEqual(CaptureDates.dayCounts(photos, pairing: pairing, chunk: chunk), days, "days, chunks of \(chunk)")
            XCTAssertEqual(FolderTreeService.counts(for: items, assets: photos, pairing: pairing, chunk: chunk), folders,
                           "folders, chunks of \(chunk)")
        }
    }

    // ---------- stacks ----------

    func testStackPassesAtAnyChunkAreTheSerialPasses() {
        let photos = Self.catalog(700, seed: 3)
        let pairing = AssetPairing.rawJpeg(photos)
        let shown = photos.filter(pairing.shows)

        let edits = EditedVersions.groups(photos, chunk: .max)
        XCTAssertGreaterThan(edits.count, 5, "edited copies stack with their originals")
        let groups = edits + Self.duplicates(photos)
        let captureTime = PhotoStackService.captureTimeGroups(shown, within: 2)
        XCTAssertGreaterThan(captureTime.count, 20, "bursts")
        let stacks = PhotoStackService.stacks(from: groups, captureTimeGroups: captureTime, chunk: .max)
        let collapsed = Set(stacks.indices.filter { $0 % 2 == 0 }.map { stacks[$0].id })
        let folded = PhotoStackService.visibleAssets(photos, stacks: stacks, collapsedStackIds: collapsed, chunk: .max)
        XCTAssertLessThan(folded.count, photos.count)
        let order = AppState.captureOrder(of: photos, pairing: pairing, chunk: .max, run: .max)

        func ids(_ groups: [DuplicateGroup]) -> [[String]] { groups.map { [$0.id, $0.method] + $0.items.map(\.id) } }
        for chunk in Self.sweep + [photos.count, photos.count + 1] {
            XCTAssertEqual(ids(EditedVersions.groups(photos, chunk: chunk)), ids(edits), "edited copies, chunks of \(chunk)")
            XCTAssertEqual(PhotoStackService.stacks(from: groups, captureTimeGroups: captureTime, chunk: chunk), stacks,
                           "stacks, chunks of \(chunk)")
            XCTAssertEqual(PhotoStackService.visibleAssets(photos, stacks: stacks, collapsedStackIds: collapsed,
                                                           chunk: chunk).map(\.id), folded.map(\.id),
                           "folded, chunks of \(chunk)")
            let chunked = AppState.captureOrder(of: photos, pairing: pairing, chunk: chunk, run: .max)
            XCTAssertEqual(chunked.keys, order.keys, "capture order, chunks of \(chunk)")
            XCTAssertEqual(chunked.ranks, order.ranks, "camera ranks, chunks of \(chunk)")
        }
        // no photos at all
        XCTAssertEqual(AppState.captureOrder(of: [], pairing: .empty, chunk: 3).keys, [])
        XCTAssertEqual(PhotoStackService.stacks(from: [], chunk: 3), [])
        XCTAssertTrue(EditedVersions.groups([], chunk: 3).isEmpty)
    }

    // ---------- the defaults ----------

    /// A catalog larger than every pass's default chunk, so each default splits it.
    func testDefaultChunksSplitALargeCatalogAsOnePassWould() {
        let photos = Self.catalog(40_000, seed: 4)
        let serialPairing = AssetPairing.rawJpeg(photos, chunk: .max)
        let pairing = AssetPairing.rawJpeg(photos)
        XCTAssertEqual(pairing, serialPairing, "pairing")
        let cutoff = Date(timeIntervalSince1970: 1_760_000_000 + 200 * 86_400)
        let items = Self.folderItems()

        let keywords = AppState.keywordCounts(of: photos, pairing: pairing)
        let serialKeywords = AppState.keywordCounts(of: photos, pairing: pairing, chunk: .max)
        XCTAssertEqual(keywords.order, serialKeywords.order)
        XCTAssertEqual(keywords.counts, serialKeywords.counts)
        XCTAssertEqual(keywords.first, serialKeywords.first)
        XCTAssertEqual(AppState.libraryCounts(photos, pairing: pairing, recentCutoff: cutoff),
                       AppState.libraryCounts(photos, pairing: pairing, recentCutoff: cutoff, chunk: .max))
        for field: KeyPath<Asset, String> in [\.project, \.camera] {
            XCTAssertEqual(AppState.metadataCounts(photos, pairing: pairing, field),
                           AppState.metadataCounts(photos, pairing: pairing, field, chunk: .max), "\(field)")
        }
        XCTAssertEqual(CaptureDates.dayCounts(photos, pairing: pairing),
                       CaptureDates.dayCounts(photos, pairing: pairing, chunk: .max))
        XCTAssertEqual(FolderTreeService.counts(for: items, assets: photos, pairing: pairing),
                       FolderTreeService.counts(for: items, assets: photos, pairing: pairing, chunk: .max))

        func ids(_ groups: [DuplicateGroup]) -> [[String]] { groups.map { [$0.id, $0.method] + $0.items.map(\.id) } }
        let edits = EditedVersions.groups(photos)
        XCTAssertEqual(ids(edits), ids(EditedVersions.groups(photos, chunk: .max)), "edited copies")
        let captureTime = PhotoStackService.captureTimeGroups(photos.filter(pairing.shows), within: 2)
        let stacks = PhotoStackService.stacks(from: edits, captureTimeGroups: captureTime)
        XCTAssertGreaterThan(stacks.count, 4_096, "more stacks than a default chunk")
        XCTAssertEqual(stacks, PhotoStackService.stacks(from: edits, captureTimeGroups: captureTime, chunk: .max))
        let collapsed = Set(stacks.map(\.id))
        XCTAssertEqual(PhotoStackService.visibleAssets(photos, stacks: stacks, collapsedStackIds: collapsed).map(\.id),
                       PhotoStackService.visibleAssets(photos, stacks: stacks, collapsedStackIds: collapsed, chunk: .max)
                           .map(\.id))
        let order = AppState.captureOrder(of: photos, pairing: pairing)
        let serialOrder = AppState.captureOrder(of: photos, pairing: pairing, chunk: .max)
        XCTAssertEqual(order.keys, serialOrder.keys)
        XCTAssertEqual(order.ranks, serialOrder.ranks)
    }
}
