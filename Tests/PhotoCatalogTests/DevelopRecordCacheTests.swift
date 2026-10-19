import XCTest
@testable import PhotoCatalog

/// Develop history and snapshots are read from the catalog per photo shown; going through a
/// whole library keeps only the recent ones in memory.
final class DevelopRecordCacheTests: CatalogTestCase {
    @MainActor
    func testBrowsingManyPhotosKeepsTheHistoryCacheBounded() throws {
        let store = try CatalogStore(packageURL: scratch.appendingPathComponent("History.photolibrary"))
        let app = AppState.selfCheckFixture(store: store)
        var exposure = DevelopSettings()
        exposure.exposure = 1
        var contrast = DevelopSettings()
        contrast.contrast = 20

        app.commitDevelop(["first": exposure], undoName: "调整曝光度")
        XCTAssertEqual(app.developHistory(for: "first").map(\.name), ["调整曝光度"])
        app.primaryId = "current"
        XCTAssertEqual(app.developHistory(for: "current").count, 0)
        XCTAssertEqual(app.developSnapshots(for: "current").count, 0)

        for index in 0..<200 {
            _ = app.developHistory(for: "photo-\(index)")
            _ = app.developSnapshots(for: "photo-\(index)")
        }

        XCTAssertLessThanOrEqual(app.cachedDevelopRecordCount, 64, "only the recently shown photos stay in memory")
        // a step stored behind the cache's back shows only once the photo is read again
        try store.appendDevelopHistory(["current": (name: "外部", settings: contrast)])
        XCTAssertEqual(app.developHistory(for: "current").count, 0, "the photo on screen is never dropped")

        // a step added while the photo was out of memory is there when it's read again
        app.commitDevelop(["first": contrast], undoName: "调整对比度")
        XCTAssertEqual(app.developHistory(for: "first").map(\.name), ["调整曝光度", "调整对比度"])
    }
}
