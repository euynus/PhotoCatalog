import Foundation
@testable import PhotoCatalog

/// Photos the tests catalog, with only what a test varies left to it. Each caller states the
/// file type and whether the photo is a demo one, rather than taking a default for either.
extension Asset {
    /// A ready 6000 × 4000 landscape shot from the 2026-10-12 folder, at 50 mm, f/4, 1/100 s and
    /// ISO 100, 1 MB, unflagged and untitled.
    static func dayShot(_ id: String, _ filename: String, type: String, isRaw: Bool, camera: String, date: Date,
                        importedAt: Date, rating: Int = 0, keywords: [String] = [], localPath: String,
                        isDemo: Bool) -> Asset {
        Asset(id: id, pid: 0, ori: "l", thumb: "", preview: "", filename: filename,
              type: type, isRaw: isRaw, folderId: "day", folderName: "2026-10-12",
              date: date, width: 6000, height: 4000, orientation: 1,
              camera: camera, lens: "", focal: 50, aperture: 4, shutter: "1/100", iso: 100,
              colorSpace: "sRGB", fileMB: 1, rating: rating, flag: .none, keywords: keywords,
              title: "", caption: "", location: "", gps: (0, 0), status: .ready, importedAt: importedAt,
              localPath: localPath, isDemo: isDemo)
    }

    /// An 80 × 60 landscape photo, as `makeTestJPEG` writes one, without camera details: 0.01 MB,
    /// unrated, imported now.
    static func smallPhoto(_ id: String, filename: String, type: String, folderId: String, folderName: String,
                           date: Date, localPath: String, preview: String = "", status: AssetStatus = .ready,
                           keywords: [String] = [], title: String = "", caption: String = "",
                           contentHash: String? = nil, isDemo: Bool) -> Asset {
        Asset(id: id, pid: 1, ori: "l", thumb: "", preview: preview, filename: filename, type: type,
              isRaw: false, folderId: folderId, folderName: folderName,
              date: date, width: 80, height: 60, orientation: 1, camera: "", lens: "", focal: 0, aperture: 0,
              shutter: "", iso: 0, colorSpace: "sRGB", fileMB: 0.01, rating: 0, flag: .none, keywords: keywords,
              title: title, caption: caption, location: "", gps: (0, 0), status: status, importedAt: .now,
              localPath: localPath, contentHash: contentHash, isDemo: isDemo)
    }
}
