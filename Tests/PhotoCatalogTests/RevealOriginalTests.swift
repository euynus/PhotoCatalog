import XCTest
@testable import PhotoCatalog

/// Show in Finder is offered from the catalog's status of a photo, without looking at its file;
/// the action finds the photo by id and checks the file before revealing it.
final class RevealOriginalTests: CatalogTestCase {
    @MainActor
    func testRevealIsOfferedForReadyPhotosWithAnOriginal() {
        let app = AppState()
        var photo = DemoData.assets[0]
        photo.isDemo = false
        photo.localPath = "/Volumes/Elsewhere/photo.jpg"
        photo.status = .ready
        XCTAssertTrue(app.canRevealOriginal(photo), "ready: offered, whether or not the file is there now")

        var offline = photo
        offline.status = .offline
        XCTAssertFalse(app.canRevealOriginal(offline))
        var missing = photo
        missing.status = .missing
        XCTAssertFalse(app.canRevealOriginal(missing), "missing: Locate is offered instead")
        var noPath = photo
        noPath.localPath = nil
        XCTAssertFalse(app.canRevealOriginal(noPath))
        var demo = photo
        demo.isDemo = true
        XCTAssertFalse(app.canRevealOriginal(demo))
    }

    /// A file gone since the catalog last looked: offered, and the click says it's gone.
    @MainActor
    func testRevealingAPhotoWhoseFileIsGoneSaysSo() throws {
        let file = scratch.appendingPathComponent("Source/photo.jpg")
        try makeTestJPEG(at: file, shade: 1)
        let package = scratch.appendingPathComponent("Library.photolibrary")
        var photo = DemoData.assets[0]
        photo.isDemo = false
        photo.deleted = false
        photo.localPath = file.path
        photo.status = .ready
        try CatalogStore(packageURL: package).upsert([photo])
        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))
        try FileManager.default.removeItem(at: file)

        let current = try XCTUnwrap(app.asset(id: photo.id))
        XCTAssertTrue(app.canRevealOriginal(current))
        app.revealInFinder(photo.id)
        XCTAssertEqual(app.toastCenter.toasts.last?.message, "原件不存在，请先重新定位")
    }

    @MainActor
    func testRevealAndLocateFindThePhotoById() {
        let app = AppState()
        let demo = DemoData.assets[3]

        app.revealInFinder("no-such-photo")
        XCTAssertEqual(app.toastCenter.toasts.last?.message, "演示照片没有本地原件")
        let toasts = app.toastCenter.toasts.count
        app.locate("no-such-photo")
        XCTAssertEqual(app.toastCenter.toasts.count, toasts, "no photo, nothing to locate")

        app.locate(demo.id)
        XCTAssertEqual(app.toastCenter.toasts.count, toasts + 1)
        XCTAssertEqual(app.toastCenter.toasts.last?.message, "演示照片没有本地原件", "found the demo photo by its id")
    }
}
