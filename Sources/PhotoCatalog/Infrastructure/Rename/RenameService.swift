// ============================================================
//  RenameService — batch rename of originals on disk (PRD §4.2)
//  Returns the new file URL per asset id; caller updates + persists.
// ============================================================
import Foundation

enum RenameService {
    /// The base name (no extension) `template` gives `asset` as number `sequence`. Tokens are
    /// those of `FileNameTemplate`: {original} {seq} {date} {time} {camera} {title} {rating}.
    static func baseName(for asset: Asset, template: String, sequence: Int) -> String {
        let original = ((asset.localPath ?? asset.filename) as NSString).lastPathComponent
        return FileNameTemplate.render(template, original: (original as NSString).deletingPathExtension,
                                       sequence: sequence, date: asset.date, camera: asset.camera,
                                       title: asset.title, rating: asset.rating)
    }

    /// The files in the folders a rename reaches, by stem (the lowercased name without its
    /// extension). A new name is free only when no other file has its stem, whatever the
    /// extension: a RAW renamed beside an unrelated JPEG of that name would pair with it and
    /// take its sidecar.
    struct FolderNames {
        /// folder path → stem → the lowercased names of the files with that stem
        private var stems: [String: [String: Set<String>]] = [:]

        init(folders: Set<String>) {
            for folder in folders {
                var byStem: [String: Set<String>] = [:]
                for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] {
                    byStem[Self.stem(name), default: []].insert(name.lowercased())
                }
                stems[folder] = byStem
            }
        }

        /// The folders `assets`' originals are in.
        init(for assets: [Asset]) {
            self.init(folders: Set(assets.compactMap { $0.localPath.map { ($0 as NSString).deletingLastPathComponent } }))
        }

        static func stem(_ name: String) -> String { (name as NSString).deletingPathExtension.lowercased() }

        /// Whether no file but `own` (names of the files being renamed together) has `stem`.
        func isFree(_ stem: String, in folder: String, own: Set<String>) -> Bool {
            (stems[folder]?[stem.lowercased()] ?? []).isSubset(of: own)
        }

        mutating func moved(_ name: String, to newName: String, in folder: String) {
            stems[folder]?[Self.stem(name)]?.remove(name.lowercased())
            stems[folder, default: [:]][Self.stem(newName), default: []].insert(newName.lowercased())
        }
    }

    /// What renaming would do, without touching the disk: each photo's current and new file
    /// name, numbered from `start`. `clashes` counts new names used more than once in the batch,
    /// and `taken` those already used by another file in the folder (`folders`, when given);
    /// renaming tells them apart with _1, _2….
    static func plan(_ assets: [Asset], template: String, start: Int = 1, folders: FolderNames? = nil)
        -> (names: [(id: String, from: String, to: String)], clashes: Int, taken: Int) {
        var names: [(id: String, from: String, to: String)] = []
        var seen: [String: Int] = [:]
        var taken = 0
        for (offset, asset) in assets.enumerated() {
            let path = asset.localPath ?? asset.filename
            let from = (path as NSString).lastPathComponent
            let ext = (from as NSString).pathExtension
            let base = baseName(for: asset, template: template, sequence: start + offset)
            let to = ext.isEmpty ? base : "\(base).\(ext)"
            names.append((asset.id, from, to))
            seen[to.lowercased(), default: 0] += 1
            if let folders, FolderNames.stem(to) != FolderNames.stem(from),
               !folders.isFree(FolderNames.stem(to), in: (path as NSString).deletingLastPathComponent, own: []) {
                taken += 1
            }
        }
        return (names, seen.values.filter { $0 > 1 }.reduce(0) { $0 + $1 - 1 }, taken)
    }

    /// Rename each asset's original from a token template (§4.2), numbering from `start`; the
    /// extension is preserved. `companions` (keyed by asset id) move to the same new base
    /// name — a RAW's paired JPEG stays paired — and the sidecar goes along. A name is only
    /// taken when no other file in the folder has it, whatever the extension.
    static func renameWithTemplate(_ assets: [Asset], template: String, start: Int = 1,
                                   companions: [String: [Asset]] = [:]) -> [String: URL] {
        let fm = FileManager.default
        var folders = FolderNames(for: assets)
        var result: [String: URL] = [:]
        var seq = start
        for a in assets {
            guard let path = a.localPath else { continue }
            let src = URL(fileURLWithPath: path)
            guard fm.fileExists(atPath: src.path) else { continue }
            let ext = src.pathExtension
            let dir = src.deletingLastPathComponent()
            let base = baseName(for: a, template: template, sequence: seq)
            let partners = (companions[a.id] ?? []).compactMap { partner in
                partner.localPath.map { (id: partner.id, src: URL(fileURLWithPath: $0)) }
            }
            let sidecar = XMPSidecar.sidecarURL(for: src)
            let group = [src] + partners.map(\.src) + (fm.fileExists(atPath: sidecar.path) ? [sidecar] : [])
            let own = Set(group.map { $0.lastPathComponent.lowercased() })
            func candidate(_ suffix: String, ext: String = ext) -> URL {
                dir.appendingPathComponent(ext.isEmpty ? base + suffix : "\(base)\(suffix).\(ext)")
            }
            func isFree(_ suffix: String) -> Bool {
                // keeping its own name is always possible
                candidate(suffix).path == src.path || folders.isFree(base + suffix, in: dir.path, own: own)
            }
            var suffix = ""
            var k = 1
            while !isFree(suffix) { suffix = "_\(k)"; k += 1 }
            let dest = candidate(suffix)
            if dest.path != src.path {
                do { try fm.moveItem(at: src, to: dest) } catch { continue }
                folders.moved(src.lastPathComponent, to: dest.lastPathComponent, in: dir.path)
                if XMPSidecar.moveSidecar(from: src, to: dest), group.contains(sidecar) {
                    folders.moved(sidecar.lastPathComponent, to: XMPSidecar.sidecarURL(for: dest).lastPathComponent,
                                  in: dir.path)
                }
            }
            result[a.id] = dest
            seq += 1
            for partner in partners {
                let target = candidate(suffix, ext: partner.src.pathExtension)
                if target.path == partner.src.path { result[partner.id] = target; continue }
                if (try? fm.moveItem(at: partner.src, to: target)) != nil {
                    folders.moved(partner.src.lastPathComponent, to: target.lastPathComponent, in: dir.path)
                    result[partner.id] = target
                }
            }
        }
        return result
    }

}
