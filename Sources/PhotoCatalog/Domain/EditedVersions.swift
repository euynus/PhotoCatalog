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
    private static let editedNameWord = "编辑"

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
        func split(_ path: String) -> (dir: String, stem: String) {
            let url = URL(fileURLWithPath: path)
            return (url.deletingLastPathComponent().path, url.deletingPathExtension().lastPathComponent)
        }
        var edits: [(asset: Asset, key: String)] = []
        var directories = Set<String>()
        for asset in assets where !asset.deleted && !asset.isVirtualCopy {
            // a cheap test first: only names that could be an edited copy are parsed
            guard asset.filename.contains(editedNameWord) || asset.filename.range(of: "edit", options: .caseInsensitive) != nil,
                  let path = asset.localPath else { continue }
            let (dir, stem) = split(path)
            guard let original = originalStem(of: stem) else { continue }
            edits.append((asset, dir + "/" + original.lowercased()))
            directories.insert(dir)
        }
        guard !edits.isEmpty else { return [] }
        var originals: [String: Asset] = [:]
        for asset in assets where !asset.deleted && !asset.isVirtualCopy {
            guard let path = asset.localPath else { continue }
            let (dir, stem) = split(path)
            guard directories.contains(dir), originalStem(of: stem) == nil else { continue }
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
