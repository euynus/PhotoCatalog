// ============================================================
//  CatalogStore — the `.photolibrary` package + SQLite store
//  (PRD §9 file structure, §10 schema, §6.12 backup)
// ============================================================
import Foundation

final class CatalogStore {
    let packageURL: URL
    let db: Database

    var cacheURL: URL { packageURL.appendingPathComponent("Cache") }
    var thumb256URL: URL { cacheURL.appendingPathComponent("Thumbnails/256") }
    var thumb512URL: URL { cacheURL.appendingPathComponent("Thumbnails/512") }
    var preview2048URL: URL { cacheURL.appendingPathComponent("Previews/2048") }
    var backupsURL: URL { packageURL.appendingPathComponent("Backups") }
    var originalsURL: URL { packageURL.appendingPathComponent("Originals") }
    var logsURL: URL { packageURL.appendingPathComponent("Logs") }

    static var defaultURL: URL {
        let pics = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
        return pics.appendingPathComponent("PhotoCatalog Library.photolibrary")
    }

    init(packageURL: URL) throws {
        self.packageURL = packageURL
        let fm = FileManager.default
        try fm.createDirectory(at: packageURL, withIntermediateDirectories: true)
        db = try Database(path: packageURL.appendingPathComponent("catalog.sqlite").path)
        // both stored properties are set now — computed URLs are safe to use
        for dir in [cacheURL, thumb256URL, thumb512URL, preview2048URL,
                    backupsURL, originalsURL, logsURL] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try migrate()
        writeManifestIfNeeded()
    }

    // ---------- schema ----------
    private func migrate() throws {
        db.exec("CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT);")
        let current = db.scalarInt("SELECT COALESCE(MAX(version),0) FROM schema_migrations;")
        if current < 1 {
            try db.transaction {
                db.exec(Self.ddlV1)
                try db.run("INSERT INTO schema_migrations(version, applied_at) VALUES(1, ?);",
                           [.text(ISO8601DateFormatter().string(from: Date()))])
            }
        }
        if current < 2 {
            try db.transaction {
                db.exec("""
                CREATE VIRTUAL TABLE IF NOT EXISTS asset_search USING fts5(
                  asset_id UNINDEXED, filename, title, caption, keywords, camera, lens, tokenize='unicode61');
                """)
                db.exec("""
                INSERT INTO asset_search(asset_id, filename, title, caption, keywords, camera, lens)
                SELECT id, filename, title, caption, keywords, camera, lens FROM assets;
                """)
                try db.run("INSERT INTO schema_migrations(version, applied_at) VALUES(2, ?);",
                           [.text(ISO8601DateFormatter().string(from: Date()))])
            }
        }
    }

    /// FTS5 full-text search returning matching asset ids (§12.7).
    func search(_ query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let match = q.split(separator: " ").map { "\"\($0)\"*" }.joined(separator: " ")
        let rows = (try? db.query("SELECT asset_id FROM asset_search WHERE asset_search MATCH ?;", [.text(match)])) ?? []
        return rows.compactMap { $0.text("asset_id") }
    }

    private static let ddlV1 = """
    CREATE TABLE IF NOT EXISTS assets (
      id TEXT PRIMARY KEY, pid INTEGER, ori TEXT, thumb TEXT, preview TEXT,
      filename TEXT, type TEXT, is_raw INTEGER, folder_id TEXT, folder_name TEXT,
      capture_date REAL, width INTEGER, height INTEGER, orientation INTEGER,
      camera TEXT, lens TEXT, focal INTEGER, aperture REAL, shutter TEXT, iso INTEGER,
      color_space TEXT, file_mb REAL, rating INTEGER, flag TEXT, color_label TEXT,
      keywords TEXT, title TEXT, caption TEXT, location TEXT, gps_lat REAL, gps_lon REAL,
      status TEXT, imported_at REAL, deleted INTEGER, is_demo INTEGER, local_path TEXT,
      capture_date_source TEXT, content_hash TEXT, quick_hash TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_assets_capture ON assets(capture_date);
    CREATE INDEX IF NOT EXISTS idx_assets_hash ON assets(content_hash);
    CREATE INDEX IF NOT EXISTS idx_assets_folder ON assets(folder_id);
    CREATE TABLE IF NOT EXISTS source_roots (
      id TEXT PRIMARY KEY, display_name TEXT, path_hint TEXT, bookmark_data BLOB,
      management_mode TEXT, status TEXT, created_at TEXT
    );
    """

    // ---------- assets ----------
    private static let columns = """
    id,pid,ori,thumb,preview,filename,type,is_raw,folder_id,folder_name,\
    capture_date,width,height,orientation,camera,lens,focal,aperture,shutter,iso,\
    color_space,file_mb,rating,flag,color_label,keywords,title,caption,location,gps_lat,gps_lon,\
    status,imported_at,deleted,is_demo,local_path,capture_date_source,content_hash,quick_hash
    """

    func upsert(_ assets: [Asset]) throws {
        let placeholders = Array(repeating: "?", count: 39).joined(separator: ",")
        let sql = "INSERT OR REPLACE INTO assets(\(Self.columns)) VALUES(\(placeholders));"
        try db.transaction {
            for a in assets {
                try db.run(sql, Self.params(a))
                // keep the FTS index in sync
                try db.run("DELETE FROM asset_search WHERE asset_id=?;", [.text(a.id)])
                try db.run("""
                INSERT INTO asset_search(asset_id, filename, title, caption, keywords, camera, lens)
                VALUES(?,?,?,?,?,?,?);
                """, [.text(a.id), .text(a.filename), .text(a.title), .text(a.caption),
                      .text(Self.keywordsJSON(a.keywords)), .text(a.camera), .text(a.lens)])
            }
        }
    }

    func updateAsset(_ a: Asset) throws { try upsert([a]) }

    func loadAssets() throws -> [Asset] {
        try db.query("SELECT \(Self.columns) FROM assets;").compactMap(Self.asset(from:))
    }

    func assetCount(includeDeleted: Bool = false) -> Int {
        db.scalarInt("SELECT COUNT(*) FROM assets" + (includeDeleted ? ";" : " WHERE deleted=0;"))
    }

    // ---------- source roots ----------
    func addSourceRoot(id: String, displayName: String, path: String, bookmark: Data?) throws {
        try db.run("""
        INSERT OR REPLACE INTO source_roots(id, display_name, path_hint, bookmark_data, management_mode, status, created_at)
        VALUES(?,?,?,?,?,?,?);
        """, [.text(id), .text(displayName), .text(path), .null, .text("referenced"),
              .text("online"), .text(ISO8601DateFormatter().string(from: Date()))])
    }

    // ---------- backup (§6.12) ----------
    @discardableResult
    func backup(stamp: String) throws -> URL {
        // checkpoint WAL so the single .sqlite file is current, then copy it
        db.exec("PRAGMA wal_checkpoint(TRUNCATE);")
        let dest = backupsURL.appendingPathComponent("catalog-\(stamp).sqlite")
        let src = packageURL.appendingPathComponent("catalog.sqlite")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: src, to: dest)
        return dest
    }

    // ---------- manifest.json (§9) ----------
    private func writeManifestIfNeeded() {
        let url = packageURL.appendingPathComponent("manifest.json")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let manifest: [String: Any] = [
            "libraryVersion": 1, "schemaVersion": 1,
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "appBuild": "1.0.0", "uuid": UUID().uuidString,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: manifest, options: .prettyPrinted) {
            try? data.write(to: url)
        }
    }

    // ---------- row <-> Asset ----------
    private static func keywordsJSON(_ kws: [String]) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: kws), encoding: .utf8)) ?? "[]"
    }

    private static func params(_ a: Asset) -> [SQLValue] {
        [
            .text(a.id), .int(a.pid), .text(a.ori), .text(a.thumb), .text(a.preview),
            .text(a.filename), .text(a.type), .int(a.isRaw ? 1 : 0), .text(a.folderId), .text(a.folderName),
            .double(a.date.timeIntervalSince1970), .int(a.width), .int(a.height), .int(a.orientation),
            .text(a.camera), .text(a.lens), .int(a.focal), .double(a.aperture), .text(a.shutter), .int(a.iso),
            .text(a.colorSpace), .double(a.fileMB), .int(a.rating), .text(a.flag.rawValue),
            a.colorLabel.map { SQLValue.text($0.rawValue) } ?? .null,
            .text(keywordsJSON(a.keywords)), .text(a.title), .text(a.caption),
            .text(a.location), .double(a.gps.0), .double(a.gps.1), .text(a.status.rawValue),
            .double(a.importedAt.timeIntervalSince1970), .int(a.deleted ? 1 : 0), .int(a.isDemo ? 1 : 0),
            a.localPath.map { SQLValue.text($0) } ?? .null,
            .text(a.captureDateSource),
            a.contentHash.map { SQLValue.text($0) } ?? .null,
            a.quickHash.map { SQLValue.text($0) } ?? .null,
        ]
    }

    private static func asset(from row: Row) -> Asset? {
        guard let id = row.text("id") else { return nil }
        let kws = ((try? JSONSerialization.jsonObject(with: Data((row.text("keywords") ?? "[]").utf8)))
                   as? [String]) ?? []
        return Asset(
            id: id, pid: row.int("pid") ?? 0, ori: row.text("ori") ?? "l",
            thumb: row.text("thumb") ?? "", preview: row.text("preview") ?? "",
            filename: row.text("filename") ?? "", type: row.text("type") ?? "",
            isRaw: row.bool("is_raw"), folderId: row.text("folder_id") ?? "",
            folderName: row.text("folder_name") ?? "",
            date: Date(timeIntervalSince1970: row.double("capture_date") ?? 0),
            width: row.int("width") ?? 0, height: row.int("height") ?? 0,
            orientation: row.int("orientation") ?? 1,
            camera: row.text("camera") ?? "", lens: row.text("lens") ?? "",
            focal: row.int("focal") ?? 0, aperture: row.double("aperture") ?? 0,
            shutter: row.text("shutter") ?? "", iso: row.int("iso") ?? 0,
            colorSpace: row.text("color_space") ?? "", fileMB: row.double("file_mb") ?? 0,
            rating: row.int("rating") ?? 0,
            flag: Flag(rawValue: row.text("flag") ?? "none") ?? .none,
            colorLabel: row.text("color_label").flatMap { ColorLabel(rawValue: $0) },
            keywords: kws, title: row.text("title") ?? "", caption: row.text("caption") ?? "",
            location: row.text("location") ?? "",
            gps: (row.double("gps_lat") ?? 0, row.double("gps_lon") ?? 0),
            status: AssetStatus(rawValue: row.text("status") ?? "ready") ?? .ready,
            importedAt: Date(timeIntervalSince1970: row.double("imported_at") ?? 0),
            deleted: row.bool("deleted"),
            localPath: row.text("local_path"),
            captureDateSource: row.text("capture_date_source") ?? "EXIF · DateTimeOriginal",
            contentHash: row.text("content_hash"), quickHash: row.text("quick_hash"),
            isDemo: row.bool("is_demo"))
    }
}
