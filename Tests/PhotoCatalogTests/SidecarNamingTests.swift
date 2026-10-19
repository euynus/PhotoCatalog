import XCTest
@testable import PhotoCatalog

/// Which `.xmp` belongs to which photo when files share a name: `IMG.xmp` is the sole file's, or
/// a RAW+JPEG pair's (shared); any other file of that name keeps its own `IMG.JPG.xmp`.
final class SidecarNamingTests: CatalogTestCase {
    private var savedAutoWrite: Any?

    override func setUp() {
        super.setUp()
        savedAutoWrite = UserDefaults.app.object(forKey: "pc_autoWriteXMP")
        UserDefaults.app.set(true, forKey: "pc_pairRawJpeg")
    }

    override func tearDown() {
        if let savedAutoWrite {
            UserDefaults.app.set(savedAutoWrite, forKey: "pc_autoWriteXMP")
        } else {
            UserDefaults.app.removeObject(forKey: "pc_autoWriteXMP")
        }
        super.tearDown()
    }

    /// Empty files with these names in a folder of their own; returns the folder.
    private func folder(_ name: String, files: [String]) throws -> URL {
        let folder = scratch.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in files {
            XCTAssertTrue(FileManager.default.createFile(atPath: folder.appendingPathComponent(file).path, contents: Data()))
        }
        return folder
    }

    private func sidecarName(_ file: String, in folder: URL) -> String {
        XMPSidecar.sidecarURL(for: folder.appendingPathComponent(file)).lastPathComponent
    }

    func testSoleFileKeepsThePlainName() throws {
        let folder = try folder("Sole", files: ["IMG_0001.JPG", "IMG_0002.CR3", "IMG_0002.xmp", "Other.TIF"])
        XCTAssertEqual(sidecarName("IMG_0001.JPG", in: folder), "IMG_0001.xmp")
        XCTAssertEqual(sidecarName("IMG_0002.CR3", in: folder), "IMG_0002.xmp", "a sidecar isn't a file of the name")
        XCTAssertEqual(sidecarName("Other.TIF", in: folder), "Other.xmp")
    }

    func testRawJpegPairSharesThePlainName() throws {
        let folder = try folder("Pair", files: ["IMG_0001.CR3", "IMG_0001.JPG", "IMG_0001.HEIC", "IMG_0001.TIF"])
        XCTAssertEqual(sidecarName("IMG_0001.CR3", in: folder), "IMG_0001.xmp")
        XCTAssertEqual(sidecarName("IMG_0001.JPG", in: folder), "IMG_0001.xmp")
        XCTAssertEqual(sidecarName("IMG_0001.HEIC", in: folder), "IMG_0001.xmp")
        XCTAssertEqual(sidecarName("IMG_0001.TIF", in: folder), "IMG_0001.TIF.xmp", "a TIFF beside the pair isn't of it")
    }

    func testUnpairedFilesOfOneNameKeepTheirOwn() throws {
        let edited = try folder("Edited", files: ["IMG_0001.JPG", "IMG_0001.TIF"])
        XCTAssertEqual(sidecarName("IMG_0001.JPG", in: edited), "IMG_0001.xmp", "the camera's JPEG keeps the name")
        XCTAssertEqual(sidecarName("IMG_0001.TIF", in: edited), "IMG_0001.TIF.xmp")

        let converted = try folder("Converted", files: ["IMG_0002.HEIC", "IMG_0002.JPG"])
        XCTAssertNotEqual(sidecarName("IMG_0002.HEIC", in: converted), sidecarName("IMG_0002.JPG", in: converted))
        XCTAssertEqual(sidecarName("IMG_0002.HEIC", in: converted), "IMG_0002.xmp")
        XCTAssertEqual(sidecarName("IMG_0002.JPG", in: converted), "IMG_0002.JPG.xmp")

        let twoRaws = try folder("TwoRaws", files: ["IMG_0003.CR3", "IMG_0003.DNG", "IMG_0003.JPG"])
        let names = Set(["IMG_0003.CR3", "IMG_0003.DNG", "IMG_0003.JPG"].map { sidecarName($0, in: twoRaws) })
        XCTAssertEqual(names.count, 3, "no pair: each its own")
    }

    func testWithPairingOffTheJpegKeepsItsOwn() throws {
        UserDefaults.app.set(false, forKey: "pc_pairRawJpeg")
        let folder = try folder("Unpaired", files: ["IMG_0001.CR3", "IMG_0001.JPG"])
        XCTAssertEqual(sidecarName("IMG_0001.CR3", in: folder), "IMG_0001.xmp", "the RAW keeps the name")
        XCTAssertEqual(sidecarName("IMG_0001.JPG", in: folder), "IMG_0001.JPG.xmp")
    }

    func testVideoBesideAPhotoKeepsItsOwn() throws {
        let folder = try folder("Live", files: ["LIVE.HEIC", "LIVE.MOV", "ALONE.MOV"])
        XCTAssertEqual(sidecarName("LIVE.HEIC", in: folder), "LIVE.xmp")
        XCTAssertEqual(sidecarName("LIVE.MOV", in: folder), "LIVE.MOV.xmp")
        XCTAssertEqual(sidecarName("ALONE.MOV", in: folder), "ALONE.xmp")
    }

    /// Looking at many photos at once (a whole folder) names each sidecar as one at a time does.
    func testManyAtOnceMatchesOneAtATime() throws {
        var files: [String] = []
        for index in 0..<60 { files.append(String(format: "IMG_%04d.JPG", index)) }
        files += ["IMG_0001.CR3", "IMG_0002.TIF", "IMG_0003.HEIC", "IMG_0004.MOV", "img_0005.cr3", "Solo.tif"]
        let folder = try folder("Many", files: files)
        let originals = files.map { folder.appendingPathComponent($0) }
        for pairing in [true, false] {
            UserDefaults.app.set(pairing, forKey: "pc_pairRawJpeg")
            XCTAssertEqual(XMPSidecar.sidecarURLs(for: originals).map(\.lastPathComponent),
                           originals.map { XMPSidecar.sidecarURL(for: $0).lastPathComponent }, "pairing \(pairing)")
            XCTAssertEqual(XMPSidecar.sidecarURLs(for: Array(originals.prefix(1))).map(\.lastPathComponent),
                           originals.prefix(1).map { XMPSidecar.sidecarURL(for: $0).lastPathComponent })
        }
    }

    /// A catalog holding one RAW+JPEG shot — same camera, same moment — whose shared sidecar
    /// was last synced long ago.
    @MainActor
    private func openPairCatalog() throws -> (app: AppState, package: URL, raw: Asset, jpeg: Asset, shared: URL) {
        let source = try folder("Source", files: ["IMG_0001.CR3"])
        let jpegURL = source.appendingPathComponent("IMG_0001.JPG")
        try makeTestJPEG(at: jpegURL, shade: 1)
        let shot = Date(timeIntervalSince1970: 1_700_000_000)
        func photo(_ id: String, _ url: URL, isRaw: Bool) -> Asset {
            Asset(id: id, pid: 1, ori: "l", thumb: "", preview: "", filename: url.lastPathComponent,
                  type: url.pathExtension.uppercased(), isRaw: isRaw, folderId: "source-1", folderName: "Source",
                  date: shot, width: 80, height: 60, orientation: 1, camera: "Canon EOS R6m2", lens: "",
                  focal: 0, aperture: 0, shutter: "", iso: 0, colorSpace: "sRGB", fileMB: 0.01, rating: 0,
                  flag: .none, keywords: [], title: "", caption: "", location: "", gps: (0, 0), status: .ready,
                  importedAt: .now, localPath: url.path, isDemo: false)
        }
        let raw = photo("pair-raw", source.appendingPathComponent("IMG_0001.CR3"), isRaw: true)
        let jpeg = photo("pair-jpeg", jpegURL, isRaw: false)
        let package = scratch.appendingPathComponent("Library.photolibrary")
        try CatalogStore(packageURL: package).upsert([raw, jpeg])
        let shared = XMPSidecar.sidecarURL(for: jpegURL)
        XCTAssertEqual(shared.lastPathComponent, "IMG_0001.xmp")
        XCTAssertTrue(XMPSidecar.write(raw, to: shared))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-500)],
                                              ofItemAtPath: shared.path)

        let app = AppState()
        app.onboarded = true
        app.runsBackgroundMaintenance = false
        XCTAssertTrue(app.openCatalog(at: package))
        XCTAssertEqual(app.assetPairing.primaryByCompanion[jpeg.id], raw.id, "one shot")
        app.checkExternalXMPChangesNow()
        return (app, package, raw, jpeg, shared)
    }

    /// Whether the sidecar time last synced for `id` is `sidecar`'s now.
    @MainActor
    private func startsFrom(_ sidecar: URL, _ id: String, in app: AppState) -> Bool {
        guard let time = XMPSidecar.modificationTime(of: sidecar), let synced = app.xmpSyncTime(for: id) else {
            return false
        }
        return abs(synced - time) < 1
    }

    /// Turning pairing off gives a RAW's JPEG a sidecar of its own, and on again the pair's: the
    /// sidecar it now uses isn't taken for one another app changed.
    @MainActor
    func testSwitchingPairingDoesNotFlagTheJpegs() async throws {
        let (app, _, raw, jpeg, shared) = try openPairCatalog()
        app.autoWriteXMPSidecar = true

        app.pairRawAndJpeg = false
        XCTAssertTrue(app.setRating(2, on: [jpeg.id]))
        let own = URL(fileURLWithPath: jpeg.localPath!).appendingPathExtension("xmp")
        try await waitUntil("the JPEG's own sidecar is written") {
            XMPSidecar.read(own)?.rating == 2 && self.startsFrom(own, jpeg.id, in: app)
        }
        XCTAssertEqual(XMPSidecar.read(shared)?.rating, raw.rating, "the RAW's is left alone")
        app.checkExternalXMPChangesNow()
        XCTAssertEqual(app.externallyChangedXMPIds, [])

        app.pairRawAndJpeg = true
        try await waitUntil("the JPEG starts from the pair's sidecar") { self.startsFrom(shared, jpeg.id, in: app) }
        app.checkExternalXMPChangesNow()
        XCTAssertEqual(app.externallyChangedXMPIds, [], "switching pairing isn't a change made elsewhere")
    }

    /// Sidecar times worked out in the background can land late — after pairing was switched,
    /// or after one of our writes: an outdated one never replaces the time of the sidecar the
    /// photo uses now.
    @MainActor
    func testLateSidecarResultsDontReplaceNewerOnes() async throws {
        let (app, package, raw, jpeg, shared) = try openPairCatalog()

        // worked out with pairing off, for the JPEG's own sidecar
        app.pairRawAndJpeg = false
        try await waitUntil("pairing off settles") { app.xmpSyncTime(for: jpeg.id) == 0 }
        let offSnapshot = app.xmpSyncSnapshot()
        var edited = jpeg
        edited.rating = 2
        let lateWrite = await AutomaticXMPWriter().write([edited], sequence: 1)
        XCTAssertNotNil(lateWrite.written[jpeg.id])
        let lateReseed = AppState.sidecarReseedTimes(app.xmpCheckCandidates(), from: true, to: false)
        XCTAssertNotNil(lateReseed[jpeg.id])
        let lateCheck = AppState.findChangedSidecars(app.xmpCheckCandidates(), known: [jpeg.id: 0], pairing: false)
        XCTAssertNotNil(lateCheck.changed[jpeg.id])

        // landing once it's back on
        app.pairRawAndJpeg = true
        try await waitUntil("the JPEG starts from the pair's sidecar") { self.startsFrom(shared, jpeg.id, in: app) }
        app.applyAutomaticXMPWrite(lateWrite, catalogURL: package)
        XCTAssertTrue(startsFrom(shared, jpeg.id, in: app), "a write to the sidecar pairing swapped out doesn't count")
        app.applySidecarReseed(lateReseed, since: offSnapshot)
        XCTAssertTrue(startsFrom(shared, jpeg.id, in: app), "nor a re-seed for pairing off")
        app.applyExternalXMPCheck(seeded: lateCheck.seeded, changed: lateCheck.changed,
                                  pairingDependent: lateCheck.pairingDependent, since: offSnapshot)
        XCTAssertEqual(app.externallyChangedXMPIds, [], "nor a check of the JPEG's own sidecar")

        // worked out before one of our writes, landing after it
        let onSnapshot = app.xmpSyncSnapshot()
        let earlyReseed = AppState.sidecarReseedTimes(app.xmpCheckCandidates(), from: false, to: true)
        XCTAssertNotNil(earlyReseed[jpeg.id])
        app.autoWriteXMPSidecar = true
        XCTAssertTrue(app.setRating(4, on: [raw.id]))
        try await waitUntil("the pair's edit is written") {
            XMPSidecar.read(shared)?.rating == 4 && self.startsFrom(shared, jpeg.id, in: app)
        }
        app.applySidecarReseed(earlyReseed, since: onSnapshot)
        XCTAssertTrue(startsFrom(shared, jpeg.id, in: app), "nor a re-seed from before our write")
        app.checkExternalXMPChangesNow()
        XCTAssertEqual(app.externallyChangedXMPIds, [])
    }

    /// Export Originals with sidecars: photos from different folders that share a name get
    /// numbered names and sidecars of their own; a RAW+JPEG pair keeps its one name and sidecar.
    func testExportOriginalsGivesEachPhotoItsOwnSidecar() throws {
        var demo = DemoData.assets.makeIterator()
        func photo(_ folder: String, _ name: String, rating: Int) throws -> Asset {
            let url = scratch.appendingPathComponent(folder).appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("\(folder)/\(name)".utf8).write(to: url)
            var asset = try XCTUnwrap(demo.next())
            asset.isDemo = false
            asset.localPath = url.path
            asset.filename = name
            asset.rating = rating
            asset.keywords = ["\(folder)/\(name)"]
            return asset
        }
        let photos = [
            try photo("A", "IMG_0001.CR3", rating: 5), try photo("B", "IMG_0001.JPG", rating: 1),
            try photo("A", "P.CR3", rating: 3), try photo("A", "P.JPG", rating: 3),
            try photo("C", "X.JPG", rating: 2), try photo("D", "X.JPG", rating: 4),
        ]
        let out = scratch.appendingPathComponent("Export")
        let report = ExportService.copyOriginals(photos, to: out, xmp: true)
        XCTAssertEqual(report.copied, 6)
        XCTAssertEqual(report.xmpFailed, 0)
        func rating(_ sidecar: String) -> Int? { XMPSidecar.read(out.appendingPathComponent(sidecar))?.rating }
        func keywords(_ sidecar: String) -> [String]? { XMPSidecar.read(out.appendingPathComponent(sidecar))?.keywords }
        XCTAssertEqual(keywords("IMG_0001.xmp"), ["A/IMG_0001.CR3"], "the RAW's sidecar is the RAW's alone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("IMG_0001 (1).JPG").path),
                      "another photo of that name is numbered, not made the RAW's JPEG")
        XCTAssertEqual(keywords("IMG_0001 (1).xmp"), ["B/IMG_0001.JPG"])
        for name in ["P.CR3", "P.JPG", "X.JPG", "X (1).JPG"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent(name).path), name)
        }
        XCTAssertEqual(rating("P.xmp"), 3, "the pair keeps its name and one sidecar")
        XCTAssertEqual(keywords("X.xmp"), ["C/X.JPG"])
        XCTAssertEqual(keywords("X (1).xmp"), ["D/X.JPG"])

        // a folder holding another photo of that name, with its sidecar: neither is touched
        let busy = scratch.appendingPathComponent("Busy")
        try FileManager.default.createDirectory(at: busy, withIntermediateDirectories: true)
        try Data("tiff".utf8).write(to: busy.appendingPathComponent("IMG_0001.TIF"))
        let theirs = Data("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"/>".utf8)
        try theirs.write(to: busy.appendingPathComponent("IMG_0001.xmp"))
        XCTAssertEqual(ExportService.copyOriginals([photos[1]], to: busy, xmp: true).copied, 1)
        XCTAssertEqual(try Data(contentsOf: busy.appendingPathComponent("IMG_0001.xmp")), theirs)
        XCTAssertEqual(XMPSidecar.read(busy.appendingPathComponent("IMG_0001 (1).xmp"))?.keywords, ["B/IMG_0001.JPG"])

        // exporting again over the same files replaces them, under their own names
        let again = ExportService.copyOriginals(Array(photos[2...3]), to: out, conflict: .overwrite, xmp: true)
        XCTAssertEqual(again.copied, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("P (1).CR3").path))
        XCTAssertEqual(rating("P.xmp"), 3)
    }

    /// A JPEG and a TIFF of one name in the catalog: writing one's sidecar doesn't make the other
    /// look changed elsewhere, nor give it the other's rating.
    @MainActor
    func testWritingOnePhotosSidecarLeavesItsNamesakeAlone() async throws {
        let source = scratch.appendingPathComponent("Source")
        let jpeg = source.appendingPathComponent("IMG_0001.jpg")
        let tiff = source.appendingPathComponent("IMG_0001.tif")
        try makeTestJPEG(at: jpeg, shade: 1)
        try makeTestJPEG(at: tiff, shade: 2)
        let package = scratch.appendingPathComponent("Library.photolibrary")
        let store = try CatalogStore(packageURL: package)
        try store.addSourceRoot(id: "source-1", displayName: "Source", path: source.path, bookmark: nil)
        let imported = try ImportCoordinator(store: store)
            .importFiles([jpeg, tiff], from: source, sourceRootId: "source-1", folderName: "Source")
        try store.upsert(imported)
        let jpegId = try XCTUnwrap(imported.first { $0.localPath == jpeg.path }?.id)
        let tiffId = try XCTUnwrap(imported.first { $0.localPath == tiff.path }?.id)

        let app = AppState()
        app.onboarded = true
        app.runsBackgroundMaintenance = false
        XCTAssertTrue(app.openCatalog(at: package))
        app.checkExternalXMPChangesNow()
        app.autoWriteXMPSidecar = true
        XCTAssertTrue(app.setRating(5, on: [jpegId]))
        try await waitUntil("the JPEG's sidecar is written") {
            XMPSidecar.read(XMPSidecar.sidecarURL(for: jpeg))?.rating == 5
        }
        app.checkExternalXMPChangesNow()
        XCTAssertEqual(app.externallyChangedXMPIds, [], "the TIFF's sidecar didn't change")
        XCTAssertNil(XMPSidecar.read(XMPSidecar.sidecarURL(for: tiff))?.rating)
        app.readMetadataFromFiles([tiffId], undoable: false)
        XCTAssertEqual(app.asset(id: tiffId)?.rating, 0, "the TIFF doesn't take the JPEG's rating")
    }
}
