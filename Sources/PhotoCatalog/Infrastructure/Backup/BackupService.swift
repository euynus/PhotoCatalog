// ============================================================
//  BackupService — catalog backup & restore (PRD §6.12)
// ============================================================
import Foundation

enum BackupError: Error {
    case backupNotFound
}

enum BackupService {
    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    @discardableResult
    static func backup(_ store: CatalogStore, at date: Date = Date()) throws -> URL {
        try store.backup(stamp: stampFormatter.string(from: date))
    }

    static func listBackups(_ store: CatalogStore) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: store.backupsURL,
            includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "sqlite" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Replace the live catalog DB with a backup (caller must reopen the store after).
    static func restore(_ backup: URL, into store: CatalogStore) throws {
        try restore(backup, intoPackageAt: store.packageURL)
    }

    /// Replace the live catalog DB with a backup after the current store has been closed.
    static func restore(_ backup: URL, intoPackageAt packageURL: URL) throws {
        let live = packageURL.appendingPathComponent("catalog.sqlite")
        let fm = FileManager.default
        guard fm.fileExists(atPath: backup.path) else { throw BackupError.backupNotFound }
        try fm.createDirectory(at: packageURL, withIntermediateDirectories: true)
        let temp = packageURL.appendingPathComponent("catalog.restore.tmp")
        try? fm.removeItem(at: temp)
        try fm.copyItem(at: backup, to: temp)
        if fm.fileExists(atPath: live.path) {
            _ = try fm.replaceItemAt(live, withItemAt: temp, backupItemName: nil)
        } else {
            try fm.moveItem(at: temp, to: live)
        }
        // drop stale WAL/SHM sidecars only after the live DB replacement succeeds
        for sidecar in ["catalog.sqlite-wal", "catalog.sqlite-shm"] {
            try? fm.removeItem(at: packageURL.appendingPathComponent(sidecar))
        }
    }
}
