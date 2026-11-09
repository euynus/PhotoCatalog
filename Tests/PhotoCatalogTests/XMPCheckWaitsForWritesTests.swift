import CoreServices
import XCTest
@testable import PhotoCatalog

/// The sidecar check never looks while one of our own sidecar writes is under way: a write
/// records the new times of the sidecars it rewrote only once it's done, so a check meanwhile
/// would take them for another app's changes (and, reading them back, undo a later edit).
final class XMPCheckWaitsForWritesTests: CatalogTestCase {
    private static let fileModified = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified
        | kFSEventStreamEventFlagItemIsFile)

    /// A catalog of one photo, its watcher stopped so only the events a test hands in reach it,
    /// with Write XMP Automatically on and the background checks on from now (each test turns
    /// them off as it ends, so a check left waiting stops at its guard).
    @MainActor
    private func appWithPhoto() throws -> (app: AppState, photo: Asset, sidecar: URL) {
        let (_, package, photo, original) = try importPhoto("IMG_0001.jpg", shade: 3)
        let app = openCatalog(package)
        app.watcher?.stop()
        app.autoWriteXMPSidecar = true
        app.runsBackgroundMaintenance = true
        app.lastXMPCheck = nil
        return (app, photo, XMPSidecar.sidecarURL(for: original))
    }

    /// A batch of sidecar events arrives while a rating's sidecar is being written: the check
    /// waits for the write, then runs, and finds our own write no change.
    @MainActor
    func testSidecarBatchDuringAWriteWaitsForIt() async throws {
        let (app, photo, sidecar) = try appWithPhoto()
        defer { app.runsBackgroundMaintenance = false }

        XCTAssertTrue(app.setRating(4, on: [photo.id]))
        XCTAssertEqual(app.xmpWritesInFlight, 1, "the rating's sidecar is being written")
        app.watchedFilesChanged([(sidecar.path, Self.fileModified)])

        XCTAssertFalse(app.isCheckingXMP, "the check waits for the write")
        XCTAssertNil(app.lastXMPCheck)
        try await waitUntil("the write is done and the check ran") { app.lastXMPCheck != nil && !app.isCheckingXMP }
        XCTAssertEqual(app.xmpWritesInFlight, 0)
        XCTAssertFalse(app.xmpCheckAwaitsWrites)
        XCTAssertEqual(app.xmpSyncTime(for: photo.id), XMPSidecar.modificationTime(of: sidecar), "the write is recorded")
        XCTAssertEqual(app.externallyChangedXMPIds, [], "our own write isn't another app's change")
        XCTAssertEqual(app.assets.first { $0.id == photo.id }?.rating, 4)
    }

    /// A write that begins while a check looks: the check's findings are set aside, and it runs
    /// again once the write is done.
    @MainActor
    func testWriteThatBeginsDuringACheckHasItRunAgain() async throws {
        let (app, photo, sidecar) = try appWithPhoto()
        defer { app.runsBackgroundMaintenance = false }
        XCTAssertTrue(XMPSidecar.write(photo, to: sidecar))
        XCTAssertNil(app.xmpSyncTime(for: photo.id), "the sidecar isn't known yet")
        let count = app.xmpSyncCount

        app.checkExternalXMPChanges()
        XCTAssertTrue(app.isCheckingXMP)
        // as a write does when it's queued (an edit's own would race the check)
        app.xmpWriteStarted()
        try await waitUntil("the check finished looking") { !app.isCheckingXMP }
        XCTAssertEqual(app.xmpSyncCount, count, "nothing it found is taken in")
        XCTAssertNil(app.xmpSyncTime(for: photo.id))
        XCTAssertTrue(app.xmpCheckAwaitsWrites, "it waits to run again")

        app.lastXMPCheck = nil   // not held back by the interval since the first
        app.xmpWriteFinished()
        XCTAssertTrue(app.isCheckingXMP, "it runs again once the write is done")
        try await waitUntil("the check ran again") { !app.isCheckingXMP }
        XCTAssertEqual(app.xmpSyncTime(for: photo.id), XMPSidecar.modificationTime(of: sidecar), "first sighting stored")
        XCTAssertEqual(app.externallyChangedXMPIds, [])
    }
}
