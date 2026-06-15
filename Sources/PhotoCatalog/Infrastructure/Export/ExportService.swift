// ============================================================
//  ExportService — copy originals + export metadata (PRD §6.11, §12.10)
// ============================================================
import Foundation

enum ExportConflict { case skip, overwrite, rename }

struct ExportReport {
    var copied = 0
    var skipped = 0
    var failed = 0
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
                if xmp { XMPSidecar.write(a, to: XMPSidecar.sidecarURL(for: target)) }
                report.copied += 1
            } catch {
                report.failed += 1
            }
        }
        return report
    }

    /// Export cached previews for lightweight sharing (PRD §6.11 EXP-004).
    static func exportPreviews(_ assets: [Asset], to destination: URL,
                               conflict: ExportConflict = .rename) -> ExportReport {
        var report = ExportReport()
        let fm = FileManager.default
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)

        for asset in assets where !asset.deleted {
            guard let source = previewSource(for: asset, fm: fm) else {
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
                "captureDate": formatter.string(from: a.date),
                "fileModifiedAt": jsonDate(a.fileModifiedAt, formatter: formatter),
                "fileCreatedAt": jsonDate(a.fileCreatedAt, formatter: formatter),
                "hasICCProfile": a.hasICCProfile,
                "camera": a.camera, "lens": a.lens,
                "originalPath": a.localPath ?? a.thumb,
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else {
            return false
        }
        return (try? data.write(to: fileURL)) != nil
    }

    /// Export per-asset metadata as CSV for spreadsheet workflows (PRD §6.11 EXP-003).
    @discardableResult
    static func exportMetadataCSV(_ assets: [Asset], to fileURL: URL) -> Bool {
        let header = [
            "assetId", "filename", "rating", "flag", "colorLabel", "keywords", "title", "caption",
            "captureDate", "fileModifiedAt", "fileCreatedAt", "hasICCProfile", "camera", "lens", "originalPath",
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
                formatter.string(from: a.date),
                a.fileModifiedAt.map { formatter.string(from: $0) } ?? "",
                a.fileCreatedAt.map { formatter.string(from: $0) } ?? "",
                a.hasICCProfile ? "true" : "false",
                a.camera,
                a.lens,
                a.localPath ?? a.thumb,
            ].map(csvField).joined(separator: ",")
        }
        let csv = ([header.joined(separator: ",")] + rows).joined(separator: "\n") + "\n"
        return (try? csv.write(to: fileURL, atomically: true, encoding: .utf8)) != nil
    }

    private static func resolve(_ url: URL, conflict: ExportConflict, fm: FileManager) -> URL? {
        guard fm.fileExists(atPath: url.path) else { return url }
        switch conflict {
        case .overwrite: return url
        case .skip: return nil
        case .rename:
            let base = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            var i = 1
            while true {
                let candidate = url.deletingLastPathComponent()
                    .appendingPathComponent("\(base) (\(i)).\(ext)")
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
            let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day],
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

    private static func previewSource(for asset: Asset, fm: FileManager) -> URL? {
        for path in [asset.preview, asset.thumb] where !path.isEmpty && !path.hasPrefix("http") {
            if fm.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    private static func jsonDate(_ date: Date?, formatter: ISO8601DateFormatter) -> Any {
        date.map { formatter.string(from: $0) } ?? NSNull()
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
