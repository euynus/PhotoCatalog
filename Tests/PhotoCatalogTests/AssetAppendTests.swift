import XCTest
@testable import PhotoCatalog

/// Photos added at the end of the catalog (an import batch, a tethered shot, virtual copies) carry
/// what's derived from every photo on to themselves — the id index, the RAW+JPEG pairing, the
/// library, keyword, project, client, camera and lens counts, the sidebar's counts, the capture
/// dates and the folders — exactly as working it all out again would give it, including for the
/// earlier photos a new RAW hides or a second RAW of their name shows again.
final class AssetAppendTests: CatalogTestCase {
    private let shot = Date(timeIntervalSince1970: 1_791_800_000)
    private var root: URL { scratch.appendingPathComponent("Photos") }
    private let everything = ["index", "pairing", "library", "keywords", "projects", "clients", "cameras", "lenses",
                              "sidebar", "dates", "folder tree", "folder counts"]

    private func photo(_ id: String, _ file: String, raw: Bool? = nil, camera: String = "Canon EOS R5",
                       lens: String = "RF50mm F1.2 L USM", offset: TimeInterval = 0, rating: Int = 0,
                       flag: Flag = .none, keywords: [String] = [], project: String = "", client: String = "",
                       gps: (Double, Double) = (0, 0), status: AssetStatus = .ready, deleted: Bool = false) -> Asset {
        let ext = PathString.splitExtension(file).ext.uppercased()
        var asset = Asset(id: id, pid: 0, ori: "l", thumb: "", preview: "", filename: PathString.lastComponent(file),
                          type: ext, isRaw: raw ?? ["CR3", "NEF"].contains(ext), folderId: "src", folderName: "Photos",
                          date: shot.addingTimeInterval(offset), width: 6000, height: 4000, orientation: 1,
                          camera: camera, lens: lens, focal: 50, aperture: 2, shutter: "1/200", iso: 100,
                          colorSpace: "sRGB", fileMB: 1, rating: rating, flag: flag, keywords: keywords, title: "",
                          caption: "", location: Asset.locationLabel(gps.0 == 0 ? nil : gps), gps: gps,
                          status: status, importedAt: shot, deleted: deleted,
                          localPath: root.appendingPathComponent(file).path, isDemo: false)
        asset.project = project
        asset.client = client
        return asset
    }

    /// A catalog of one source folder with subfolders, smart albums and an album, every derived
    /// part of it worked out.
    @MainActor
    private func catalog() throws -> AppState {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try CatalogStore(packageURL: scratch.appendingPathComponent("Library.photolibrary"))
        try store.addSourceRoot(id: "src", displayName: "Photos", path: root.path, bookmark: nil)
        let app = AppState.selfCheckFixture(store: store)
        app.runsBackgroundMaintenance = false
        app.pairRawAndJpeg = true
        let photos = [
            photo("a1", "IMG_0001.CR3", rating: 4, flag: .pick, keywords: ["trip"], project: "Wedding", client: "Acme"),
            photo("a2r", "IMG_0002.CR3", keywords: ["trip", "beach"]),
            photo("a2j", "IMG_0002.JPG", keywords: ["trip", "beach"]),
            photo("a3j", "IMG_0003.JPG", offset: 20, keywords: ["home"], project: " Garden ", client: "Bob"),
            photo("a4j", "IMG_0004.JPG", offset: 30, keywords: ["trip"]),
            photo("a4h", "IMG_0004.HEIC", offset: 30, keywords: ["trip"], client: "Bob"),
            photo("a5j", "IMG_0005.JPG", camera: "Apple iPhone 15 Pro", lens: "iPhone back camera", offset: 3 * 3600),
            photo("a6r", "IMG_0006.CR3", offset: 60, rating: 3),
            photo("a6j", "IMG_0006.JPG", offset: 60, rating: 3, keywords: ["trip"]),
            photo("b1", "sub/IMG_0100.JPG", offset: 86_400, gps: (30.5, 114.3), status: .missing),
            photo("b2", "sub/deep/IMG_0101.CR3", offset: 2 * 86_400, rating: 2, flag: .reject, keywords: ["beach"]),
        ] + (0..<6).map {
            photo("f\($0)", "IMG_09\($0).JPG", offset: Double($0) * 40 * 86_400, rating: $0 % 3,
                  keywords: $0 % 2 == 0 ? ["trip"] : ["city"], project: $0 % 3 == 0 ? "Wedding" : "")
        }
        app.applyLoadedCatalogForScaleCheck(photos, from: store)
        app.duplicateGroupsCache = []
        func smart(_ id: String, _ field: String, _ op: String, _ value: String) -> SmartAlbum {
            SmartAlbum(id: id, name: id, rule: SmartRule(conditions: [SmartCondition(field: field, op: op, value: value)]),
                       count: 0)
        }
        app.smartAlbums = [smart("rated", "rating", ">=", "3"), smart("trip", "keywords", "包含", "trip"),
                           smart("picks", "flag", "=", "pick"), smart("wedding", "search", "包含", "Wedding"),
                           smart("canon", "camera", "包含", "canon")]
        app.albums = [Album(id: "album", name: "Album", assetIds: ["a3j", "a4j", "a4h", "n10"])]
        XCTAssertEqual(app.assets.count, photos.count)
        XCTAssertTrue(app.assetPairing.isHiddenCompanion("a2j") && app.assetPairing.isHiddenCompanion("a6j"))
        XCTAssertGreaterThan(app.folderTree.count, 2, "the source and its subfolders")
        work(app)
        return app
    }

    /// What the sidebar, the filter bar and the inspector read as the window redraws.
    @MainActor
    private func work(_ app: AppState) {
        _ = app.assetPairing
        _ = app.asset(id: "a1")
        _ = app.libraryCounts
        _ = app.keywordList
        _ = app.projectList
        _ = app.clientList
        _ = app.gearCounts
        _ = app.sidebarCounts
        _ = app.captureDateGroups
        for item in app.folderTree { _ = app.countForFolderTreeItem(item) }
    }

    /// Adds `photos` as an import batch does, then checks that what's derived was carried on as
    /// `held` says and is what a recount gives, and that the list and the id lookups follow.
    @MainActor
    private func append(_ photos: [Asset], to app: AppState, _ name: String, dropping dropped: [String] = [],
                        file: StaticString = #filePath, line: UInt = #line) {
        work(app)
        let rebuilds = (app.sidebarCountIndexRebuilds, app.metadataListRebuilds)
        app.appendAssets(photos)
        XCTAssertEqual(app.heldDerivedCaches, everything.filter { !dropped.contains($0) },
                       "\(name): carried on, not dropped", file: file, line: line)
        XCTAssertEqual(app.cachesDifferingFromRecount(), [], "\(name): as a recount gives", file: file, line: line)
        XCTAssertEqual(app.sidebarCounts, app.recountedSidebarCounts(), name, file: file, line: line)
        XCTAssertEqual(app.keywordList, app.recountedKeywordList(), name, file: file, line: line)
        let lists = app.recountedMetadataLists()
        XCTAssertEqual(app.projectList, lists.projects, name, file: file, line: line)
        XCTAssertEqual(app.clientList, lists.clients, name, file: file, line: line)
        XCTAssertEqual(app.captureDateGroups, CaptureDates.groups(app.assets.filter(app.assetPairing.shows)), name,
                       file: file, line: line)
        let sidebarRebuilt = dropped.contains("sidebar") ? 1 : 0
        let listsRebuilt = dropped.filter { ["projects", "clients"].contains($0) }.count
        XCTAssertEqual(app.sidebarCountIndexRebuilds, rebuilds.0 + sidebarRebuilt, name, file: file, line: line)
        XCTAssertEqual(app.metadataListRebuilds, rebuilds.1 + listsRebuilt, name, file: file, line: line)
        // the photo list is worked out again, the new photos in it as shown
        XCTAssertEqual(Set(app.list.map(\.id)), Set(app.assets.filter(app.assetPairing.shows).map(\.id)), name,
                       file: file, line: line)
        for asset in app.assets { XCTAssertEqual(app.asset(id: asset.id)?.id, asset.id, name, file: file, line: line) }
    }

    @MainActor
    func testImportBatchesCarryWhatsDerivedOnAsARecountWouldGiveIt() throws {
        let app = try catalog()

        append([photo("n1", "IMG_0001.JPG", keywords: ["trip"], project: "Wedding")], to: app, "a JPEG after its RAW")
        XCTAssertTrue(app.assetPairing.isHiddenCompanion("n1"))

        append([photo("n2", "IMG_0004.CR3", offset: 30, keywords: ["trip"])], to: app, "a RAW after its JPEG and HEIC")
        XCTAssertEqual(app.assetPairing.companionsByPrimary["n2"], ["a4j", "a4h"])
        XCTAssertEqual(app.countForAlbum(app.albums[0]), 1, "the album's JPEG and HEIC now behind the RAW")

        // the JPEG is the first photo with "home": a pass would meet it elsewhere now
        append([photo("n3", "IMG_0003.CR3", offset: 20)], to: app, "a RAW hiding the photo a keyword is first met on",
               dropping: ["keywords"])
        XCTAssertNil(app.keywordList.first { $0.name == "home" })
        XCTAssertNil(app.projectList.first { $0.name == "Garden" })

        append([photo("n4", "IMG_0005.CR3")], to: app, "another camera's photo by the same name, hours apart")
        XCTAssertNil(app.assetPairing.companionsByPrimary["n4"])

        append([photo("n5", "IMG_0006.NEF", offset: 60)], to: app, "a second RAW of a name: the pair is ambiguous")
        XCTAssertFalse(app.assetPairing.isHiddenCompanion("a6j"), "its JPEG shown again")

        var copy = app.asset(id: "a1")!.virtualCopy(id: "n8", name: "副本 1")
        copy.rating = 5
        append([photo("n6r", "IMG_0200.CR3", offset: 400), photo("n6j", "IMG_0200.JPG", offset: 400.5),
                photo("n7", "IMG_0201.JPG", keywords: ["gone"], deleted: true), copy,
                photo("n9", "sub/IMG_0202.JPG", camera: "FUJIFILM X-T4", lens: "XF23mmF1.4 R", offset: -86_400,
                      keywords: ["night", "trip"], project: "Launch", client: " Zed ", gps: (1, 2), status: .offline),
                photo("n10", "sub/deep/IMG_0203.JPG", flag: .pick, keywords: ["night"])],
               to: app, "a pair, a removed photo, a virtual copy and new values in one batch")
        XCTAssertTrue(app.assetPairing.isHiddenCompanion("n6j"))
        XCTAssertEqual(app.countForAlbum(app.albums[0]), 1, "a new photo the album already lists")

        append([photo("n11", "new/IMG_0300.JPG")], to: app, "a photo in a folder the tree hasn't got",
               dropping: ["folder tree", "folder counts"])
        XCTAssertNotNil(app.folderTree.first { $0.directoryPath?.hasSuffix("/new") == true })

        // with pairing off, every file is a photo of its own
        app.pairRawAndJpeg = false
        append([photo("n12", "IMG_0400.CR3"), photo("n13", "IMG_0400.JPG")], to: app, "pairing off",
               dropping: ["pairing"])
    }

    /// A pairing carried on through photos added in batches pairs as working it out from all the
    /// photos at once does, whatever the batches: the photos of the pairing oracle, cut anywhere.
    func testPairingCarriedThroughBatchesIsTheWholePairing() {
        for seed: UInt64 in [11, 12, 13] {
            let photos = AssetPairingOracleTests.tangle(1_500, seed: seed)
            let cuts = [0, 1, 2, 3, 50, 51, 333, 700, 701, 702, 999, 1_200, 1_201, 1_499, 1_500]
            var pairing = AssetPairing.rawJpeg(Array(photos.prefix(cuts[0])))
            var flipped = 0
            for (from, to) in zip(cuts, cuts.dropFirst()) {
                let before = AssetPairing.rawJpeg(Array(photos.prefix(from)))
                guard let changed = pairing.append(Array(photos.prefix(to)), from: from) else {
                    return XCTFail("seed \(seed): carried on from \(from)")
                }
                let whole = AssetPairing.rawJpeg(Array(photos.prefix(to)))
                XCTAssertEqual(pairing, whole, "seed \(seed): \(from)..<\(to)")
                // the earlier photos whose being hidden changed, and only they
                let expected = (0..<from).filter { before.isHiddenCompanion(photos[$0].id) != whole.isHiddenCompanion(photos[$0].id) }
                XCTAssertEqual(changed.sorted(), expected, "seed \(seed): \(from)..<\(to)")
                flipped += expected.count
            }
            XCTAssertGreaterThan(flipped, 0, "seed \(seed): some batch hid or showed an earlier photo")
        }
        var pairing = AssetPairing.rawJpeg([])
        XCTAssertNil(pairing.append(AssetPairingOracleTests.tangle(10, seed: 1), from: 5), "not the pairing of those photos")
    }
}
