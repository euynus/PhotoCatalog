import XCTest
@testable import PhotoCatalog

/// Places groups photos by where they were taken into one pin per map cell.
final class PlacesMapTests: XCTestCase {
    private func photo(_ index: Int, _ gps: (Double, Double)) -> Asset {
        var asset = DemoData.assets[index]
        asset.gps = gps
        asset.location = Asset.locationLabel(gps)
        return asset
    }

    /// A location that isn't a place on Earth (one an older version read from a malformed
    /// sidecar) is left off the map instead of stopping the app.
    @MainActor
    func testClustersLeaveOutImpossibleLocations() {
        let located = [
            photo(0, (35.0, 139.0)),
            photo(1, (.nan, 10)),
            photo(2, (.infinity, 10)),
            photo(3, (1e300, -1e300)),
            photo(4, (35.0001, 139.0001)),
        ]
        let clusters = PlacesMapView.clusters(of: located, step: 0.01)
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters.first?.count, 2, "the two real places share a pin")
    }
}
