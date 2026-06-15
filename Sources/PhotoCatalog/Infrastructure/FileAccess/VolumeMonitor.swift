// ============================================================
//  VolumeMonitor — detect external volume mount/unmount so assets
//  on offline drives are flagged (PRD §5.3, §6.4 ORG-007).
// ============================================================
import Foundation
import AppKit

final class VolumeMonitor {
    private let onChange: () -> Void
    private var observers: [NSObjectProtocol] = []

    init(onChange: @escaping () -> Void) { self.onChange = onChange }

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.onChange()
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

    /// Classify an inaccessible original: offline (volume unmounted) vs missing (moved/deleted).
    static func status(forInaccessible path: String) -> AssetStatus {
        if let root = volumeRoot(of: path), !FileManager.default.fileExists(atPath: root) {
            return .offline
        }
        return .missing
    }
}
