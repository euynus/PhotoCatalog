// ============================================================
//  RenameService — batch rename of originals on disk (PRD §4.2)
//  Returns the new file URL per asset id; caller updates + persists.
// ============================================================
import Foundation

enum RenameService {
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
            let dir = src.deletingLastPathComponent()
            var dest = dir.appendingPathComponent("\(prefix)_\(String(format: "%04d", seq)).\(ext)")
            var k = 1
            while fm.fileExists(atPath: dest.path) && dest.path != src.path {
                dest = dir.appendingPathComponent("\(prefix)_\(String(format: "%04d", seq))_\(k).\(ext)")
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
