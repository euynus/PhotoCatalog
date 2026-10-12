// ============================================================
//  OriginalFileOperationService — app-initiated copy/move of
//  selected original files.
// ============================================================
import Foundation

enum OriginalFileOperation: Equatable, Sendable {
    case copy
    case move
}

enum OriginalFileOperationError: Error {
    case missingPath
    case missingFile
}

struct OriginalFileOperationReport: Sendable {
    var copied = 0
    var moved = 0
    var skipped = 0
    var failed = 0
    var updatedLocations: [String: URL] = [:]
}

struct OriginalTrashLocation: Sendable {
    let original: URL
    let trashed: URL
}

struct OriginalTrashReport: Sendable {
    var trashedIds: Set<String> = []
    var locations: [String: OriginalTrashLocation] = [:]
    var failed = 0
}

enum OriginalFileOperationService {
    /// Copies or moves the originals into `destination`. The files sharing a folder and a name
    /// (a RAW and its JPEG) go together: they take one name there — their own, or a numbered one
    /// when another file there has it in any extension — and their sidecars go along. A group
    /// moves whole or not at all, so a pair never ends up split, or beside another photo's sidecar.
    static func perform(_ operation: OriginalFileOperation, assets: [Asset],
                        destination: URL) -> OriginalFileOperationReport {
        var report = OriginalFileOperationReport()
        let fm = FileManager.default
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)

        var order: [String] = []
        var groups: [String: [(asset: Asset, source: URL)]] = [:]
        for asset in assets {
            guard let path = asset.localPath else { report.skipped += 1; continue }
            let source = URL(fileURLWithPath: path)
            guard fm.fileExists(atPath: source.path) else { report.failed += 1; continue }
            if operation == .move && destination.standardizedFileURL == source.deletingLastPathComponent().standardizedFileURL {
                report.skipped += 1
                continue
            }
            let key = source.deletingLastPathComponent().path + "\n" + source.deletingPathExtension().lastPathComponent.lowercased()
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append((asset, source))
        }

        var names = RenameService.FolderNames(folders: [destination.path])
        for key in order {
            let members = groups[key] ?? []
            guard let number = freeNumber(for: members.map(\.source), in: destination.path, names: names) else {
                report.skipped += members.count
                continue
            }
            // each sidecar as it's named beside the whole group, before any of it leaves
            let sidecars = members.map { XMPSidecar.sidecarURL(for: $0.source) }
            var done: [(asset: Asset, source: URL, target: URL, sidecar: URL)] = []
            var failed = false
            for (member, sidecar) in zip(members, sidecars) {
                let target = destination.appendingPathComponent(targetName(member.source, number: number,
                                                                           base: members[0].source))
                do {
                    switch operation {
                    case .copy:
                        try fm.copyItem(at: member.source, to: target)
                        preserveModificationDate(from: member.source, to: target, fm: fm)
                    case .move:
                        try fm.moveItem(at: member.source, to: target)
                    }
                    done.append((member.asset, member.source, target, sidecar))
                } catch {
                    failed = true
                    if operation == .move { break }
                    report.failed += 1
                }
            }
            // then the sidecars, named as they are beside the whole group at its new place (the
            // name is free there, so none is another photo's); a pair's one goes once
            var movedSidecars: [(from: URL, to: URL)] = []
            var handled = Set<String>()
            for item in done where handled.insert(item.sidecar.path).inserted && fm.fileExists(atPath: item.sidecar.path) {
                let target = XMPSidecar.sidecarURL(for: item.target)
                if operation == .copy {
                    if !fm.fileExists(atPath: target.path) { try? fm.copyItem(at: item.sidecar, to: target) }
                } else if XMPSidecar.moveSidecar(at: item.sidecar, to: target) {
                    movedSidecars.append((item.sidecar, target))
                } else {
                    // the sidecar goes along, or the photo's metadata would stay behind for other apps
                    failed = true
                    break
                }
            }
            if operation == .move && failed {
                // not all of it could go: what went comes back, so the group stays whole
                for sidecar in movedSidecars.reversed() { try? fm.moveItem(at: sidecar.to, to: sidecar.from) }
                for item in done.reversed() { try? fm.moveItem(at: item.target, to: item.source) }
                report.failed += members.count
                continue
            }
            for item in done {
                names.added(item.target.lastPathComponent, in: destination.path)
                switch operation {
                case .copy: report.copied += 1
                case .move:
                    report.updatedLocations[item.asset.id] = item.target
                    report.moved += 1
                }
            }
        }
        return report
    }

    static func rollBackMoves(_ movedLocations: [String: URL], originals: [Asset]) -> Int {
        let fm = FileManager.default
        let originalsById = Dictionary(uniqueKeysWithValues: originals.compactMap { asset -> (String, URL)? in
            guard let path = asset.localPath else { return nil }
            return (asset.id, URL(fileURLWithPath: path))
        })
        // each sidecar as it's named beside all the moved files, before any goes back
        let sidecars = movedLocations.mapValues { XMPSidecar.sidecarURL(for: $0) }
        var rolledBack = 0
        var back: [(original: URL, sidecar: URL)] = []
        for (id, moved) in movedLocations {
            guard let original = originalsById[id],
                  fm.fileExists(atPath: moved.path),
                  !fm.fileExists(atPath: original.path) else { continue }
            do {
                try fm.moveItem(at: moved, to: original)
                rolledBack += 1
                if let sidecar = sidecars[id] { back.append((original, sidecar)) }
            } catch {}
        }
        // then the sidecars, named as they are beside the files back in place
        for item in back { XMPSidecar.moveSidecar(at: item.sidecar, to: XMPSidecar.sidecarURL(for: item.original)) }
        return rolledBack
    }

    static func trashOriginals(_ assets: [Asset]) -> OriginalTrashReport {
        var report = OriginalTrashReport()
        for asset in assets {
            do {
                let location = try trashOriginal(asset)
                report.trashedIds.insert(asset.id)
                report.locations[asset.id] = location
            } catch {
                report.failed += 1
            }
        }
        return report
    }

    static func trashOriginal(_ asset: Asset) throws -> OriginalTrashLocation {
        guard let path = asset.localPath else { throw OriginalFileOperationError.missingPath }
        let original = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: original.path) else {
            throw OriginalFileOperationError.missingFile
        }
        var trashedURL: NSURL?
        try FileManager.default.trashItem(at: original, resultingItemURL: &trashedURL)
        return OriginalTrashLocation(original: original, trashed: (trashedURL as URL?) ?? original)
    }

    static func rollBackTrash(_ locations: [String: OriginalTrashLocation]) -> Int {
        let fm = FileManager.default
        var rolledBack = 0
        for location in locations.values {
            guard fm.fileExists(atPath: location.trashed.path),
                  !fm.fileExists(atPath: location.original.path) else { continue }
            do {
                try fm.moveItem(at: location.trashed, to: location.original)
                rolledBack += 1
            } catch {}
        }
        return rolledBack
    }

    /// The number a group of files sharing a name takes in `folder`: 0 for their own name, else
    /// the first `name (n)` that no file there has yet in any extension, their sidecars' names
    /// (`name.xmp`, `name.JPG.xmp`) included; nil when none is free.
    private static func freeNumber(for sources: [URL], in folder: String, names: RenameService.FolderNames) -> Int? {
        let base = sources[0].deletingPathExtension().lastPathComponent
        for number in 0..<10_000 {
            let stem = number == 0 ? base : "\(base) (\(number))"
            let free = names.isFree(stem, in: folder, own: []) && sources.allSatisfy { source in
                source.pathExtension.isEmpty || names.isFree(stem + "." + source.pathExtension, in: folder, own: [])
            }
            if free { return number }
        }
        return nil
    }

    /// `source`'s name in the group's new place: its own, or the group's (`base`'s) numbered.
    private static func targetName(_ source: URL, number: Int, base: URL) -> String {
        guard number > 0 else { return source.lastPathComponent }
        let stem = "\(base.deletingPathExtension().lastPathComponent) (\(number))"
        return source.pathExtension.isEmpty ? stem : "\(stem).\(source.pathExtension)"
    }

    private static func preserveModificationDate(from source: URL, to target: URL, fm: FileManager) {
        guard let attrs = try? fm.attributesOfItem(atPath: source.path),
              let mtime = attrs[.modificationDate] as? Date else { return }
        try? fm.setAttributes([.modificationDate: mtime], ofItemAtPath: target.path)
    }
}
