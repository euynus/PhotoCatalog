import Foundation

/// Locations: GPX parsing and matching, XMP GPS, and setting / clearing places on photos.
enum LocationCheck {
    static func run() {
        checkGPX()
        checkSidecarGPS()
        MainActor.assumeIsolated { checkCatalogEdits() }
        print("--- location assertions passed ---")
    }

    private static let gpx = """
    <?xml version="1.0" encoding="UTF-8"?>
    <gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1">
      <trk><trkseg>
        <trkpt lat="30.0" lon="114.0"><ele>10</ele><time>2024-05-01T02:00:00Z</time></trkpt>
        <trkpt lat="30.1" lon="114.2"><ele>30</ele><time>2024-05-01T02:10:00Z</time></trkpt>
        <trkpt lat="31.0" lon="115.0"><time>2024-05-01T05:00:00.250Z</time></trkpt>
        <trkpt lat="99" lon="99"></trkpt>
      </trkseg></trk>
    </gpx>
    """

    private static func utc(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    private static func checkGPX() {
        let track = GPXParser.parse(Data(gpx.utf8))!
        assert(track.points.count == 3 && track.points[1].elevation == 30
               && track.end == utc("2024-05-01T05:00:00Z").addingTimeInterval(0.25),
               "timed track points are read (fractional seconds too), untimed skipped")
        let middle = track.location(at: utc("2024-05-01T02:05:00Z"))!
        assert(abs(middle.latitude - 30.05) < 0.001 && abs(middle.longitude - 114.1) < 0.001
               && abs((middle.elevation ?? 0) - 20) < 0.1, "a photo between close fixes is interpolated")
        let snapped = track.location(at: utc("2024-05-01T02:11:30Z"))!
        assert(snapped.latitude == 30.1, "across a long gap the nearest fix within two minutes is used")
        assert(track.location(at: utc("2024-05-01T03:30:00Z")) == nil, "far from any fix there's no match")
        assert(track.location(at: utc("2024-05-01T01:00:00Z")) == nil, "before the track starts there's no match")
        let wallClock = utc("2024-05-01T10:05:00Z")   // 10:05 on a UTC+8 camera
        assert(GPXTrack.instant(ofCapture: wallClock, cameraUTCOffset: 8 * 3600) == utc("2024-05-01T02:05:00Z"),
               "the camera's time zone lines its clock up with the track")
    }

    private static func checkSidecarGPS() {
        assert(XMPSidecar.gpsCoordinate(30.5, positive: "N", negative: "S") == "30,30.000000N"
               && XMPSidecar.gpsCoordinate(-122.25, positive: "E", negative: "W") == "122,15.000000W",
               "coordinates are written as degrees and decimal minutes")
        assert(XMPSidecar.parseGPSCoordinate("30,30.000000N") == 30.5
               && XMPSidecar.parseGPSCoordinate("122,15,0W") == -122.25
               && XMPSidecar.parseGPSCoordinate("12.5") == nil, "both XMP GPS forms parse, junk doesn't")

        var asset = DemoData.assets[0]
        asset.gps = (35.6586, 139.7454)
        asset.location = Asset.locationLabel(asset.gps)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pc-gps-\(UUID().uuidString).xmp")
        defer { try? FileManager.default.removeItem(at: url) }
        XMPSidecar.write(asset, to: url)
        let read = XMPSidecar.read(url)?.gps
        assert(read.map { abs($0.0 - 35.6586) < 1e-5 && abs($0.1 - 139.7454) < 1e-5 } == true,
               "a location round-trips through the sidecar")
    }

    @MainActor
    private static func checkCatalogEdits() {
        let app = AppState.selfCheckFixture()
        app.assets = DemoData.assets.map {
            var asset = $0
            asset.gps = (0, 0)
            asset.location = ""
            return asset
        }
        app.duplicateGroupsCache = []
        app.select(Selection(type: .lib, id: "all", name: "Location check"))
        let ids = Array(app.list.prefix(3).map(\.id))
        let undo = UndoManager()
        undo.groupsByEvent = false
        app.undoManager = undo
        undo.beginUndoGrouping()
        app.setLocation((48.8584, 2.2945), for: Set(ids.prefix(2)))
        undo.endUndoGrouping()
        let placed = app.assets.filter { ids.prefix(2).contains($0.id) }
        assert(placed.allSatisfy { $0.hasGPS && $0.location == "48.858, 2.295" }, "setting a place writes coordinates")
        undo.undo()
        assert(!app.assets.contains { ids.contains($0.id) && $0.hasGPS }, "undo takes the place back")
        app.undoManager = nil

        // a track covering the first photo's capture time on a UTC+2 camera
        let first = app.assets.first { $0.id == ids[0] }!
        let instant = GPXTrack.instant(ofCapture: first.date, cameraUTCOffset: 7200)
        let track = GPXTrack(points: [
            GPXPoint(latitude: 1, longitude: 2, elevation: nil, time: instant.addingTimeInterval(-60)),
            GPXPoint(latitude: 3, longitude: 4, elevation: nil, time: instant.addingTimeInterval(60)),
        ])
        let matches = app.gpxMatches(track, ids: Set(ids), cameraUTCOffset: 7200, overwrite: false)
        assert(matches.keys.contains(ids[0]) && matches[ids[0]]?.latitude == 2, "matching finds the photo on the track")
        assert(app.applyGPXMatches(matches) && app.assets.first { $0.id == ids[0] }?.hasGPS == true,
               "applying matches places the photos")
        assert(app.gpxMatches(track, ids: Set(ids), cameraUTCOffset: 7200, overwrite: false)[ids[0]] == nil,
               "photos with a location are left alone unless overwriting")
        app.setLocation(nil, for: [ids[0]])
        assert(app.assets.first { $0.id == ids[0] }?.hasGPS == false, "a place can be removed")
    }
}
