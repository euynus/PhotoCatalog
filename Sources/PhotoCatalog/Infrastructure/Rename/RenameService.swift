// ============================================================
//  RenameService — batch rename of originals on disk (PRD §4.2)
//  Returns the new file URL per asset id; caller updates + persists.
// ============================================================
import Foundation

enum RenameService {
    /// Rename each asset's original from a token template (§4.2).
    /// Supported tokens: {seq} {date} {time} {camera} {original}. The extension is preserved.
    static func renameWithTemplate(_ assets: [Asset], template: String, start: Int = 1) -> [String: URL] {
        let fm = FileManager.default
        // {date}/{time} come from the capture wall-clock (UTC-anchored), so renamed files carry
        // the time the camera recorded regardless of the machine's timezone
        let dateFmt = DateFormatter(); dateFmt.dateFormat = "yyyyMMdd"; dateFmt.locale = Locale(identifier: "en_US_POSIX")
        dateFmt.timeZone = TimeZone.captureWallClock
        let timeFmt = DateFormatter(); timeFmt.dateFormat = "HHmmss"; timeFmt.locale = Locale(identifier: "en_US_POSIX")
        timeFmt.timeZone = TimeZone.captureWallClock
        var result: [String: URL] = [:]
        var seq = start
        for a in assets {
            guard let path = a.localPath else { continue }
            let src = URL(fileURLWithPath: path)
            guard fm.fileExists(atPath: src.path) else { continue }
            let ext = src.pathExtension
            let dir = src.deletingLastPathComponent()
            let original = src.deletingPathExtension().lastPathComponent
            var name = template
                .replacingOccurrences(of: "{seq}", with: String(format: "%04d", seq))
                .replacingOccurrences(of: "{date}", with: dateFmt.string(from: a.date))
                .replacingOccurrences(of: "{time}", with: timeFmt.string(from: a.date))
                .replacingOccurrences(of: "{camera}", with: sanitize(a.camera))
                .replacingOccurrences(of: "{original}", with: original)
            name = sanitize(name)
            let base = name.isEmpty ? original : name
            func candidate(_ suffix: String) -> URL {
                dir.appendingPathComponent(ext.isEmpty ? base + suffix : "\(base)\(suffix).\(ext)")
            }
            var dest = candidate("")
            var k = 1
            while fm.fileExists(atPath: dest.path) && dest.path != src.path { dest = candidate("_\(k)"); k += 1 }
            if dest.path == src.path { result[a.id] = src; seq += 1; continue }
            do { try fm.moveItem(at: src, to: dest); result[a.id] = dest; seq += 1 } catch { continue }
        }
        return result
    }

    private static func sanitize(_ s: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: illegal).joined(separator: "-")
    }

    /// Rename each asset's original to `<prefix>_<seq>.<ext>` starting at `start`.
    /// Only assets with an existing local original are touched.
    static func rename(_ assets: [Asset], prefix: String, start: Int = 1) -> [String: URL] {
        let fm = FileManager.default
        var result: [String: URL] = [:]
        var seq = start
        for a in assets {
            guard let path = a.localPath else { continue }
            let src = URL(fileURLWithPath: path)
            guard fm.fileExists(atPath: src.path) else { continue }
            let ext = src.pathExtension
            let suffix = ext.isEmpty ? "" : ".\(ext)"
            let dir = src.deletingLastPathComponent()
            var dest = dir.appendingPathComponent("\(prefix)_\(String(format: "%04d", seq))\(suffix)")
            var k = 1
            while fm.fileExists(atPath: dest.path) && dest.path != src.path {
                dest = dir.appendingPathComponent("\(prefix)_\(String(format: "%04d", seq))_\(k)\(suffix)")
                k += 1
            }
            if dest.path == src.path { result[a.id] = src; seq += 1; continue }
            do {
                try fm.moveItem(at: src, to: dest)
                result[a.id] = dest
                seq += 1
            } catch {
                continue
            }
        }
        return result
    }
}
