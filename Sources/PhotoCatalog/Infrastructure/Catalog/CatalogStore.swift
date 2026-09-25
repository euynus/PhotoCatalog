// ============================================================
//  CatalogStore — the `.photolibrary` package + SQLite store
//  (PRD §9 file structure, §10 schema, §6.12 backup)
// ============================================================
import Foundation

struct SourceRootRecord: Identifiable, Sendable {
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
    let archiveRule: String?
    let readSidecar: Bool?
    let previewMaxPixel: Int?

    init(kind: String = "importFolder", sessionId: String, sourcePath: String,
         mode: String, autoTag: Bool, archiveRule: String? = nil,
         readSidecar: Bool? = nil, previewMaxPixel: Int? = nil) {
        self.kind = kind
        self.sessionId = sessionId
        self.sourcePath = sourcePath
        self.mode = mode
        self.autoTag = autoTag
        self.archiveRule = archiveRule
        self.readSidecar = readSidecar
        self.previewMaxPixel = previewMaxPixel
    }
}

enum CatalogStoreError: Error, Equatable {
    case incompatibleSchema(current: Int, supported: Int)
}

enum AssetQueryScope: Equatable, Sendable {
    case all
    case recent(since: Date)
    case unrated
    case picks
    case rejected
    case missingOrOffline
    case places
    case people
    case folder(sourceId: String, directoryPath: String? = nil)
    case album(id: String)
    case smart(rule: SmartRule)
    case keyword(String)
    case project(String)
    case client(String)
    case captureDate(String)
}

struct AssetQuery: Equatable, Sendable {
    var scope: AssetQueryScope = .all
    var filters = Filters()
    var search = ""
    var sort = Sort()
    var referenceDate = Date.now
}

struct AssetPage: Sendable {
    let assets: [Asset]
    let totalCount: Int
    let offset: Int

    var hasMore: Bool { offset + assets.count < totalCount }
}

// @unchecked Sendable: immutable URLs + a serialized Database (see Database).
final class CatalogStore: @unchecked Sendable {
    static let latestSchemaVersion = 20
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
        if current < 14 {
            // indexes for the hot deleted/quick_hash filters and reverse album lookups
            try db.execChecked("CREATE INDEX IF NOT EXISTS idx_assets_deleted ON assets(deleted);")
            try db.execChecked("CREATE INDEX IF NOT EXISTS idx_assets_quick_hash ON assets(quick_hash);")
            try db.execChecked("CREATE INDEX IF NOT EXISTS idx_album_assets_asset ON album_assets(asset_id);")
            try recordMigration(14)
        }
        if current < 15 {
            try db.run("ALTER TABLE assets ADD COLUMN perceptual_hash INTEGER;")
            try recordMigration(15)
        }
        if current < 16 {
            try db.execChecked("DROP TABLE IF EXISTS asset_search;")
            try db.execChecked(Self.assetSearchDDL)
            try db.execChecked("""
            INSERT INTO asset_search(asset_id, content)
            SELECT id,
                   COALESCE(filename, '') || ' ' || COALESCE(title, '') || ' '
                   || COALESCE(caption, '') || ' ' || COALESCE(keywords, '') || ' '
                   || COALESCE(camera, '') || ' ' || COALESCE(lens, '') || ' '
                   || COALESCE(location, '') || ' ' || COALESCE(project, '') || ' '
                   || COALESCE(client, '')
            FROM assets;
            """)
            try recordMigration(16)
        }
        if current < 17 {
            try db.execChecked(Self.assetQueryIndexesDDL)
            try recordMigration(17)
        }
        if current < 18 {
            // non-destructive develop adjustments; one JSON document per edited photo
            try db.execChecked("""
            CREATE TABLE IF NOT EXISTS develop_settings (
              asset_id TEXT PRIMARY KEY,
              settings TEXT NOT NULL,
              updated_at TEXT
            );
            """)
            try recordMigration(18)
        }
        if current < 19 {
            // faces found by on-device Vision; face_scans remembers photos already looked at,
            // including those without faces
            try db.execChecked("""
            CREATE TABLE IF NOT EXISTS faces (
              id TEXT PRIMARY KEY,
              asset_id TEXT NOT NULL,
              x REAL NOT NULL, y REAL NOT NULL, w REAL NOT NULL, h REAL NOT NULL,
              quality REAL NOT NULL DEFAULT 0,
              vector BLOB NOT NULL,
              person TEXT,
              confirmed INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS idx_faces_asset ON faces(asset_id);
            CREATE TABLE IF NOT EXISTS face_scans (
              asset_id TEXT PRIMARY KEY,
              scanned_at TEXT NOT NULL
            );
            """)
            try recordMigration(19)
        }
        if current < 20 {
            // Key each search row by its asset's rowid. Deleting by the UNINDEXED asset_id
            // column scanned the whole index on every upsert — quadratic imports and edits in
            // big catalogs (~100 rows/s at 50k photos). Nothing here VACUUMs (which could
            // renumber assets' rowids); rebuild asset_search if that ever changes.
            try db.execChecked("DROP TABLE IF EXISTS asset_search;")
            try db.execChecked(Self.assetSearchDDL)
            try db.execChecked("""
            INSERT INTO asset_search(rowid, asset_id, content)
            SELECT rowid, id,
                   COALESCE(filename, '') || ' ' || COALESCE(title, '') || ' '
                   || COALESCE(caption, '') || ' ' || COALESCE(keywords, '') || ' '
                   || COALESCE(camera, '') || ' ' || COALESCE(lens, '') || ' '
                   || COALESCE(location, '') || ' ' || COALESCE(project, '') || ' '
                   || COALESCE(client, '')
            FROM assets;
            """)
            try recordMigration(20)
        }
    }

    private func recordMigration(_ version: Int) throws {
        try db.run("INSERT INTO schema_migrations(version, applied_at) VALUES(?, ?);",
                   [.int(version), .text(Self.iso(.now))])
    }

    /// Trigram FTS search returning substring matches for queries of at least three characters.
    func search(_ query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 3 else { return [] }
        let match = Self.ftsMatch(q)
        let rows = (try? db.query("""
        SELECT asset_search.asset_id
        FROM asset_search
        JOIN assets ON assets.id = asset_search.asset_id
        WHERE assets.deleted=0 AND asset_search MATCH ?;
        """, [.text(match)])) ?? []
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

    private static let assetSearchDDL = """
    CREATE VIRTUAL TABLE asset_search USING fts5(
      asset_id UNINDEXED, content, tokenize='trigram');
    """

    private static let assetQueryIndexesDDL = """
    CREATE INDEX IF NOT EXISTS idx_assets_deleted_capture
      ON assets(deleted, capture_date, id);
    CREATE INDEX IF NOT EXISTS idx_assets_deleted_imported
      ON assets(deleted, imported_at, id);
    CREATE INDEX IF NOT EXISTS idx_assets_deleted_filename
      ON assets(deleted, filename COLLATE NOCASE, id);
    CREATE INDEX IF NOT EXISTS idx_assets_deleted_rating
      ON assets(deleted, rating, id);
    CREATE INDEX IF NOT EXISTS idx_assets_deleted_size
      ON assets(deleted, file_mb, id);
    """

    // ---------- assets ----------
    private static let columns = """
    id,pid,ori,thumb,preview,filename,type,is_raw,folder_id,folder_name,\
    capture_date,width,height,orientation,camera,lens,focal,aperture,shutter,iso,\
    color_space,has_icc_profile,file_mb,rating,flag,color_label,keywords,title,caption,author,copyright,maker_notes,project,client,location,gps_lat,gps_lon,gps_altitude,\
    status,imported_at,deleted,is_demo,local_path,capture_date_source,content_hash,quick_hash,faces,\
    file_modified_at,file_created_at,perceptual_hash
    """

    func upsert(_ assets: [Asset]) throws {
        let cols = Self.columns.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let placeholders = Array(repeating: "?", count: cols.count).joined(separator: ",")
        // True in-place upsert. INSERT OR REPLACE would DELETE the conflicting row before
        // re-inserting, which — with foreign_keys=ON — fires album_assets' ON DELETE CASCADE
        // and silently drops the asset from every manual album on each metadata edit. The
        // ON CONFLICT…DO UPDATE form updates the row in place, leaving FK children intact.
        let assignments = cols.filter { $0 != "id" }.map { "\($0)=excluded.\($0)" }.joined(separator: ",")
        let sql = "INSERT INTO assets(\(Self.columns)) VALUES(\(placeholders)) ON CONFLICT(id) DO UPDATE SET \(assignments);"
        try db.transaction {
            for a in assets {
                try db.run(sql, Self.params(a))
                // keep the FTS index in sync; its rows share the asset's rowid (schema v20)
                guard let rowid = try db.queryMap("SELECT rowid AS r FROM assets WHERE id=?;", [.text(a.id)],
                                                  transform: { $0.int("r") }).first else { continue }
                try db.run("DELETE FROM asset_search WHERE rowid=?;", [.int(rowid)])
                try db.run("INSERT INTO asset_search(rowid, asset_id, content) VALUES(?,?,?);", [
                    .int(rowid),
                    .text(a.id),
                    .text(Self.searchContent(a)),
                ])
            }
        }
    }

    private static func searchContent(_ asset: Asset) -> String {
        [asset.filename, asset.title, asset.caption, asset.keywords.joined(separator: " "),
         asset.camera, asset.lens, asset.location, asset.project, asset.client]
            .joined(separator: " ")
    }

    func updateAsset(_ a: Asset) throws { try upsert([a]) }

    func updateRatings(_ rating: Int, assetIDs: Set<String>) throws {
        try updateAssetColumn("rating", value: .int(rating), assetIDs: assetIDs)
    }

    func updateFlags(_ flag: Flag, assetIDs: Set<String>) throws {
        try updateAssetColumn("flag", value: .text(flag.rawValue), assetIDs: assetIDs)
    }

    func updateColorLabels(_ color: ColorLabel?, assetIDs: Set<String>) throws {
        try updateAssetColumn("color_label", value: color.map { .text($0.rawValue) } ?? .null,
                              assetIDs: assetIDs)
    }

    func updateAssetAvailability(_ updates: [AssetAvailabilityUpdate]) throws {
        guard !updates.isEmpty else { return }
        try db.transaction {
            for update in updates {
                try db.run(
                    "UPDATE assets SET status=?, local_path=? WHERE id=? AND deleted=0;",
                    [
                        .text(update.status.rawValue),
                        update.localPath.map(SQLValue.text) ?? .null,
                        .text(update.assetId),
                    ]
                )
            }
        }
    }

    private func updateAssetColumn(_ column: String, value: SQLValue, assetIDs: Set<String>) throws {
        guard !assetIDs.isEmpty else { return }
        let ids = assetIDs.sorted()
        try db.transaction {
            for start in stride(from: 0, to: ids.count, by: 500) {
                let chunk = ids[start..<min(start + 500, ids.count)]
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let params = [value] + chunk.map(SQLValue.text)
                try db.run("UPDATE assets SET \(column)=? WHERE id IN (\(placeholders));", params)
            }
        }
    }

    func loadAssets() throws -> [Asset] {
        // soft-deleted rows are never shown; skip materializing them (uses idx_assets_deleted)
        try db.queryMap(
            "SELECT \(Self.columns) FROM assets WHERE deleted=0 ORDER BY capture_date DESC;",
            transform: Self.asset(from:)
        )
    }

    /// Returns a stable page and the full match count from one read transaction.
    /// All user-controlled values are bound parameters; only enum-backed sort columns enter SQL.
    func loadAssetPage(matching query: AssetQuery = AssetQuery(),
                       offset: Int = 0, limit: Int = 200) throws -> AssetPage {
        let safeOffset = max(0, offset)
        let safeLimit = max(0, limit)
        let sql = Self.assetSQL(for: query)
        var totalCount = 0
        var assets: [Asset] = []

        try db.transaction {
            totalCount = try db.queryMap(
                "SELECT COUNT(*) AS total FROM assets AS a WHERE \(sql.predicate);",
                sql.params
            ) { $0.int("total") }.first ?? 0

            guard safeLimit > 0, safeOffset < totalCount else { return }
            assets = try db.queryMap(
                """
                SELECT \(Self.columns)
                FROM assets AS a
                WHERE \(sql.predicate)
                ORDER BY \(Self.orderClause(for: query.sort))
                LIMIT ? OFFSET ?;
                """,
                sql.params + [.int(safeLimit), .int(safeOffset)],
                transform: Self.asset(from:)
            )
        }
        return AssetPage(assets: assets, totalCount: totalCount, offset: safeOffset)
    }

    private struct AssetSQL {
        let predicate: String
        let params: [SQLValue]
    }

    private static func assetSQL(for query: AssetQuery) -> AssetSQL {
        var predicates = ["a.deleted=0"]
        var params: [SQLValue] = []

        func append(_ predicate: String, _ values: [SQLValue] = []) {
            predicates.append(predicate)
            params.append(contentsOf: values)
        }

        switch query.scope {
        case .all:
            break
        case .recent(let since):
            append("a.imported_at > ?", [.double(since.timeIntervalSince1970)])
        case .unrated:
            append("a.rating=0 AND a.flag<>'reject'")
        case .picks:
            append("a.flag='pick'")
        case .rejected:
            append("a.flag='reject'")
        case .missingOrOffline:
            append("a.status IN ('missing','offline')")
        case .places:
            append(hasGPSPredicate)
        case .people:
            append("a.faces>0")
        case .folder(let sourceId, let directoryPath):
            append("a.folder_id=?", [.text(sourceId)])
            if let directoryPath {
                let path = directoryPath.count > 1 && directoryPath.hasSuffix("/")
                    ? String(directoryPath.dropLast()) : directoryPath
                let prefix = path == "/" ? "/" : path + "/"
                append("a.local_path IS NOT NULL AND instr(a.local_path, ?)=1", [.text(prefix)])
            }
        case .album(let id):
            append("EXISTS (SELECT 1 FROM album_assets aa WHERE aa.album_id=? AND aa.asset_id=a.id)",
                   [.text(id)])
        case .smart(let rule):
            let smart = smartPredicate(rule, referenceDate: query.referenceDate)
            append(smart.predicate, smart.params)
        case .keyword(let keyword):
            append("""
            EXISTS (
              SELECT 1
              FROM json_each(CASE WHEN json_valid(a.keywords) THEN a.keywords ELSE '[]' END) kw
              WHERE CAST(kw.value AS TEXT)=?
            )
            """, [.text(keyword)])
        case .project(let project):
            append("a.project=?", [.text(project)])
        case .client(let client):
            append("a.client=?", [.text(client)])
        case .captureDate(let key):
            if let range = CaptureDates.interval(for: key) {
                append("a.capture_date>=? AND a.capture_date<?",
                       [.double(range.start.timeIntervalSince1970), .double(range.end.timeIntervalSince1970)])
            } else {
                append("0")
            }
        }

        let filters = query.filters
        if filters.minRating > 0 {
            append("a.rating>=?", [.int(filters.minRating)])
        }
        if filters.flag != "any" {
            append("a.flag=?", [.text(filters.flag)])
        }
        if filters.color != "any" {
            append("a.color_label=?", [.text(filters.color)])
        }
        if filters.type != "any" {
            if filters.type == "RAW" {
                append("a.is_raw=1")
            } else {
                append("a.type=?", [.text(filters.type)])
            }
        }

        let camera = filters.camera.trimmingCharacters(in: .whitespacesAndNewlines)
        if !camera.isEmpty {
            append(textContainsPredicate(column: "a.camera"), [.text(camera)])
        }
        let lens = filters.lens.trimmingCharacters(in: .whitespacesAndNewlines)
        if !lens.isEmpty {
            append(textContainsPredicate(column: "a.lens"), [.text(lens)])
        }
        if filters.date != "any" {
            if let range = filters.captureDateInterval(now: query.referenceDate) {
                append("a.capture_date>=? AND a.capture_date<?",
                       [.double(range.start.timeIntervalSince1970), .double(range.end.timeIntervalSince1970)])
            } else {
                append("0")
            }
        }
        if filters.gps == "yes" {
            append(hasGPSPredicate)
        } else if filters.gps == "no" {
            append("NOT \(hasGPSPredicate)")
        }
        if filters.status != "any" {
            append("a.status=?", [.text(filters.status)])
        }

        let search = query.search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !search.isEmpty {
            let searchSQL = searchPredicate(search)
            append(searchSQL.predicate, searchSQL.params)
        }

        return AssetSQL(predicate: predicates.map { "(\($0))" }.joined(separator: " AND "),
                        params: params)
    }

    private static func smartPredicate(_ rule: SmartRule, referenceDate: Date) -> AssetSQL {
        let conditions = rule.conditions.map { smartConditionPredicate($0, referenceDate: referenceDate) }
        guard !conditions.isEmpty else {
            return AssetSQL(predicate: rule.match == "all" ? "1" : "0", params: [])
        }
        let separator = rule.match == "all" ? " AND " : " OR "
        return AssetSQL(
            predicate: conditions.map { "(\($0.predicate))" }.joined(separator: separator),
            params: conditions.flatMap(\.params)
        )
    }

    private static func smartConditionPredicate(_ condition: SmartCondition,
                                                referenceDate: Date) -> AssetSQL {
        switch condition.field {
        case "rating":
            let op = [">=", "<=", "="].contains(condition.op) ? condition.op : "="
            return AssetSQL(predicate: "a.rating\(op)?", params: [.int(Int(condition.value) ?? 0)])
        case "flag":
            return AssetSQL(predicate: "a.flag=?", params: [.text(condition.value)])
        case "colorLabel":
            if condition.value.isEmpty {
                return AssetSQL(predicate: "a.color_label IS NULL", params: [])
            }
            return AssetSQL(predicate: "a.color_label=?", params: [.text(condition.value)])
        case "keywords":
            let contains = """
            EXISTS (
              SELECT 1
              FROM json_each(CASE WHEN json_valid(a.keywords) THEN a.keywords ELSE '[]' END) kw
              WHERE \(textContainsPredicate(column: "CAST(kw.value AS TEXT)"))
            )
            """
            return AssetSQL(predicate: condition.op == "包含" ? contains : "NOT (\(contains))",
                            params: [.text(condition.value)])
        case "camera", "lens":
            let column = condition.field == "camera" ? "a.camera" : "a.lens"
            let predicate = condition.op == "=" ? "\(column)=?" : textContainsPredicate(column: column)
            return AssetSQL(predicate: predicate, params: [.text(condition.value)])
        case "type":
            if condition.value == "RAW" {
                return AssetSQL(predicate: "a.is_raw=1", params: [])
            }
            return AssetSQL(predicate: "a.type=?", params: [.text(condition.value)])
        case "captureYear":
            let op = [">=", "<=", "="].contains(condition.op) ? condition.op : "="
            return AssetSQL(
                predicate: "CAST(strftime('%Y', a.capture_date, 'unixepoch') AS INTEGER)\(op)?",
                params: [.int(Int(condition.value) ?? 0)]
            )
        case "datePreset":
            if condition.value == "any" { return AssetSQL(predicate: "1", params: []) }
            guard let range = CaptureDates.presetInterval(condition.value, now: referenceDate) else {
                return AssetSQL(predicate: "0", params: [])
            }
            return AssetSQL(predicate: "a.capture_date>=? AND a.capture_date<?", params: [
                .double(range.start.timeIntervalSince1970),
                .double(range.end.timeIntervalSince1970),
            ])
        case "captureDate":
            guard let range = CaptureDates.interval(for: condition.value) else {
                return AssetSQL(predicate: "0", params: [])
            }
            if condition.op == ">=" {
                return AssetSQL(predicate: "a.capture_date>=?", params: [.double(range.start.timeIntervalSince1970)])
            }
            if condition.op == "<=" {
                return AssetSQL(predicate: "a.capture_date<?", params: [.double(range.end.timeIntervalSince1970)])
            }
            return AssetSQL(predicate: "a.capture_date>=? AND a.capture_date<?", params: [
                .double(range.start.timeIntervalSince1970), .double(range.end.timeIntervalSince1970),
            ])
        case "gps":
            return AssetSQL(predicate: condition.value == "yes" ? hasGPSPredicate : "NOT \(hasGPSPredicate)",
                            params: [])
        case "status":
            return AssetSQL(predicate: "a.status=?", params: [.text(condition.value)])
        case "search":
            return searchPredicate(condition.value)
        default:
            return AssetSQL(predicate: "1", params: [])
        }
    }

    private static func searchPredicate(_ value: String) -> AssetSQL {
        let query = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 3 else {
            let content = """
            COALESCE(a.filename,'') || ' ' || COALESCE(a.camera,'') || ' ' ||
            COALESCE(a.lens,'') || ' ' || COALESCE(a.title,'') || ' ' ||
            COALESCE(a.caption,'') || ' ' || COALESCE(a.location,'') || ' ' ||
            COALESCE(a.project,'') || ' ' || COALESCE(a.client,'') || ' ' ||
            COALESCE(a.keywords,'')
            """
            return AssetSQL(predicate: textContainsPredicate(column: "(\(content))"), params: [.text(query)])
        }
        return AssetSQL(
            predicate: "a.id IN (SELECT asset_id FROM asset_search WHERE asset_search MATCH ?)",
            params: [.text(ftsMatch(query))]
        )
    }

    private static func textContainsPredicate(column: String) -> String {
        "instr(lower(COALESCE(\(column), '')), lower(?))>0"
    }

    private static func orderClause(for sort: Sort) -> String {
        let direction = sort.descending ? "DESC" : "ASC"
        let column: String
        switch sort.field {
        case .capture: column = "a.capture_date"
        case .imported: column = "a.imported_at"
        case .name: column = "a.filename COLLATE NOCASE"
        case .rating: column = "a.rating"
        case .size: column = "a.file_mb"
        }
        return "\(column) \(direction), a.id \(direction)"
    }

    private static func ftsMatch(_ query: String) -> String {
        "\"\(query.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static let hasGPSPredicate = """
    (
      a.gps_lat<>0 OR a.gps_lon<>0 OR (
        instr(a.location, ',')>1 AND
        instr(substr(a.location, instr(a.location, ',')+1), ',')=0 AND
        trim(substr(a.location, 1, instr(a.location, ',')-1))<>'' AND
        trim(substr(a.location, instr(a.location, ',')+1))<>'' AND
        trim(substr(a.location, 1, instr(a.location, ',')-1)) NOT GLOB '*[^0-9.+-]*' AND
        trim(substr(a.location, instr(a.location, ',')+1)) NOT GLOB '*[^0-9.+-]*' AND
        CAST(trim(substr(a.location, 1, instr(a.location, ',')-1)) AS REAL) BETWEEN -90 AND 90 AND
        CAST(trim(substr(a.location, instr(a.location, ',')+1)) AS REAL) BETWEEN -180 AND 180
      )
    )
    """

    func assetCount(includeDeleted: Bool = false) -> Int {
        db.scalarInt("SELECT COUNT(*) FROM assets" + (includeDeleted ? ";" : " WHERE deleted=0;"))
    }

    // ---------- source roots ----------
    func addSourceRoot(id: String, displayName: String, path: String, bookmark: Data?,
                       mode: ImportMode = .referenced,
                       volumeIdentifier: String? = nil) throws {
        try db.run("""
        INSERT OR REPLACE INTO source_roots(
          id, display_name, path_hint, bookmark_data, management_mode, status, created_at, volume_identifier)
        VALUES(?,?,?,?,?,?,?,?);
        """, [.text(id), .text(displayName), .text(path),
              bookmark.map { SQLValue.blob($0) } ?? .null, .text(mode.rawValue),
              .text("online"), .text(ISO8601DateFormatter().string(from: Date())),
              volumeIdentifier.map { SQLValue.text($0) } ?? .null])
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

    func removeSourceRoot(id: String) throws {
        try db.run("DELETE FROM source_roots WHERE id=?;", [.text(id)])
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

    // ---------- albums (§6.8 / §10.2) ----------
    // ---------- develop settings ----------
    func loadDevelopSettings() throws -> [String: DevelopSettings] {
        let decoder = JSONDecoder()
        var result: [String: DevelopSettings] = [:]
        for row in try db.query("SELECT asset_id, settings FROM develop_settings;") {
            guard let id = row.text("asset_id"), let json = row.text("settings"),
                  let settings = try? decoder.decode(DevelopSettings.self, from: Data(json.utf8)) else { continue }
            result[id] = settings
        }
        return result
    }

    /// Stores `settings` for each asset; neutral settings delete the row (the photo is as shot).
    func saveDevelopSettings(_ settings: [String: DevelopSettings]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try db.transaction {
            for (id, value) in settings {
                if value.isNeutral {
                    try db.run("DELETE FROM develop_settings WHERE asset_id=?;", [.text(id)])
                } else {
                    let json = String(decoding: try encoder.encode(value), as: UTF8.self)
                    try db.run("""
                    INSERT INTO develop_settings(asset_id, settings, updated_at) VALUES(?, ?, ?)
                    ON CONFLICT(asset_id) DO UPDATE SET settings=excluded.settings, updated_at=excluded.updated_at;
                    """, [.text(id), .text(json), .text(Self.iso(.now))])
                }
            }
        }
    }

    // ---------- faces ----------
    func loadFaces() throws -> [FaceRecord] {
        try db.query("SELECT id, asset_id, x, y, w, h, quality, vector, person, confirmed FROM faces;").compactMap { row in
            guard let id = row.text("id"), let assetId = row.text("asset_id"), let blob = row.blob("vector") else {
                return nil
            }
            let vector = blob.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            return FaceRecord(id: id, assetId: assetId,
                              box: CGRect(x: row.double("x") ?? 0, y: row.double("y") ?? 0,
                                          width: row.double("w") ?? 0, height: row.double("h") ?? 0),
                              quality: Float(row.double("quality") ?? 0), vector: vector,
                              person: row.text("person"), confirmed: (row.int("confirmed") ?? 0) != 0)
        }
    }

    func loadFaceScannedAssetIds() throws -> Set<String> {
        Set(try db.query("SELECT asset_id FROM face_scans;").compactMap { $0.text("asset_id") })
    }

    /// Records a scan of each asset (replacing earlier faces for it) in one transaction.
    func saveFaceScans(_ scans: [String: [FaceRecord]]) throws {
        let now = Self.iso(.now)
        try db.transaction {
            for (assetId, faces) in scans {
                try db.run("DELETE FROM faces WHERE asset_id=?;", [.text(assetId)])
                for face in faces {
                    let blob = face.vector.withUnsafeBufferPointer { Data(buffer: $0) }
                    try db.run("""
                    INSERT INTO faces(id, asset_id, x, y, w, h, quality, vector, person, confirmed)
                    VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """, [.text(face.id), .text(assetId), .double(face.box.minX), .double(face.box.minY),
                          .double(face.box.width), .double(face.box.height), .double(Double(face.quality)),
                          .blob(blob), face.person.map { .text($0) } ?? .null, .int(face.confirmed ? 1 : 0)])
                }
                try db.run("""
                INSERT INTO face_scans(asset_id, scanned_at) VALUES(?, ?)
                ON CONFLICT(asset_id) DO UPDATE SET scanned_at=excluded.scanned_at;
                """, [.text(assetId), .text(now)])
            }
        }
    }

    /// Names (or with nil, un-names) faces.
    func setFacePeople(_ changes: [String: (person: String?, confirmed: Bool)]) throws {
        try db.transaction {
            for (id, change) in changes {
                try db.run("UPDATE faces SET person=?, confirmed=? WHERE id=?;",
                           [change.person.map { .text($0) } ?? .null, .int(change.confirmed ? 1 : 0), .text(id)])
            }
        }
    }

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

    func deleteSmartAlbum(id: String) throws {
        try db.run("DELETE FROM albums WHERE id=? AND type='smart';", [.text(id)])
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
        let updated = try db.query("""
        UPDATE import_sessions
        SET root_id=?, state=?, total_count=?, imported_count=?, skipped_count=?, failed_count=?,
            finished_at=?, error_message=?
        WHERE id=? RETURNING id;
        """, [
            rootId.map { SQLValue.text($0) } ?? .null,
            .text(state), .int(totalCount), .int(importedCount), .int(skippedCount), .int(failedCount),
            finishedAt.map { SQLValue.text(Self.iso($0)) } ?? .null,
            errorMessage.map { SQLValue.text($0) } ?? .null,
            .text(id),
        ])
        guard updated.count == 1 else { throw DBError.step("Import session not found: \(id)") }
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
                        autoTag: Bool, archiveRule: ManagedArchiveRule? = nil,
                        readSidecar: Bool? = nil, previewMaxPixel: Int? = nil,
                        priority: Int = 10, createdAt: Date = .now) throws {
        let payload = Self.importJobPayload(sessionId: sessionId, sourcePath: sourcePath,
                                            mode: mode, autoTag: autoTag,
                                            archiveRule: archiveRule, readSidecar: readSidecar,
                                            previewMaxPixel: previewMaxPixel)
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
        let updated = try db.query("""
        UPDATE jobs
        SET state=?, locked_at=?, last_error=?, updated_at=?
        WHERE id=? RETURNING id;
        """, [
            .text(state),
            lockedAt.map { SQLValue.text(Self.iso($0)) } ?? .null,
            lastError.map { SQLValue.text($0) } ?? .null,
            .text(Self.iso(.now)),
            .text(id),
        ])
        guard updated.count == 1 else { throw DBError.step("Import job not found: \(id)") }
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
        // Flush the WAL into the single .sqlite file before copying it. The restore path deletes
        // the -wal/-shm sidecars, so the copied file must be self-contained; abort rather than
        // produce a stale backup if the checkpoint didn't fully complete.
        guard db.walCheckpointTruncate() else {
            throw DBError.step("WAL checkpoint incomplete — backup aborted to avoid a stale copy")
        }
        let src = packageURL.appendingPathComponent("catalog.sqlite")
        // the stamp is 1-second granular, so a pre-restore safety backup can collide with an
        // auto-backup from the same second — never overwrite an existing backup; pick -N instead.
        let fm = FileManager.default
        var dest = backupsURL.appendingPathComponent("catalog-\(stamp).sqlite")
        var n = 1
        while fm.fileExists(atPath: dest.path) {
            dest = backupsURL.appendingPathComponent("catalog-\(stamp)-\(n).sqlite")
            n += 1
        }
        try fm.copyItem(at: src, to: dest)
        return dest
    }

    // ---------- manifest.json (§9) ----------
    private func writeManifestIfNeeded() {
        let url = packageURL.appendingPathComponent("manifest.json")
        let existing = (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        if existing["schemaVersion"] as? Int == Self.latestSchemaVersion { return }
        let manifest: [String: Any] = [
            "libraryVersion": 1, "schemaVersion": Self.latestSchemaVersion,
            "createdAt": existing["createdAt"] as? String ?? ISO8601DateFormatter().string(from: Date()),
            "appBuild": "1.0.0", "uuid": existing["uuid"] as? String ?? UUID().uuidString,
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
                                         mode: ImportMode, autoTag: Bool,
                                         archiveRule: ManagedArchiveRule?,
                                         readSidecar: Bool?, previewMaxPixel: Int?) -> String {
        let payload = ImportJobPayload(sessionId: sessionId, sourcePath: sourcePath,
                                       mode: mode.rawValue, autoTag: autoTag,
                                       archiveRule: archiveRule?.rawValue,
                                       readSidecar: readSidecar,
                                       previewMaxPixel: previewMaxPixel)
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
            a.perceptualHash.map { SQLValue.int(Int(Int64(bitPattern: $0))) } ?? .null,
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
            camera: MetadataReader.normalizedCameraName(row.text("camera") ?? ""), lens: row.text("lens") ?? "",
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
            isDemo: row.bool("is_demo"), faces: row.int("faces") ?? 0,
            perceptualHash: row.int("perceptual_hash").map { UInt64(bitPattern: Int64($0)) })
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
