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
        var groups: [String: [Int]] = [:]
        for index in assets.indices {
            let asset = assets[index]
            guard !asset.deleted, let path = asset.localPath else { continue }
            let (stem, ext) = PathString.splitExtension(path)
            guard asset.isRaw || companionExtensions.contains(ext.lowercased()) else { continue }
            groups[stem.lowercased(), default: []].append(index)
        }
        var companionsByPrimary: [String: [String]] = [:]
        var primaryByCompanion: [String: String] = [:]
        for members in groups.values where members.count > 1 {
            let raws = members.filter { assets[$0].isRaw }
            guard raws.count == 1 else { continue }
            let primary = assets[raws[0]].id
            let companions = members.filter { !assets[$0].isRaw }.map { assets[$0].id }
            companionsByPrimary[primary] = companions
            for id in companions { primaryByCompanion[id] = primary }
        }
        return AssetPairing(companionsByPrimary: companionsByPrimary, primaryByCompanion: primaryByCompanion)
    }
}
