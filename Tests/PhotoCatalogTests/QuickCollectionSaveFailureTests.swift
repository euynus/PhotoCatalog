import XCTest
@testable import PhotoCatalog

/// Only the photos that join or leave the quick collection are written, so a save that fails
/// leaves the collection as it was: kept in memory alone, a photo would show as in it while the
/// catalog never got it, and the next B would take it out instead of adding it.
final class QuickCollectionSaveFailureTests: CatalogTestCase {
    /// What the app's toasts said, kept past their time on screen.
    private final class Heard {
        var messages: [String] = []
    }
    private var heard = Heard()

    /// A catalog of one photo, opened and the photo selected.
    @MainActor
    private func appWithSelectedPhoto() throws -> (app: AppState, db: Database, photo: Asset) {
        let (_, package, photo, _) = try importPhoto("IMG_0001.jpg", shade: 3)
        let app = openCatalog(package)
        let heard = heard
        app.toastCenter.announce = { message, _ in heard.messages.append(message) }
        app.selectedIds = [photo.id]
        app.setPrimary(photo.id)
        return (app, try XCTUnwrap(app.store?.db), photo)
    }

    @MainActor
    private func savedMembers(_ db: Database) throws -> [String] {
        try db.query("SELECT asset_id FROM album_assets WHERE album_id=?;", [.text(AppState.quickCollectionID)])
            .compactMap { $0.text("asset_id") }
    }

    @MainActor
    func testFailedAddLeavesTheCollectionAsItWas() throws {
        let (app, db, photo) = try appWithSelectedPhoto()
        try db.failWrites("fail_quick_add", before: "INSERT", on: "album_assets", message: "forced quick collection failure")

        XCTAssertTrue(app.toggleQuickCollection(), "B is handled")
        XCTAssertEqual(app.quickCollection, [], "the photo isn't shown as in the collection")
        XCTAssertEqual(try savedMembers(db), [])
        XCTAssertTrue(heard.messages.contains("快捷收藏保存失败"), "the failure is reported")
        XCTAssertFalse(heard.messages.contains("已加入快捷收藏 1 张"), "and not as added")

        try db.execChecked("DROP TRIGGER fail_quick_add;")
        XCTAssertTrue(app.toggleQuickCollection())
        XCTAssertEqual(app.quickCollection, [photo.id], "B again adds it")
        XCTAssertEqual(try savedMembers(db), [photo.id], "and the catalog has it")
    }

    @MainActor
    func testFailedRemovalKeepsThePhotoIn() throws {
        let (app, db, photo) = try appWithSelectedPhoto()
        XCTAssertTrue(app.toggleQuickCollection())
        XCTAssertEqual(try savedMembers(db), [photo.id])
        try db.failWrites("fail_quick_remove", before: "DELETE", on: "album_assets",
                          message: "forced quick collection failure")

        XCTAssertTrue(app.toggleQuickCollection())
        XCTAssertEqual(app.quickCollection, [photo.id], "the photo stays in, as in the catalog")
        XCTAssertEqual(try savedMembers(db), [photo.id])
        XCTAssertFalse(heard.messages.contains("已从快捷收藏移除 1 张"))
    }
}
