// ============================================================
//  VolumeMonitor — detect external volume mount/unmount/rename so
//  assets on offline drives are flagged and followed (PRD §5.3, §6.4 ORG-007).
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
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
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
        VolumeProbe.system.volumeRoot(of: path)
    }

    static func volumeIdentifier(for url: URL) -> String? {
        VolumeProbe.system.identifier(url)
    }

    static func pathByReplacingVolumeRoot(in path: String, oldRoot: String, newRoot: String) -> String? {
        let cleanOldRoot = oldRoot.trimmingTrailingSlash()
        let cleanNewRoot = newRoot.trimmingTrailingSlash()
        if path == cleanOldRoot { return cleanNewRoot }
        guard path.hasPrefix(cleanOldRoot + "/") else { return nil }
        return cleanNewRoot + String(path.dropFirst(cleanOldRoot.count))
    }

    /// Classify an inaccessible original: offline (volume unmounted) vs missing (moved/deleted).
    static func status(forInaccessible path: String, volumeIdentifier: String? = nil) -> AssetStatus {
        VolumeProbe.system.status(forInaccessible: path, volumeIdentifier: volumeIdentifier)
    }
}

/// Where a drive something was recorded on is now.
enum VolumePlacement: Equatable, Sendable {
    /// Not on an external drive, or no drive recorded: the path is all there is to go by.
    case unchecked
    /// The drive is mounted where it was.
    case mounted
    /// The drive is mounted at another mount point (renamed, or back as "Name 1").
    case moved(from: String, to: String)
    /// The drive isn't mounted; whatever is at its mount point is another drive.
    case absent
}

/// What the app asks the file system about drives: where they're mounted and which is which.
/// The system's answers in the app; a test stands folders in for drives.
struct VolumeProbe: Sendable {
    /// The folder drives are mounted in.
    var mountDirectory: String
    /// The stable identifier of the volume holding `url`; nil when it has none.
    var identifier: @Sendable (URL) -> String?

    static let system = VolumeProbe(mountDirectory: "/Volumes") { url in
        // .volumeUUIDStringKey is a stable UUID that survives remount/reboot; .volumeIdentifierKey
        // is an ephemeral per-session token that would break cross-session offline/relocation match.
        guard let values = try? url.resourceValues(forKeys: [.volumeUUIDStringKey]),
              let value = values.allValues[.volumeUUIDStringKey] else { return nil }
        let identifier = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
        return identifier.isEmpty ? nil : identifier
    }

    /// `/Volumes/Name/...` → `/Volumes/Name` (the mount point); nil for internal paths.
    func volumeRoot(of path: String) -> String? {
        let directory = mountDirectory.trimmingTrailingSlash()
        guard path.hasPrefix(directory + "/") else { return nil }
        let name = path.dropFirst(directory.count + 1).split(separator: "/", omittingEmptySubsequences: true).first
        return name.map { "\(directory)/\($0)" }
    }

    func mountedVolumeRoot(matching identifier: String) -> URL? {
        mountedVolumeRoots().first { self.identifier($0) == identifier }
    }

    /// Where the drive that `path` was recorded on (`identifier`) is now. A drive's name isn't
    /// what tells it apart: another drive of the same name mounted where it was isn't it.
    func placement(of path: String, onVolume identifier: String?) -> VolumePlacement {
        guard let identifier, let mountPoint = volumeRoot(of: path) else { return .unchecked }
        if FileManager.default.fileExists(atPath: mountPoint),
           self.identifier(URL(fileURLWithPath: mountPoint, isDirectory: true)) == identifier {
            return .mounted
        }
        if let current = mountedVolumeRoot(matching: identifier), current.path != mountPoint {
            return .moved(from: mountPoint, to: current.path)
        }
        return .absent
    }

    /// `path` on its drive as the drive is now: itself, the same place where the drive is mounted
    /// now, or nil while the drive isn't mounted.
    func currentPath(of path: String, onVolume identifier: String?) -> String? {
        switch placement(of: path, onVolume: identifier) {
        case .unchecked, .mounted: path
        case .moved(let from, let to): VolumeMonitor.pathByReplacingVolumeRoot(in: path, oldRoot: from, newRoot: to)
        case .absent: nil
        }
    }

    /// Classify an inaccessible original: offline (volume unmounted) vs missing (moved/deleted).
    func status(forInaccessible path: String, volumeIdentifier: String? = nil) -> AssetStatus {
        if let root = volumeRoot(of: path), !FileManager.default.fileExists(atPath: root) {
            if let volumeIdentifier, mountedVolumeRoot(matching: volumeIdentifier) != nil {
                return .missing
            }
            return .offline
        }
        return .missing
    }

    private func mountedVolumeRoots() -> [URL] {
        let volumes = URL(fileURLWithPath: mountDirectory, isDirectory: true)
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
