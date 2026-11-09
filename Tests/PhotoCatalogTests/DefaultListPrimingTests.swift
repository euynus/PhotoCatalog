import XCTest
@testable import PhotoCatalog

/// All Photographs as a catalog opens is ready without being worked out: the photos just loaded,
/// each JPEG behind its RAW told by its place in the pairing, as working the list out gives it.
final class DefaultListPrimingTests: CatalogTestCase {
    private let shot = Date(timeIntervalSince1970: 1_791_800_000)

    private func photo(_ id: String, _ file: String, offset: TimeInterval, deleted: Bool = false) -> Asset {
        let ext = PathString.splitExtension(file).ext.uppercased()
        return Asset(id: id, pid: 0, ori: "l", thumb: "", preview: "", filename: file, type: ext,
                     isRaw: ext == "CR3", folderId: "src", folderName: "Photos", date: shot.addingTimeInterval(offset),
                     width: 6000, height: 4000, orientation: 1, camera: "Canon EOS R5", lens: "", focal: 50,
                     aperture: 2, shutter: "1/200", iso: 100, colorSpace: "sRGB", fileMB: 1, rating: 0, flag: .none,
                     keywords: [], title: "", caption: "", location: "", gps: (0, 0), status: .ready,
                     importedAt: shot, deleted: deleted,
                     localPath: scratch.appendingPathComponent("Photos").appendingPathComponent(file).path,
                     isDemo: false)
    }

    /// RAW+JPEG pairs (a JPEG before its RAW and after it), a HEIC with its RAW, photos alone.
    private var photos: [Asset] {
        (0..<30).flatMap { index -> [Asset] in
            let offset = Double(index) * 30
            switch index % 4 {
            case 0: return [photo("r\(index)", "IMG_\(index).CR3", offset: offset),
                            photo("j\(index)", "IMG_\(index).JPG", offset: offset + 0.5)]
            case 1: return [photo("j\(index)", "IMG_\(index).JPG", offset: offset),
                            photo("r\(index)", "IMG_\(index).CR3", offset: offset)]
            case 2: return [photo("r\(index)", "IMG_\(index).CR3", offset: offset),
                            photo("h\(index)", "IMG_\(index).HEIC", offset: offset)]
            default: return [photo("p\(index)", "IMG_\(index).JPG", offset: offset)]
            }
        }
    }

    @MainActor
    private func openedCatalog() throws -> AppState {
        let root = scratch.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try CatalogStore(packageURL: scratch.appendingPathComponent("Library.photolibrary"))
        try store.addSourceRoot(id: "src", displayName: "Photos", path: root.path, bookmark: nil)
        try store.upsert(photos)
        let app = AppState.selfCheckFixture(store: store)
        app.runsBackgroundMaintenance = false
        app.pairRawAndJpeg = true
        // as an open reads them: in the order All Photographs lists them
        app.applyLoadedCatalogForScaleCheck(try store.loadAssets(), from: store)
        return app
    }

    @MainActor
    func testTheListAsTheCatalogOpensIsTheListWorkedOut() throws {
        let app = try openedCatalog()
        XCTAssertEqual(app.assetPairing.primaryByCompanion.count, 23, "each JPEG and HEIC behind its RAW")
        let computations = app.listComputations
        let primed = app.list.map(\.id)
        XCTAssertEqual(app.listComputations, computations, "ready without being worked out")
        XCTAssertEqual(Set(primed), Set(app.assets.filter(app.assetPairing.shows).map(\.id)))

        (app.listCache, app.uncollapsedListCache, app.matchingPositionsCache) = (nil, nil, nil)
        XCTAssertEqual(app.list.map(\.id), primed, "as working it out gives it")
        XCTAssertEqual(app.listComputations, computations + 1)
    }

    /// Photos other than the catalog's own array are asked about by id: the pairing's places are
    /// those of the photos it was worked out from (a misplaced ask would fail its debug check).
    @MainActor
    func testOtherPhotosAreAskedAboutById() throws {
        let app = try openedCatalog()
        let pairing = app.assetPairing
        for other in [Array(app.assets.reversed()), app.assets.map { $0 }, Array(app.assets.dropFirst(3))] {
            app.primeDefaultListCache(with: other)
            XCTAssertEqual(app.list.map(\.id), other.filter(pairing.shows).map(\.id))
        }
        // and the catalog's own array by place
        app.primeDefaultListCache(with: app.assets)
        XCTAssertEqual(app.list.map(\.id), app.assets.filter(pairing.shows).map(\.id))

        // with pairing off, every photo
        app.pairRawAndJpeg = false
        app.primeDefaultListCache(with: app.assets)
        XCTAssertEqual(app.list.count, app.assets.count)
    }
}
