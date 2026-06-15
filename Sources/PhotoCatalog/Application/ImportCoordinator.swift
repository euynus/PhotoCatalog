// ============================================================
//  ImportCoordinator — referenced / managed import pipeline
//  scan → metadata → thumbnails → hash → (XMP sidecar) → Asset
//  (PRD §6.3, §6.5 META-006, §11)
// ============================================================
import Foundation
import CryptoKit
import UniformTypeIdentifiers

enum ImportMode: String, Sendable { case referenced, managed }

struct ImportProgress: Sendable {
    var total = 0
    var processed = 0
    var failed = 0
    var latestAsset: Asset?
    var latestFailure: ImportFailure?
}

// @unchecked Sendable: holds only Sendable services; runs the scan/metadata/
// thumbnail pipeline on a background queue without touching shared mutable state.
final class ImportCoordinator: @unchecked Sendable {
    let store: CatalogStore
    let thumbnails: ThumbnailService

    init(store: CatalogStore) {
        self.store = store
        thumbnails = ThumbnailService(store: store)
    }

    func assetId(forPath path: String) -> String { "r" + shortHash(path) }

    /// Full import of a folder (managed mode copies originals into Originals/YYYY/MM/DD;
    /// autoTag runs on-device Vision scene tagging + face detection).
    func importFolder(_ folder: URL, mode: ImportMode = .referenced, autoTag: Bool = false,
                      control: ImportControl? = nil,
                      progress: ((ImportProgress) -> Void)? = nil) -> [Asset] {
        let files = FileScanner.scan(folder)
        progress?(ImportProgress(total: files.count, processed: 0, failed: 0))
        return process(files, folder: folder, mode: mode, autoTag: autoTag, control: control, progress: progress)
    }

    /// Retry/import a known file list while preserving the original source folder identity.
    func importFiles(_ files: [URL], from folder: URL, mode: ImportMode = .referenced, autoTag: Bool = false,
                     control: ImportControl? = nil,
                     progress: ((ImportProgress) -> Void)? = nil) -> [Asset] {
        progress?(ImportProgress(total: files.count, processed: 0, failed: 0))
        return process(files, folder: folder, mode: mode, autoTag: autoTag, control: control, progress: progress)
    }

    /// Incremental: only files not already imported by path (for FSEvents rescans, §12.8).
    func scanNew(in folder: URL, knownPaths: Set<String>, mode: ImportMode = .referenced,
                 autoTag: Bool = false) -> [Asset] {
        let files = FileScanner.scan(folder).filter { !knownPaths.contains($0.path) }
        return process(files, folder: folder, mode: mode, autoTag: autoTag, control: nil, progress: nil)
    }

    /// Incremental: reprocess known originals whose quick hash changed so metadata and caches stay fresh.
    func scanChanged(in folder: URL, knownAssetsByPath: [String: Asset], mode: ImportMode = .referenced,
                     autoTag: Bool = false) -> [Asset] {
        let files = FileScanner.scan(folder).filter { url in
            let known = knownAssetsByPath[url.path] ?? knownAssetsByPath[url.resolvingSymlinksInPath().path]
            guard let known else { return false }
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int64 else { return true }
            return HashService.quickHash(url, fileSize: size) != known.quickHash
        }
        return process(files, folder: folder, mode: mode, autoTag: autoTag, control: nil, progress: nil)
    }

    private func process(_ files: [URL], folder: URL, mode: ImportMode, autoTag: Bool,
                         control: ImportControl?, progress: ((ImportProgress) -> Void)?) -> [Asset] {
        let folderId = "src-" + shortHash(folder.path)
        let folderName = folder.lastPathComponent
        var assets: [Asset] = []
        var prog = ImportProgress(total: files.count, processed: 0, failed: 0)
        for url in files {
            control?.waitIfPaused()
            guard FileManager.default.fileExists(atPath: url.path) else {
                prog.failed += 1
                prog.latestAsset = nil
                prog.latestFailure = ImportFailure(url: url, reason: "文件不存在或不可访问")
                progress?(prog)
                continue
            }
            if let asset = makeAsset(source: url, folderId: folderId, folderName: folderName,
                                     mode: mode, autoTag: autoTag) {
                assets.append(asset)
                prog.processed += 1
                prog.latestAsset = asset
                prog.latestFailure = nil
            } else {
                prog.failed += 1
                prog.latestAsset = nil
                prog.latestFailure = ImportFailure(url: url, reason: "无法读取图片元数据或像素尺寸")
            }
            progress?(prog)
        }
        return assets
    }

    private func makeAsset(source url: URL, folderId: String, folderName: String,
                           mode: ImportMode, autoTag: Bool) -> Asset? {
        let meta = MetadataReader.read(url)
        guard meta.width > 0, meta.height > 0 else { return nil }
        let finalURL = mode == .managed ? (copyToOriginals(url, date: meta.captureDate) ?? url) : url

        let hash = shortHash(finalURL.path)
        let assetId = "r" + hash
        let pid = (Int(hash.prefix(6), radix: 16) ?? 0) % 100000
        let quick = HashService.quickHash(finalURL, fileSize: meta.fileSize)
        let content = HashService.contentHash(finalURL)
        let (thumb, preview) = thumbnails.generateAll(from: finalURL, assetId: assetId)
        let ext = finalURL.pathExtension.uppercased()
        let isRaw = UTType(filenameExtension: finalURL.pathExtension.lowercased())?.conforms(to: .rawImage) ?? false
            || ["CR2", "CR3", "NEF", "ARW", "RAF", "ORF", "RW2", "DNG"].contains(ext)

        var asset = Asset(
            id: assetId, pid: pid, ori: meta.width >= meta.height ? "l" : "p",
            thumb: thumb?.path ?? "", preview: preview?.path ?? thumb?.path ?? "",
            filename: finalURL.lastPathComponent, type: ext.isEmpty ? "IMG" : ext, isRaw: isRaw,
            folderId: folderId, folderName: folderName,
            date: meta.captureDate, width: meta.width, height: meta.height, orientation: meta.orientation,
            camera: meta.camera, lens: meta.lens, focal: meta.focal, aperture: meta.aperture,
            shutter: meta.shutter, iso: meta.iso, colorSpace: meta.colorSpace,
            hasICCProfile: meta.hasICCProfile,
            fileMB: Double(meta.fileSize) / (1024 * 1024),
            fileModifiedAt: meta.fileModifiedAt, fileCreatedAt: meta.fileCreatedAt,
            rating: 0, flag: .none, colorLabel: nil, keywords: [], title: "", caption: "",
            location: gpsLabel(meta.gps), gps: meta.gps, gpsAltitude: meta.gpsAltitude,
            status: .ready, importedAt: Date(), deleted: false,
            localPath: finalURL.path, captureDateSource: meta.captureDateSource,
            contentHash: content, quickHash: quick, isDemo: false)

        // on-device Vision scene tags + face count (§4.3)
        if autoTag {
            let v = VisionService.analyze(finalURL)
            asset.faces = v.faces
            for tag in v.sceneLabels where !asset.keywords.contains(tag) { asset.keywords.append(tag) }
        }

        // apply XMP sidecar metadata next to the original, if present (§6.5 META-006)
        if let sc = XMPSidecar.read(XMPSidecar.sidecarURL(for: url)) {
            asset.rating = sc.rating
            asset.colorLabel = sc.colorLabel
            if !sc.keywords.isEmpty { asset.keywords = sc.keywords }
            if !sc.title.isEmpty { asset.title = sc.title }
            if !sc.caption.isEmpty { asset.caption = sc.caption }
        }
        return asset
    }

    private func copyToOriginals(_ url: URL, date: Date) -> URL? {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let dir = store.originalsURL
            .appendingPathComponent(String(format: "%04d", c.year ?? 1970))
            .appendingPathComponent(String(format: "%02d", c.month ?? 1))
            .appendingPathComponent(String(format: "%02d", c.day ?? 1))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var dest = dir.appendingPathComponent(url.lastPathComponent)
        var i = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            let base = url.deletingPathExtension().lastPathComponent
            dest = dir.appendingPathComponent("\(base) (\(i)).\(url.pathExtension)")
            i += 1
        }
        do { try FileManager.default.copyItem(at: url, to: dest); return dest } catch { return nil }
    }

    private func gpsLabel(_ gps: (Double, Double)) -> String {
        (gps.0 == 0 && gps.1 == 0) ? "" : String(format: "%.3f, %.3f", gps.0, gps.1)
    }

    private func shortHash(_ s: String) -> String {
        String(SHA256.hash(data: Data(s.utf8)).compactMap { String(format: "%02x", $0) }.joined().prefix(16))
    }
}
