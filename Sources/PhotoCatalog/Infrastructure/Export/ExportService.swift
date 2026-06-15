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
                              conflict: ExportConflict = .rename, xmp: Bool = false) -> ExportReport {
        var report = ExportReport()
        let fm = FileManager.default
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for a in assets {
            guard let path = a.localPath else { report.skipped += 1; continue }
            let src = URL(fileURLWithPath: path)
            guard fm.fileExists(atPath: src.path) else { report.failed += 1; continue }
            let target = resolve(destination.appendingPathComponent(src.lastPathComponent),
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

    /// Export per-asset metadata as a JSON sidecar bundle (PRD §6.11 EXP-003).
    @discardableResult
    static func exportMetadataJSON(_ assets: [Asset], to fileURL: URL) -> Bool {
        let payload = assets.map { a -> [String: Any] in
            [
                "assetId": a.id, "filename": a.filename, "rating": a.rating,
                "flag": a.flag.rawValue, "colorLabel": a.colorLabel?.rawValue ?? NSNull(),
                "keywords": a.keywords, "title": a.title, "caption": a.caption,
                "captureDate": ISO8601DateFormatter().string(from: a.date),
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
            "captureDate", "camera", "lens", "originalPath",
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

    private static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
