import XCTest
@testable import PhotoCatalog

/// With Read Changed XMP Automatically on, a photo edited while its changed sidecar is read in
/// the background keeps the edit: the newer change wins, and the sidecar stays shown as changed
/// elsewhere, unread, until it's read or written or another app changes it again.
final class BackgroundReadEditConflictTests: CatalogTestCase {
    private static let readToast = "已从 1 个 XMP 附属文件读取元数据"

    /// What the app's toasts said, kept past their time on screen.
    private final class Heard {
        var messages: [String] = []
    }
    private var heard = Heard()

    /// A catalog of one photo (rated 1, keyword "mine") whose sidecar the app has seen, opened
    /// with background work off and automatic reading on.
    @MainActor
    private func appWithPhoto() throws -> (app: AppState, photo: Asset, sidecar: URL) {
        let (store, package, imported, original) = try importPhoto("IMG_0001.jpg", shade: 3)
        var photo = imported
        photo.rating = 1
        photo.keywords = ["mine"]
        try store.upsert([photo])
        let sidecar = XMPSidecar.sidecarURL(for: original)
        XCTAssertTrue(XMPSidecar.write(photo, to: sidecar))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-100)],
                                              ofItemAtPath: sidecar.path)
        let app = openCatalog(package)
        app.autoWriteXMPSidecar = false
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

    private func readToasts() -> Int { heard.messages.filter { $0 == Self.readToast }.count }

    /// A rating given while the sidecar is read stands, with the rest of the catalog's metadata;
    /// the sidecar shows as changed elsewhere, through later checks too, without being read
    /// again, until it's read from the menu.
    @MainActor
    func testEditDuringTheReadWinsAndStaysShown() async throws {
        let (app, photo, sidecar) = try appWithPhoto()
        try otherAppWrites(photo, to: sidecar, rating: 4, keyword: "theirs", secondsLater: 10)

        let reading = try XCTUnwrap(app.readChangedSidecarsInBackground([photo.id]))
        // before the read is back: the main actor isn't let go of until the await
        XCTAssertTrue(app.setRating(5, on: [photo.id]))
        await reading.value

        XCTAssertEqual(current(app, photo.id)?.rating, 5, "the edit made during the read stands")
        XCTAssertEqual(current(app, photo.id)?.keywords, ["mine"], "and the sidecar isn't taken in")
        XCTAssertEqual(app.externallyChangedXMPIds, [photo.id], "the sidecar shows as changed elsewhere")
        XCTAssertEqual(app.xmpSyncTime(for: photo.id), XMPSidecar.modificationTime(of: sidecar),
                       "its time is recorded, so it isn't read again")
        XCTAssertEqual(readToasts(), 0)

        app.checkExternalXMPChangesNow()
        XCTAssertEqual(current(app, photo.id)?.rating, 5, "a later check doesn't read it over the edit")
        XCTAssertEqual(app.externallyChangedXMPIds, [photo.id], "and still shows it")
        XCTAssertEqual(readToasts(), 0)

        XCTAssertEqual(app.readMetadataFromFiles([photo.id]), 1, "read from the menu")
        XCTAssertEqual(current(app, photo.id)?.rating, 4)
        XCTAssertEqual(app.externallyChangedXMPIds, [])
        app.checkExternalXMPChangesNow()
        XCTAssertEqual(app.externallyChangedXMPIds, [], "settled")
    }

    /// Another app changes the sidecar again after the edit won: that newer change is read.
    @MainActor
    func testSidecarChangedAgainAfterTheConflictIsRead() async throws {
        let (app, photo, sidecar) = try appWithPhoto()
        try otherAppWrites(photo, to: sidecar, rating: 4, keyword: "theirs", secondsLater: 10)
        let reading = try XCTUnwrap(app.readChangedSidecarsInBackground([photo.id]))
        XCTAssertTrue(app.setRating(5, on: [photo.id]))
        await reading.value
        XCTAssertEqual(current(app, photo.id)?.rating, 5)

        try otherAppWrites(photo, to: sidecar, rating: 2, keyword: "again", secondsLater: 40)
        app.checkExternalXMPChangesNow()
        XCTAssertEqual(current(app, photo.id)?.rating, 2, "the newer change is read")
        XCTAssertEqual(current(app, photo.id)?.keywords, ["again"])
        XCTAssertEqual(app.externallyChangedXMPIds, [])
        XCTAssertEqual(readToasts(), 1)
    }

    /// A change the sidecar doesn't carry (a flag) made during the read doesn't hold it back.
    @MainActor
    func testChangeTheSidecarDoesNotCarryLetsTheReadIn() async throws {
        let (app, photo, sidecar) = try appWithPhoto()
        try otherAppWrites(photo, to: sidecar, rating: 4, keyword: "theirs", secondsLater: 10)
        let reading = try XCTUnwrap(app.readChangedSidecarsInBackground([photo.id]))
        XCTAssertTrue(app.setFlag(.pick, on: [photo.id]))
        await reading.value

        XCTAssertEqual(current(app, photo.id)?.rating, 4, "the sidecar is taken in")
        XCTAssertEqual(current(app, photo.id)?.keywords, ["theirs"])
        XCTAssertEqual(current(app, photo.id)?.flag, .pick, "with the flag set meanwhile")
        XCTAssertEqual(app.externallyChangedXMPIds, [])
        XCTAssertEqual(readToasts(), 1)
    }
}
