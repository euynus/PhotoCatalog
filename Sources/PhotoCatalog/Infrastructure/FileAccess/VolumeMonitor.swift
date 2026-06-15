// ============================================================
//  VolumeMonitor — detect external volume mount/unmount so assets
//  on offline drives are flagged (PRD §5.3, §6.4 ORG-007).
// ============================================================
import Foundation
import AppKit

// @unchecked Sendable: observer callbacks are delivered onto the main queue and
// hop to MainActor before touching app state.
final class VolumeMonitor: @unchecked Sendable {
    private let onChange: @MainActor @Sendable () -> Void
    private var observers: [NSObjectProtocol] = []

    init(onChange: @escaping @MainActor @Sendable () -> Void) { self.onChange = onChange }

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.onChange() }
            })
        }
    }

    func stop() {
        let nc = NSWorkspace.shared.notificationCenter
        observers.forEach { nc.removeObserver($0) }
        observers.removeAll()
    }

    deinit { stop() }

    /// `/Volumes/Name/...` → `/Volumes/Name` (the mount point); nil for internal paths.
    static func volumeRoot(of path: String) -> String? {
        guard path.hasPrefix("/Volumes/") else { return nil }
        let comps = path.split(separator: "/", omittingEmptySubsequences: true)
        guard comps.count >= 2 else { return nil }
        return "/Volumes/\(comps[1])"
    }

    static func volumeIdentifier(for url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.volumeIdentifierKey]),
              let value = values.allValues[.volumeIdentifierKey] else { return nil }
        let identifier = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
        return identifier.isEmpty ? nil : identifier
    }

    static func mountedVolumeRoot(matching identifier: String) -> URL? {
        mountedVolumeRoots().first { volumeIdentifier(for: $0) == identifier }
    }

    static func pathByReplacingVolumeRoot(in path: String, oldRoot: String, newRoot: String) -> String? {
        let cleanOldRoot = oldRoot.trimmingTrailingSlash()
        let cleanNewRoot = newRoot.trimmingTrailingSlash()
        if path == cleanOldRoot { return cleanNewRoot }
        guard path.hasPrefix(cleanOldRoot + "/") else { return nil }
        return cleanNewRoot + String(path.dropFirst(cleanOldRoot.count))
    }

    static func relocatedURL(for path: String, volumeIdentifier: String?) -> URL? {
        guard let volumeIdentifier,
              !FileManager.default.fileExists(atPath: path),
              let oldRoot = volumeRoot(of: path),
              let newRoot = mountedVolumeRoot(matching: volumeIdentifier),
              let relocated = pathByReplacingVolumeRoot(in: path, oldRoot: oldRoot, newRoot: newRoot.path),
              relocated != path,
              FileManager.default.fileExists(atPath: relocated) else { return nil }
        return URL(fileURLWithPath: relocated)
    }

    /// Classify an inaccessible original: offline (volume unmounted) vs missing (moved/deleted).
    static func status(forInaccessible path: String, volumeIdentifier: String? = nil) -> AssetStatus {
        if let root = volumeRoot(of: path), !FileManager.default.fileExists(atPath: root) {
            if let volumeIdentifier, mountedVolumeRoot(matching: volumeIdentifier) != nil {
                return .missing
            }
            return .offline
        }
        return .missing
    }

    private static func mountedVolumeRoots() -> [URL] {
        let volumes = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        return (try? FileManager.default.contentsOfDirectory(
            at: volumes,
            includingPropertiesForKeys: [.volumeIdentifierKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
    }
}

private extension String {
    func trimmingTrailingSlash() -> String {
        guard count > 1, hasSuffix("/") else { return self }
        return String(dropLast())
    }
}
