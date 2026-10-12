import XCTest
@testable import PhotoCatalog

/// The library as a catalog opens: All Photographs is ready without being computed, and must
/// be what computing it gives.
final class CatalogOpenListTests: CatalogTestCase {
    @MainActor
    func testOpenedCatalogShowsRawJpegPairAsOnePhoto() throws {
        UserDefaults.standard.set(true, forKey: "pc_pairRawJpeg")
        let folder = scratch.appendingPathComponent("Shoot")
        var raw = try XCTUnwrap(DemoData.assets.first { $0.isRaw })
        var jpeg = try XCTUnwrap(DemoData.assets.first { !$0.isRaw && !$0.isVideo })
        raw.filename = "IMG_0001.CR3"
        raw.localPath = folder.appendingPathComponent(raw.filename).path
        jpeg.filename = "IMG_0001.JPG"
        jpeg.localPath = folder.appendingPathComponent(jpeg.filename).path
        // the JPEG sorts first, so a list that shows it also makes it the photo selected on open
        raw.date = Date(timeIntervalSince1970: 1_700_000_000)
        jpeg.date = Date(timeIntervalSince1970: 1_700_000_001)
        raw.isDemo = false
        jpeg.isDemo = false
        raw.deleted = false
        jpeg.deleted = false
        let package = scratch.appendingPathComponent("Library.photolibrary")
        try CatalogStore(packageURL: package).upsert([raw, jpeg])

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))
        XCTAssertEqual(app.selection.type, .lib)
        XCTAssertEqual(app.selection.id, "all")
        let opened = app.list.map(\.id)
        let openedPrimary = app.primaryId

        // the same list computed: another order and back
        app.setSort(Sort(field: .name, descending: false))
        _ = app.list
        app.setSort(Sort())
        XCTAssertEqual(app.list.map(\.id), [raw.id])
        XCTAssertEqual(opened, [raw.id], "the JPEG is behind its RAW's tile")
        XCTAssertEqual(openedPrimary, raw.id, "the photo selected on open is the RAW, so edits reach both")
    }
}
