// ============================================================
//  ImportCoordinator — referenced / managed import pipeline
//  scan → metadata → thumbnails → hash → (XMP sidecar) → Asset
//  (PRD §6.3, §6.5 META-006, §11)
// ============================================================
import Foundation
import CryptoKit
import UniformTypeIdentifiers

enum ImportMode: String, Sendable { case referenced, managed }

/// Folder layout used when copying originals into the managed Originals/ tree (PRD §6.3 IMP-006, §17.2).
enum ManagedArchiveRule: String, Sendable, CaseIterable {
    case date    // Originals/YYYY/MM/DD
    case camera  // Originals/<camera>/YYYY/MM
    var label: String { self == .date ? "按日期" : "按相机" }
}

/// Turns a file an import found into the file to catalog — a card import copies it off first.
protocol ImportFilePreparer: Sendable {
    func prepare(_ source: URL) throws -> URL
}

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

    func sourceId(forFolder folder: URL) -> String { "src-" + shortHash(folder.path) }
    func assetId(forPath path: String) -> String { "r" + shortHash(path) }

    /// Full import of a folder (managed mode copies originals into Originals/YYYY/MM/DD;
    /// autoTag runs on-device Vision scene tagging + face detection).
    func importFolder(_ folder: URL, mode: ImportMode = .referenced, autoTag: Bool = false,
                      archiveRule: ManagedArchiveRule = .date, readSidecar: Bool = true,
                      previewMaxPixel: Int = 2048,
                      control: ImportControl? = nil,
                      knownAssetsById: [String: Asset] = [:],
                      progress: ((ImportProgress) -> Void)? = nil) -> [Asset] {
        let files = FileScanner.scan(folder)
        progress?(ImportProgress(total: files.count, processed: 0, failed: 0))
        return process(files, folder: folder, mode: mode, autoTag: autoTag, archiveRule: archiveRule,
                       readSidecar: readSidecar, previewMaxPixel: previewMaxPixel, control: control,
                       knownAssetsById: knownAssetsById, progress: progress)
    }

    /// Retry/import a known file list while preserving the original source folder identity.
    /// `preparer` turns each file into the one to catalog first — a card import's copy of it.
    func importFiles(_ files: [URL], from folder: URL, mode: ImportMode = .referenced, autoTag: Bool = false,
                     archiveRule: ManagedArchiveRule = .date, readSidecar: Bool = true,
                     previewMaxPixel: Int = 2048,
                     control: ImportControl? = nil,
                     knownAssetsById: [String: Asset] = [:],
                     preparer: (any ImportFilePreparer)? = nil,
                     progress: ((ImportProgress) -> Void)? = nil) -> [Asset] {
        progress?(ImportProgress(total: files.count, processed: 0, failed: 0))
        return process(files, folder: folder, mode: mode, autoTag: autoTag, archiveRule: archiveRule,
                       readSidecar: readSidecar, previewMaxPixel: previewMaxPixel, control: control,
                       knownAssetsById: knownAssetsById, preparer: preparer, progress: progress)
    }

    /// Incremental: only files not already imported by path (for FSEvents rescans, §12.8).
    func scanNew(in folder: URL, knownPaths: Set<String>, mode: ImportMode = .referenced,
                 autoTag: Bool = false, readSidecar: Bool = true, previewMaxPixel: Int = 2048,
                 sourceRootId: String? = nil, folderName: String? = nil) -> [Asset] {
        var knownAliases = knownPaths
        for path in knownPaths {
            knownAliases.formUnion(PathIdentity.aliases(forPath: path))
        }
        let files = FileScanner.scan(folder).filter {
            PathIdentity.aliases(for: $0).isDisjoint(with: knownAliases)
        }
        return process(files, folder: folder, mode: mode, autoTag: autoTag, readSidecar: readSidecar,
                       previewMaxPixel: previewMaxPixel, control: nil, sourceRootId: sourceRootId,
                       folderName: folderName, progress: nil)
    }

    /// Incremental: reprocess known originals whose quick hash changed so metadata and caches stay fresh.
    func scanChanged(in folder: URL, knownAssetsByPath: [String: Asset], mode: ImportMode = .referenced,
                     autoTag: Bool = false, readSidecar: Bool = true, previewMaxPixel: Int = 2048,
                     sourceRootId: String? = nil, folderName: String? = nil) -> [Asset] {
        let files = FileScanner.scan(folder).filter { url in
            let known = PathIdentity.aliases(for: url).lazy.compactMap { knownAssetsByPath[$0] }.first
            guard let known else { return false }
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int64 else { return true }
            let knownSize = Int64((known.fileMB * 1024 * 1024).rounded())
            let sizeChanged = knownSize != size
            let modifiedAt = attrs[.modificationDate] as? Date
            let modifiedChanged = known.fileModifiedAt.map { knownDate in
                modifiedAt.map { abs($0.timeIntervalSince(knownDate)) >= 1 } ?? true
            } ?? (modifiedAt != nil)
            let quickHashChanged = HashService.quickHash(url, fileSize: size) != known.quickHash
            return sizeChanged || modifiedChanged || quickHashChanged
        }
        let refreshed = process(files, folder: folder, mode: mode, autoTag: autoTag, readSidecar: readSidecar,
                                previewMaxPixel: previewMaxPixel, control: nil, sourceRootId: sourceRootId,
                                folderName: folderName, progress: nil)
        var knownById: [String: Asset] = [:]
        for asset in knownAssetsByPath.values where knownById[asset.id] == nil {
            knownById[asset.id] = asset
        }
        var hasSidecarById: [String: Bool] = [:]
        if readSidecar {
            for url in files {
                hasSidecarById[assetId(forPath: url.path)] =
                    FileManager.default.fileExists(atPath: XMPSidecar.sidecarURL(for: url).path)
            }
        }
        return refreshed.map { asset in
            guard let known = knownById[asset.id] else { return asset }
            return preservingCatalogMetadata(from: known, in: asset,
                                             hasSidecar: hasSidecarById[asset.id] == true,
                                             autoTag: autoTag)
        }
    }

    private func process(_ files: [URL], folder: URL, mode: ImportMode, autoTag: Bool,
                         archiveRule: ManagedArchiveRule = .date, readSidecar: Bool = true,
                         previewMaxPixel: Int, control: ImportControl?,
                         knownAssetsById: [String: Asset] = [:],
                         sourceRootId: String? = nil, folderName: String? = nil,
                         preparer: (any ImportFilePreparer)? = nil,
                         progress: ((ImportProgress) -> Void)?) -> [Asset] {
        let folderId = sourceRootId ?? sourceId(forFolder: folder)
        let folderName = folderName ?? folder.lastPathComponent
        var assets: [Asset] = []
        var prog = ImportProgress(total: files.count, processed: 0, failed: 0)
        for url in files {
            guard control?.waitIfPaused() != false else { break }
            // A detached import can run for hours; drain Foundation/ImageIO temporaries
            // per file, before reporting progress or blocking at the next pause point.
            autoreleasepool {
                guard FileManager.default.fileExists(atPath: url.path) else {
                    prog.failed += 1
                    prog.latestAsset = nil
                    prog.latestFailure = ImportFailure(url: url, reason: "文件不存在或不可访问")
                    return
                }
                // Reuse cataloged referenced files; downstream dedup still counts them as skipped.
                if mode == .referenced, let known = knownAssetsById[assetId(forPath: url.path)] {
                    assets.append(known)
                    prog.processed += 1
                    prog.latestAsset = known
                    prog.latestFailure = nil
                    return
                }
                do {
                    let target = try preparer?.prepare(url) ?? url
                    if let asset = try makeAsset(source: target, folderId: folderId, folderName: folderName,
                                                mode: mode, autoTag: autoTag, archiveRule: archiveRule,
                                                readSidecar: readSidecar, previewMaxPixel: previewMaxPixel) {
                        assets.append(asset)
                        prog.processed += 1
                        prog.latestAsset = asset
                        prog.latestFailure = nil
                    } else {
                        prog.failed += 1
                        prog.latestAsset = nil
                        prog.latestFailure = ImportFailure(url: url, reason: "无法读取图片元数据或像素尺寸")
                    }
                } catch {
                    prog.failed += 1
                    prog.latestAsset = nil
                    prog.latestFailure = ImportFailure(url: url, reason: "复制原件失败：\(error.localizedDescription)")
                }
            }
            progress?(prog)
        }
        return assets
    }

    private func makeAsset(source url: URL, folderId: String, folderName: String,
                           mode: ImportMode, autoTag: Bool, archiveRule: ManagedArchiveRule = .date,
                           readSidecar: Bool = true, previewMaxPixel: Int) throws -> Asset? {
        let meta = MetadataReader.read(url)
        guard meta.width > 0, meta.height > 0 else { return nil }
        let finalURL: URL
        if mode == .managed {
            finalURL = try copyToOriginals(url, date: meta.captureDate, camera: meta.camera, rule: archiveRule)
        } else {
            finalURL = url
        }

        let hash = shortHash(finalURL.path)
        let assetId = "r" + hash
        let pid = (Int(hash.prefix(6), radix: 16) ?? 0) % 100000
        let quick = HashService.quickHash(finalURL, fileSize: meta.fileSize)
        let content = HashService.contentHash(finalURL)
        let (thumb, preview) = thumbnails.generateAll(from: finalURL, assetId: assetId,
                                                      previewMaxPixel: previewMaxPixel)
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
            author: meta.author, copyright: meta.copyright, makerNotes: meta.makerNotes,
            location: gpsLabel(meta.gps, hasGPS: meta.hasGPS), gps: meta.gps, gpsAltitude: meta.gpsAltitude,
            status: .ready, importedAt: Date(), deleted: false,
            localPath: finalURL.path, captureDateSource: meta.captureDateSource,
            contentHash: content, quickHash: quick, isDemo: false)

        // on-device Vision scene tags + face count (§4.3)
        if autoTag {
            let v = VisionService.analyze(finalURL)
            asset.faces = v.faces
            for tag in v.sceneLabels where !asset.keywords.contains(tag) { asset.keywords.append(tag) }
        }

        // apply XMP sidecar metadata next to the original, if present (§6.5 META-006, §17.4)
        if readSidecar, let sc = XMPSidecar.read(XMPSidecar.sidecarURL(for: url)) {
            asset.rating = sc.rating
            asset.colorLabel = sc.colorLabel
            // merge, not overwrite, so sidecar keywords don't discard the Vision scene tags
            // appended above (normalize de-dups, keeping sidecar keywords first)
            if !sc.keywords.isEmpty { asset.keywords = KeywordService.normalize(sc.keywords + asset.keywords) }
            if !sc.title.isEmpty { asset.title = sc.title }
            if !sc.caption.isEmpty { asset.caption = sc.caption }
            if !sc.author.isEmpty { asset.author = sc.author }
            if !sc.copyright.isEmpty { asset.copyright = sc.copyright }
            // a capture-time correction made in another app (or mirrored by us) takes precedence
            if let d = sc.captureDate { asset.date = d; asset.captureDateSource = "sidecar" }
            // a location set in another app (or by us) travels in the sidecar
            if let gps = sc.gps {
                asset.gps = gps
                asset.location = Asset.locationLabel(gps)
            }
        }

        // cache the perceptual hash from the just-generated thumbnail (avoids re-decoding later)
        if !asset.thumb.isEmpty { asset.perceptualHash = PerceptualHash.dHash(path: asset.thumb) }
        return asset
    }

    private func copyToOriginals(_ url: URL, date: Date, camera: String, rule: ManagedArchiveRule) throws -> URL {
        let c = Calendar.captureWallClock.dateComponents([.year, .month, .day], from: date)
        let year = String(format: "%04d", c.year ?? 1970)
        let month = String(format: "%02d", c.month ?? 1)
        let day = String(format: "%02d", c.day ?? 1)
        let dir: URL
        switch rule {
        case .date:
            dir = store.originalsURL.appendingPathComponent(year)
                .appendingPathComponent(month).appendingPathComponent(day)
        case .camera:
            let folderName = sanitizeFolderName(camera)
            dir = store.originalsURL.appendingPathComponent(folderName)
                .appendingPathComponent(year).appendingPathComponent(month)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var dest = dir.appendingPathComponent(url.lastPathComponent)
        var i = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            // An identical original is already here — e.g. an import resumed after a crash
            // re-scans files already copied. Reuse it (its asset id then matches the existing
            // one and dedups) instead of writing a duplicate "name (1).ext" + duplicate asset.
            if let existing = HashService.contentHash(dest), existing == HashService.contentHash(url) {
                return dest
            }
            let base = url.deletingPathExtension().lastPathComponent
            dest = dir.appendingPathComponent("\(base) (\(i)).\(url.pathExtension)")
            i += 1
        }
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }

    private func preservingCatalogMetadata(from known: Asset, in refreshed: Asset,
                                           hasSidecar: Bool, autoTag: Bool) -> Asset {
        var asset = refreshed
        asset.importedAt = known.importedAt
        asset.flag = known.flag
        asset.project = known.project
        asset.client = known.client
        if !hasSidecar {
            asset.rating = known.rating
            asset.colorLabel = known.colorLabel
            asset.keywords = known.keywords
            asset.title = known.title
            asset.caption = known.caption
        }
        if !autoTag {
            asset.faces = known.faces
        }
        return asset
    }

    private func gpsLabel(_ gps: (Double, Double), hasGPS: Bool) -> String {
        Asset.locationLabel(hasGPS ? gps : nil)
    }

    private func sanitizeFolderName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "未知相机" }
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        return trimmed.components(separatedBy: illegal).joined(separator: "-")
    }

    private func shortHash(_ s: String) -> String {
        String(SHA256.hash(data: Data(s.utf8)).compactMap { String(format: "%02x", $0) }.joined().prefix(16))
    }
}
