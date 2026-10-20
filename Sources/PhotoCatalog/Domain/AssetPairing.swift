// ============================================================
//  RAW+JPEG pairing — one exposure, two files
// ============================================================
import Foundation

/// Cameras shooting RAW+JPEG write both files with the same base name into the same
/// folder. The pair is presented as one photo: the RAW is the primary (it owns the tile
/// and the selection), and JPEG/HEIC companions follow every edit made to it.
struct AssetPairing: Sendable, Equatable {
    private(set) var companionsByPrimary: [String: [String]]
    private(set) var primaryByCompanion: [String: String]
    /// Whether each of the photos it was worked out from is a companion, by position: a pass over
    /// those photos asks here instead of looking every photo's id up (at 500k photos, those
    /// lookups were most of what counting the library or its capture dates took).
    private var hiddenAt: [Bool] = []
    /// The photos that can pair, sorted by the hash of their case-folded folder and base name (and
    /// position): photos added later find the ones they may pair with here.
    private var keys: [Key] = []

    static let empty = AssetPairing(companionsByPrimary: [:], primaryByCompanion: [:])

    static let companionExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif"]

    var isEmpty: Bool { companionsByPrimary.isEmpty }

    func isHiddenCompanion(_ id: String) -> Bool { primaryByCompanion[id] != nil }

    /// Whether the catalog shows `asset`: not removed, and not the JPEG behind its RAW.
    func shows(_ asset: Asset) -> Bool { !asset.deleted && !isHiddenCompanion(asset.id) }

    /// `shows(_:)` for the photo at `position` of the photos this pairing was worked out from,
    /// without looking its id up: what passes over all of those photos ask.
    func isShown(_ asset: Asset, at position: Int) -> Bool {
        guard !asset.deleted else { return false }
        let hidden = position < hiddenAt.count && hiddenAt[position]
        assert(hidden == isHiddenCompanion(asset.id), "a pairing asked about photos it wasn't worked out from")
        return !hidden
    }

    /// `ids` plus the companions of any primaries among them.
    func withCompanions(_ ids: Set<String>) -> Set<String> {
        guard !isEmpty else { return ids }
        var result = ids
        for id in ids { result.formUnion(companionsByPrimary[id] ?? []) }
        return result
    }

    /// Whether two files are one exposure: taken within a second or two of each other, by the
    /// same camera when both name theirs. Files that only share a name — another camera's
    /// IMG_1234, the same camera's counter come round again — are two photos.
    static func isSameShot(_ a: (camera: String, date: Date), _ b: (camera: String, date: Date)) -> Bool {
        guard abs(a.date.timeIntervalSince(b.date)) < 2 else { return false }
        // one camera's name, as both files nearly always give it: alike however it's compared
        if a.camera == b.camera { return true }
        let left = a.camera.trimmingCharacters(in: .whitespaces)
        let right = b.camera.trimmingCharacters(in: .whitespaces)
        return left.isEmpty || right.isEmpty || left.caseInsensitiveCompare(right) == .orderedSame
    }

    /// Pairs live assets sharing a folder and base name, when exactly one is a RAW and the
    /// others are JPEG/HEIC of the same shot. Ambiguous groups (two RAWs, other formats) stay
    /// separate, and virtual copies always stand alone.
    static func rawJpeg(_ assets: [Asset]) -> AssetPairing {
        // Candidates sorted by a hash of their case-folded folder + base name (position breaks
        // ties, so the photos sharing one are in catalog order): hashed on every core, then put
        // in buckets by the hash's top bits, each bucket sorted and paired on every core. One
        // thread took ~0.55 s for this at 500k photos.
        let keys = Self.keys(of: assets, in: assets.indices)
        let bucketBits = 8
        var starts = [Int](repeating: 0, count: (1 << bucketBits) + 1)
        for key in keys { starts[Int(key.hash >> (64 - bucketBits)) + 1] += 1 }
        for bucket in 0 ..< 1 << bucketBits { starts[bucket + 1] += starts[bucket] }
        var sorted = [Key](unsafeUninitializedCapacity: keys.count) { buffer, count in
            var next = starts
            for key in keys {
                let bucket = Int(key.hash >> (64 - bucketBits))
                (buffer.baseAddress! + next[bucket]).initialize(to: key)
                next[bucket] += 1
            }
            count = keys.count
        }
        let lock = NSLock()
        var pairs: [Pair] = []
        sorted.withUnsafeMutableBufferPointer { sortedKeys in
            let buffer = sortedKeys
            DispatchQueue.concurrentPerform(iterations: 1 << bucketBits) { bucket in
                var keys = UnsafeMutableBufferPointer(rebasing: buffer[starts[bucket] ..< starts[bucket + 1]])
                keys.sort { $0.hash != $1.hash ? $0.hash < $1.hash : $0.position < $1.position }
                var found: [Pair] = []
                var start = 0
                while start < keys.count {
                    var end = start + 1
                    while end < keys.count, keys[end].hash == keys[start].hash { end += 1 }
                    if end - start > 1 { Self.pairs(among: keys[start..<end].map(\.position), of: assets, into: &found) }
                    start = end
                }
                if !found.isEmpty { lock.withLock { pairs += found } }
            }
        }
        var pairing = AssetPairing(companionsByPrimary: [:], primaryByCompanion: [:],
                                   hiddenAt: Array(repeating: false, count: assets.count), keys: sorted)
        pairing.add(pairs, of: assets)
        return pairing
    }

    /// Carries this pairing of the photos before `start` on to `assets`, which has more photos
    /// after them (an import batch, a tethered shot, virtual copies): only the names the new
    /// photos share with others are paired again, as `rawJpeg(assets)` would pair them. A new
    /// JPEG can hide behind a RAW already there, a new RAW can take JPEGs already there as its
    /// companions, and a second RAW of a name makes it ambiguous, its JPEG shown again.
    /// Returns the earlier photos whose being hidden changed; nil, and nothing changed, when this
    /// isn't the pairing of exactly the photos before `start`.
    mutating func append(_ assets: [Asset], from start: Int) -> [Int]? {
        guard hiddenAt.count == start, start <= assets.count else { return nil }
        var added = Self.keys(of: assets, in: start ..< assets.count)
        added.sort { $0.hash != $1.hash ? $0.hash < $1.hash : $0.position < $1.position }
        hiddenAt.append(contentsOf: repeatElement(false, count: assets.count - start))
        var earlier: [(position: Int, wasHidden: Bool)] = []
        var pairs: [Pair] = []
        var next = 0
        while next < added.count {
            var end = next + 1
            while end < added.count, added[end].hash == added[next].hash { end += 1 }
            // the photos already there by the same hash: a binary search of the sorted keys
            let hash = added[next].hash
            var lower = 0, upper = keys.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if keys[middle].hash < hash { lower = middle + 1 } else { upper = middle }
            }
            var last = lower
            while last < keys.count, keys[last].hash == hash { last += 1 }
            let before = keys[lower..<last].map(\.position)
            let members = before + added[next..<end].map(\.position)
            if members.count > 1 {
                // what they paired as goes (a RAW and its companions share a name, so a hash),
                // and they're paired again with the new ones
                for position in before {
                    earlier.append((position, hiddenAt[position]))
                    let id = assets[position].id
                    companionsByPrimary[id] = nil
                    primaryByCompanion[id] = nil
                    hiddenAt[position] = false
                }
                Self.pairs(among: members, of: assets, into: &pairs)
            }
            next = end
        }
        add(pairs, of: assets)
        if !added.isEmpty { keys = Self.merged(keys, added) }
        return earlier.filter { hiddenAt[$0.position] != $0.wasHidden }.map(\.position)
    }

    /// Two key lists sorted alike, as one.
    private static func merged(_ a: [Key], _ b: [Key]) -> [Key] {
        var result: [Key] = []
        result.reserveCapacity(a.count + b.count)
        var (i, j) = (0, 0)
        while i < a.count, j < b.count {
            let first = a[i].hash != b[j].hash ? a[i].hash < b[j].hash : a[i].position < b[j].position
            if first {
                result.append(a[i])
                i += 1
            } else {
                result.append(b[j])
                j += 1
            }
        }
        result += a[i...]
        result += b[j...]
        return result
    }

    /// A RAW and its companions, by position.
    private typealias Pair = (primary: Int, companions: [Int])

    /// A photo that can pair: the hash of its case-folded folder and base name, and where it is.
    private struct Key: Equatable {
        var hash: UInt64
        var position: Int
    }

    private mutating func add(_ pairs: [Pair], of assets: [Asset]) {
        for pair in pairs {
            for position in pair.companions { hiddenAt[position] = true }
        }
        // the two tables on two cores, each a lookup by id per photo paired
        var byPrimary = companionsByPrimary, byCompanion = primaryByCompanion
        (companionsByPrimary, primaryByCompanion) = ([:], [:])   // so the tables are changed in place
        let both = pairs.count <= 1_000   // too few for a second thread to pay
        DispatchQueue.concurrentPerform(iterations: both ? 1 : 2) { table in
            if both || table == 0 {
                byPrimary.reserveCapacity(byPrimary.count + pairs.count)
                for pair in pairs { byPrimary[assets[pair.primary].id] = pair.companions.map { assets[$0].id } }
            }
            if both || table == 1 {
                byCompanion.reserveCapacity(byCompanion.count + pairs.reduce(0) { $0 + $1.companions.count })
                for pair in pairs {
                    let primary = assets[pair.primary].id
                    for position in pair.companions { byCompanion[assets[position].id] = primary }
                }
            }
        }
        (companionsByPrimary, primaryByCompanion) = (byPrimary, byCompanion)
    }

    /// The pairs among photos whose names hash alike (`members`, positions in order): grouped by
    /// the actual case-folded folder and base name, so a collision never pairs, and in each group
    /// its one RAW with the JPEG/HEIC files of the same shot.
    private static func pairs(among members: [Int], of assets: [Asset], into pairs: inout [Pair]) {
        let groups: [[Int]]
        if sameASCIIName(members, of: assets) {
            groups = [members]
        } else {
            // a collision, or a name beyond ASCII: compared as `lowercased()` gives it
            groups = Array(Dictionary(grouping: members) {
                PathString.splitExtension(assets[$0].localPath ?? "").stem.lowercased()
            }.values)
        }
        for group in groups where group.count > 1 {
            let raws = group.filter { assets[$0].isRaw }
            guard raws.count == 1 else { continue }
            let raw = assets[raws[0]]
            // a same-named file from another camera or another moment is another photo
            let companions = group.filter {
                !assets[$0].isRaw && isSameShot((raw.camera, raw.date), (assets[$0].camera, assets[$0].date))
            }
            if !companions.isEmpty { pairs.append((raws[0], companions)) }
        }
    }

    /// The keys of the photos in `range` that can pair, in order, worked out in chunks on every
    /// core: one thread took ~0.3 s at 500k photos.
    private static func keys(of assets: [Asset], in range: Range<Int>, chunk: Int = 16_384) -> [Key] {
        func keys(_ range: Range<Int>) -> [Key] {
            var keys: [Key] = []
            keys.reserveCapacity(range.count)
            for position in range {
                if let hash = nameHash(of: assets[position]) { keys.append(Key(hash: hash, position: position)) }
            }
            return keys
        }
        let chunks = (range.count + chunk - 1) / chunk
        guard chunks > 1 else { return keys(range) }
        let lock = NSLock()
        var parts = [[Key]](repeating: [], count: chunks)
        DispatchQueue.concurrentPerform(iterations: chunks) { index in
            let lower = range.lowerBound + index * chunk
            let part = keys(lower ..< min(range.upperBound, lower + chunk))
            lock.withLock { parts[index] = part }
        }
        return Array(parts.joined())
    }

    /// The hash of a photo's case-folded folder + base name (FNV-1a of its `lowercased()`
    /// UTF-8), when it can pair: a live original with a file that's a RAW or a JPEG/HEIC.
    private static func nameHash(of asset: Asset) -> UInt64? {
        guard !asset.deleted, !asset.isVirtualCopy, let path = asset.localPath else { return nil }
        let raw = asset.isRaw
        // over the path's UTF-8 in place: splitting it into Substrings, lower-casing the
        // extension and walking the name per photo made this most of a second at 500k photos
        switch path.utf8.withContiguousStorageIfAvailable({ asciiNameHash($0, raw: raw) }) ?? .unicode {
        case .none:
            return nil
        case .hash(let hash):
            return hash
        case .unicode:
            let (stem, ext) = PathString.splitExtension(path)
            guard raw || companionExtensions.contains(ext.lowercased()) else { return nil }
            return fnv(stem.lowercased().utf8)
        }
    }

    private enum NameHash {
        case none, hash(UInt64)
        /// a name or extension beyond ASCII, hashed from its `lowercased()` string instead
        case unicode
    }

    private static func asciiNameHash(_ path: UnsafeBufferPointer<UInt8>, raw: Bool) -> NameHash {
        let (stemEnd, extStart) = split(path)
        if !raw {
            guard let companion = isCompanionExtension(path[extStart...]) else { return .unicode }
            guard companion else { return .none }
        }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in path[..<stemEnd] {
            guard byte < 0x80 else { return .unicode }
            hash = (hash ^ UInt64(folded(byte))) &* 0x100_0000_01b3
        }
        return .hash(hash)
    }

    /// Whether an ASCII extension is jpg, jpeg, heic or heif in any case; nil beyond ASCII.
    private static func isCompanionExtension(_ ext: Slice<UnsafeBufferPointer<UInt8>>) -> Bool? {
        var packed: UInt32 = 0
        for byte in ext {
            guard byte < 0x80 else { return nil }
            packed = packed << 8 | UInt32(folded(byte))
        }
        switch ext.count {
        case 3: return packed == 0x6A_70_67                                          // jpg
        case 4: return packed == 0x6A_70_65_67 || packed == 0x68_65_69_63 || packed == 0x68_65_69_66   // jpeg heic heif
        default: return false
        }
    }

    /// Where a path's folder + base name ends and its extension starts, as `PathString.splitExtension`
    /// splits it: no extension (none, or a name that starts with its only dot) is the whole path.
    private static func split(_ path: UnsafeBufferPointer<UInt8>) -> (stemEnd: Int, extStart: Int) {
        var dot: Int?
        var nameStart = 0
        var index = path.count
        while index > 0 {
            index -= 1
            if path[index] == UInt8(ascii: "/") {
                nameStart = index + 1
                break
            }
            if dot == nil, path[index] == UInt8(ascii: ".") { dot = index }
        }
        guard let dot, dot > nameStart else { return (path.count, path.count) }
        return (dot, dot + 1)
    }

    /// Whether the photos' folders and base names are one, all ASCII and alike ignoring case:
    /// what `lowercased()` compares of such names, without making a string of each.
    private static func sameASCIIName(_ members: [Int], of assets: [Asset]) -> Bool {
        guard let first = assets[members[0]].localPath else { return false }
        return first.utf8.withContiguousStorageIfAvailable { name in
            let end = split(name).stemEnd
            for position in members.dropFirst() {
                guard let path = assets[position].localPath else { return false }
                let same = path.utf8.withContiguousStorageIfAvailable { other in
                    guard split(other).stemEnd == end else { return false }
                    for index in 0..<end {
                        let (a, b) = (name[index], other[index])
                        guard a < 0x80, b < 0x80, folded(a) == folded(b) else { return false }
                    }
                    return true
                }
                guard same == true else { return false }
            }
            return true
        } ?? false
    }

    private static func folded(_ byte: UInt8) -> UInt8 {
        (0x41...0x5A).contains(byte) ? byte + 0x20 : byte
    }

    private static func fnv(_ bytes: String.UTF8View) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return hash
    }
}
