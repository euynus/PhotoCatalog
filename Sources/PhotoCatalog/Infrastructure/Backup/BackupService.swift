// ============================================================
//  BackupService — catalog backup & restore (PRD §6.12)
// ============================================================
import Foundation

enum BackupError: Error, Equatable {
    case backupNotFound
    case invalidBackup
}

enum BackupService {
    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// A schema migration's safety backup is stamped in UTC (CatalogStore.filenameStamp).
    private static let migrationStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    @discardableResult
    static func backup(_ store: CatalogStore, at date: Date = Date()) throws -> URL {
        try store.backup(stamp: stampFormatter.string(from: date))
    }

    /// Newest first.
    static func listBackups(_ store: CatalogStore) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: store.backupsURL,
            includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "sqlite" }
            .map { (url: $0, date: date(of: $0)) }
            .sorted {
                if $0.date != $1.date { return ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
                return $0.url.lastPathComponent > $1.url.lastPathComponent
            }
            .map(\.url)
    }

    /// When `backup` was made: the time it's named for, or the file's modification date when its
    /// name carries none. Not the file's date first: a backup copied from the catalog file can keep
    /// the date that file was last written.
    static func date(of backup: URL) -> Date? {
        let name = backup.deletingPathExtension().lastPathComponent
        if name.hasPrefix("catalog-") {
            let stamp = name.dropFirst("catalog-".count)
            // catalog-2026-07-05-121125, then -1, -2… for more in the same second
            if let date = stampFormatter.date(from: String(stamp.prefix(17))) { return date }
            // catalog-pre-migration-v24-20261012T031348Z
            if let last = stamp.split(separator: "-").last,
               let date = migrationStampFormatter.date(from: String(last)) { return date }
        }
        return try? backup.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
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
        defer {
            for path in [temp.path, temp.path + "-wal", temp.path + "-shm"] {
                try? fm.removeItem(atPath: path)
            }
        }
        guard isValidBackupDatabase(temp) else { throw BackupError.invalidBackup }
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

    private static func isValidBackupDatabase(_ url: URL) -> Bool {
        do {
            let db = try Database(path: url.path)
            let rows = try db.query("""
            SELECT name FROM sqlite_master
            WHERE type='table' AND name IN ('assets', 'schema_migrations');
            """)
            return Set(rows.compactMap { $0.text("name") }) == ["assets", "schema_migrations"]
        } catch {
            return false
        }
    }
}
