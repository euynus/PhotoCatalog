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
        sourceRootsById: [String: SourceRootRecord]
    ) -> [AssetAvailabilityUpdate]? {
        let identifiers = Set(sourceRootsById.values.compactMap(\.volumeIdentifier))
        let mountedRoots = Dictionary(uniqueKeysWithValues: identifiers.compactMap { identifier in
            VolumeMonitor.mountedVolumeRoot(matching: identifier).map { (identifier, $0) }
        })
        let fileManager = FileManager.default
        var changes: [AssetAvailabilityUpdate] = []

        for asset in assets where !asset.isDemo && !asset.deleted {
            guard !Task.isCancelled else { return nil }
            guard let path = asset.localPath else { continue }

            let resolved = resolve(
                path: path,
                sourceRoot: sourceRootsById[asset.folderId],
                mountedRoots: mountedRoots,
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
        mountedRoots: [String: URL],
        fileManager: FileManager
    ) -> (status: AssetStatus, localPath: String) {
        if fileManager.fileExists(atPath: path) {
            return (.ready, path)
        }

        let identifier = sourceRoot?.volumeIdentifier
        let mountedRoot = identifier.flatMap { mountedRoots[$0] }
        if let oldRoot = VolumeMonitor.volumeRoot(of: path),
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

        if let oldRoot = VolumeMonitor.volumeRoot(of: path),
           !fileManager.fileExists(atPath: oldRoot),
           mountedRoot == nil {
            return (.offline, path)
        }
        return (.missing, path)
    }
}
