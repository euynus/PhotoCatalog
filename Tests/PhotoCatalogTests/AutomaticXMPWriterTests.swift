import XCTest
@testable import PhotoCatalog

/// Automatic XMP writing (Settings → Write XMP sidecars automatically): every edit reaches the
/// photo's sidecar, and only another app's change to it holds a write back.
final class AutomaticXMPWriterTests: CatalogTestCase {
    private var savedAutoWrite: Any?

    override func setUp() {
        super.setUp()
        savedAutoWrite = UserDefaults.standard.object(forKey: "pc_autoWriteXMP")
    }

    override func tearDown() {
        if let savedAutoWrite {
            UserDefaults.standard.set(savedAutoWrite, forKey: "pc_autoWriteXMP")
        } else {
            UserDefaults.standard.removeObject(forKey: "pc_autoWriteXMP")
        }
        super.tearDown()
    }

    /// A photo whose original is at `path`.
    private func photo(_ index: Int, at path: URL) -> Asset {
        var asset = DemoData.assets[index]
        asset.isDemo = false
        asset.deleted = false
        asset.localPath = path.path
        asset.filename = path.lastPathComponent
        return asset
    }

    /// Writes `asset`'s sidecar dated `age` seconds ago, as a sync long past; returns that time.
    private func writeOldSidecar(for asset: Asset, age: TimeInterval = 100) throws -> Double {
        let sidecar = XMPSidecar.sidecarURL(for: URL(fileURLWithPath: asset.localPath!))
        XCTAssertTrue(XMPSidecar.write(asset, to: sidecar))
        let date = Date().addingTimeInterval(-age)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: sidecar.path)
        return try XCTUnwrap(XMPSidecar.modificationTime(forOriginal: asset.localPath!))
    }

    /// Two writes queued before either ran both know only the sidecar as it was last synced:
    /// the first one's own write isn't another app's change to the second.
    func testSecondQueuedWriteIsNotHeldBackByTheFirst() async throws {
        let original = scratch.appendingPathComponent("IMG_0001.jpg")
        try makeTestJPEG(at: original, shade: 1)
        var asset = photo(0, at: original)
        asset.rating = 1
        let synced = try writeOldSidecar(for: asset)
        let writer = AutomaticXMPWriter()

        asset.rating = 2
        let first = await writer.write([asset], sequence: 1, baselines: [asset.id: synced])
        asset.rating = 3
        let second = await writer.write([asset], sequence: 2, baselines: [asset.id: synced])

        XCTAssertEqual(first.changedElsewhere, [])
        XCTAssertEqual(second.changedElsewhere, [], "our own first write isn't a change made elsewhere")
        XCTAssertNotNil(second.written[asset.id])
        XCTAssertEqual(XMPSidecar.read(XMPSidecar.sidecarURL(for: original))?.rating, 3, "the second edit is written")
    }

    /// A RAW and its JPEG share one sidecar: writing the RAW's isn't a change to the JPEG's.
    func testPairWrittenTogetherIsNotHeldBack() async throws {
        UserDefaults.standard.set(true, forKey: "pc_pairRawJpeg")
        let raw = scratch.appendingPathComponent("IMG_0002.CR3")
        let jpeg = scratch.appendingPathComponent("IMG_0002.JPG")
        try Data("raw".utf8).write(to: raw)
        try makeTestJPEG(at: jpeg, shade: 2)
        var rawAsset = photo(0, at: raw), jpegAsset = photo(1, at: jpeg)
        let synced = try writeOldSidecar(for: rawAsset)
        rawAsset.rating = 5
        jpegAsset.rating = 5

        let result = await AutomaticXMPWriter().write([rawAsset, jpegAsset], sequence: 1,
                                                      baselines: [rawAsset.id: synced, jpegAsset.id: synced])
        XCTAssertEqual(result.changedElsewhere, [])
        XCTAssertEqual(Set(result.written.keys), [rawAsset.id, jpegAsset.id])
    }

    /// Another app's change still holds the write back, after one of ours too.
    func testChangeElsewhereAfterOurWriteHoldsTheNextBack() async throws {
        let original = scratch.appendingPathComponent("IMG_0003.jpg")
        try makeTestJPEG(at: original, shade: 3)
        var asset = photo(0, at: original)
        let synced = try writeOldSidecar(for: asset)
        let writer = AutomaticXMPWriter()
        asset.rating = 2
        _ = await writer.write([asset], sequence: 1, baselines: [asset.id: synced])
        let sidecar = XMPSidecar.sidecarURL(for: original)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(50)],
                                              ofItemAtPath: sidecar.path)
        asset.rating = 4
        let next = await writer.write([asset], sequence: 2, baselines: [asset.id: synced])
        XCTAssertEqual(next.changedElsewhere, [asset.id])
        XCTAssertEqual(XMPSidecar.read(sidecar)?.rating, 2, "another app's version isn't written over")
    }

    /// Two quick edits in the app, then undo: each reaches the sidecar, and the photo isn't
    /// taken for one another app changed.
    @MainActor
    func testQuickEditsAndUndoAllReachTheSidecar() async throws {
        let source = scratch.appendingPathComponent("Source")
        let original = source.appendingPathComponent("quick.jpg")
        try makeTestJPEG(at: original, shade: 4)
        let package = scratch.appendingPathComponent("Library.photolibrary")
        let store = try CatalogStore(packageURL: package)
        try store.addSourceRoot(id: "source-1", displayName: "Source", path: source.path, bookmark: nil)
        let imported = try XCTUnwrap(ImportCoordinator(store: store)
            .importFiles([original], from: source, sourceRootId: "source-1", folderName: "Source").first)
        try store.upsert([imported])
        _ = try writeOldSidecar(for: imported)
        let sidecar = XMPSidecar.sidecarURL(for: original)

        let app = AppState()
        app.onboarded = true
        app.runsBackgroundMaintenance = false
        XCTAssertTrue(app.openCatalog(at: package))
        app.checkExternalXMPChangesNow()
        XCTAssertNotNil(app.xmpSyncTime(for: imported.id), "the sidecar's starting point is known")
        app.autoWriteXMPSidecar = true
        let undo = UndoManager()
        undo.groupsByEvent = false
        app.undoManager = undo

        undo.beginUndoGrouping()
        XCTAssertTrue(app.setRating(3, on: [imported.id]))
        undo.endUndoGrouping()
        undo.beginUndoGrouping()
        XCTAssertTrue(app.setRating(4, on: [imported.id]))
        undo.endUndoGrouping()
        try await waitUntil("the second edit is written") { XMPSidecar.read(sidecar)?.rating == 4 }
        XCTAssertEqual(app.externallyChangedXMPIds, [])

        undo.undo()
        try await waitUntil("the undo is written") { XMPSidecar.read(sidecar)?.rating == 3 }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(XMPSidecar.read(sidecar)?.rating, 3)
        XCTAssertEqual(app.externallyChangedXMPIds, [], "no write of ours counts as a change elsewhere")
        app.checkExternalXMPChangesNow()
        XCTAssertEqual(app.externallyChangedXMPIds, [])
    }

    /// Undo and redo queue each photo's sidecar write once, as the edit itself did.
    @MainActor
    func testUndoQueuesOneSidecarWrite() throws {
        let source = scratch.appendingPathComponent("Source")
        let original = source.appendingPathComponent("once.jpg")
        try makeTestJPEG(at: original, shade: 6)
        let package = scratch.appendingPathComponent("Library.photolibrary")
        let store = try CatalogStore(packageURL: package)
        try store.addSourceRoot(id: "source-1", displayName: "Source", path: source.path, bookmark: nil)
        let imported = try XCTUnwrap(ImportCoordinator(store: store)
            .importFiles([original], from: source, sourceRootId: "source-1", folderName: "Source").first)
        try store.upsert([imported])

        let app = AppState()
        app.onboarded = true
        app.runsBackgroundMaintenance = false
        XCTAssertTrue(app.openCatalog(at: package))
        app.autoWriteXMPSidecar = true
        let undo = UndoManager()
        undo.groupsByEvent = false
        app.undoManager = undo

        var queued = app.xmpWriteSequence
        undo.beginUndoGrouping()
        XCTAssertTrue(app.setRating(3, on: [imported.id]))
        undo.endUndoGrouping()
        XCTAssertEqual(app.xmpWriteSequence - queued, 1, "the edit queues one write")
        queued = app.xmpWriteSequence
        undo.undo()
        XCTAssertEqual(app.asset(id: imported.id)?.rating, imported.rating)
        XCTAssertEqual(app.xmpWriteSequence - queued, 1, "so does its undo")
        queued = app.xmpWriteSequence
        undo.redo()
        XCTAssertEqual(app.asset(id: imported.id)?.rating, 3)
        XCTAssertEqual(app.xmpWriteSequence - queued, 1, "and its redo")
    }

    /// An edit made while the photo's drive is away is written to its sidecar once the original
    /// is back (the availability check that follows a mount finds it).
    @MainActor
    func testEditWhileOriginalIsAwayIsWrittenWhenItIsBack() async throws {
        let source = scratch.appendingPathComponent("Source")
        let original = source.appendingPathComponent("away.jpg")
        try makeTestJPEG(at: original, shade: 5)
        let package = scratch.appendingPathComponent("Library.photolibrary")
        let store = try CatalogStore(packageURL: package)
        try store.addSourceRoot(id: "source-1", displayName: "Source", path: source.path, bookmark: nil)
        let imported = try XCTUnwrap(ImportCoordinator(store: store)
            .importFiles([original], from: source, sourceRootId: "source-1", folderName: "Source").first)
        try store.upsert([imported])
        let sidecar = XMPSidecar.sidecarURL(for: original)

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))
        app.autoWriteXMPSidecar = true
        let parked = scratch.appendingPathComponent("parked.jpg")
        try FileManager.default.moveItem(at: original, to: parked)

        XCTAssertTrue(app.setRating(4, on: [imported.id]))
        try await waitUntil("the write waits for the original") { app.xmpWriteIsPending(for: imported.id) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path), "nothing to write beside yet")
        app.detectMissingRealAssets()
        try await waitUntil("the check notices the original is away") {
            app.asset(id: imported.id)?.status == .missing
        }
        XCTAssertTrue(app.xmpWriteIsPending(for: imported.id), "still waiting while the original is away")

        try FileManager.default.moveItem(at: parked, to: original)
        app.detectMissingRealAssets()
        try await waitUntil("the edit reaches the sidecar") { XMPSidecar.read(sidecar)?.rating == 4 }
        XCTAssertFalse(app.xmpWriteIsPending(for: imported.id))
        XCTAssertEqual(app.externallyChangedXMPIds, [])
    }
}
