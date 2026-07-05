// ============================================================
//  OriginalFileOperationService — app-initiated copy/move of
//  selected original files.
// ============================================================
import Foundation

enum OriginalFileOperation: Equatable, Sendable {
    case copy
    case move
}

struct OriginalFileOperationReport: Sendable {
    var copied = 0
    var moved = 0
    var skipped = 0
    var failed = 0
    var updatedLocations: [String: URL] = [:]
}

enum OriginalFileOperationService {
    static func perform(_ operation: OriginalFileOperation, assets: [Asset],
                        destination: URL) -> OriginalFileOperationReport {
        var report = OriginalFileOperationReport()
        let fm = FileManager.default
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)

        for asset in assets {
            guard let path = asset.localPath else { report.skipped += 1; continue }
            let source = URL(fileURLWithPath: path)
            guard fm.fileExists(atPath: source.path) else { report.failed += 1; continue }
            if operation == .move && destination.standardizedFileURL == source.deletingLastPathComponent().standardizedFileURL {
                report.skipped += 1
                continue
            }
            guard let target = resolvedTarget(for: source, in: destination, fm: fm) else {
                report.skipped += 1
                continue
            }

            do {
                switch operation {
                case .copy:
                    try fm.copyItem(at: source, to: target)
                    preserveModificationDate(from: source, to: target, fm: fm)
                    report.copied += 1
                case .move:
                    try fm.moveItem(at: source, to: target)
                    report.updatedLocations[asset.id] = target
                    report.moved += 1
                }
            } catch {
                report.failed += 1
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
        var rolledBack = 0
        for (id, moved) in movedLocations {
            guard let original = originalsById[id],
                  fm.fileExists(atPath: moved.path),
                  !fm.fileExists(atPath: original.path) else { continue }
            do {
                try fm.moveItem(at: moved, to: original)
                rolledBack += 1
            } catch {}
        }
        return rolledBack
    }

    private static func resolvedTarget(for source: URL, in destination: URL, fm: FileManager) -> URL? {
        let initial = destination.appendingPathComponent(source.lastPathComponent)
        guard fm.fileExists(atPath: initial.path) else { return initial }

        let base = initial.deletingPathExtension().lastPathComponent
        let ext = initial.pathExtension
        var index = 1
        while index < 10_000 {
            let filename = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            let candidate = destination.appendingPathComponent(filename)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
        return nil
    }

    private static func preserveModificationDate(from source: URL, to target: URL, fm: FileManager) {
        guard let attrs = try? fm.attributesOfItem(atPath: source.path),
              let mtime = attrs[.modificationDate] as? Date else { return }
        try? fm.setAttributes([.modificationDate: mtime], ofItemAtPath: target.path)
    }
}
