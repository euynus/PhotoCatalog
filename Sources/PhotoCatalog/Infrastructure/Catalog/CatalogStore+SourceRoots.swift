import Foundation

extension CatalogStore {
    // ---------- source roots ----------
    /// Adds a source folder, or updates the one with this id as an import of it again: its name,
    /// path, access and volume are the import's, while it keeps its place in the sidebar (when
    /// it was added) and its mode as `managementMode(keeping:importing:)` gives it.
    func addSourceRoot(id: String, displayName: String, path: String, bookmark: Data?,
                       mode: ImportMode = .referenced,
                       volumeIdentifier: String? = nil) throws {
        let kept = Self.managementMode(keeping: try existingManagementMode(id: id), importing: mode)
        try db.run("""
        INSERT INTO source_roots(
          id, display_name, path_hint, bookmark_data, management_mode, status, created_at, volume_identifier)
        VALUES(?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
          display_name=excluded.display_name, path_hint=excluded.path_hint, bookmark_data=excluded.bookmark_data,
          management_mode=excluded.management_mode, status=excluded.status,
          volume_identifier=excluded.volume_identifier;
        """, [.text(id), .text(displayName), .text(path),
              bookmark.map { SQLValue.blob($0) } ?? .null, .text(kept),
              .text("online"), .text(Self.iso(Date())),
              volumeIdentifier.map { SQLValue.text($0) } ?? .null])
    }

    /// The mode a source folder has after an import of it in `mode`. Once it holds photos in
    /// place it stays referenced — watched, and opened through its bookmark — whatever later
    /// imports copy from it; a folder only copied from becomes referenced when photos are added
    /// in place.
    static func managementMode(keeping existing: String?, importing mode: ImportMode) -> String {
        existing == ImportMode.referenced.rawValue ? ImportMode.referenced.rawValue : mode.rawValue
    }

    /// The stored mode of source folder `id` (nil: no such folder), a missing one read as referenced.
    func existingManagementMode(id: String) throws -> String? {
        try db.query("SELECT management_mode FROM source_roots WHERE id=?;", [.text(id)]).first
            .map { $0.text("management_mode") ?? ImportMode.referenced.rawValue }
    }

    /// Drop all stored security-scoped bookmarks, forcing re-authorization (§17.6).
    func clearSourceBookmarks() throws {
        try db.run("UPDATE source_roots SET bookmark_data = NULL, status = 'permissionLost';")
    }

    func loadSourceRoots() throws -> [SourceRootRecord] {
        try db.query("""
        SELECT id, display_name, path_hint, bookmark_data, management_mode, status, volume_identifier
        FROM source_roots
        ORDER BY created_at ASC;
        """).compactMap { row in
            guard let id = row.text("id"),
                  let displayName = row.text("display_name"),
                  let pathHint = row.text("path_hint") else { return nil }
            return SourceRootRecord(
                id: id,
                displayName: displayName,
                pathHint: pathHint,
                bookmarkData: row.blob("bookmark_data"),
                managementMode: row.text("management_mode") ?? "referenced",
                status: row.text("status") ?? "unknown",
                volumeIdentifier: row.text("volume_identifier"))
        }
    }

    func updateSourceRootStatus(id: String, status: String) throws {
        try db.run("UPDATE source_roots SET status=? WHERE id=?;", [.text(status), .text(id)])
    }

    func updateSourceRootAccess(id: String, displayName: String, path: String,
                                bookmark: Data?, status: String = "online",
                                volumeIdentifier: String? = nil) throws {
        try db.run("""
        UPDATE source_roots
        SET display_name=?, path_hint=?, bookmark_data=?, status=?, volume_identifier=?
        WHERE id=?;
        """, [.text(displayName), .text(path), bookmark.map { SQLValue.blob($0) } ?? .null,
              .text(status), volumeIdentifier.map { SQLValue.text($0) } ?? .null, .text(id)])
    }

    func removeSourceRootAndSoftDeleteAssets(id: String) throws {
        try db.transaction {
            try db.run("""
            UPDATE assets
            SET deleted=1
            WHERE folder_id=? AND is_demo=0;
            """, [.text(id)])
            try db.run("DELETE FROM source_roots WHERE id=?;", [.text(id)])
        }
    }
}
