// ============================================================
//  Memory-card import — find cards, list their photos, copy them off
// ============================================================
import Foundation
import UniformTypeIdentifiers

/// A mounted volume with a camera's DCIM folder.
struct CardVolume: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let dcim: URL
    var id: String { url.path }
}

/// One photo on a card, as listed before import.
struct CardFile: Identifiable, Hashable, Sendable {
    let url: URL
    let size: Int64
    /// File time: cameras stamp it at capture, so it groups by day without reading metadata.
    let modified: Date
    let isRaw: Bool
    /// The catalog already holds a photo of this size with the same name or capture time.
    var alreadyImported = false

    var id: String { url.path }
    var name: String { url.lastPathComponent }
    /// RAW and JPEG of one shot share a folder and base name; they are renamed together.
    var pairKey: String { url.deletingPathExtension().path.lowercased() }
}

/// Where and how card photos are copied before they join the catalog.
struct CardImportOptions: Codable, Equatable, Sendable {
    enum Organize: String, Codable, CaseIterable, Identifiable, Sendable {
        case yearDay, day, flat

        var id: Self { self }
        var title: String {
            switch self {
            case .yearDay: "年 / 年-月-日"
            case .day: "年-月-日"
            case .flat: "不分文件夹"
            }
        }
    }

    var destination: URL
    var organize = Organize.yearDay
    var rename = false
    /// Tokens as in export: {original} {seq} {date} {time} {camera}.
    var renameTemplate = "{date}_{seq}"
    var sequenceStart = 1
    var backupEnabled = false
    var backup: URL?
    var ejectAfter = false

    static var standard: CardImportOptions {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return CardImportOptions(destination: pictures.appendingPathComponent("PhotoCatalog 照片", isDirectory: true))
    }
}

enum CardImportService {
    /// Mounted volumes carrying a DCIM folder — memory cards and cameras in mass-storage mode.
    static func detectCards() -> [CardVolume] {
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey],
                                                            options: [.skipHiddenVolumes]) ?? []
        return volumes.compactMap { url in
            guard url.path.hasPrefix("/Volumes/") else { return nil }
            let dcim = url.appendingPathComponent("DCIM", isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dcim.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            let name = (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? url.lastPathComponent
            return CardVolume(url: url, name: name, dcim: dcim)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// What the catalog holds, by byte size, for spotting photos imported before.
    struct CatalogIndex: Sendable {
        var bySize: [Int64: [(name: String, date: Date)]] = [:]

        init(_ assets: [Asset]) {
            for asset in assets where !asset.deleted && !asset.isDemo {
                let size = Int64((asset.fileMB * 1024 * 1024).rounded())
                bySize[size, default: []].append((asset.filename.lowercased(), asset.date))
            }
        }
    }

    /// Photos under `root`, oldest first. Only files matching a catalog photo's exact size have
    /// their metadata read, so a full card lists in moments.
    static func scan(_ root: URL, catalog: CatalogIndex) -> [CardFile] {
        FileScanner.scan(root).compactMap { url -> CardFile? in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(values?.fileSize ?? 0)
            let ext = url.pathExtension.lowercased()
            let isRaw = UTType(filenameExtension: ext)?.conforms(to: .rawImage) ?? false
                || ["cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "dng"].contains(ext)
            var file = CardFile(url: url, size: size, modified: values?.contentModificationDate ?? .distantPast,
                                isRaw: isRaw)
            if let candidates = catalog.bySize[size] {
                let name = url.lastPathComponent.lowercased()
                file.alreadyImported = candidates.contains { $0.name == name }
                    || {
                        let captured = MetadataReader.read(url).captureDate
                        return candidates.contains { abs($0.date.timeIntervalSince(captured)) < 1 }
                    }()
            }
            return file
        }
        .sorted { ($0.modified, $0.name) < ($1.modified, $1.name) }
    }
}

/// Copies card photos into the destination as the import reaches them: dated folders, the
/// rename template (one sequence number per RAW+JPEG pair), XMP sidecars, and a backup copy.
/// Used from the import's single worker thread; the lock only guards the name cache.
final class CardCopier: ImportFilePreparer, @unchecked Sendable {
    let options: CardImportOptions
    private let sequenceByPair: [String: Int]
    private let extensionsByPair: [String: [String]]
    private let importDay: String
    private var baseNames: [String: String] = [:]
    private let lock = NSLock()

    init(options: CardImportOptions, files: [CardFile]) {
        self.options = options
        var sequences: [String: Int] = [:]
        var extensions: [String: [String]] = [:]
        for file in files {
            if sequences[file.pairKey] == nil { sequences[file.pairKey] = options.sequenceStart + sequences.count }
            extensions[file.pairKey, default: []].append(file.url.pathExtension)
        }
        sequenceByPair = sequences
        extensionsByPair = extensions
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        day.locale = Locale(identifier: "en_US_POSIX")
        importDay = day.string(from: Date())
    }

    func folder(for date: Date) -> URL {
        switch options.organize {
        case .yearDay:
            options.destination.appendingPathComponent(FileNameTemplate.format(date, "yyyy"), isDirectory: true)
                .appendingPathComponent(FileNameTemplate.format(date, "yyyy-MM-dd"), isDirectory: true)
        case .day:
            options.destination.appendingPathComponent(FileNameTemplate.format(date, "yyyy-MM-dd"), isDirectory: true)
        case .flat:
            options.destination
        }
    }

    func prepare(_ source: URL) throws -> URL { try copy(source) }

    /// Copies one photo (and its sidecar) and returns the copy the catalog should reference.
    func copy(_ source: URL) throws -> URL {
        let fm = FileManager.default
        let meta = MetadataReader.read(source)
        let directory = folder(for: meta.captureDate)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? -1
        let base = baseName(for: source, date: meta.captureDate, camera: meta.camera, in: directory, size: size)
        let destination = directory.appendingPathComponent(base).appendingPathExtension(source.pathExtension)
        if !Self.isSameFile(destination, size: size) {
            try fm.copyItem(at: source, to: destination)
            guard Self.isSameFile(destination, size: size) else {
                try? fm.removeItem(at: destination)
                throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "复制后大小不一致"])
            }
        }
        let sidecar = XMPSidecar.sidecarURL(for: source)
        let copiedSidecar = XMPSidecar.sidecarURL(for: destination)
        if fm.fileExists(atPath: sidecar.path), !fm.fileExists(atPath: copiedSidecar.path) {
            try? fm.copyItem(at: sidecar, to: copiedSidecar)
        }
        if options.backupEnabled, let backup = options.backup {
            let folder = backup.appendingPathComponent("导入于 \(importDay)", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appendingPathComponent(destination.lastPathComponent)
            if !Self.isSameFile(copy, size: size) {
                try? fm.removeItem(at: copy)
                try fm.copyItem(at: source, to: copy)
            }
        }
        return destination
    }

    /// One base name per pair and folder, free for every extension in the pair — unless the
    /// very same file is already there (an import picked up again after an interruption).
    private func baseName(for source: URL, date: Date, camera: String, in directory: URL, size: Int64) -> String {
        let key = CardFile(url: source, size: 0, modified: date, isRaw: false).pairKey
        let cacheKey = key + "|" + directory.path
        return lock.withLock {
            if let cached = baseNames[cacheKey] { return cached }
            let original = source.deletingPathExtension().lastPathComponent
            let wanted = options.rename
                ? FileNameTemplate.render(options.renameTemplate, original: original,
                                          sequence: sequenceByPair[key] ?? options.sequenceStart, date: date,
                                          camera: camera)
                : original
            let extensions = extensionsByPair[key] ?? [source.pathExtension]
            var candidate = wanted
            var counter = 1
            while extensions.contains(where: { ext in
                let url = directory.appendingPathComponent(candidate).appendingPathExtension(ext)
                return FileManager.default.fileExists(atPath: url.path)
                    && !(ext == source.pathExtension && Self.isSameFile(url, size: size))
            }) {
                candidate = "\(wanted)-\(counter)"
                counter += 1
            }
            baseNames[cacheKey] = candidate
            return candidate
        }
    }

    private static func isSameFile(_ url: URL, size: Int64) -> Bool {
        guard let existing = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
        return Int64(existing) == size
    }
}
