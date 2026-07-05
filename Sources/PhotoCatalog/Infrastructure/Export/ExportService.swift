// ============================================================
//  ExportService — copy originals + export metadata (PRD §6.11, §12.10)
// ============================================================
import Foundation

enum ExportConflict { case skip, overwrite, rename }

struct ExportReport {
    var copied = 0
    var skipped = 0
    var failed = 0
    var xmpFailed = 0
}

enum ExportService {
    /// Copy each asset's original into `destination`, preserving mtime.
    /// When `xmp` is true, an `.xmp` sidecar is written next to each copied original.
    static func copyOriginals(_ assets: [Asset], to destination: URL,
                              conflict: ExportConflict = .rename,
                              xmp: Bool = false,
                              directoryStructure: ExportDirectoryStructure = .flat,
                              albumNamesByAssetId: [String: String] = [:],
                              sourceRootPathsByFolderId: [String: String] = [:]) -> ExportReport {
        var report = ExportReport()
        let fm = FileManager.default
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for a in assets {
            guard let path = a.localPath else { report.skipped += 1; continue }
            let src = URL(fileURLWithPath: path)
            guard fm.fileExists(atPath: src.path) else { report.failed += 1; continue }
            let targetDirectory = exportDirectory(for: a, source: src, destination: destination,
                                                  structure: directoryStructure,
                                                  albumNamesByAssetId: albumNamesByAssetId,
                                                  sourceRootPathsByFolderId: sourceRootPathsByFolderId)
            try? fm.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
            let target = resolve(targetDirectory.appendingPathComponent(src.lastPathComponent),
                                 conflict: conflict, fm: fm)
            guard let target else { report.skipped += 1; continue }
            do {
                if conflict == .overwrite { try? fm.removeItem(at: target) }
                try fm.copyItem(at: src, to: target)
                if let attrs = try? fm.attributesOfItem(atPath: src.path),
                   let mtime = attrs[.modificationDate] as? Date {
                    try? fm.setAttributes([.modificationDate: mtime], ofItemAtPath: target.path)
                }
                if xmp, !XMPSidecar.write(a, to: XMPSidecar.sidecarURL(for: target)) {
                    report.xmpFailed += 1
                }
                report.copied += 1
            } catch {
                report.failed += 1
            }
        }
        return report
    }

    /// Export cached previews for lightweight sharing (PRD §6.11 EXP-004).
    static func exportPreviews(_ assets: [Asset], to destination: URL,
                               conflict: ExportConflict = .rename,
                               thumbnails: ThumbnailService? = nil,
                               previewMaxPixel: Int = 2048) -> ExportReport {
        var report = ExportReport()
        let fm = FileManager.default
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)

        for asset in assets where !asset.deleted {
            guard let source = previewSource(for: asset, fm: fm,
                                             thumbnails: thumbnails,
                                             previewMaxPixel: previewMaxPixel) else {
                report.skipped += 1
                continue
            }
            let base = URL(fileURLWithPath: asset.filename).deletingPathExtension().lastPathComponent
            let targetName = base.isEmpty ? "\(asset.id)-preview.jpg" : "\(base)-preview.jpg"
            guard let target = resolve(destination.appendingPathComponent(targetName),
                                       conflict: conflict, fm: fm) else {
                report.skipped += 1
                continue
            }
            do {
                if conflict == .overwrite { try? fm.removeItem(at: target) }
                try fm.copyItem(at: source, to: target)
                report.copied += 1
            } catch {
                report.failed += 1
            }
        }
        return report
    }

    /// Export per-asset metadata as a JSON sidecar bundle (PRD §6.11 EXP-003).
    @discardableResult
    static func exportMetadataJSON(_ assets: [Asset], to fileURL: URL) -> Bool {
        let formatter = ISO8601DateFormatter()
        let payload = assets.map { a -> [String: Any] in
            [
                "assetId": a.id, "filename": a.filename, "rating": a.rating,
                "flag": a.flag.rawValue, "colorLabel": a.colorLabel?.rawValue ?? NSNull(),
                "keywords": a.keywords, "title": a.title, "caption": a.caption,
                "author": a.author, "copyright": a.copyright,
                "makerNotes": a.makerNotes,
                "project": a.project, "client": a.client,
                "captureDate": formatter.string(from: a.date),
                "fileModifiedAt": jsonDate(a.fileModifiedAt, formatter: formatter),
                "fileCreatedAt": jsonDate(a.fileCreatedAt, formatter: formatter),
                "hasICCProfile": a.hasICCProfile,
                "gpsLatitude": jsonGPS(a.gps.0, asset: a),
                "gpsLongitude": jsonGPS(a.gps.1, asset: a),
                "gpsAltitude": jsonNumber(a.gpsAltitude),
                "camera": a.camera, "lens": a.lens,
                "originalPath": a.localPath ?? a.thumb,
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else {
            return false
        }
        // don't clobber a copied original sharing this name (a flat export of a photo literally
        // named metadata.json); fall back to a numbered name, as the originals themselves do.
        guard let target = resolve(fileURL, conflict: .rename, fm: .default) else { return false }
        return (try? data.write(to: target)) != nil
    }

    /// Export per-asset metadata as CSV for spreadsheet workflows (PRD §6.11 EXP-003).
    @discardableResult
    static func exportMetadataCSV(_ assets: [Asset], to fileURL: URL) -> Bool {
        let header = [
            "assetId", "filename", "rating", "flag", "colorLabel", "keywords", "title", "caption",
            "author", "copyright", "makerNotes", "project", "client",
            "captureDate", "fileModifiedAt", "fileCreatedAt", "hasICCProfile",
            "gpsLatitude", "gpsLongitude", "gpsAltitude", "camera", "lens", "originalPath",
        ]
        let formatter = ISO8601DateFormatter()
        let rows = assets.map { a in
            [
                a.id,
                a.filename,
                String(a.rating),
                a.flag.rawValue,
                a.colorLabel?.rawValue ?? "",
                a.keywords.joined(separator: ";"),
                a.title,
                a.caption,
                a.author,
                a.copyright,
                a.makerNotes,
                a.project,
                a.client,
                formatter.string(from: a.date),
                a.fileModifiedAt.map { formatter.string(from: $0) } ?? "",
                a.fileCreatedAt.map { formatter.string(from: $0) } ?? "",
                a.hasICCProfile ? "true" : "false",
                csvGPS(a.gps.0, asset: a),
                csvGPS(a.gps.1, asset: a),
                a.gpsAltitude.map { String($0) } ?? "",
                a.camera,
                a.lens,
                a.localPath ?? a.thumb,
            ].map(csvField).joined(separator: ",")
        }
        let csv = ([header.joined(separator: ",")] + rows).joined(separator: "\n") + "\n"
        // see exportMetadataJSON: never overwrite a copied original of the same name
        guard let target = resolve(fileURL, conflict: .rename, fm: .default) else { return false }
        return (try? csv.write(to: target, atomically: true, encoding: .utf8)) != nil
    }

    private static func resolve(_ url: URL, conflict: ExportConflict, fm: FileManager) -> URL? {
        guard fm.fileExists(atPath: url.path) else { return url }
        switch conflict {
        case .overwrite: return url
        case .skip: return nil
        case .rename:
            let base = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            let suffix = ext.isEmpty ? "" : ".\(ext)"  // extensionless originals must not gain a trailing dot
            var i = 1
            while true {
                let candidate = url.deletingLastPathComponent()
                    .appendingPathComponent("\(base) (\(i))\(suffix)")
                if !fm.fileExists(atPath: candidate.path) { return candidate }
                i += 1
            }
        }
    }

    private static func exportDirectory(for asset: Asset, source: URL, destination: URL,
                                        structure: ExportDirectoryStructure,
                                        albumNamesByAssetId: [String: String],
                                        sourceRootPathsByFolderId: [String: String]) -> URL {
        let components: [String]
        switch structure {
        case .flat:
            components = []
        case .date:
            let parts = Calendar.captureWallClock.dateComponents([.year, .month, .day],
                                                                 from: asset.date)
            components = [
                String(format: "%04d", parts.year ?? 0),
                String(format: "%02d", parts.month ?? 1),
                String(format: "%02d", parts.day ?? 1),
            ]
        case .sourceFolder:
            components = sourceFolderComponents(for: asset, source: source,
                                                sourceRootPathsByFolderId: sourceRootPathsByFolderId)
        case .album:
            components = [safePathComponent(albumNamesByAssetId[asset.id] ?? "未加入相册")]
        }
        return components.reduce(destination) { url, component in
            url.appendingPathComponent(component, isDirectory: true)
        }
    }

    private static func sourceFolderComponents(for asset: Asset, source: URL,
                                               sourceRootPathsByFolderId: [String: String]) -> [String] {
        let rootName = safePathComponent(asset.folderName, fallback: "Source")
        let parent = source.deletingLastPathComponent().standardizedFileURL.path
        guard let rootPath = sourceRootPathsByFolderId[asset.folderId] else { return [rootName] }

        let root = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        guard parent != root else { return [rootName] }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard parent.hasPrefix(prefix) else { return [rootName] }

        let relative = String(parent.dropFirst(prefix.count))
        let nested = relative.split(separator: "/").map { safePathComponent(String($0)) }
        return [rootName] + nested
    }

    private static func safePathComponent(_ value: String, fallback: String = "Untitled") -> String {
        let disallowed = CharacterSet(charactersIn: "/:").union(.controlCharacters)
        let cleaned = value.components(separatedBy: disallowed).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned != "." && cleaned != ".." else { return fallback }
        return cleaned.isEmpty ? fallback : cleaned
    }

    private static func previewSource(for asset: Asset, fm: FileManager,
                                      thumbnails: ThumbnailService?,
                                      previewMaxPixel: Int) -> URL? {
        let original = asset.localPath.map(URL.init(fileURLWithPath:))
        let originalExists = original.map { fm.fileExists(atPath: $0.path) } ?? false
        let previewKind = ThumbnailService.previewKind(forCachePath: asset.preview,
                                                       fallbackMaxPixel: previewMaxPixel)

        for path in [asset.preview, asset.thumb] where !path.isEmpty && !path.hasPrefix("http") {
            let cached = URL(fileURLWithPath: path)
            guard fm.fileExists(atPath: cached.path) else { continue }
            guard let thumbnails, let original, originalExists,
                  ThumbnailService.cacheIsStale(cache: cached, original: original)
                    || thumbnails.cachedRepresentationNeedsRegeneration(at: cached,
                                                                        original: original,
                                                                        kind: previewKind) else {
                return cached
            }
            if let repaired = thumbnails.ensureCached(from: original, assetId: asset.id, kind: previewKind) {
                return repaired
            }
        }
        guard let thumbnails, let original, originalExists else { return nil }
        return thumbnails.ensureCached(from: original, assetId: asset.id, kind: previewKind)
    }

    private static func jsonDate(_ date: Date?, formatter: ISO8601DateFormatter) -> Any {
        date.map { formatter.string(from: $0) } ?? NSNull()
    }

    private static func jsonNumber(_ value: Double?) -> Any {
        guard let value else { return NSNull() }
        return value
    }

    private static func jsonGPS(_ value: Double, asset: Asset) -> Any {
        hasGPS(asset) ? value : NSNull()
    }

    private static func csvGPS(_ value: Double, asset: Asset) -> String {
        hasGPS(asset) ? String(value) : ""
    }

    private static func hasGPS(_ asset: Asset) -> Bool {
        !(asset.gps.0 == 0 && asset.gps.1 == 0)
    }

    private static func csvField(_ value: String) -> String {
        var v = value
        // Mitigate CSV/formula injection: spreadsheet apps execute a cell that begins with
        // = + - @ (or a leading tab/CR/LF), even inside quotes, so attacker-controlled EXIF/XMP
        // text (caption, keywords, makerNotes, …) could run formulas. Force such cells to text
        // with a leading apostrophe — but leave genuine numbers (e.g. "-122.4" GPS) untouched.
        let riskyPrefix = v.unicodeScalars.first.map { "=+-@\t\r\n".unicodeScalars.contains($0) } ?? false
        if riskyPrefix, Double(v) == nil {
            v = "'" + v
        }
        guard v.contains(",") || v.contains("\"") || v.contains("\n") || v.contains("\r") else {
            return v
        }
        return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
