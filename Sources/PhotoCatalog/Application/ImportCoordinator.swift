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
    var label: String { self == .date ? L("按日期") : L("按相机") }
}

/// Turns a file an import found into the file to catalog — a card import copies it off first.
protocol ImportFilePreparer: Sendable {
    func prepare(_ source: URL) throws -> URL
    /// Whether `source` can be imported. A preparer that fetches files (from a camera) knows
    /// its sources without them being on disk yet.
    func isAvailable(_ source: URL) -> Bool
}

extension ImportFilePreparer {
    func isAvailable(_ source: URL) -> Bool { FileManager.default.fileExists(atPath: source.path) }
}

struct ImportProgress: Sendable {
    var total = 0
    var processed = 0
    var failed = 0
    var latestAsset: Asset?
    var latestFailure: ImportFailure?
    var latestSource: ImportSourceFile?
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

    /// The id a file being cataloged gets. It's made from the file's path, but a photo keeps its
    /// id when renamed or moved, so the path's id may already be another photo's: then the path
    /// is hashed again with a counter until the id is free. A photo already cataloged at this
    /// path is this file and keeps its id — a removed one too, so importing it again brings it
    /// back in place, unless `reusingRemoved` is false: a file the app has just written where a
    /// removed (trashed) one was is a new photo.
    func newAssetId(forPath path: String, reusingRemoved: Bool = true) -> String {
        var removed: String?
        for attempt in 0... {
            let id = "r" + shortHash(attempt == 0 ? path : path + "\u{0}" + String(attempt))
            guard let row = store.assetPathRecord(id: id) else { return removed ?? id }
            let samePath = row.localPath.map { $0 == path || PathIdentity.aliases(forPath: $0).contains(path) } ?? false
            guard samePath else { continue }
            // a live photo at this path wins over a removed one
            if !row.deleted { return id }
            if reusingRemoved, removed == nil { removed = id }
        }
        return removed ?? "r" + shortHash(path)
    }

    /// Full import of a folder (managed mode copies originals into Originals/YYYY/MM/DD;
    /// autoTag runs on-device Vision scene tagging + face detection).
    func importFolder(_ folder: URL, mode: ImportMode = .referenced, autoTag: Bool = false,
                      archiveRule: ManagedArchiveRule = .date, readSidecar: Bool = true,
                      previewMaxPixel: Int = 2048,
                      control: ImportControl? = nil,
                      knownAssetsById: [String: Asset] = [:],
                      checkpoints: [String: ImportFileCheckpoint] = [:],
                      progress: ((ImportProgress) -> Void)? = nil) -> [Asset] {
        let files = FileScanner.scan(folder)
        progress?(ImportProgress(total: files.count, processed: 0, failed: 0))
        return process(files, folder: folder, mode: mode, autoTag: autoTag, archiveRule: archiveRule,
                       readSidecar: readSidecar, previewMaxPixel: previewMaxPixel, control: control,
                       knownAssetsById: knownAssetsById, checkpoints: checkpoints, progress: progress)
    }

    /// Retry/import a known file list while preserving the original source folder identity.
    /// `preparer` turns each file into the one to catalog first — a card import's copy of it.
    /// `sourceRootId` and `folderName` file the photos under a source folder that contains
    /// `folder` rather than under `folder` itself. `reusingRemovedIds` false: the files are new
    /// output (an edit, merge or enhance), never a removed photo coming back.
    func importFiles(_ files: [URL], from folder: URL, mode: ImportMode = .referenced, autoTag: Bool = false,
                     archiveRule: ManagedArchiveRule = .date, readSidecar: Bool = true,
                     previewMaxPixel: Int = 2048,
                     control: ImportControl? = nil,
                     knownAssetsById: [String: Asset] = [:],
                     checkpoints: [String: ImportFileCheckpoint] = [:],
                     sourceRootId: String? = nil, folderName: String? = nil,
                     preparer: (any ImportFilePreparer)? = nil,
                     reusingRemovedIds: Bool = true,
                     progress: ((ImportProgress) -> Void)? = nil) -> [Asset] {
        progress?(ImportProgress(total: files.count, processed: 0, failed: 0))
        return process(files, folder: folder, mode: mode, autoTag: autoTag, archiveRule: archiveRule,
                       readSidecar: readSidecar, previewMaxPixel: previewMaxPixel, control: control,
                       knownAssetsById: knownAssetsById, checkpoints: checkpoints,
                       sourceRootId: sourceRootId, folderName: folderName,
                       preparer: preparer, reusingRemovedIds: reusingRemovedIds, progress: progress)
    }

    /// A folder's files with each one's path aliases: walked and resolved once for both
    /// incremental scans of a rescan rather than once in each.
    static func scanWithAliases(_ folder: URL) -> [(url: URL, aliases: Set<String>)] {
        FileScanner.scan(folder).map { ($0, PathIdentity.aliases(for: $0)) }
    }

    /// Incremental: only files not already imported by path (for FSEvents rescans, §12.8).
    func scanNew(in folder: URL, knownPaths: Set<String>, mode: ImportMode = .referenced,
                 autoTag: Bool = false, readSidecar: Bool = true, previewMaxPixel: Int = 2048,
                 sourceRootId: String? = nil, folderName: String? = nil,
                 scanned: [(url: URL, aliases: Set<String>)]? = nil) -> [Asset] {
        var knownAliases = knownPaths
        for path in knownPaths {
            knownAliases.formUnion(PathIdentity.aliases(forPath: path))
        }
        let files = (scanned ?? Self.scanWithAliases(folder))
            .filter { $0.aliases.isDisjoint(with: knownAliases) }
            .map(\.url)
        return process(files, folder: folder, mode: mode, autoTag: autoTag, readSidecar: readSidecar,
                       previewMaxPixel: previewMaxPixel, control: nil, sourceRootId: sourceRootId,
                       folderName: folderName, progress: nil)
    }

    /// Incremental: reprocess known originals whose quick hash changed so what the files hold and
    /// the caches stay fresh. Their sidecars aren't read: a changed sidecar is the external-XMP
    /// check's to report, and an old one mustn't undo the catalog's edits.
    func scanChanged(in folder: URL, knownAssetsByPath: [String: Asset], mode: ImportMode = .referenced,
                     autoTag: Bool = false, previewMaxPixel: Int = 2048,
                     sourceRootId: String? = nil, folderName: String? = nil,
                     scanned: [(url: URL, aliases: Set<String>)]? = nil) -> [Asset] {
        // each changed file is made again as the photo whose file it is, under that photo's id —
        // never the one its path would give, which a renamed photo doesn't have
        var knownIdByPath: [String: String] = [:]
        let files = (scanned ?? Self.scanWithAliases(folder)).compactMap { file -> URL? in
            let known = file.aliases.lazy.compactMap { knownAssetsByPath[$0] }.first
            guard let known else { return nil }
            let url = file.url
            knownIdByPath[url.path] = known.id
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int64 else { return url }
            let knownSize = known.fileBytes
            let sizeChanged = knownSize != size
            let modifiedAt = attrs[.modificationDate] as? Date
            let modifiedChanged = known.fileModifiedAt.map { knownDate in
                modifiedAt.map { abs($0.timeIntervalSince(knownDate)) >= 1 } ?? true
            } ?? (modifiedAt != nil)
            let quickHashChanged = HashService.quickHash(url, fileSize: size) != known.quickHash
            return sizeChanged || modifiedChanged || quickHashChanged ? url : nil
        }
        let refreshed = process(files, folder: folder, mode: mode, autoTag: autoTag, readSidecar: false,
                                previewMaxPixel: previewMaxPixel, control: nil, sourceRootId: sourceRootId,
                                folderName: folderName, refreshingIds: knownIdByPath, progress: nil)
        var knownById: [String: Asset] = [:]
        for asset in knownAssetsByPath.values where knownById[asset.id] == nil {
            knownById[asset.id] = asset
        }
        return refreshed.map { asset in
            guard let known = knownById[asset.id] else { return asset }
            return Self.preservingCatalogMetadata(from: known, in: asset, autoTag: autoTag)
        }
    }

    /// Files imported at once. Two thirds of a RAW's import was spent waiting for Quick Look,
    /// which renders it in another process and takes more than one request at a time: on 217
    /// RAWs and JPEGs two at once took 13 s instead of 30 s; four or six were no faster.
    static let parallelism = min(3, max(1, ProcessInfo.processInfo.activeProcessorCount / 2))

    private enum Outcome {
        case imported(Asset)
        case failed(ImportFailure)
        case skipped
    }

    private func process(_ files: [URL], folder: URL, mode: ImportMode, autoTag: Bool,
                         archiveRule: ManagedArchiveRule = .date, readSidecar: Bool = true,
                         previewMaxPixel: Int, control: ImportControl?,
                         knownAssetsById: [String: Asset] = [:],
                         checkpoints: [String: ImportFileCheckpoint] = [:],
                         sourceRootId: String? = nil, folderName: String? = nil,
                         preparer: (any ImportFilePreparer)? = nil,
                         refreshingIds: [String: String] = [:], reusingRemovedIds: Bool = true,
                         progress: ((ImportProgress) -> Void)?) -> [Asset] {
        let folderId = sourceRootId ?? sourceId(forFolder: folder)
        let folderName = folderName ?? folder.lastPathComponent
        // cataloged files are known by where they are now: a photo's id needn't match its path
        var knownByPath: [String: Asset] = [:]
        for asset in knownAssetsById.values {
            if let path = asset.localPath { knownByPath[path] = asset }
        }
        // copying into Originals/ picks a free name, and a preparer may share staging space:
        // both one file at a time
        let copying = NSLock()
        func importOne(_ url: URL) -> Outcome {
            if let checkpoint = checkpoints[url.path], checkpoint.matches(url) {
                if checkpoint.outcome == .skipped { return .skipped }
                if checkpoint.outcome == .saved, let id = checkpoint.assetId,
                   let known = knownAssetsById[id], let path = known.localPath,
                   FileManager.default.fileExists(atPath: path) {
                    return .imported(known)
                }
            }
            guard preparer?.isAvailable(url) ?? FileManager.default.fileExists(atPath: url.path) else {
                return .failed(ImportFailure(url: url, reason: L("文件不存在或不可访问")))
            }
            // `url` is a known photo's changed file: made again, as that photo
            let refreshingId = refreshingIds[url.path]
            // Reuse cataloged referenced files; downstream dedup still counts them as skipped.
            if refreshingId == nil, mode == .referenced, let known = knownByPath[url.path] {
                return .imported(known)
            }
            do {
                let target = try copying.withLock { try preparer?.prepare(url) ?? url }
                if let asset = try makeAsset(source: target, folderId: folderId, folderName: folderName,
                                            mode: mode, autoTag: autoTag, archiveRule: archiveRule,
                                            readSidecar: readSidecar, previewMaxPixel: previewMaxPixel,
                                            assetId: refreshingId, reusingRemovedIds: reusingRemovedIds,
                                            copying: copying) {
                    return .imported(asset)
                }
                return .failed(ImportFailure(url: url, reason: L("无法读取图片元数据或像素尺寸")))
            } catch {
                return .failed(ImportFailure(url: url, reason: L("复制原件失败：\(error.localizedDescription)")))
            }
        }

        let state = NSLock()
        var next = 0
        var stopped = false
        var results = [Asset?](repeating: nil, count: files.count)
        var prog = ImportProgress(total: files.count, processed: 0, failed: 0)
        let workers = min(Self.parallelism, files.count)
        DispatchQueue.concurrentPerform(iterations: max(1, workers)) { _ in
            while true {
                let index: Int? = state.withLock {
                    guard !stopped, next < files.count else { return nil }
                    next += 1
                    return next - 1
                }
                guard let index else { return }
                guard control?.waitIfPaused() != false else {
                    state.withLock { stopped = true }
                    return
                }
                // A detached import can run for hours; drain Foundation/ImageIO temporaries
                // per file, before reporting progress or blocking at the next pause point.
                let outcome = autoreleasepool { importOne(files[index]) }
                // counted and reported in one place, so the progress only ever moves forward
                state.withLock {
                    prog.latestSource = ImportSourceFile(url: files[index])
                    switch outcome {
                    case .imported(let asset):
                        results[index] = asset
                        prog.processed += 1
                        prog.latestAsset = asset
                        prog.latestFailure = nil
                        if preparer != nil, let path = asset.localPath {
                            // Card/device recovery scans the destination, not the removable source.
                            prog.latestSource = ImportSourceFile(url: URL(fileURLWithPath: path))
                        }
                    case .failed(let failure):
                        prog.failed += 1
                        prog.latestAsset = nil
                        prog.latestFailure = failure
                    case .skipped:
                        prog.processed += 1
                        prog.latestAsset = nil
                        prog.latestFailure = nil
                    }
                    progress?(prog)
                }
            }
        }
        return results.compactMap { $0 }
    }

    private func makeAsset(source url: URL, folderId: String, folderName: String,
                           mode: ImportMode, autoTag: Bool, archiveRule: ManagedArchiveRule = .date,
                           readSidecar: Bool = true, previewMaxPixel: Int, assetId knownId: String? = nil,
                           reusingRemovedIds: Bool = true, copying: NSLock) throws -> Asset? {
        let meta = MetadataReader.read(url)
        guard meta.width > 0, meta.height > 0 else { return nil }
        let finalURL: URL
        if mode == .managed {
            finalURL = try copying.withLock {
                try copyToOriginals(url, date: meta.captureDate, camera: meta.camera, rule: archiveRule)
            }
        } else {
            finalURL = url
        }

        let assetId = knownId ?? newAssetId(forPath: finalURL.path, reusingRemoved: reusingRemovedIds)
        let pid = (Int(assetId.dropFirst().prefix(6), radix: 16) ?? 0) % 100000
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
            fileMB: Asset.megabytes(bytes: meta.fileSize),
            fileModifiedAt: meta.fileModifiedAt, fileCreatedAt: meta.fileCreatedAt,
            rating: 0, flag: .none, colorLabel: nil, keywords: [], title: "", caption: "",
            author: meta.author, copyright: meta.copyright, makerNotes: meta.makerNotes,
            location: gpsLabel(meta.gps, hasGPS: meta.hasGPS), gps: meta.gps, gpsAltitude: meta.gpsAltitude,
            status: .ready, importedAt: Date(), deleted: false,
            localPath: finalURL.path, captureDateSource: meta.captureDateSource,
            contentHash: content, quickHash: quick, isDemo: false, duration: meta.duration)

        // on-device Vision scene tags + face count (§4.3); a movie isn't an image Vision can read
        if autoTag, !asset.isVideo {
            let v = VisionService.analyze(finalURL)
            asset.faces = v.faces
            for tag in v.sceneLabels where !asset.keywords.contains(tag) { asset.keywords.append(tag) }
        }

        // apply XMP sidecar metadata next to the original, if present (§6.5 META-006, §17.4)
        if readSidecar, let sc = XMPSidecar.read(XMPSidecar.sidecarURL(for: url)) {
            // keywords merge, so sidecar keywords don't discard the Vision scene tags appended above
            XMPSidecar.apply(sc, to: &asset)
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
        let base = url.deletingPathExtension().lastPathComponent
        var dest = dir.appendingPathComponent(url.lastPathComponent)
        var i = 1
        lazy var sourceHash = HashService.contentHash(url)   // read once, and only on a name clash
        // A name is free when no other photo has it in any extension: an iPhone's IMG_1234.HEIC
        // beside a Canon's IMG_1234.CR3 would pass for the RAW's JPEG. Another file of the same
        // shot (this JPEG's RAW, copied a moment ago) shares it.
        nameSearch: while true {
            var free = true
            for existing in CopyNaming.files(named: dest.deletingPathExtension().lastPathComponent, in: dir) {
                if existing.pathExtension.caseInsensitiveCompare(url.pathExtension) == .orderedSame {
                    // An identical original is already here — e.g. an import resumed after a crash
                    // re-scans files already copied. Reuse it (the photo cataloged at this path keeps
                    // its id and dedups) instead of writing a duplicate "name (1).ext" + duplicate asset.
                    if let hash = HashService.contentHash(existing), hash == sourceHash { return existing }
                    free = false
                } else if !CopyNaming.isSameShot(existing, camera: camera, date: date) {
                    free = false
                }
            }
            if free { break nameSearch }
            dest = dir.appendingPathComponent("\(base) (\(i)).\(url.pathExtension)")
            i += 1
        }
        // the photo a link points to, not the link: a copied link would dangle once the photo goes
        try FileManager.default.copyItem(at: url.resolvingSymlinksInPath(), to: dest)
        return dest
    }

    /// `refreshed`, an original read again after it changed on disk, with everything the catalog
    /// keeps about the photo taken from `known` (the same photo): only what the file itself holds
    /// is refreshed — size and dates on disk, pixels, camera data, hashes and caches. The capture
    /// time, location, author and copyright first read from the file may have been edited since,
    /// and the file is where the catalog has it (renamed since the read, it's the same file).
    static func preservingCatalogMetadata(from known: Asset, in refreshed: Asset, autoTag: Bool) -> Asset {
        var asset = refreshed
        asset.filename = known.filename
        asset.localPath = known.localPath
        asset.folderId = known.folderId
        asset.folderName = known.folderName
        asset.date = known.date
        asset.captureDateSource = known.captureDateSource
        asset.rating = known.rating
        asset.flag = known.flag
        asset.colorLabel = known.colorLabel
        asset.keywords = known.keywords
        asset.title = known.title
        asset.caption = known.caption
        asset.author = known.author
        asset.copyright = known.copyright
        asset.project = known.project
        asset.client = known.client
        asset.location = known.location
        asset.gps = known.gps
        asset.gpsAltitude = known.gpsAltitude
        asset.importedAt = known.importedAt
        asset.deleted = known.deleted
        asset.isDemo = known.isDemo
        asset.masterId = known.masterId
        asset.copyName = known.copyName
        // faces found again only when the rescan looks for them
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
        guard !trimmed.isEmpty else { return L("未知相机") }
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        return trimmed.components(separatedBy: illegal).joined(separator: "-")
    }

    private func shortHash(_ s: String) -> String {
        String(SHA256.hash(data: Data(s.utf8)).compactMap { String(format: "%02x", $0) }.joined().prefix(16))
    }
}
