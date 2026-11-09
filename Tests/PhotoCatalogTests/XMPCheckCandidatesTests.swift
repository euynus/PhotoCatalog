import XCTest
@testable import PhotoCatalog

/// The background XMP check lists the originals whose sidecars it looks at off the main thread,
/// and a check asked for while one is under way waits its turn.
final class XMPCheckCandidatesTests: CatalogTestCase {
    /// A catalog of three photos, each with a sidecar, opened with background work off.
    @MainActor
    private func appWithCatalog() throws -> (app: AppState, photos: [Asset]) {
        let source = scratch.appendingPathComponent("Source")
        var originals: [URL] = []
        for shade in 1...3 {
            let original = source.appendingPathComponent("IMG_000\(shade).jpg")
            try makeTestJPEG(at: original, shade: shade)
            originals.append(original)
        }
        let package = scratch.appendingPathComponent("Library.photolibrary")
        let store = try CatalogStore(packageURL: package)
        try store.addSourceRoot(id: "source-1", displayName: "Source", path: source.path, bookmark: nil)
        let imported = ImportCoordinator(store: store)
            .importFiles(originals, from: source, sourceRootId: "source-1", folderName: "Source")
        XCTAssertEqual(imported.count, 3)
        try store.upsert(imported)
        for photo in imported {
            XCTAssertTrue(XMPSidecar.write(photo, to: XMPSidecar.sidecarURL(for: URL(fileURLWithPath: photo.localPath!))))
        }
        let app = AppState()
        app.onboarded = true
        app.runsBackgroundMaintenance = false
        XCTAssertTrue(app.openCatalog(at: package))
        return (app, imported)
    }

    /// The list built off the main thread is the one the app builds from its photos: originals
    /// only, no virtual copy, removed photo or demo photo.
    @MainActor
    func testStaticListIsTheInstanceList() throws {
        let (app, photos) = try appWithCatalog()
        app.selectedIds = [photos[0].id]
        app.setPrimary(photos[0].id)
        app.createVirtualCopies()
        XCTAssertEqual(app.assets.filter(\.isVirtualCopy).count, 1, "a virtual copy was made")
        XCTAssertTrue(app.mutate([photos[1].id]) { $0.deleted = true })

        let listed = AppState.xmpCheckCandidates(in: app.assets)
        let instance = app.xmpCheckCandidates()
        XCTAssertEqual(listed.map(\.id), instance.map(\.id))
        XCTAssertEqual(listed.map(\.path), instance.map(\.path))
        XCTAssertEqual(Set(listed.map(\.id)), [photos[0].id, photos[2].id])
        XCTAssertEqual(AppState.xmpCheckCandidates(in: Array(DemoData.assets.prefix(5))).count, 0, "demo photos aren't listed")
        XCTAssertEqual(app.assets.filter(AppState.isXMPCandidate).map(\.id), listed.map(\.id))
    }

    /// A check asked for again before the first has finished doesn't start a second: it waits
    /// its turn, and the first check's sightings are stored once.
    @MainActor
    func testCheckAskedForTwiceRunsOnce() async throws {
        let (app, photos) = try appWithCatalog()
        for photo in photos { XCTAssertNil(app.xmpSyncTime(for: photo.id), "no sidecar seen yet") }
        // on only now, so opening the catalog started no check of its own
        app.runsBackgroundMaintenance = true
        defer { app.runsBackgroundMaintenance = false }   // the waiting check then stops at its guard
        let count = app.xmpSyncCount

        app.checkExternalXMPChanges()
        let started = try XCTUnwrap(app.lastXMPCheck)
        XCTAssertTrue(app.isCheckingXMP)
        app.checkExternalXMPChanges()
        XCTAssertEqual(app.lastXMPCheck, started, "the second check didn't start")
        XCTAssertTrue(app.xmpCheckPending, "the second check waits its turn")

        try await waitUntil("the check finished") { !app.isCheckingXMP }
        XCTAssertEqual(app.xmpSyncCount, count + 1, "the sightings were stored once")
        for photo in photos {
            XCTAssertEqual(app.xmpSyncTime(for: photo.id), XMPSidecar.modificationTime(forOriginal: photo.localPath!))
        }
        XCTAssertEqual(app.externallyChangedXMPIds, [], "a first sighting isn't a change")
    }
}
