// ============================================================
//  CatalogStore — the `.photolibrary` package + SQLite store
//  (PRD §9 file structure, §10 schema, §6.12 backup)
// ============================================================
import Foundation
import os

// @unchecked Sendable: immutable URLs + a serialized Database (see Database).
final class CatalogStore: @unchecked Sendable {
    static let latestSchemaVersion = 25
    let packageURL: URL
    let db: Database

    init(packageURL: URL) throws {
        self.packageURL = packageURL
        let fm = FileManager.default
        try fm.createDirectory(at: packageURL, withIntermediateDirectories: true)
        db = try Database(path: packageURL.appendingPathComponent("catalog.sqlite").path)
        // both stored properties are set now — computed URLs are safe to use
        for dir in [cacheURL, thumb256URL, thumb512URL, preview1600URL, preview2048URL,
                    backupsURL, configURL, originalsURL, logsURL, tempURL] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try migrate()
        writeManifestIfNeeded()
    }

    // ---------- assets ----------
    /// How many photos' rows the search index was written for (for tests).
    var searchIndexWrites = 0

    // ---------- develop settings ----------
    /// How many writes to develop_settings have begun on this catalog, each counted inside its
    /// transaction: develop settings read with the count (`loadDevelopSettingsCounted`) are still
    /// the stored ones as long as it hasn't moved.
    let developSettingsWrites = OSAllocatedUnfairLock(initialState: 0)
}
