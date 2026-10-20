import XCTest
@testable import PhotoCatalog

/// Checks that a change of the photos carries what's derived from every photo on — the id index,
/// the RAW+JPEG pairing, the library, keyword, project, client, camera and lens counts, the
/// sidebar's counts, the capture dates and the folders — exactly as working it all out again would
/// give it, on a catalog of one source folder with subfolders, RAW+JPEG pairs, smart albums and an
/// album.
class DerivedCacheTestCase: CatalogTestCase {
    let shot = Date(timeIntervalSince1970: 1_791_800_000)
    var root: URL { scratch.appendingPathComponent("Photos") }
    let everything = ["index", "pairing", "library", "keywords", "projects", "clients", "cameras", "lenses",
                      "sidebar", "dates", "folder tree", "folder counts"]

    func photo(_ id: String, _ file: String, raw: Bool? = nil, camera: String = "Canon EOS R5",
               lens: String = "RF50mm F1.2 L USM", offset: TimeInterval = 0, rating: Int = 0,
               flag: Flag = .none, keywords: [String] = [], project: String = "", client: String = "",
               gps: (Double, Double) = (0, 0), status: AssetStatus = .ready, deleted: Bool = false,
               folderId: String = "src", in folder: URL? = nil) -> Asset {
        let ext = PathString.splitExtension(file).ext.uppercased()
        var asset = Asset(id: id, pid: 0, ori: "l", thumb: "", preview: "", filename: PathString.lastComponent(file),
                          type: ext, isRaw: raw ?? ["CR3", "NEF"].contains(ext), folderId: folderId,
                          folderName: "Photos", date: shot.addingTimeInterval(offset), width: 6000, height: 4000,
                          orientation: 1, camera: camera, lens: lens, focal: 50, aperture: 2, shutter: "1/200",
                          iso: 100, colorSpace: "sRGB", fileMB: 1, rating: rating, flag: flag, keywords: keywords,
                          title: "", caption: "", location: Asset.locationLabel(gps.0 == 0 ? nil : gps), gps: gps,
                          status: status, importedAt: shot, deleted: deleted,
                          localPath: (folder ?? root).appendingPathComponent(file).path, isDemo: false)
        asset.project = project
        asset.client = client
        return asset
    }

    /// A catalog of one source folder with subfolders, smart albums and an album, every derived
    /// part of it worked out.
    @MainActor
    func catalog() throws -> AppState {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try CatalogStore(packageURL: scratch.appendingPathComponent("Library.photolibrary"))
        try store.addSourceRoot(id: "src", displayName: "Photos", path: root.path, bookmark: nil)
        let app = AppState.selfCheckFixture(store: store)
        app.runsBackgroundMaintenance = false
        app.autoWriteXMPSidecar = false
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
        try store.upsert(photos)
        app.applyLoadedCatalogForScaleCheck(photos, from: store)
        app.duplicateGroupsCache = []
        func smart(_ id: String, _ field: String, _ op: String, _ value: String) -> SmartAlbum {
            SmartAlbum(id: id, name: id, rule: SmartRule(conditions: [SmartCondition(field: field, op: op, value: value)]),
                       count: 0)
        }
        app.smartAlbums = [smart("rated", "rating", ">=", "3"), smart("trip", "keywords", "包含", "trip"),
                           smart("picks", "flag", "=", "pick"), smart("wedding", "search", "包含", "Wedding"),
                           smart("canon", "camera", "包含", "canon"), smart("offline", "status", "=", "offline")]
        app.albums = [Album(id: "album", name: "Album", assetIds: ["a3j", "a4j", "a4h", "n10"])]
        XCTAssertEqual(app.assets.count, photos.count)
        XCTAssertTrue(app.assetPairing.isHiddenCompanion("a2j") && app.assetPairing.isHiddenCompanion("a6j"))
        XCTAssertGreaterThan(app.folderTree.count, 2, "the source and its subfolders")
        work(app)
        return app
    }

    /// The folder tree's row of a folder under the source (the tree's paths may be another spelling
    /// of the scratch folder's: /var for /private/var).
    @MainActor
    func folder(_ relative: String, in app: AppState) -> FolderTreeItem? {
        app.folderTree.first { $0.directoryPath?.hasSuffix("/Photos/" + relative) == true }
    }

    /// What the sidebar, the filter bar and the inspector read as the window redraws.
    @MainActor
    func work(_ app: AppState) {
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

    /// Makes `change` on a catalog with everything derived worked out, then checks that what's
    /// derived was carried on as `dropped` says (all else held) and is what a recount gives, that
    /// nothing was counted again from every photo but what was dropped, and that the list and the
    /// id lookups follow.
    @MainActor
    func check(_ app: AppState, _ name: String, dropping dropped: [String] = [], _ change: () -> Void,
               file: StaticString = #filePath, line: UInt = #line) {
        let rebuilds = begin(app)
        change()
        verify(app, name, dropping: dropped, since: rebuilds, file: file, line: line)
    }

    /// Works out everything derived before a change: what's counted again from every photo since
    /// is told by the counts this returns.
    @MainActor
    func begin(_ app: AppState) -> (sidebar: Int, lists: Int) {
        work(app)
        return (app.sidebarCountIndexRebuilds, app.metadataListRebuilds)
    }

    /// `check`'s checks, after a change made since `begin` gave `rebuilds`.
    @MainActor
    func verify(_ app: AppState, _ name: String, dropping dropped: [String] = [], since rebuilds: (sidebar: Int, lists: Int),
                file: StaticString = #filePath, line: UInt = #line) {
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
        XCTAssertEqual(app.sidebarCountIndexRebuilds, rebuilds.sidebar + sidebarRebuilt, name, file: file, line: line)
        XCTAssertEqual(app.metadataListRebuilds, rebuilds.lists + listsRebuilt, name, file: file, line: line)
        // the photo list is worked out again, the photos in it as shown
        XCTAssertEqual(Set(app.list.map(\.id)), Set(app.assets.filter(app.assetPairing.shows).map(\.id)), name,
                       file: file, line: line)
        for asset in app.assets { XCTAssertEqual(app.asset(id: asset.id)?.id, asset.id, name, file: file, line: line) }
    }
}
