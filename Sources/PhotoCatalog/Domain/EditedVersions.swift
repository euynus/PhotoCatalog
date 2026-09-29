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
    /// A byte scan — Foundation's case-insensitive search took ~1.3 s over 500k names.
    static func mightBeEditedCopy(_ name: String) -> Bool {
        var window: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)
        for byte in name.utf8 {
            let folded = byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte
            window = (window.1, window.2, window.3, folded)
            if window == (0x65, 0x64, 0x69, 0x74) { return true }                  // "edit"
            if window.1 == 0xE7 && window.2 == 0xBC && window.3 == 0x96 { return true } // "编"
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
    /// when a RAW and a JPEG share its name; virtual copies take no part.
    static func groups(_ assets: [Asset]) -> [DuplicateGroup] {
        // string splitting, not URLs: this runs over every photo in the catalog
        func split(_ path: String) -> (dir: String, stem: String) {
            (PathString.directory(of: path), String(PathString.splitExtension(PathString.lastComponent(path)).stem))
        }
        var edits: [(asset: Asset, key: String)] = []
        var directories = Set<String>()
        for asset in assets where !asset.deleted && !asset.isVirtualCopy {
            // a cheap test first: only names that could be an edited copy are parsed
            guard mightBeEditedCopy(asset.filename), let path = asset.localPath else { continue }
            let (dir, stem) = split(path)
            guard let original = originalStem(of: stem) else { continue }
            edits.append((asset, dir + "/" + original.lowercased()))
            directories.insert(dir)
        }
        guard !edits.isEmpty else { return [] }
        var originals: [String: Asset] = [:]
        for asset in assets where !asset.deleted && !asset.isVirtualCopy {
            guard let path = asset.localPath else { continue }
            let dir = PathString.directory(of: path)
            guard directories.contains(dir) else { continue }
            let stem = String(PathString.splitExtension(PathString.lastComponent(path)).stem)
            guard originalStem(of: stem) == nil else { continue }
            let key = dir + "/" + stem.lowercased()
            if let existing = originals[key], existing.isRaw || !asset.isRaw { continue }
            originals[key] = asset
        }
        var grouped: [String: [Asset]] = [:]
        var order: [String] = []
        for edit in edits {
            guard originals[edit.key] != nil else { continue }
            if grouped[edit.key] == nil { order.append(edit.key) }
            grouped[edit.key, default: []].append(edit.asset)
        }
        return order.compactMap { key in
            guard let original = originals[key], let copies = grouped[key] else { return nil }
            return DuplicateGroup(id: "edit-" + original.id, method: "edit", score: 1, items: [original] + copies)
        }
    }
}
