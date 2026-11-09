import Foundation

extension CatalogStore {
    // ---------- albums (§6.8 / §10.2) ----------
    /// Develop settings, albums, smart albums, album sets and sidecar sync times, as a catalog
    /// opens: a table that can't be read fails the open rather than showing as empty.
    func loadCatalogCollections() throws -> CatalogCollections {
        CatalogCollections(developSettings: try loadDevelopSettings(), albums: try loadAlbums(),
                           smartAlbums: try loadSmartAlbums(), albumSets: try loadAlbumSets(),
                           xmpSyncTimes: try loadXMPSyncTimes())
    }

    func loadAlbums() throws -> [Album] {
        let rows = try db.query("""
        SELECT id, name, parent_id
        FROM albums
        WHERE type='album'
        ORDER BY sort_order ASC, created_at ASC;
        """)
        return try rows.compactMap { row in
            guard let id = row.text("id"), let name = row.text("name") else { return nil }
            let assetIds = try db.query("""
            SELECT asset_id FROM album_assets
            WHERE album_id=?
            ORDER BY position ASC, added_at ASC;
            """, [.text(id)]).compactMap { $0.text("asset_id") }
            return Album(id: id, name: name, assetIds: assetIds, setId: row.text("parent_id"))
        }
    }

    /// Saves an album, filed in its set when it's new; one already saved stays where it is
    /// (setAlbumParent moves it), so a caller that doesn't know the set can't take it out.
    func saveAlbum(_ album: Album, sortOrder: Int = 0, updatedAt: Date = .now) throws {
        let now = Self.iso(updatedAt)
        try db.transaction {
            try upsertAlbumRow(id: album.id, setId: album.setId, type: "album", name: album.name,
                               sortOrder: sortOrder, now: now)
            try db.run("DELETE FROM album_assets WHERE album_id=?;", [.text(album.id)])
            // a photo the catalog has no row for (a demo photo, never saved) is left out, rather
            // than failing the foreign key and the save of the album's other photos with it
            for (index, assetId) in album.assetIds.enumerated() {
                try db.run("""
                INSERT INTO album_assets(album_id, asset_id, position, added_at)
                SELECT ?, id, ?, ? FROM assets WHERE id=?;
                """, [.text(album.id), .int(index), .text(now), .text(assetId)])
            }
        }
    }

    /// Adds and removes these photos in an album, leaving its other members' rows as they are:
    /// for the quick collection, a set, which saving whole renumbered on every change.
    func updateAlbumMembers(albumId: String, name: String, sortOrder: Int, adding: Set<String>,
                            removing: Set<String>, updatedAt: Date = .now) throws {
        let now = Self.iso(updatedAt)
        try db.transaction {
            // the album's row first: its members' foreign key needs it
            try upsertAlbumRow(id: albumId, setId: nil, type: "album", name: name, sortOrder: sortOrder, now: now)
            if !removing.isEmpty {
                let ids = String(decoding: try JSONSerialization.data(withJSONObject: removing.sorted()), as: UTF8.self)
                try db.run("DELETE FROM album_assets WHERE album_id=? AND asset_id IN (SELECT value FROM json_each(?));",
                           [.text(albumId), .text(ids)])
            }
            guard !adding.isEmpty else { return }
            let position = try db.query("SELECT COALESCE(MAX(position),-1)+1 AS n FROM album_assets WHERE album_id=?;",
                                        [.text(albumId)]).first?.int("n") ?? 0
            // a photo the catalog has no row for (a demo photo) is left out, as saveAlbum does
            for (offset, assetId) in adding.sorted().enumerated() {
                try db.run("""
                INSERT OR IGNORE INTO album_assets(album_id, asset_id, position, added_at)
                SELECT ?, id, ?, ? FROM assets WHERE id=?;
                """, [.text(albumId), .int(position + offset), .text(now), .text(assetId)])
            }
        }
    }

    func renameAlbum(id: String, name: String, updatedAt: Date = .now) throws {
        try db.run("""
        UPDATE albums
        SET name=?, updated_at=?
        WHERE id=? AND type='album';
        """, [.text(name), .text(Self.iso(updatedAt)), .text(id)])
    }

    func deleteAlbum(id: String) throws {
        try db.run("DELETE FROM albums WHERE id=? AND type='album';", [.text(id)])
    }

    func loadSmartAlbums() throws -> [SmartAlbum] {
        let decoder = JSONDecoder()
        return try db.query("""
        SELECT albums.id, albums.name, albums.parent_id, smart_album_rules.rule_json
        FROM albums
        JOIN smart_album_rules ON smart_album_rules.album_id = albums.id
        WHERE albums.type='smart'
        ORDER BY albums.sort_order ASC, albums.created_at ASC;
        """).compactMap { row in
            guard let id = row.text("id"),
                  let name = row.text("name"),
                  let json = row.text("rule_json"),
                  let data = json.data(using: .utf8),
                  let rule = try? decoder.decode(SmartRule.self, from: data) else { return nil }
            return SmartAlbum(id: id, name: name, rule: rule, count: 0, setId: row.text("parent_id"))
        }
    }

    /// An album's row (`type` "album" or "smart"), filed under `setId` when it's new; one
    /// already saved keeps its set and creation date.
    private func upsertAlbumRow(id: String, setId: String?, type: String, name: String, sortOrder: Int,
                                now: String) throws {
        try db.run("""
        INSERT INTO albums(id, parent_id, type, name, sort_order, created_at, updated_at)
        VALUES(?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
          name=excluded.name,
          sort_order=excluded.sort_order,
          updated_at=excluded.updated_at;
        """, [.text(id), setId.map(SQLValue.text) ?? .null, .text(type), .text(name),
              .int(sortOrder), .text(now), .text(now)])
    }

    /// Saves a smart album, filed in its set when it's new, as saveAlbum does.
    func saveSmartAlbum(_ album: SmartAlbum, sortOrder: Int = 0, updatedAt: Date = .now) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(album.rule)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        let now = Self.iso(updatedAt)
        try db.transaction {
            try upsertAlbumRow(id: album.id, setId: album.setId, type: "smart", name: album.name,
                               sortOrder: sortOrder, now: now)
            try db.run("""
            INSERT INTO smart_album_rules(album_id, rule_json, updated_at)
            VALUES(?,?,?)
            ON CONFLICT(album_id) DO UPDATE SET
              rule_json=excluded.rule_json,
              updated_at=excluded.updated_at;
            """, [.text(album.id), .text(json), .text(now)])
        }
    }

    func deleteSmartAlbum(id: String) throws {
        try db.run("DELETE FROM albums WHERE id=? AND type='smart';", [.text(id)])
    }

    // album sets: rows of type 'set'; albums, smart albums and sets point at theirs by parent_id
    func loadAlbumSets() throws -> [AlbumSet] {
        try db.query("""
        SELECT id, name, parent_id FROM albums WHERE type='set' ORDER BY sort_order ASC, created_at ASC;
        """).compactMap { row in
            guard let id = row.text("id"), let name = row.text("name") else { return nil }
            return AlbumSet(id: id, name: name, parentId: row.text("parent_id"))
        }
    }

    func saveAlbumSet(_ set: AlbumSet, sortOrder: Int = 0, updatedAt: Date = .now) throws {
        let now = Self.iso(updatedAt)
        try db.run("""
        INSERT INTO albums(id, parent_id, type, name, sort_order, created_at, updated_at)
        VALUES(?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET name=excluded.name, sort_order=excluded.sort_order,
          updated_at=excluded.updated_at;
        """, [.text(set.id), set.parentId.map { .text($0) } ?? .null, .text("set"), .text(set.name),
              .int(sortOrder), .text(now), .text(now)])
    }

    /// Files an album, smart album or set into `parentId` (nil: the top level).
    func setAlbumParent(id: String, parentId: String?, updatedAt: Date = .now) throws {
        try db.run("UPDATE albums SET parent_id=?, updated_at=? WHERE id=?;",
                   [parentId.map { .text($0) } ?? .null, .text(Self.iso(updatedAt)), .text(id)])
    }

    /// Deletes a set; what it held moves up to the set's own parent (the parent link would
    /// otherwise cascade and delete it).
    func deleteAlbumSet(id: String) throws {
        try db.transaction {
            let parent = try db.queryMap("SELECT parent_id FROM albums WHERE id=?;", [.text(id)],
                                         transform: { $0.text("parent_id") }).first ?? nil
            try db.run("UPDATE albums SET parent_id=? WHERE parent_id=?;", [parent.map { .text($0) } ?? .null, .text(id)])
            try db.run("DELETE FROM albums WHERE id=? AND type='set';", [.text(id)])
        }
    }
}
