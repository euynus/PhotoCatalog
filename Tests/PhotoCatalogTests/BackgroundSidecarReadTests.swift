import XCTest
@testable import PhotoCatalog

/// With Read Changed XMP Automatically on, the background check reads the changed sidecars off
/// the main actor and takes them in once it's back: not for a photo removed meanwhile, not for a
/// sidecar read or written again meanwhile, and never twice.
final class BackgroundSidecarReadTests: CatalogTestCase {
    private static let readToast = "已从 1 个 XMP 附属文件读取元数据"

    /// What the app's toasts said, kept past their 2.2 s on screen.
    private final class Heard {
        var messages: [String] = []
    }
    private var heard = Heard()

    /// A catalog of one photo whose sidecar the app has seen, opened with background work off
    /// and automatic reading on.
    @MainActor
    private func appWithPhoto() throws -> (app: AppState, photo: Asset, sidecar: URL) {
        let source = scratch.appendingPathComponent("Source")
        let original = source.appendingPathComponent("IMG_0001.jpg")
        try makeTestJPEG(at: original, shade: 3)
        let package = scratch.appendingPathComponent("Library.photolibrary")
        let store = try CatalogStore(packageURL: package)
        try store.addSourceRoot(id: "source-1", displayName: "Source", path: source.path, bookmark: nil)
        var photo = try XCTUnwrap(ImportCoordinator(store: store)
            .importFiles([original], from: source, sourceRootId: "source-1", folderName: "Source").first)
        photo.rating = 1
        photo.keywords = ["mine"]
        try store.upsert([photo])
        let sidecar = XMPSidecar.sidecarURL(for: original)
        XCTAssertTrue(XMPSidecar.write(photo, to: sidecar))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-100)],
                                              ofItemAtPath: sidecar.path)
        let app = AppState()
        app.onboarded = true
        app.runsBackgroundMaintenance = false
        XCTAssertTrue(app.openCatalog(at: package))
        let heard = heard
        app.toastCenter.announce = { message, _ in heard.messages.append(message) }
        app.checkExternalXMPChangesNow()
        XCTAssertNotNil(app.xmpSyncTime(for: photo.id), "the sidecar's starting point is known")
        app.autoReadChangedXMP = true
        return (app, photo, sidecar)
    }

    /// Another app writes the photo's sidecar: its rating and keyword, dated `secondsLater`.
    private func otherAppWrites(_ photo: Asset, to sidecar: URL, rating: Int, keyword: String,
                                secondsLater: TimeInterval) throws {
        var theirs = photo
        theirs.rating = rating
        theirs.keywords = [keyword]
        XCTAssertTrue(XMPSidecar.write(theirs, to: sidecar))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(secondsLater)],
                                              ofItemAtPath: sidecar.path)
    }

    @MainActor
    private func current(_ app: AppState, _ id: String) -> Asset? { app.assets.first { $0.id == id } }

    /// How many times a sidecar read was reported.
    private func readToasts() -> Int {
        heard.messages.filter { $0 == Self.readToast }.count
    }

    /// A check worked out in the background reads the changed sidecar once it's back, not
    /// before it returns; the change is then taken in and remembered.
    @MainActor
    func testBackgroundCheckReadsTheChangedSidecarAfterward() async throws {
        let (app, photo, sidecar) = try appWithPhoto()
        try otherAppWrites(photo, to: sidecar, rating: 4, keyword: "theirs", secondsLater: 10)
        let snapshot = app.xmpSyncSnapshot()
        let found = AppState.findChangedSidecars(app.xmpCheckCandidates(), known: [photo.id: app.xmpSyncTime(for: photo.id)!],
                                                 pairing: snapshot.pairing)
        XCTAssertEqual(Set(found.changed.keys), [photo.id])

        app.applyExternalXMPCheck(seeded: found.seeded, changed: found.changed, pairingDependent: found.pairingDependent,
                                  since: snapshot, readingInBackground: true)
        XCTAssertEqual(current(app, photo.id)?.rating, 1, "read off the main actor, so not yet")
        XCTAssertEqual(app.externallyChangedXMPIds, [photo.id])

        try await waitUntil("the sidecar is read") { self.current(app, photo.id)?.rating == 4 }
        XCTAssertEqual(current(app, photo.id)?.keywords, ["theirs"])
        XCTAssertEqual(app.externallyChangedXMPIds, [], "read, so no longer changed elsewhere")
        XCTAssertEqual(app.xmpSyncTime(for: photo.id), XMPSidecar.modificationTime(of: sidecar))
        XCTAssertEqual(readToasts(), 1)
        app.checkExternalXMPChangesNow()
        XCTAssertEqual(app.externallyChangedXMPIds, [], "and the next check finds nothing new")
    }

    /// The whole background check, start to finish, with automatic reading on.
    @MainActor
    func testBackgroundCheckFromStartReadsTheChange() async throws {
        let (app, photo, sidecar) = try appWithPhoto()
        try otherAppWrites(photo, to: sidecar, rating: 3, keyword: "bridge", secondsLater: 10)
        app.runsBackgroundMaintenance = true
        defer { app.runsBackgroundMaintenance = false }
        app.checkExternalXMPChanges()
        try await waitUntil("the sidecar is read") { self.current(app, photo.id)?.rating == 3 }
        XCTAssertEqual(current(app, photo.id)?.keywords, ["bridge"])
        XCTAssertEqual(app.externallyChangedXMPIds, [])
    }

    /// A photo removed from the catalog while its sidecar is read stays as it was removed.
    @MainActor
    func testPhotoRemovedDuringTheReadIsLeftAlone() async throws {
        let (app, photo, sidecar) = try appWithPhoto()
        try otherAppWrites(photo, to: sidecar, rating: 4, keyword: "theirs", secondsLater: 10)
        let synced = app.xmpSyncTime(for: photo.id)

        let reading = try XCTUnwrap(app.readChangedSidecarsInBackground([photo.id]))
        // before the read is back: the main actor isn't let go of until the await
        app.selectedIds = [photo.id]
        app.setPrimary(photo.id)
        app.removeSelected()
        XCTAssertEqual(current(app, photo.id)?.deleted, true)
        await reading.value

        XCTAssertEqual(current(app, photo.id)?.rating, 1, "the removed photo keeps the catalog's metadata")
        XCTAssertEqual(current(app, photo.id)?.keywords, ["mine"])
        XCTAssertEqual(app.xmpSyncTime(for: photo.id), synced, "and its sidecar isn't taken as read")
        XCTAssertEqual(readToasts(), 0)
    }

    /// A sidecar read from the menu while the background read is under way is taken in once:
    /// the background read, from before it, doesn't apply it again over a later edit.
    @MainActor
    func testSidecarReadMeanwhileIsNotTakenInTwice() async throws {
        let (app, photo, sidecar) = try appWithPhoto()
        try otherAppWrites(photo, to: sidecar, rating: 4, keyword: "theirs", secondsLater: 10)

        let reading = try XCTUnwrap(app.readChangedSidecarsInBackground([photo.id]))
        XCTAssertEqual(app.readMetadataFromFiles([photo.id]), 1, "read from the menu meanwhile")
        XCTAssertEqual(current(app, photo.id)?.rating, 4)
        XCTAssertTrue(app.setRating(5, on: [photo.id]))
        await reading.value

        XCTAssertEqual(current(app, photo.id)?.rating, 5, "the later edit isn't overwritten")
        XCTAssertEqual(readToasts(), 1, "taken in once")
    }

    /// A sidecar recorded anew while the background read is under way (our own write) isn't
    /// taken in from the read.
    @MainActor
    func testSidecarRecordedDuringTheReadIsSkipped() async throws {
        let (app, photo, sidecar) = try appWithPhoto()
        try otherAppWrites(photo, to: sidecar, rating: 4, keyword: "theirs", secondsLater: 10)

        let reading = try XCTUnwrap(app.readChangedSidecarsInBackground([photo.id]))
        let recorded = try XCTUnwrap(XMPSidecar.modificationTime(of: sidecar))
        app.recordXMPSync([photo.id: recorded])
        await reading.value

        XCTAssertEqual(current(app, photo.id)?.rating, 1, "the read from before the record isn't taken in")
        XCTAssertEqual(app.xmpSyncTime(for: photo.id), recorded)
        XCTAssertEqual(readToasts(), 0)
    }

    /// A sidecar changed again after the background read looked at it but before the read is
    /// taken in: the read's own time is remembered, so the next check still finds the change,
    /// and reads it once.
    @MainActor
    func testSidecarChangedDuringTheReadIsFoundByTheNextCheck() throws {
        let (app, photo, sidecar) = try appWithPhoto()
        try otherAppWrites(photo, to: sidecar, rating: 4, keyword: "first", secondsLater: 10)
        let snapshot = app.xmpSyncSnapshot()
        // the background hop's work, then another write before the main actor takes it in
        let read = AppState.readSidecars([(photo.id, photo.localPath!)], pairing: snapshot.pairing)
        XCTAssertEqual(read.map(\.id), [photo.id])
        try otherAppWrites(photo, to: sidecar, rating: 2, keyword: "second", secondsLater: 40)
        app.takeInBackgroundRead(read, since: snapshot)
        XCTAssertEqual(current(app, photo.id)?.rating, 4)
        XCTAssertEqual(readToasts(), 1)

        app.autoReadChangedXMP = false
        app.checkExternalXMPChangesNow()
        XCTAssertEqual(app.externallyChangedXMPIds, [photo.id], "the second write is found")
        app.autoReadChangedXMP = true
        app.checkExternalXMPChangesNow()
        XCTAssertEqual(current(app, photo.id)?.rating, 2)
        XCTAssertEqual(current(app, photo.id)?.keywords, ["second"])
        XCTAssertEqual(app.externallyChangedXMPIds, [])
        XCTAssertEqual(readToasts(), 2, "each version read once")
        app.checkExternalXMPChangesNow()
        XCTAssertEqual(readToasts(), 2, "and not again")
    }
}
