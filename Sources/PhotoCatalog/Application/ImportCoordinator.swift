// ============================================================
//  ImportCoordinator — referenced-mode import pipeline
//  scan → metadata → thumbnails → hash → Asset (PRD §6.3, §11)
// ============================================================
import Foundation
import CryptoKit
import UniformTypeIdentifiers

struct ImportProgress {
    var total = 0
    var processed = 0
    var failed = 0
}

final class ImportCoordinator {
    let store: CatalogStore
    let thumbnails: ThumbnailService

    init(store: CatalogStore) {
        self.store = store
        thumbnails = ThumbnailService(store: store)
    }

    /// Scan a folder and build real Asset records (metadata + thumbnails + hashes).
    func importFolder(_ folder: URL, progress: ((ImportProgress) -> Void)? = nil) -> [Asset] {
        let files = FileScanner.scan(folder)
        let folderId = "src-" + shortHash(folder.path)
        let folderName = folder.lastPathComponent
        var assets: [Asset] = []
        var prog = ImportProgress(total: files.count, processed: 0, failed: 0)
        for url in files {
            if let asset = buildAsset(url, folderId: folderId, folderName: folderName) {
                assets.append(asset)
                prog.processed += 1
            } else {
                prog.failed += 1
            }
            progress?(prog)
        }
        return assets
    }

    private func buildAsset(_ url: URL, folderId: String, folderName: String) -> Asset? {
        let m = MetadataReader.read(url)
        guard m.width > 0, m.height > 0 else { return nil }   // not a decodable image
        let assetId = "r" + shortHash(url.path)
        let pid = Int(UInt32(truncatingIfNeeded: shortHash(url.path).hashValue) % 100000)

        let quick = HashService.quickHash(url, fileSize: m.fileSize)
        let content = HashService.contentHash(url)
        let (thumb, preview) = thumbnails.generateAll(from: url, assetId: assetId)

        let ext = url.pathExtension.uppercased()
        let isRaw = FileScanner.isSupported(url)
            && (UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .rawImage) ?? false
                || ["CR2", "CR3", "NEF", "ARW", "RAF", "ORF", "RW2", "DNG"].contains(ext))

        return Asset(
            id: assetId, pid: pid, ori: m.width >= m.height ? "l" : "p",
            thumb: thumb?.path ?? "", preview: preview?.path ?? thumb?.path ?? "",
            filename: url.lastPathComponent, type: ext.isEmpty ? "IMG" : ext, isRaw: isRaw,
            folderId: folderId, folderName: folderName,
            date: m.captureDate, width: m.width, height: m.height, orientation: m.orientation,
            camera: m.camera, lens: m.lens, focal: m.focal, aperture: m.aperture,
            shutter: m.shutter, iso: m.iso, colorSpace: m.colorSpace,
            fileMB: Double(m.fileSize) / (1024 * 1024),
            rating: 0, flag: .none, colorLabel: nil, keywords: [], title: "", caption: "",
            location: gpsLabel(m.gps), gps: m.gps,
            status: .ready, importedAt: Date(), deleted: false,
            localPath: url.path, captureDateSource: m.captureDateSource,
            contentHash: content, quickHash: quick, isDemo: false)
    }

    private func gpsLabel(_ gps: (Double, Double)) -> String {
        (gps.0 == 0 && gps.1 == 0) ? "" : String(format: "%.3f, %.3f", gps.0, gps.1)
    }

    private func shortHash(_ s: String) -> String {
        String(SHA256.hash(data: Data(s.utf8)).compactMap { String(format: "%02x", $0) }.joined().prefix(16))
    }
}
