import Foundation

struct AssetAvailabilityUpdate: Equatable, Sendable {
    let assetId: String
    let status: AssetStatus
    let localPath: String?
}

enum AssetAvailabilityService {
    /// Resolves original-file availability without touching UI state. Returning
    /// nil means the caller cancelled the scan before it completed.
    static func changes(
        in assets: [Asset],
        sourceRootsById: [String: SourceRootRecord],
        probe: VolumeProbe = .system
    ) -> [AssetAvailabilityUpdate]? {
        let identifiers = Set(sourceRootsById.values.compactMap(\.volumeIdentifier))
        let mountedRoots = Dictionary(uniqueKeysWithValues: identifiers.compactMap { identifier in
            probe.mountedVolumeRoot(matching: identifier).map { (identifier, $0) }
        })
        // where each source folder's drive is now, asked once per folder (a managed folder's
        // recorded drive is the card it was copied from, not where its photos are)
        let placements = sourceRootsById.mapValues { root in
            root.managementMode == ImportMode.managed.rawValue
                ? .unchecked : probe.placement(of: root.pathHint, onVolume: root.volumeIdentifier)
        }
        let fileManager = FileManager.default
        var changes: [AssetAvailabilityUpdate] = []

        for asset in assets where !asset.isDemo && !asset.deleted {
            guard !Task.isCancelled else { return nil }
            guard let path = asset.localPath else { continue }

            let resolved = resolve(
                path: path,
                sourceRoot: sourceRootsById[asset.folderId],
                placement: placements[asset.folderId] ?? .unchecked,
                mountedRoots: mountedRoots,
                probe: probe,
                fileManager: fileManager
            )
            if resolved.status != asset.status || resolved.localPath != asset.localPath {
                changes.append(AssetAvailabilityUpdate(
                    assetId: asset.id,
                    status: resolved.status,
                    localPath: resolved.localPath
                ))
            }
        }
        return changes
    }

    private static func resolve(
        path: String,
        sourceRoot: SourceRootRecord?,
        placement: VolumePlacement,
        mountedRoots: [String: URL],
        probe: VolumeProbe,
        fileManager: FileManager
    ) -> (status: AssetStatus, localPath: String) {
        // the source folder's drive decides for its photos on that drive: not mounted, they're
        // offline, even with another drive of its name holding a file at the same path; mounted
        // under another name, they're there
        if let mountPoint = probe.volumeRoot(of: path),
           let sourceRoot, probe.volumeRoot(of: sourceRoot.pathHint) == mountPoint {
            switch placement {
            case .absent:
                return (.offline, path)
            case .moved(let from, let to):
                if let relocated = VolumeMonitor.pathByReplacingVolumeRoot(in: path, oldRoot: from, newRoot: to),
                   fileManager.fileExists(atPath: relocated) {
                    return (.ready, relocated)
                }
                return (.missing, path)
            case .mounted, .unchecked:
                break
            }
        }

        if fileManager.fileExists(atPath: path) {
            return (.ready, path)
        }

        let identifier = sourceRoot?.volumeIdentifier
        let mountedRoot = identifier.flatMap { mountedRoots[$0] }
        if let oldRoot = probe.volumeRoot(of: path),
           let mountedRoot,
           let relocated = VolumeMonitor.pathByReplacingVolumeRoot(
               in: path,
               oldRoot: oldRoot,
               newRoot: mountedRoot.path
           ),
           relocated != path,
           fileManager.fileExists(atPath: relocated) {
            return (.ready, relocated)
        }

        if let oldRoot = probe.volumeRoot(of: path),
           !fileManager.fileExists(atPath: oldRoot),
           mountedRoot == nil {
            return (.offline, path)
        }
        return (.missing, path)
    }
}
