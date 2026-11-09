import XCTest
@testable import PhotoCatalog

/// An import batch into a new album whose photos are all JPEGs behind RAWs the catalog has shows
/// none of them: the album's count in the sidebar's counts is none, as counting again gives it,
/// rather than missing (which a debug build's check of the carried counts caught).
final class HiddenImportAlbumCountTests: DerivedCacheTestCase {
    @MainActor
    func testANewAlbumOfJpegsBehindTheirRawsCountsNone() throws {
        let app = try catalog()
        check(app, "JPEGs behind their RAWs, into a new album") {
            app.addImportBatch([photo("n1", "IMG_0001.JPG"), photo("n2", "sub/deep/IMG_0101.JPG", offset: 2 * 86_400)],
                               revivedIds: [], album: ("hidden", "Hidden"))
        }
        XCTAssertTrue(app.assetPairing.isHiddenCompanion("n1") && app.assetPairing.isHiddenCompanion("n2"))
        XCTAssertEqual(app.sidebarCounts.albums["hidden"], 0)
    }

    /// The same for a removed JPEG behind its RAW imported again: it comes back in its place.
    @MainActor
    func testANewAlbumOfARemovedJpegBehindItsRawCountsNone() throws {
        let app = try catalog()
        let returning = try XCTUnwrap(app.asset(id: "a6j"))
        XCTAssertTrue(app.mutate(["a6j"]) { $0.deleted = true })
        check(app, "a removed JPEG behind its RAW imported again, into a new album") {
            app.addImportBatch([returning], revivedIds: ["a6j"], album: ("hidden", "Hidden"))
        }
        XCTAssertTrue(app.assetPairing.isHiddenCompanion("a6j"))
        XCTAssertEqual(app.sidebarCounts.albums["hidden"], 0)
    }
}
