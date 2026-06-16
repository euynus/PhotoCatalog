// ============================================================
//  CatalogStore — the `.photolibrary` package + SQLite store
//  (PRD §9 file structure, §10 schema, §6.12 backup)
// ============================================================
import Foundation

struct SourceRootRecord: Identifiable {
    let id: String
    let displayName: String
    let pathHint: String
    let bookmarkData: Data?
    let managementMode: String
    let status: String
    let volumeIdentifier: String?
}

struct ImportSessionRecord: Identifiable, Equatable, Sendable {
    let id: String
    let rootId: String?
    let state: String
    let totalCount: Int
    let importedCount: Int
    let skippedCount: Int
    let failedCount: Int
    let startedAt: Date
    let finishedAt: Date?
    let errorMessage: String?
}

struct JobRecord: Identifiable, Equatable, Sendable {
    let id: String
    let type: String
    let priority: Int
    let state: String
    let payloadJSON: String
    let attempts: Int
    let maxAttempts: Int
    let lockedAt: Date?
    let lastError: String?
    let createdAt: Date
    let updatedAt: Date
}

struct ImportJobPayload: Codable, Equatable, Sendable {
    let kind: String
    let sessionId: String
    let sourcePath: String
    let mode: String
    let autoTag: Bool

    init(kind: String = "importFolder", sessionId: String, sourcePath: String,
         mode: String, autoTag: Bool) {
        self.kind = kind
        self.sessionId = sessionId
        self.sourcePath = sourcePath
        self.mode = mode
        self.autoTag = autoTag
    }
}

enum CatalogStoreError: Error, Equatable {
    case incompatibleSchema(current: Int, supported: Int)
}

// @unchecked Sendable: immutable URLs + a serialized Database (see Database).
final class CatalogStore: @unchecked Sendable {
    private static let latestSchemaVersion = 13
    let packageURL: URL
    let db: Database

    var cacheURL: URL { packageURL.appendingPathComponent("Cache") }
    var thumb256URL: URL { cacheURL.appendingPathComponent("Thumbnails/256") }
    var thumb512URL: URL { cacheURL.appendingPathComponent("Thumbnails/512") }
    var preview1600URL: URL { cacheURL.appendingPathComponent("Previews/1600") }
    var preview2048URL: URL { cacheURL.appendingPathComponent("Previews/2048") }
    var backupsURL: URL { packageURL.appendingPathComponent("Backups") }
    var configURL: URL { packageURL.appendingPathComponent("Config") }
    var originalsURL: URL { packageURL.appendingPathComponent("Originals") }
    var logsURL: URL { packageURL.appendingPathComponent("Logs") }
    var tempURL: URL { packageURL.appendingPathComponent("Temp") }

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
        for dir in [cacheURL, thumb256URL, thumb512URL, preview1600URL, preview2048URL,
                    backupsURL, configURL, originalsURL, logsURL, tempURL] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try migrate()
        writeManifestIfNeeded()
    }

    // ---------- schema ----------
    private func migrate() throws {
        try db.execChecked("CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT);")
        let current = db.scalarInt("SELECT COALESCE(MAX(version),0) FROM schema_migrations;")
        if current > Self.latestSchemaVersion {
            throw CatalogStoreError.incompatibleSchema(current: current, supported: Self.latestSchemaVersion)
        }
        if current > 0 && current < Self.latestSchemaVersion {
            try backup(stamp: "pre-migration-v\(current)-\(Self.filenameStamp(.now))")
        }
        guard current < Self.latestSchemaVersion else { return }
        try db.transaction {
            try applyMigrations(from: current)
        }
    }

    private func applyMigrations(from current: Int) throws {
        if current < 1 {
            try db.execChecked(Self.ddlV1)
            try recordMigration(1)
        }
        if current < 2 {
            try db.execChecked("""
            CREATE VIRTUAL TABLE IF NOT EXISTS asset_search USING fts5(
              asset_id UNINDEXED, filename, title, caption, keywords, camera, lens, tokenize='unicode61');
            """)
            try db.execChecked("""
            INSERT INTO asset_search(asset_id, filename, title, caption, keywords, camera, lens)
            SELECT id, filename, title, caption, keywords, camera, lens FROM assets;
            """)
            try recordMigration(2)
        }
        if current < 3 {
            try db.execChecked("ALTER TABLE assets ADD COLUMN faces INTEGER DEFAULT 0;")
            try recordMigration(3)
        }
        if current < 4 {
            try db.execChecked(Self.importSessionsDDL)
            try recordMigration(4)
        }
        if current < 5 {
            try db.execChecked(Self.jobsDDL)
            try recordMigration(5)
        }
        if current < 6 {
            try db.execChecked(Self.albumsDDL)
            try recordMigration(6)
        }
        if current < 7 {
            try db.run("ALTER TABLE source_roots ADD COLUMN volume_identifier TEXT;")
            try recordMigration(7)
        }
        if current < 8 {
            try db.run("ALTER TABLE assets ADD COLUMN file_modified_at REAL;")
            try db.run("ALTER TABLE assets ADD COLUMN file_created_at REAL;")
            try recordMigration(8)
        }
        if current < 9 {
            try db.run("ALTER TABLE assets ADD COLUMN has_icc_profile INTEGER DEFAULT 0;")
            try recordMigration(9)
        }
        if current < 10 {
            try db.run("ALTER TABLE assets ADD COLUMN gps_altitude REAL;")
            try recordMigration(10)
        }
        if current < 11 {
            try db.run("ALTER TABLE assets ADD COLUMN author TEXT DEFAULT '';")
            try db.run("ALTER TABLE assets ADD COLUMN copyright TEXT DEFAULT '';")
            try recordMigration(11)
        }
        if current < 12 {
            try db.run("ALTER TABLE assets ADD COLUMN maker_notes TEXT DEFAULT '';")
            try recordMigration(12)
        }
        if current < 13 {
            try db.run("ALTER TABLE assets ADD COLUMN project TEXT DEFAULT '';")
            try db.run("ALTER TABLE assets ADD COLUMN client TEXT DEFAULT '';")
            try recordMigration(13)
        }
    }

    private func recordMigration(_ version: Int) throws {
        try db.run("INSERT INTO schema_migrations(version, applied_at) VALUES(?, ?);",
                   [.int(version), .text(Self.iso(.now))])
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
      keywords TEXT, title TEXT, caption TEXT,
      location TEXT, gps_lat REAL, gps_lon REAL,
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

    private static let importSessionsDDL = """
    CREATE TABLE IF NOT EXISTS import_sessions (
      id TEXT PRIMARY KEY,
      root_id TEXT,
      state TEXT NOT NULL,
      total_count INTEGER NOT NULL DEFAULT 0,
      imported_count INTEGER NOT NULL DEFAULT 0,
      skipped_count INTEGER NOT NULL DEFAULT 0,
      failed_count INTEGER NOT NULL DEFAULT 0,
      started_at TEXT NOT NULL,
      finished_at TEXT,
      error_message TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_import_sessions_state ON import_sessions(state);
    """

    private static let jobsDDL = """
    CREATE TABLE IF NOT EXISTS jobs (
      id TEXT PRIMARY KEY,
      type TEXT NOT NULL,
      priority INTEGER NOT NULL DEFAULT 0,
      state TEXT NOT NULL DEFAULT 'pending',
      payload_json TEXT NOT NULL,
      attempts INTEGER NOT NULL DEFAULT 0,
      max_attempts INTEGER NOT NULL DEFAULT 3,
      locked_at TEXT,
      last_error TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_jobs_state_type ON jobs(state, type);
    """

    private static let albumsDDL = """
    CREATE TABLE IF NOT EXISTS albums (
      id TEXT PRIMARY KEY,
      parent_id TEXT REFERENCES albums(id) ON DELETE CASCADE,
      type TEXT NOT NULL,
      name TEXT NOT NULL,
      sort_order INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS album_assets (
      album_id TEXT NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
      asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
      position INTEGER NOT NULL DEFAULT 0,
      added_at TEXT NOT NULL,
      PRIMARY KEY(album_id, asset_id)
    );
    CREATE TABLE IF NOT EXISTS smart_album_rules (
      album_id TEXT PRIMARY KEY REFERENCES albums(id) ON DELETE CASCADE,
      rule_json TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_album_assets_album ON album_assets(album_id, position);
    """

    // ---------- assets ----------
    private static let columns = """
    id,pid,ori,thumb,preview,filename,type,is_raw,folder_id,folder_name,\
    capture_date,width,height,orientation,camera,lens,focal,aperture,shutter,iso,\
    color_space,has_icc_profile,file_mb,rating,flag,color_label,keywords,title,caption,author,copyright,maker_notes,project,client,location,gps_lat,gps_lon,gps_altitude,\
    status,imported_at,deleted,is_demo,local_path,capture_date_source,content_hash,quick_hash,faces,\
    file_modified_at,file_created_at
    """

    func upsert(_ assets: [Asset]) throws {
        let placeholders = Array(repeating: "?", count: 49).joined(separator: ",")
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
    func addSourceRoot(id: String, displayName: String, path: String, bookmark: Data?,
                       volumeIdentifier: String? = nil) throws {
        try db.run("""
        INSERT OR REPLACE INTO source_roots(
          id, display_name, path_hint, bookmark_data, management_mode, status, created_at, volume_identifier)
        VALUES(?,?,?,?,?,?,?,?);
        """, [.text(id), .text(displayName), .text(path),
              bookmark.map { SQLValue.blob($0) } ?? .null, .text("referenced"),
              .text("online"), .text(ISO8601DateFormatter().string(from: Date())),
              volumeIdentifier.map { SQLValue.text($0) } ?? .null])
    }

    /// Drop all stored security-scoped bookmarks, forcing re-authorization (§17.6).
    func clearSourceBookmarks() throws {
        try db.run("UPDATE source_roots SET bookmark_data = NULL;")
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

    func removeSourceRoot(id: String) throws {
        try db.run("DELETE FROM source_roots WHERE id=?;", [.text(id)])
    }

    // ---------- albums (§6.8 / §10.2) ----------
    func loadAlbums() throws -> [Album] {
        let rows = try db.query("""
        SELECT id, name
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
            return Album(id: id, name: name, assetIds: assetIds)
        }
    }

    func saveAlbum(_ album: Album, sortOrder: Int = 0, updatedAt: Date = .now) throws {
        let now = Self.iso(updatedAt)
        try db.transaction {
            try db.run("""
            INSERT INTO albums(id, parent_id, type, name, sort_order, created_at, updated_at)
            VALUES(?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
              name=excluded.name,
              sort_order=excluded.sort_order,
              updated_at=excluded.updated_at;
            """, [.text(album.id), .null, .text("album"), .text(album.name),
                  .int(sortOrder), .text(now), .text(now)])
            try db.run("DELETE FROM album_assets WHERE album_id=?;", [.text(album.id)])
            for (index, assetId) in album.assetIds.enumerated() {
                try db.run("""
                INSERT INTO album_assets(album_id, asset_id, position, added_at)
                VALUES(?,?,?,?);
                """, [.text(album.id), .text(assetId), .int(index), .text(now)])
            }
        }
    }

    func loadSmartAlbums() throws -> [SmartAlbum] {
        let decoder = JSONDecoder()
        return try db.query("""
        SELECT albums.id, albums.name, smart_album_rules.rule_json
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
            return SmartAlbum(id: id, name: name, rule: rule, count: 0)
        }
    }

    func saveSmartAlbum(_ album: SmartAlbum, sortOrder: Int = 0, updatedAt: Date = .now) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(album.rule)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        let now = Self.iso(updatedAt)
        try db.transaction {
            try db.run("""
            INSERT INTO albums(id, parent_id, type, name, sort_order, created_at, updated_at)
            VALUES(?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
              name=excluded.name,
              sort_order=excluded.sort_order,
              updated_at=excluded.updated_at;
            """, [.text(album.id), .null, .text("smart"), .text(album.name),
                  .int(sortOrder), .text(now), .text(now)])
            try db.run("""
            INSERT INTO smart_album_rules(album_id, rule_json, updated_at)
            VALUES(?,?,?)
            ON CONFLICT(album_id) DO UPDATE SET
              rule_json=excluded.rule_json,
              updated_at=excluded.updated_at;
            """, [.text(album.id), .text(json), .text(now)])
        }
    }

    // ---------- import sessions (§10.2 / §12.2) ----------
    func startImportSession(id: String, startedAt: Date = .now) throws {
        try db.run("""
        INSERT OR REPLACE INTO import_sessions(
          id, root_id, state, total_count, imported_count, skipped_count, failed_count,
          started_at, finished_at, error_message
        ) VALUES(?,?,?,?,?,?,?,?,?,?);
        """, [.text(id), .null, .text("running"), .int(0), .int(0), .int(0), .int(0),
              .text(Self.iso(startedAt)), .null, .null])
    }

    func updateImportSession(id: String, rootId: String? = nil, state: String, totalCount: Int,
                             importedCount: Int, skippedCount: Int, failedCount: Int,
                             finishedAt: Date? = nil, errorMessage: String? = nil) throws {
        try db.run("""
        UPDATE import_sessions
        SET root_id=?, state=?, total_count=?, imported_count=?, skipped_count=?, failed_count=?,
            finished_at=?, error_message=?
        WHERE id=?;
        """, [
            rootId.map { SQLValue.text($0) } ?? .null,
            .text(state), .int(totalCount), .int(importedCount), .int(skippedCount), .int(failedCount),
            finishedAt.map { SQLValue.text(Self.iso($0)) } ?? .null,
            errorMessage.map { SQLValue.text($0) } ?? .null,
            .text(id),
        ])
    }

    func loadImportSessions() throws -> [ImportSessionRecord] {
        try db.query("""
        SELECT id, root_id, state, total_count, imported_count, skipped_count, failed_count,
               started_at, finished_at, error_message
        FROM import_sessions
        ORDER BY started_at DESC;
        """).compactMap(Self.importSession(from:))
    }

    // ---------- jobs (§10.2 / §13) ----------
    func startImportJob(id: String, sessionId: String, sourcePath: String, mode: ImportMode,
                        autoTag: Bool, priority: Int = 10, createdAt: Date = .now) throws {
        let payload = Self.importJobPayload(sessionId: sessionId, sourcePath: sourcePath,
                                            mode: mode, autoTag: autoTag)
        let now = Self.iso(createdAt)
        try db.run("""
        INSERT OR REPLACE INTO jobs(
          id, type, priority, state, payload_json, attempts, max_attempts,
          locked_at, last_error, created_at, updated_at
        ) VALUES(?,?,?,?,?,?,?,?,?,?,?);
        """, [.text(id), .text("scan"), .int(priority), .text("running"), .text(payload),
              .int(0), .int(3), .text(now), .null, .text(now), .text(now)])
    }

    func updateJob(id: String, state: String, lockedAt: Date? = .now, lastError: String? = nil) throws {
        try db.run("""
        UPDATE jobs
        SET state=?, locked_at=?, last_error=?, updated_at=?
        WHERE id=?;
        """, [
            .text(state),
            lockedAt.map { SQLValue.text(Self.iso($0)) } ?? .null,
            lastError.map { SQLValue.text($0) } ?? .null,
            .text(Self.iso(.now)),
            .text(id),
        ])
    }

    func loadJobs(type: String? = nil, states: [String]? = nil) throws -> [JobRecord] {
        var clauses: [String] = []
        var params: [SQLValue] = []
        if let type {
            clauses.append("type=?")
            params.append(.text(type))
        }
        if let states, !states.isEmpty {
            clauses.append("state IN (\(Array(repeating: "?", count: states.count).joined(separator: ",")))")
            params.append(contentsOf: states.map { .text($0) })
        }
        let whereSQL = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        return try db.query("""
        SELECT id, type, priority, state, payload_json, attempts, max_attempts,
               locked_at, last_error, created_at, updated_at
        FROM jobs\(whereSQL)
        ORDER BY priority DESC, created_at ASC;
        """, params).compactMap(Self.job(from:))
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

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func filenameStamp(_ date: Date) -> String {
        iso(date)
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    private static func date(_ string: String?) -> Date? {
        guard let string else { return nil }
        return ISO8601DateFormatter().date(from: string)
    }

    private static func importJobPayload(sessionId: String, sourcePath: String,
                                         mode: ImportMode, autoTag: Bool) -> String {
        let payload = ImportJobPayload(sessionId: sessionId, sourcePath: sourcePath,
                                       mode: mode.rawValue, autoTag: autoTag)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(payload)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func params(_ a: Asset) -> [SQLValue] {
        [
            .text(a.id), .int(a.pid), .text(a.ori), .text(a.thumb), .text(a.preview),
            .text(a.filename), .text(a.type), .int(a.isRaw ? 1 : 0), .text(a.folderId), .text(a.folderName),
            .double(a.date.timeIntervalSince1970), .int(a.width), .int(a.height), .int(a.orientation),
            .text(a.camera), .text(a.lens), .int(a.focal), .double(a.aperture), .text(a.shutter), .int(a.iso),
            .text(a.colorSpace), .int(a.hasICCProfile ? 1 : 0),
            .double(a.fileMB), .int(a.rating), .text(a.flag.rawValue),
            a.colorLabel.map { SQLValue.text($0.rawValue) } ?? .null,
            .text(keywordsJSON(a.keywords)), .text(a.title), .text(a.caption),
            .text(a.author), .text(a.copyright), .text(a.makerNotes),
            .text(a.project), .text(a.client),
            .text(a.location), .double(a.gps.0), .double(a.gps.1),
            a.gpsAltitude.map { SQLValue.double($0) } ?? .null,
            .text(a.status.rawValue),
            .double(a.importedAt.timeIntervalSince1970), .int(a.deleted ? 1 : 0), .int(a.isDemo ? 1 : 0),
            a.localPath.map { SQLValue.text($0) } ?? .null,
            .text(a.captureDateSource),
            a.contentHash.map { SQLValue.text($0) } ?? .null,
            a.quickHash.map { SQLValue.text($0) } ?? .null,
            .int(a.faces),
            a.fileModifiedAt.map { SQLValue.double($0.timeIntervalSince1970) } ?? .null,
            a.fileCreatedAt.map { SQLValue.double($0.timeIntervalSince1970) } ?? .null,
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
            colorSpace: row.text("color_space") ?? "",
            hasICCProfile: row.bool("has_icc_profile"),
            fileMB: row.double("file_mb") ?? 0,
            fileModifiedAt: row.double("file_modified_at").map(Date.init(timeIntervalSince1970:)),
            fileCreatedAt: row.double("file_created_at").map(Date.init(timeIntervalSince1970:)),
            rating: row.int("rating") ?? 0,
            flag: Flag(rawValue: row.text("flag") ?? "none") ?? .none,
            colorLabel: row.text("color_label").flatMap { ColorLabel(rawValue: $0) },
            keywords: kws, title: row.text("title") ?? "", caption: row.text("caption") ?? "",
            author: row.text("author") ?? "", copyright: row.text("copyright") ?? "",
            makerNotes: row.text("maker_notes") ?? "",
            project: row.text("project") ?? "", client: row.text("client") ?? "",
            location: row.text("location") ?? "",
            gps: (row.double("gps_lat") ?? 0, row.double("gps_lon") ?? 0),
            gpsAltitude: row.double("gps_altitude"),
            status: AssetStatus(rawValue: row.text("status") ?? "ready") ?? .ready,
            importedAt: Date(timeIntervalSince1970: row.double("imported_at") ?? 0),
            deleted: row.bool("deleted"),
            localPath: row.text("local_path"),
            captureDateSource: row.text("capture_date_source") ?? "EXIF · DateTimeOriginal",
            contentHash: row.text("content_hash"), quickHash: row.text("quick_hash"),
            isDemo: row.bool("is_demo"), faces: row.int("faces") ?? 0)
    }

    private static func importSession(from row: Row) -> ImportSessionRecord? {
        guard let id = row.text("id"),
              let state = row.text("state"),
              let startedAt = date(row.text("started_at")) else { return nil }
        return ImportSessionRecord(
            id: id,
            rootId: row.text("root_id"),
            state: state,
            totalCount: row.int("total_count") ?? 0,
            importedCount: row.int("imported_count") ?? 0,
            skippedCount: row.int("skipped_count") ?? 0,
            failedCount: row.int("failed_count") ?? 0,
            startedAt: startedAt,
            finishedAt: date(row.text("finished_at")),
            errorMessage: row.text("error_message"))
    }

    private static func job(from row: Row) -> JobRecord? {
        guard let id = row.text("id"),
              let type = row.text("type"),
              let state = row.text("state"),
              let payloadJSON = row.text("payload_json"),
              let createdAt = date(row.text("created_at")),
              let updatedAt = date(row.text("updated_at")) else { return nil }
        return JobRecord(
            id: id,
            type: type,
            priority: row.int("priority") ?? 0,
            state: state,
            payloadJSON: payloadJSON,
            attempts: row.int("attempts") ?? 0,
            maxAttempts: row.int("max_attempts") ?? 3,
            lockedAt: date(row.text("locked_at")),
            lastError: row.text("last_error"),
            createdAt: createdAt,
            updatedAt: updatedAt)
    }
}
