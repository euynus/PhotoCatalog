// ============================================================
//  RAW+JPEG pairing — one exposure, two files
// ============================================================
import Foundation

/// Cameras shooting RAW+JPEG write both files with the same base name into the same
/// folder. The pair is presented as one photo: the RAW is the primary (it owns the tile
/// and the selection), and JPEG/HEIC companions follow every edit made to it.
struct AssetPairing: Sendable {
    let companionsByPrimary: [String: [String]]
    let primaryByCompanion: [String: String]

    static let empty = AssetPairing(companionsByPrimary: [:], primaryByCompanion: [:])

    static let companionExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif"]

    var isEmpty: Bool { companionsByPrimary.isEmpty }

    func isHiddenCompanion(_ id: String) -> Bool { primaryByCompanion[id] != nil }

    /// `ids` plus the companions of any primaries among them.
    func withCompanions(_ ids: Set<String>) -> Set<String> {
        guard !isEmpty else { return ids }
        var result = ids
        for id in ids { result.formUnion(companionsByPrimary[id] ?? []) }
        return result
    }

    /// Pairs live assets sharing a folder and base name, when exactly one is a RAW and the
    /// others are JPEG/HEIC. Ambiguous groups (two RAWs, other formats) stay separate.
    static func rawJpeg(_ assets: [Asset]) -> AssetPairing {
        // Candidates sorted by a hash of their case-folded folder + base name, computed from
        // UTF-8 without allocating: a string and an array per photo made this ~0.7 s at 500k.
        var keyed: [(hash: UInt64, index: Int)] = []
        keyed.reserveCapacity(assets.count)
        for index in assets.indices {
            let asset = assets[index]
            guard !asset.deleted, let path = asset.localPath else { continue }
            let (stem, ext) = PathString.splitExtension(path)
            guard asset.isRaw || companionExtensions.contains(ext.lowercased()) else { continue }
            keyed.append((stemHash(stem), index))
        }
        keyed.sort { $0.hash < $1.hash }
        var companionsByPrimary: [String: [String]] = [:]
        var primaryByCompanion: [String: String] = [:]
        var start = 0
        while start < keyed.count {
            var end = start + 1
            while end < keyed.count, keyed[end].hash == keyed[start].hash { end += 1 }
            if end - start > 1 {
                // same hash: group by the actual case-folded stem, so a collision never pairs
                let members = keyed[start..<end].map(\.index)
                let byStem = Dictionary(grouping: members) {
                    PathString.splitExtension(assets[$0].localPath ?? "").stem.lowercased()
                }
                for group in byStem.values where group.count > 1 {
                    let raws = group.filter { assets[$0].isRaw }
                    guard raws.count == 1 else { continue }
                    let primary = assets[raws[0]].id
                    let companions = group.filter { !assets[$0].isRaw }.map { assets[$0].id }
                    companionsByPrimary[primary] = companions
                    for id in companions { primaryByCompanion[id] = primary }
                }
            }
            start = end
        }
        return AssetPairing(companionsByPrimary: companionsByPrimary, primaryByCompanion: primaryByCompanion)
    }

    /// FNV-1a of the stem with ASCII letters folded to lower case; a non-ASCII stem hashes its
    /// Unicode-lowercased form, so case variants always meet (candidates are verified anyway).
    private static func stemHash(_ stem: Substring) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in stem.utf8 {
            guard byte < 0x80 else { return fnv(stem.lowercased().utf8) }
            let folded = (0x41...0x5A).contains(byte) ? byte + 0x20 : byte
            hash = (hash ^ UInt64(folded)) &* 0x100_0000_01b3
        }
        return hash
    }

    private static func fnv(_ bytes: String.UTF8View) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return hash
    }
}
