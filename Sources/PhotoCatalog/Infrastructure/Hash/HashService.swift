// ============================================================
//  HashService — quick hash + full SHA-256 for exact duplicates
//  (PRD §6.10 DUP-001, §12.9)
// ============================================================
import Foundation
import CryptoKit

enum HashService {
    /// Cheap pre-filter: file size + first/last 1 MB hashed together.
    static func quickHash(_ url: URL, fileSize: Int64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let chunk = 1024 * 1024
        var hasher = SHA256()
        hasher.update(data: Data("\(fileSize)".utf8))
        if let head = try? handle.read(upToCount: chunk) { hasher.update(data: head) }
        if fileSize > Int64(chunk * 2) {
            try? handle.seek(toOffset: UInt64(max(0, fileSize - Int64(chunk))))
            if let tail = try? handle.read(upToCount: chunk) { hasher.update(data: tail) }
        }
        return hex(hasher.finalize())
    }

    /// Full content hash (streamed so large RAW files don't blow memory).
    static func contentHash(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try? handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hex(hasher.finalize())
    }

    /// Group assets that share an identical content hash (size-bucketed first).
    static func exactDuplicateGroups(_ assets: [Asset]) -> [DuplicateGroup] {
        // bucket by rounded size, then by content hash within each bucket
        var bySize: [Int: [Asset]] = [:]
        for a in assets where a.contentHash != nil {
            bySize[Int(a.fileMB * 1000), default: []].append(a)
        }
        var groups: [DuplicateGroup] = []
        var n = 0
        for (_, bucket) in bySize where bucket.count > 1 {
            var byHash: [String: [Asset]] = [:]
            for a in bucket { byHash[a.contentHash!, default: []].append(a) }
            for (_, items) in byHash where items.count > 1 {
                groups.append(DuplicateGroup(id: "dg-real-\(n)", method: "contentHash", score: 1.0, items: items))
                n += 1
            }
        }
        return groups
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.compactMap { String(format: "%02x", $0) }.joined()
    }
}
