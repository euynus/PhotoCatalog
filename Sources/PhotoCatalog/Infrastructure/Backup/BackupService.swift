// ============================================================
//  BackupService — catalog backup & restore (PRD §6.12)
// ============================================================
import Foundation

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
        let live = store.packageURL.appendingPathComponent("catalog.sqlite")
        let fm = FileManager.default
        // drop stale WAL/SHM sidecars so the restored DB is authoritative
        for sidecar in ["catalog.sqlite-wal", "catalog.sqlite-shm"] {
            try? fm.removeItem(at: store.packageURL.appendingPathComponent(sidecar))
        }
        try? fm.removeItem(at: live)
        try fm.copyItem(at: backup, to: live)
    }
}
