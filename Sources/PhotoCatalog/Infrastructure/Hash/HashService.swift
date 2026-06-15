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
        var bySize: [Int64: [Asset]] = [:]
        for a in assets where a.contentHash != nil {
            bySize[fileSizeBytes(a), default: []].append(a)
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

    static func exactDuplicateKey(_ asset: Asset) -> String? {
        asset.contentHash.map { "\(fileSizeBytes(asset))|\($0)" }
    }

    /// Group likely duplicates before expensive similarity checks (PRD DUP-002).
    static func suspectedDuplicateGroups(_ assets: [Asset]) -> [DuplicateGroup] {
        var buckets: [String: [Asset]] = [:]
        for asset in assets {
            buckets[suspectedKey(asset), default: []].append(asset)
        }

        var groups: [DuplicateGroup] = []
        var index = 0
        for (_, bucket) in buckets where bucket.count > 1 {
            let contentHashes = Set(bucket.compactMap(\.contentHash))
            if contentHashes.count == 1 && bucket.allSatisfy({ $0.contentHash != nil }) {
                continue
            }
            groups.append(DuplicateGroup(id: "dg-sus-\(index)",
                                         method: "suspected",
                                         score: 0.82,
                                         items: bucket))
            index += 1
        }
        return groups
    }

    private static func suspectedKey(_ asset: Asset) -> String {
        let timeBucket = Int(asset.date.timeIntervalSince1970 / 300)
        let identity = asset.quickHash ?? normalizedFilename(asset.filename)
        return [
            identity,
            "\(asset.width)x\(asset.height)",
            "\(timeBucket)",
        ].joined(separator: "|")
    }

    private static func fileSizeBytes(_ asset: Asset) -> Int64 {
        Int64((asset.fileMB * 1024 * 1024).rounded())
    }

    private static func normalizedFilename(_ filename: String) -> String {
        var base = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent.lowercased()
        for suffix in [" copy", "_copy", "-copy", " edit", "_edit", "-edit", " edited", "_edited", "-edited"] {
            if base.hasSuffix(suffix) {
                base.removeLast(suffix.count)
            }
        }
        if let range = base.range(of: #" \([0-9]+\)$"#, options: .regularExpression) {
            base.removeSubrange(range)
        }
        return base
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.compactMap { String(format: "%02x", $0) }.joined()
    }
}
