import XCTest
@testable import PhotoCatalog

/// The location dialogs ask about the photos they place by id, not by going through the catalog.
final class LocationLookupTests: XCTestCase {
    override func setUp() {
        super.setUp()
        openingNoCatalogAtLaunch()
    }

    @MainActor
    func testAnyHasLocationAsksOnlyAboutThePhotos() {
        let app = AppState()
        app.assets = app.assets.enumerated().map { offset, asset in
            var asset = asset
            asset.gps = offset % 4 == 0 ? (35.0, 139.0) : (0, 0)
            asset.location = Asset.locationLabel(offset % 4 == 0 ? asset.gps : nil)
            return asset
        }
        let located = app.assets.filter(\.hasGPS).map(\.id)
        let unlocated = app.assets.filter { !$0.hasGPS }.map(\.id)
        XCTAssertFalse(located.isEmpty)
        XCTAssertFalse(unlocated.isEmpty)
        XCTAssertTrue(app.anyHasLocation(Set(unlocated.prefix(3) + located.prefix(1))))
        XCTAssertFalse(app.anyHasLocation(Set(unlocated.prefix(5))))
        XCTAssertFalse(app.anyHasLocation(["no-such-photo"]))
        XCTAssertFalse(app.anyHasLocation([]))
    }

    /// The GPX dialog matches off the main actor, from the photos as they were when it asked.
    @MainActor
    func testGPXMatchingOffTheMainActorMatchesAsTheAppDoes() async {
        let app = AppState()
        XCTAssertTrue(app.assets.allSatisfy(\.isDemo), "the demo photos, not a catalog's")
        // photos without a location of their own, so matching without overwriting places them too
        // (demo photos come located)
        app.assets = app.assets.map { asset in
            var asset = asset
            asset.gps = (0, 0)
            asset.location = Asset.locationLabel(nil)
            return asset
        }
        let photos = Array(app.assets.prefix(40))
        let ids = Set(photos.map(\.id))
        let first = photos.min { $0.date < $1.date }!, last = photos.max { $0.date < $1.date }!
        let start = GPXTrack.instant(ofCapture: first.date, cameraUTCOffset: 3600)
        let end = GPXTrack.instant(ofCapture: last.date, cameraUTCOffset: 3600)
        let step = max(60, end.timeIntervalSince(start) / 200)
        let track = GPXTrack(points: stride(from: 0.0, through: end.timeIntervalSince(start) + 60, by: step).map {
            GPXPoint(latitude: 40 + $0 / 1e6, longitude: 10, elevation: nil, time: start.addingTimeInterval($0))
        })
        for overwrite in [false, true] {
            let expected = app.gpxMatches(track, ids: ids, cameraUTCOffset: 3600, overwrite: overwrite)
            XCTAssertFalse(expected.isEmpty, "the track covers the photos")
            let snapshot = app.gpxMatchPhotos
            let matched = await Task.detached {
                AppState.gpxMatches(track, ids: ids, in: snapshot, cameraUTCOffset: 3600, overwrite: overwrite)
            }.value
            XCTAssertEqual(matched.keys.sorted(), expected.keys.sorted())
            XCTAssertEqual(matched.mapValues(\.latitude), expected.mapValues(\.latitude))
        }
    }
}
