import XCTest
@testable import PhotoCatalog

final class DevelopPreviewEngineTests: XCTestCase {
    func testLateRenderOfThePreviousPhotoDoesNotReplaceTheCurrentOne() {
        // A's full-resolution render (token 2) lands after B's preview (token 4) is shown
        XCTAssertFalse(DevelopPreviewEngine.shows(assetId: "A", token: 2, requested: "B", over: ("B", 4)))
        // ... or before anything of B is shown
        XCTAssertFalse(DevelopPreviewEngine.shows(assetId: "A", token: 2, requested: "B", over: ("A", 3)))
    }

    func testFirstRenderOfTheNewPhotoReplacesThePreviousPhoto() {
        XCTAssertTrue(DevelopPreviewEngine.shows(assetId: "B", token: 4, requested: "B", over: ("A", 3)))
        XCTAssertTrue(DevelopPreviewEngine.shows(assetId: "B", token: 1, requested: "B", over: nil))
    }

    func testSamePhotoKeepsTheNewestRender() {
        // a coalesced older render still beats a stale one while dragging
        XCTAssertTrue(DevelopPreviewEngine.shows(assetId: "B", token: 6, requested: "B", over: ("B", 5)))
        XCTAssertTrue(DevelopPreviewEngine.shows(assetId: "B", token: 5, requested: "B", over: ("B", 5)))
        XCTAssertFalse(DevelopPreviewEngine.shows(assetId: "B", token: 4, requested: "B", over: ("B", 5)))
    }
}
