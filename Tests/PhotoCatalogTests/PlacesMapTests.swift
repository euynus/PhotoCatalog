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

    private func unlocated(_ index: Int) -> Asset {
        var asset = DemoData.assets[index]
        asset.gps = (0, 0)
        asset.location = ""
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

    /// The map's body runs with every move of its camera: the located photos are filtered from the
    /// list once per list and edit, and grouped again only when the grid step changes, into the
    /// same pins as grouping them from scratch.
    @MainActor
    func testPinsAreWorkedOutOncePerListEditAndStep() {
        let assets = (0..<40).map { index in
            index % 3 == 0 ? unlocated(index) : photo(index, (35 + Double(index) * 0.001, 139 + Double(index) * 0.002))
        }
        let list = PhotoList(assets: assets, identity: 7)
        let pins = PlacesMapView.Pins()
        func ids(_ clusters: [PlacesMapView.Cluster]) -> [String] {
            clusters.map { "\($0.id) \($0.count) \($0.representative.id) \($0.coordinate.latitude) \($0.coordinate.longitude)" }
        }
        let expected = assets.filter { $0.hasGPS && PlacesMapView.isOnMap($0) }

        XCTAssertEqual(pins.located(in: list, assetRevision: 1).map(\.id), expected.map(\.id))
        XCTAssertEqual(ids(pins.clusters(in: list, assetRevision: 1, step: 0.01)),
                       ids(PlacesMapView.clusters(of: expected, step: 0.01)))
        _ = pins.clusters(in: list, assetRevision: 1, step: 0.01)   // a pan
        XCTAssertEqual(pins.filterings, 1)
        XCTAssertEqual(pins.clusterings, 1, "a pan keeps the pins")

        XCTAssertEqual(ids(pins.clusters(in: list, assetRevision: 1, step: 0.002)),
                       ids(PlacesMapView.clusters(of: expected, step: 0.002)))
        XCTAssertEqual(pins.filterings, 1, "a zoom groups the same photos again")
        XCTAssertEqual(pins.clusterings, 2)

        // a location edit patched into the same list
        var edited = assets
        edited[0] = photo(0, (35, 139))
        let patched = PhotoList(assets: edited, identity: 7)
        XCTAssertEqual(pins.located(in: patched, assetRevision: 2).count, expected.count + 1)
        _ = pins.clusters(in: patched, assetRevision: 2, step: 0.002)
        XCTAssertEqual(pins.filterings, 2)
        XCTAssertEqual(pins.clusterings, 3)

        // another list (another album, a filter)
        _ = pins.clusters(in: PhotoList(assets: Array(edited.prefix(5)), identity: 8), assetRevision: 2, step: 0.002)
        XCTAssertEqual(pins.filterings, 3)
        XCTAssertEqual(pins.clusterings, 4)
    }
}
