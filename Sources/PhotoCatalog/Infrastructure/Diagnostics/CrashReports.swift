// ============================================================
//  Crash reports — the ones macOS keeps for this app, found at the next launch
// ============================================================
import Foundation

enum CrashReports {
    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports",
                                                                              isDirectory: true)
    }

    /// Crash reports macOS wrote for the app `bundleID` after `since`, newest first. Reports
    /// stay on this Mac; the app only points to them.
    static func find(bundleID: String, since: Date, in folder: URL = folder) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return files.compactMap { url -> (URL, Date)? in
            guard url.pathExtension == "ips",
                  let modified = try? url.resourceValues(forKeys: Set(keys)).contentModificationDate,
                  modified > since,
                  let header = firstLine(of: url),
                  let fields = try? JSONSerialization.jsonObject(with: header) as? [String: Any],
                  fields["bundleID"] as? String == bundleID,
                  fields["bug_type"] as? String == "309"   // a crash, not a hang or a disk-write report
            else { return nil }
            return (url, modified)
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    /// An .ips report starts with one line of JSON describing it.
    private static func firstLine(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4096) else { return nil }
        return head.split(separator: UInt8(ascii: "\n"), maxSplits: 1).first.map { Data($0) }
    }
}
