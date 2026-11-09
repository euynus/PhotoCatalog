import XCTest
@testable import PhotoCatalog

/// The People overview's counts of photos still to analyse and of photos an earlier method read:
/// what counting the photos as shown gives, worked out again only when the scans, the photos'
/// structure or the pairing changed, so a rating on the overview doesn't count every photo.
final class FaceAnalysisCountTests: CatalogTestCase {
    private var undo: UndoManager!

    override func setUp() {
        super.setUp()
        undo = MainActor.assumeIsolated {
            let undo = UndoManager()
            undo.groupsByEvent = false   // no run loop here to close event groups
            return undo
        }
    }

    override func tearDown() {
        undo = nil
        super.tearDown()
    }

    private func photo(_ id: String, _ file: String, raw: Bool = false, demo: Bool = false) -> Asset {
        Asset(id: id, pid: 1, ori: "l", thumb: "", preview: "", filename: file, type: raw ? "CR3" : "JPG", isRaw: raw,
              folderId: "src", folderName: "Source", date: Date(timeIntervalSince1970: 1_700_000_000), width: 80,
              height: 60, orientation: 1, camera: "Canon EOS R5", lens: "", focal: 0, aperture: 0, shutter: "", iso: 0,
              colorSpace: "sRGB", fileMB: 0.01, rating: 0, flag: .none, keywords: [], title: "", caption: "",
              location: "", gps: (0, 0), status: .ready, importedAt: .now,
              localPath: scratch.appendingPathComponent("Source/\(file)").path, isDemo: demo)
    }

    private func face(_ id: String, on assetId: String, length: Int = FaceClustering.vectorLength) -> FaceRecord {
        var vector = [Float](repeating: 0, count: length)
        vector[0] = 1
        return FaceRecord(id: id, assetId: assetId, box: CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.2), quality: 0.6,
                          vector: vector, person: nil, confirmed: false)
    }

    /// Six JPEGs, a RAW with its JPEG and a demo photo; an earlier method's face on f0 and an
    /// analysed one on f1.
    @MainActor
    private func appWithFaces() throws -> (AppState, CatalogStore) {
        let photos = (0..<6).map { photo("f\($0)", "IMG_\($0).JPG") }
            + [photo("r6", "IMG_6.CR3", raw: true), photo("j6", "IMG_6.JPG"), photo("d7", "IMG_7.JPG", demo: true)]
        let store = try CatalogStore(packageURL: scratch.appendingPathComponent("People.photolibrary"))
        try store.upsert(photos.filter { !$0.isDemo })
        try store.saveFaceScans(["f0": [face("old", on: "f0", length: 768)], "f1": [face("x1", on: "f1")]])
        let app = AppState.selfCheckFixture(store: store)
        app.runsBackgroundMaintenance = false
        app.autoWriteXMPSidecar = false
        app.pairRawAndJpeg = true
        app.assets = photos
        app.duplicateGroupsCache = []
        app.undoManager = undo
        return (app, store)
    }

    /// The counts as counting the photos as shown gives them.
    @MainActor
    private func assertCountsAsCounted(_ app: AppState, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let pairing = app.assetPairing
        let shown = app.assets.filter(pairing.shows)
        let unscanned = shown.filter { !$0.isDemo && !$0.isVirtualCopy && !app.faceScannedAssetIds.contains($0.id) }.count
        let outdated = shown.filter { !$0.isVirtualCopy && app.faceOutdatedAssetIds.contains($0.id) }.count
        XCTAssertEqual(app.faceUnscannedCount, unscanned, "\(name): not analysed", file: file, line: line)
        XCTAssertEqual(app.faceOutdatedCount, outdated, "\(name): read by the earlier method", file: file, line: line)
    }

    @MainActor
    func testCountsFollowScansStructureAndPairing() async throws {
        let (app, store) = try appWithFaces()
        assertCountsAsCounted(app, "before any faces are loaded")
        app.loadFaces(from: store)
        assertCountsAsCounted(app, "faces loaded")
        XCTAssertEqual(app.faceUnscannedCount, 6, "f0 (to analyse again), f2-f5 and the RAW")
        XCTAssertEqual(app.faceOutdatedCount, 1)

        // a name tags the photo: a metadata edit, counted nothing again
        let counted = try XCTUnwrap(app.faceAnalysisCountsCache)
        undo.beginUndoGrouping()
        app.nameFaces(["x1"], as: "小明")
        undo.endUndoGrouping()
        XCTAssertEqual(app.asset(id: "f1")?.keywords.contains("人物/小明"), true)
        XCTAssertTrue(app.faceAnalysisCountsCache.map { $0.structure == app.structureVersion && $0.scan == counted.scan } ?? false,
                      "the counts still hold")
        assertCountsAsCounted(app, "named")

        undo.beginUndoGrouping()
        XCTAssertTrue(app.mutate(["f2", "f0"], undoName: "移除") { $0.deleted = true })
        undo.endUndoGrouping()
        assertCountsAsCounted(app, "photos removed")
        XCTAssertEqual(app.faceOutdatedCount, 0)
        undo.undo()
        assertCountsAsCounted(app, "removal undone")
        XCTAssertEqual(app.faceUnscannedCount, 6)

        app.appendAssets([try XCTUnwrap(app.asset(id: "f3")).virtualCopy(id: "v8", name: "副本 1")])
        assertCountsAsCounted(app, "a virtual copy")
        XCTAssertEqual(app.faceUnscannedCount, 6, "a virtual copy's faces are its master's")

        app.pairRawAndJpeg = false
        assertCountsAsCounted(app, "pairing off")
        XCTAssertEqual(app.faceUnscannedCount, 7, "the RAW's JPEG on its own")
        app.pairRawAndJpeg = true
        assertCountsAsCounted(app, "pairing on")

        // photos analysed: three with files to read (no faces in them), the rest unreadable
        for (index, id) in ["f2", "f3", "f4"].enumerated() {
            try makeTestJPEG(at: URL(fileURLWithPath: try XCTUnwrap(app.asset(id: id)?.localPath)), shade: index)
        }
        app.startFaceAnalysis()
        try await waitUntil("the analysis finished") { app.faceAnalysis == nil }
        assertCountsAsCounted(app, "a scan")
        XCTAssertEqual(app.faceUnscannedCount, 3, "f0, f5 and the RAW still to analyse")

        try store.saveFaceScans(["f5": []])
        app.loadFaces(from: store)
        assertCountsAsCounted(app, "loaded again")
        app.clearFaces()
        assertCountsAsCounted(app, "cleared")
    }

    /// A rating on the People overview doesn't redraw what reads the counts; a removal does.
    @MainActor
    func testARatingLeavesTheCountsUnobserved() throws {
        let (app, store) = try appWithFaces()
        app.undoManager = nil
        app.loadFaces(from: store)
        _ = app.faceUnscannedCount   // counted
        let rated = CancellationFlag()
        withObservationTracking {
            _ = app.faceUnscannedCount
            _ = app.faceOutdatedCount
        } onChange: { rated.set() }
        XCTAssertTrue(app.setRating(4, on: ["f1", "f2"]))
        XCTAssertFalse(rated.isSet, "a rating changes neither count")
        assertCountsAsCounted(app, "rated")

        let removed = CancellationFlag()
        withObservationTracking {
            _ = app.faceUnscannedCount
        } onChange: { removed.set() }
        XCTAssertTrue(app.mutate(["f3"]) { $0.deleted = true })
        XCTAssertTrue(removed.isSet, "a removal may change them")
        assertCountsAsCounted(app, "removed")
    }
}
