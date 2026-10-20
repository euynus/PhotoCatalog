// ============================================================
//  Edited versions — TIFF copies made for an external editor
// ============================================================
import Foundation

/// A photo sent to an external editor comes back as `<name>-编辑.tif` (`<name>-Edit.tif` in
/// English) beside its original. Photos named that way stack with their original, whichever
/// language made them, so the relation needs nothing stored.
enum EditedVersions {
    /// What an edited copy's name adds to its original's.
    static var suffix: String { "-" + L("编辑") }

    /// How an edited copy's name ends, in every language the app writes it (file names, not UI text).
    private static let editedNameEnding = #"-(编辑|[Ee]dit)(?:[-_ ]\(?\d+\)?)?$"#

    /// Whether a file name could be an edited copy's: it contains "edit" in any case, or "编".
    /// A byte scan — Foundation's case-insensitive search took ~1.3 s over 500k names — of the
    /// bytes where the string keeps them (stepping through its UTF-8 view took ~60 ms).
    static func mightBeEditedCopy(_ name: String) -> Bool {
        name.utf8.withContiguousStorageIfAvailable(mightBeEditedCopy)
            ?? Array(name.utf8).withUnsafeBufferPointer(mightBeEditedCopy)
    }

    private static func mightBeEditedCopy(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        var index = 0
        while index + 2 < bytes.count {
            let byte = bytes[index]
            // "edit" in any case: bit 5 lowercases these capitals, and turns no other byte into the letters
            if byte | 0x20 == 0x65, index + 3 < bytes.count, bytes[index + 1] | 0x20 == 0x64,
               bytes[index + 2] | 0x20 == 0x69, bytes[index + 3] | 0x20 == 0x74 { return true }
            if byte == 0xE7, bytes[index + 1] == 0xBC, bytes[index + 2] == 0x96 { return true }   // "编"
            index += 1
        }
        return false
    }

    /// The original's base name, when `stem` (a file name without extension) is an edited
    /// copy's: "IMG_1-编辑", "IMG_1-Edit", "IMG_1-编辑-2" and "IMG_1-Edit (2)" all give "IMG_1".
    static func originalStem(of stem: String) -> String? {
        guard let ending = stem.range(of: editedNameEnding, options: .regularExpression) else { return nil }
        let original = String(stem[..<ending.lowerBound])
        return original.isEmpty ? nil : original
    }

    /// Each original with its edited copies, as groups for stacking. The original is the RAW
    /// when a RAW and a JPEG share its name; virtual copies take no part. Both passes over the
    /// photos run in chunks side by side, joined in catalog order: on one thread they took
    /// ~60 ms at 500k photos without edited copies, ~500 ms with some, after every structural change.
    static func groups(_ assets: [Asset], chunk: Int = 65_536) -> [DuplicateGroup] {
        // the edited copies, each with its original's folder and case-folded name
        let edits = PhotoStackService.found(in: assets, chunk: chunk) {
            asset, position -> (position: Int, dir: String, key: String)? in
            // a cheap test first: only names that could be an edited copy are parsed
            guard !asset.deleted, !asset.isVirtualCopy, mightBeEditedCopy(asset.filename),
                  let path = asset.localPath else { return nil }
            let (dir, stem) = split(path)
            guard let original = originalStem(of: stem) else { return nil }
            return (position, dir, dir + "/" + original.lowercased())
        }
        guard !edits.isEmpty else { return [] }
        let folders = Folders(edits.map(\.dir)), keys = Set(edits.map(\.key))
        // the photos named as an original of theirs, in catalog order: each name's first RAW is
        // its original, or else its first photo
        let candidates = PhotoStackService.found(in: assets, chunk: chunk) {
            asset, position -> (position: Int, key: String)? in
            guard !asset.deleted, !asset.isVirtualCopy, let path = asset.localPath,
                  folders.mightContain(folderOf: path) else { return nil }
            let (dir, stem) = split(path)
            guard folders.names.contains(Substring(dir)) else { return nil }
            let key = dir + "/" + stem.lowercased()
            // an edited copy's name (which no original has) says "edit" or "编": the costly
            // pattern match is for names that might
            guard keys.contains(key), !mightBeEditedCopy(stem) || originalStem(of: stem) == nil else { return nil }
            return (position, key)
        }
        var originals: [String: Int] = [:]
        for candidate in candidates {
            if let existing = originals[candidate.key], assets[existing].isRaw || !assets[candidate.position].isRaw {
                continue
            }
            originals[candidate.key] = candidate.position
        }
        var grouped: [String: [Asset]] = [:]
        var order: [String] = []
        for edit in edits {
            guard originals[edit.key] != nil else { continue }
            if grouped[edit.key] == nil { order.append(edit.key) }
            grouped[edit.key, default: []].append(assets[edit.position])
        }
        return order.compactMap { key in
            guard let original = originals[key].map({ assets[$0] }), let copies = grouped[key] else { return nil }
            return DuplicateGroup(id: "edit-" + original.id, method: "edit", score: 1, items: [original] + copies)
        }
    }

    /// A path's folder and its file's name without the extension, as `PathString` takes them
    /// (string splitting, not URLs: this runs over every photo in the catalog). Read from the
    /// bytes when the last slash stands between plain ASCII, as catalog paths' does: counting the
    /// path's characters, as `PathString` does to find it, took most of a pass over the photos.
    private static func split(_ path: String) -> (dir: String, stem: String) {
        guard let slash = lastSlash(in: path) else {
            return (PathString.directory(of: path), String(PathString.splitExtension(PathString.lastComponent(path)).stem))
        }
        let end = path.utf8.index(path.utf8.startIndex, offsetBy: slash)
        let name = String(path[path.utf8.index(after: end)...])
        return (slash == 0 ? "/" : String(path[..<end]), String(PathString.splitExtension(name).stem))
    }

    /// Where `path`'s last slash is among its bytes, when it has plain ASCII on both sides (and
    /// so is a character of its own, where `PathString` splits the path): nil for other paths.
    private static func lastSlash(in path: String) -> Int? {
        let slash = path.utf8.withContiguousStorageIfAvailable { bytes -> Int? in
            guard let last = bytes.last, last != UInt8(ascii: "/"),
                  let slash = bytes.lastIndex(of: UInt8(ascii: "/")),
                  bytes[slash + 1] < 0x80, slash == 0 || bytes[slash - 1] < 0x80 else { return nil }
            return slash
        }
        return slash ?? nil
    }

    /// The folders edited copies are in, which a pass over every photo tells most photos apart
    /// from without building the photo's folder as a string (that took most of the pass).
    private struct Folders {
        let names: Set<Substring>
        /// Hashes of the folders' bytes, when every folder is plain ASCII: a folder in plain ASCII
        /// is then one of them only byte for byte.
        let hashes: Set<UInt64>?
        /// A bit for each folder's hash, at its low bits: most other folders find theirs clear.
        private let bits: [UInt64]
        private let mask: UInt64

        init(_ folders: [String]) {
            names = Set(folders.map { Substring($0) })
            let hashed = folders.map { folder in
                folder.utf8.withContiguousStorageIfAvailable(Folders.hash) ?? Array(folder.utf8).withUnsafeBufferPointer(Folders.hash)
            }
            hashes = hashed.allSatisfy(\.ascii) ? Set(hashed.map(\.hash)) : nil
            var size = 4_096
            while size < folders.count * 64 { size *= 2 }
            var bits = [UInt64](repeating: 0, count: size / 64)
            for folder in hashed {
                let bit = Int(folder.hash & UInt64(size - 1))
                bits[bit >> 6] |= 1 << UInt64(bit & 63)
            }
            (self.bits, mask) = (bits, UInt64(size - 1))
        }

        /// Whether the folder of the photo at `path` could be one of these: false only when it
        /// surely isn't. The folder is the path before its last slash when that slash has plain
        /// ASCII on both sides (catalog paths' always does): a character of its own, then, as
        /// `PathString.directory` takes it. Other paths may be in any of them.
        func mightContain(folderOf path: String) -> Bool {
            guard let slash = EditedVersions.lastSlash(in: path) else { return true }
            // the root's folder is "/" itself
            let length = max(slash, 1)
            let answer = path.utf8.withContiguousStorageIfAvailable { bytes -> Bool in
                if let hashes {
                    let folder = Folders.hash(UnsafeBufferPointer(rebasing: bytes[..<length]))
                    if folder.ascii {
                        let bit = Int(folder.hash & mask)
                        return bits[bit >> 6] & 1 << UInt64(bit & 63) != 0 && hashes.contains(folder.hash)
                    }
                }
                return names.contains(path[..<path.utf8.index(path.utf8.startIndex, offsetBy: length)])
            }
            return answer ?? true
        }

        /// A hash of `bytes`, eight at a time, and whether they're all ASCII.
        private static func hash(_ bytes: UnsafeBufferPointer<UInt8>) -> (hash: UInt64, ascii: Bool) {
            let raw = UnsafeRawBufferPointer(bytes)
            var hash = 0x9E37_79B9_7F4A_7C15 ^ UInt64(bytes.count)
            var high: UInt64 = 0
            var offset = 0
            func mix(_ word: UInt64) {
                high |= word
                hash = (hash ^ word) &* 0xBF58_476D_1CE4_E5B9
                hash ^= hash >> 31
            }
            while offset + 8 <= bytes.count {
                mix(raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
                offset += 8
            }
            var tail: UInt64 = 0
            while offset < bytes.count {
                tail = tail << 8 | UInt64(bytes[offset])
                offset += 1
            }
            mix(tail)
            return (hash, high & 0x8080_8080_8080_8080 == 0)
        }
    }
}
