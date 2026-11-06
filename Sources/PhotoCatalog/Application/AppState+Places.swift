import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
extension AppState {
    // ---------- location: place on a map, match a GPX track ----------
    /// Photos a location edit applies to: the selection, or the photo in Loupe / Develop.
    var locationTargetIds: Set<String> {
        let ids = selectionTargetIds
        return Set(ids.filter { id in assetIndex[id].map { !assets[$0].deleted } ?? false })
    }

    var canEditLocation: Bool { onboarded && sheet == nil && selectionSummary.hasLive }

    func showLocationEditor() {
        guard canEditLocation else { return }
        sheet = "location"
    }

    /// Where the location editor opens: the spot the selected photos share, else the primary's.
    var locationEditorStart: (Double, Double)? {
        let located = locationTargetIds.compactMap { id in assetIndex[id].map { assets[$0] } }.filter(\.hasGPS)
        if let first = located.first,
           located.count == locationTargetIds.count,
           located.allSatisfy({ $0.gps.0 == first.gps.0 && $0.gps.1 == first.gps.1 }) {
            return first.gps
        }
        return primary.flatMap { $0.hasGPS ? $0.gps : nil }
    }

    /// Sets (or with nil removes) the location of `ids`, as one undoable step.
    @discardableResult
    func setLocation(_ coordinate: (Double, Double)?, altitude: Double? = nil, for ids: Set<String>) -> Bool {
        guard !ids.isEmpty else { return false }
        // a RAW's paired JPEG was taken at the same spot
        let applied = mutate(withCompanions(ids), undoName: coordinate == nil ? L("移除位置") : L("设置位置")) { asset in
            asset.gps = coordinate ?? (0, 0)
            asset.gpsAltitude = coordinate == nil ? nil : altitude
            asset.location = Asset.locationLabel(coordinate)
        }
        if applied {
            push(coordinate == nil ? "已移除 \(ids.count) 张照片的位置" : "已为 \(ids.count) 张照片设置位置", "location")
        }
        return applied
    }

    /// Whether any of `ids` has a location: looked up by id, as the location dialog asks on every
    /// keystroke in its search field and a catalog can hold half a million photos.
    func anyHasLocation(_ ids: Set<String>) -> Bool {
        let index = assetIndex, assets = self.assets
        return ids.contains { id in index[id].map { assets[$0].hasGPS } ?? false }
    }

    /// Opens a .gpx file and the matching dialog.
    func chooseGPXTrack() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "gpx") ?? .xml]
        panel.prompt = L("打开轨迹")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let track = GPXParser.parse(contentsOf: url), !track.points.isEmpty else {
            push("「\(url.lastPathComponent)」里没有带时间的轨迹点", "warning")
            return
        }
        gpxTrack = (url.lastPathComponent, track)
        sheet = "gpx"
    }

    /// Where each photo of `ids` was along the track. Capture times are the camera's wall clock,
    /// so `cameraUTCOffset` (seconds) turns them into the track's UTC instants. Photos that
    /// already have a location are left alone unless `overwrite`.
    func gpxMatches(_ track: GPXTrack, ids: Set<String>, cameraUTCOffset: Int,
                    overwrite: Bool) -> [String: GPXPoint] {
        Self.gpxMatches(track, ids: ids, in: gpxMatchPhotos, cameraUTCOffset: cameraUTCOffset, overwrite: overwrite)
    }

    /// The photos as matching them to a track reads them, taken here to match them off the main
    /// actor: the matching dialog goes through a whole view's photos as its settings change.
    struct GPXMatchPhotos: Sendable {
        fileprivate let assets: [Asset]
        fileprivate let index: [String: Int]
    }

    var gpxMatchPhotos: GPXMatchPhotos { GPXMatchPhotos(assets: assets, index: assetIndex) }

    /// Where on `track` each of `ids` was taken (by capture time, the camera's clock `cameraUTCOffset`
    /// seconds ahead of UTC); photos with a location only when `overwrite`.
    nonisolated static func gpxMatches(_ track: GPXTrack, ids: Set<String>, in photos: GPXMatchPhotos,
                                       cameraUTCOffset: Int, overwrite: Bool) -> [String: GPXPoint] {
        var matches: [String: GPXPoint] = [:]
        for id in ids {
            guard let index = photos.index[id] else { continue }
            let asset = photos.assets[index]
            guard overwrite || !asset.hasGPS else { continue }
            let instant = GPXTrack.instant(ofCapture: asset.date, cameraUTCOffset: cameraUTCOffset)
            if let point = track.location(at: instant) { matches[id] = point }
        }
        return matches
    }

    @discardableResult
    func applyGPXMatches(_ matches: [String: GPXPoint]) -> Bool {
        guard !matches.isEmpty else { return false }
        var points = matches
        for (id, point) in matches {
            for companion in withCompanions([id]) where points[companion] == nil { points[companion] = point }
        }
        let applied = mutate(Set(points.keys), undoName: L("匹配 GPX 位置")) { asset in
            guard let point = points[asset.id] else { return }
            asset.gps = (point.latitude, point.longitude)
            asset.gpsAltitude = point.elevation
            asset.location = Asset.locationLabel(asset.gps)
        }
        if applied { push("已按轨迹为 \(matches.count) 张照片添加位置", "location") }
        return applied
    }
}
