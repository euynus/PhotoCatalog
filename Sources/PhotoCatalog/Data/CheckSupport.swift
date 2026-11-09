import Foundation

// Fixtures the headless checks share.

extension AppState {
    /// A fixture showing `photos` from `store` as opening the catalog would, running no background
    /// maintenance: for checks that reload a scratch catalog of their own.
    static func selfCheckFixture(store: CatalogStore, loading photos: [Asset]) -> AppState {
        let app = selfCheckFixture(store: store)
        app.runsBackgroundMaintenance = false
        app.applyLoadedCatalogForScaleCheck(photos, from: store)
        return app
    }
}

extension Asset {
    /// This photo made again through the initializer with these fields changed: for checks and
    /// tests that need another id, cache path, type or camera, which production never changes, so
    /// they can't be set. Every other field is this photo's, masterId, copyName and duration too.
    func rebuilt(id: String? = nil, thumb: String? = nil, preview: String? = nil, type: String? = nil,
                 isRaw: Bool? = nil, camera: String? = nil) -> Asset {
        Asset(id: id ?? self.id, pid: pid, ori: ori, thumb: thumb ?? self.thumb, preview: preview ?? self.preview,
              filename: filename, type: type ?? self.type, isRaw: isRaw ?? self.isRaw, folderId: folderId,
              folderName: folderName, date: date, width: width, height: height, orientation: orientation,
              camera: camera ?? self.camera, lens: lens, focal: focal, aperture: aperture, shutter: shutter,
              iso: iso, colorSpace: colorSpace, hasICCProfile: hasICCProfile, fileMB: fileMB,
              fileModifiedAt: fileModifiedAt, fileCreatedAt: fileCreatedAt, rating: rating, flag: flag,
              colorLabel: colorLabel, keywords: keywords, title: title, caption: caption, author: author,
              copyright: copyright, makerNotes: makerNotes, project: project, client: client, location: location,
              gps: gps, gpsAltitude: gpsAltitude, status: status, importedAt: importedAt, deleted: deleted,
              localPath: localPath, captureDateSource: captureDateSource, contentHash: contentHash,
              quickHash: quickHash, isDemo: isDemo, faces: faces, perceptualHash: perceptualHash,
              masterId: masterId, copyName: copyName, duration: duration)
    }
}
