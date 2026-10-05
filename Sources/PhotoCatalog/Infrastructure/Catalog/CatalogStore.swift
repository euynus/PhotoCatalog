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
    let options: ImportOptionsSnapshot?

    init(kind: String = "importFolder", sessionId: String, sourcePath: String,
         mode: String, autoTag: Bool, archiveRule: String? = nil,
         readSidecar: Bool? = nil, previewMaxPixel: Int? = nil, options: ImportOptionsSnapshot? = nil) {
        self.kind = kind
        self.sessionId = sessionId
        self.sourcePath = sourcePath
        self.mode = mode
        self.autoTag = autoTag
        self.archiveRule = archiveRule
        self.readSidecar = readSidecar
        self.previewMaxPixel = previewMaxPixel
        self.options = options
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
    static let latestSchemaVersion = 25
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
        if current < 21 {
            // each photo's develop steps (newest last) and the snapshots kept of it
            try db.execChecked("""
            CREATE TABLE IF NOT EXISTS develop_history (
              asset_id TEXT NOT NULL,
              seq INTEGER NOT NULL,
              name TEXT NOT NULL,
              created_at TEXT NOT NULL,
              settings TEXT NOT NULL,
              PRIMARY KEY (asset_id, seq)
            );
            CREATE TABLE IF NOT EXISTS develop_snapshots (
              id TEXT PRIMARY KEY,
              asset_id TEXT NOT NULL,
              name TEXT NOT NULL,
              created_at TEXT NOT NULL,
              settings TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_develop_snapshots_asset ON develop_snapshots(asset_id);
            """)
            try recordMigration(21)
        }
        if current < 22 {
            // virtual copies: another entry for the same original, with its own settings. Added
            // only when missing, so replaying the migration (a restored backup) doesn't fail.
            let existing = Set(try db.queryMap("PRAGMA table_info(assets);", [], transform: { $0.text("name") }))
            if !existing.contains("master_id") { try db.run("ALTER TABLE assets ADD COLUMN master_id TEXT;") }
            if !existing.contains("copy_name") { try db.run("ALTER TABLE assets ADD COLUMN copy_name TEXT;") }
            try db.execChecked("CREATE INDEX IF NOT EXISTS idx_assets_master ON assets(master_id) WHERE master_id IS NOT NULL;")
            try recordMigration(22)
        }
        if current < 23 {
            // each original's sidecar as of our last read or write, to notice other apps' changes
            try db.execChecked("""
            CREATE TABLE IF NOT EXISTS xmp_sync (
              asset_id TEXT PRIMARY KEY,
              modified_at REAL NOT NULL
            );
            """)
            try recordMigration(23)
        }
        if current < 24 {
            // videos: their length in seconds (added only when missing, as v22)
            let existing = Set(try db.queryMap("PRAGMA table_info(assets);", [], transform: { $0.text("name") }))
            if !existing.contains("duration") { try db.run("ALTER TABLE assets ADD COLUMN duration REAL;") }
            try recordMigration(24)
        }
        if current < 25 {
            try db.execChecked("""
            CREATE TABLE IF NOT EXISTS import_files (
              session_id TEXT NOT NULL REFERENCES import_sessions(id) ON DELETE CASCADE,
              source_path TEXT NOT NULL,
              file_size INTEGER,
              modified_at REAL,
              asset_id TEXT,
              outcome TEXT NOT NULL,
              reason TEXT,
              PRIMARY KEY (session_id, source_path)
            );
            """)
            try recordMigration(25)
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

    /// Videos, by their file type (`Asset.videoTypes`).
    static let videoPredicate = "a.type IN (" + Asset.videoTypes.sorted().map { "'\($0)'" }.joined(separator: ",") + ")"

    // ---------- assets ----------
    private static let columns = """
    id,pid,ori,thumb,preview,filename,type,is_raw,folder_id,folder_name,\
    capture_date,width,height,orientation,camera,lens,focal,aperture,shutter,iso,\
    color_space,has_icc_profile,file_mb,rating,flag,color_label,keywords,title,caption,author,copyright,maker_notes,project,client,location,gps_lat,gps_lon,gps_altitude,\
    status,imported_at,deleted,is_demo,local_path,capture_date_source,content_hash,quick_hash,faces,\
    file_modified_at,file_created_at,perceptual_hash,master_id,copy_name,duration
    """

    func upsert(_ assets: [Asset]) throws {
        try db.transaction { try upsertRows(assets) }
    }

    /// The asset row's insert, plain and as an upsert, each giving back the row's rowid.
    /// The upsert is a true in-place one. INSERT OR REPLACE would DELETE the conflicting row
    /// before re-inserting, which — with foreign_keys=ON — fires album_assets' ON DELETE CASCADE
    /// and silently drops the asset from every manual album on each metadata edit. The
    /// ON CONFLICT…DO UPDATE form updates the row in place, leaving FK children intact.
    private static let assetInsertSQL: (insert: String, upsert: String) = {
        let cols = columns.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let placeholders = Array(repeating: "?", count: cols.count).joined(separator: ",")
        let assignments = cols.filter { $0 != "id" }.map { "\($0)=excluded.\($0)" }.joined(separator: ",")
        let insert = "INSERT INTO assets(\(columns)) VALUES(\(placeholders))"
        return (insert + " RETURNING rowid AS r;",
                insert + " ON CONFLICT(id) DO UPDATE SET \(assignments) RETURNING rowid AS r;")
    }()

    private func upsertRows(_ assets: [Asset], updatingExisting: Bool = true) throws {
        let sql = updatingExisting ? Self.assetInsertSQL.upsert : Self.assetInsertSQL.insert
        for a in assets {
            // keep the FTS index in sync; its rows share the asset's rowid (schema v20)
            guard let rowid = try db.queryMap(sql, Self.params(a), transform: { $0.int("r") }).first else { continue }
            try db.run("DELETE FROM asset_search WHERE rowid=?;", [.int(rowid)])
            try db.run("INSERT INTO asset_search(rowid, asset_id, content) VALUES(?,?,?);", [
                .int(rowid),
                .text(a.id),
                .text(Self.searchContent(a)),
            ])
        }
    }

    private static func searchContent(_ asset: Asset) -> String {
        [asset.filename, asset.title, asset.caption, asset.keywords.joined(separator: " "),
         asset.camera, asset.lens, asset.location, asset.project, asset.client]
            .joined(separator: " ")
    }

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
        // Read the table in its own order and sort in memory: ORDER BY via the capture-date
        // index fetched every row with a random seek into the table — random reads across the
        // whole file, most of a 10-20 s cold load at 500k photos. Soft-deleted rows are skipped.
        Self.readAhead(db.path)
        let decoder = AssetRowDecoder(columns: Self.columnNames)
        let loaded = try db.queryRows(
            "SELECT \(Self.columns) FROM assets NOT INDEXED WHERE deleted=0;",
            transform: decoder.asset(from:)
        )
        // newest first, as the library shows by default; ties in a stable id order
        let dates = loaded.map { $0.date.timeIntervalSince1970 }
        var order = Array(loaded.indices)
        order.sort { dates[$0] != dates[$1] ? dates[$0] > dates[$1] : loaded[$0].id > loaded[$1].id }
        return order.map { loaded[$0] }
    }

    /// Reads the database file front to back, so the table scan that follows hits the page
    /// cache. Catalogs grow by imports, which interleave table, index and search pages across
    /// the file; the scan then made scattered 4 KB reads (~80 MB/s, 6 s at 500k photos cold),
    /// while one sequential pass runs at the disk's full speed (~1 s for 900 MB).
    private static func readAhead(_ path: String) {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = fcntl(fd, F_RDAHEAD, 1)
        var buffer = [UInt8](repeating: 0, count: 8 << 20)
        while buffer.withUnsafeMutableBytes({ read(fd, $0.baseAddress, $0.count) }) > 0 {}
    }

    private static let columnNames = columns.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Decodes whole-catalog loads from raw columns (no dictionary per row) into native strings —
    /// keywords decoded by JSONSerialization were bridged NSStrings, many times slower to hash
    /// and compare — and shares values that repeat across photos (folders, lenses, keyword
    /// sets…) instead of allocating each again.
    private final class AssetRowDecoder {
        private var strings: [String: String] = [:]
        private var keywordSets: [String: [String]] = [:]
        private var cameras: [String: String] = [:]
        private let id, pid, ori, thumb, preview, filename, type, isRaw, folderId, folderName,
                    captureDate, width, height, orientation, camera, lens, focal, aperture, shutter, iso,
                    colorSpace, hasICCProfile, fileMB, rating, flag, colorLabel, keywords, title, caption,
                    author, copyright, makerNotes, project, client, location, gpsLat, gpsLon, gpsAltitude,
                    status, importedAt, deleted, isDemo, localPath, captureDateSource, contentHash,
                    quickHash, faces, fileModifiedAt, fileCreatedAt, perceptualHash, masterId, copyName, duration: Int32

        init(columns: [String]) {
            let index = Dictionary(uniqueKeysWithValues: columns.enumerated().map { ($1, Int32($0)) })
            func c(_ name: String) -> Int32 { index[name] ?? -1 }
            id = c("id"); pid = c("pid"); ori = c("ori"); thumb = c("thumb"); preview = c("preview")
            filename = c("filename"); type = c("type"); isRaw = c("is_raw"); folderId = c("folder_id")
            folderName = c("folder_name"); captureDate = c("capture_date"); width = c("width")
            height = c("height"); orientation = c("orientation"); camera = c("camera"); lens = c("lens")
            focal = c("focal"); aperture = c("aperture"); shutter = c("shutter"); iso = c("iso")
            colorSpace = c("color_space"); hasICCProfile = c("has_icc_profile"); fileMB = c("file_mb")
            rating = c("rating"); flag = c("flag"); colorLabel = c("color_label"); keywords = c("keywords")
            title = c("title"); caption = c("caption"); author = c("author"); copyright = c("copyright")
            makerNotes = c("maker_notes"); project = c("project"); client = c("client"); location = c("location")
            gpsLat = c("gps_lat"); gpsLon = c("gps_lon"); gpsAltitude = c("gps_altitude"); status = c("status")
            importedAt = c("imported_at"); deleted = c("deleted"); isDemo = c("is_demo"); localPath = c("local_path")
            captureDateSource = c("capture_date_source"); contentHash = c("content_hash")
            quickHash = c("quick_hash"); faces = c("faces"); fileModifiedAt = c("file_modified_at")
            fileCreatedAt = c("file_created_at"); perceptualHash = c("perceptual_hash")
            masterId = c("master_id"); copyName = c("copy_name"); duration = c("duration")
        }

        func asset(from row: SQLiteRow) -> Asset? {
            guard let assetId = row.text(id) else { return nil }
            let rawCamera = row.text(camera) ?? ""
            let cameraName = cameras[rawCamera] ?? {
                let normalized = shared(MetadataReader.normalizedCameraName(rawCamera))
                cameras[rawCamera] = normalized
                return normalized
            }()
            func date(_ column: Int32) -> Date? {
                row.isNull(column) ? nil : Date(timeIntervalSince1970: row.double(column))
            }
            return Asset(
                id: assetId, pid: row.int(pid), ori: row.text(ori) ?? "l",
                thumb: row.text(thumb) ?? "", preview: row.text(preview) ?? "",
                filename: row.text(filename) ?? "", type: row.text(type) ?? "",
                isRaw: row.int(isRaw) != 0, folderId: sharedText(row, folderId),
                folderName: sharedText(row, folderName),
                date: Date(timeIntervalSince1970: row.double(captureDate)),
                width: row.int(width), height: row.int(height),
                orientation: row.isNull(orientation) ? 1 : row.int(orientation),
                camera: cameraName, lens: sharedText(row, lens),
                focal: row.int(focal), aperture: row.double(aperture),
                shutter: row.text(shutter) ?? "", iso: row.int(iso),
                colorSpace: sharedText(row, colorSpace),
                hasICCProfile: row.int(hasICCProfile) != 0,
                fileMB: row.double(fileMB),
                fileModifiedAt: date(fileModifiedAt), fileCreatedAt: date(fileCreatedAt),
                rating: row.int(rating),
                flag: Flag(rawValue: row.text(flag) ?? "none") ?? .none,
                colorLabel: row.text(colorLabel).flatMap { ColorLabel(rawValue: $0) },
                keywords: keywordSet(row), title: row.text(title) ?? "", caption: row.text(caption) ?? "",
                author: sharedText(row, author), copyright: sharedText(row, copyright),
                makerNotes: row.text(makerNotes) ?? "",
                project: sharedText(row, project), client: sharedText(row, client),
                location: row.text(location) ?? "",
                gps: (row.double(gpsLat), row.double(gpsLon)),
                gpsAltitude: row.isNull(gpsAltitude) ? nil : row.double(gpsAltitude),
                status: AssetStatus(rawValue: row.text(status) ?? "ready") ?? .ready,
                importedAt: Date(timeIntervalSince1970: row.double(importedAt)),
                deleted: row.int(deleted) != 0,
                localPath: row.text(localPath),
                captureDateSource: row.isNull(captureDateSource)
                    ? "EXIF · DateTimeOriginal" : sharedText(row, captureDateSource),
                contentHash: row.text(contentHash), quickHash: row.text(quickHash),
                isDemo: row.int(isDemo) != 0, faces: row.int(faces),
                perceptualHash: row.isNull(perceptualHash) ? nil : UInt64(bitPattern: Int64(row.int(perceptualHash))),
                masterId: masterId < 0 ? nil : row.text(masterId), copyName: copyName < 0 ? nil : row.text(copyName),
                duration: duration < 0 || row.isNull(duration) ? nil : row.double(duration))
        }

        private func shared(_ value: String) -> String {
            if let existing = strings[value] { return existing }
            strings[value] = value
            return value
        }

        private func sharedText(_ row: SQLiteRow, _ column: Int32) -> String {
            let bytes = row.bytes(column)
            // up to 15 UTF-8 bytes live inline in the String itself: nothing to share
            return bytes.count <= 15 ? String(decoding: bytes, as: UTF8.self) : shared(String(decoding: bytes, as: UTF8.self))
        }

        private func keywordSet(_ row: SQLiteRow) -> [String] {
            let bytes = row.bytes(keywords)
            guard bytes.count > 2 else { return [] }   // NULL, "" or "[]"
            let raw = String(decoding: bytes, as: UTF8.self)
            if let known = keywordSets[raw] { return known }
            let parsed = (Self.parseKeywords(bytes) ?? Self.parseKeywordsSlowly(raw)).map(shared)
            keywordSets[raw] = parsed
            return parsed
        }

        /// The compact arrays the catalog writes, `["a","b\/c"]`, straight from bytes; nil for
        /// anything else (other escapes, spacing), which goes through JSONSerialization.
        static func parseKeywords(_ bytes: UnsafeBufferPointer<UInt8>) -> [String]? {
            let quote: UInt8 = 0x22, backslash: UInt8 = 0x5C, slash: UInt8 = 0x2F, comma: UInt8 = 0x2C
            guard bytes.count >= 4, bytes[0] == 0x5B, bytes[1] == quote,
                  bytes[bytes.count - 2] == quote, bytes[bytes.count - 1] == 0x5D else { return nil }
            var result: [String] = []
            var current: [UInt8] = []
            let end = bytes.count - 2
            var i = 2
            while i < end {
                let byte = bytes[i]
                if byte == backslash {
                    guard i + 1 < end, bytes[i + 1] == slash else { return nil }
                    current.append(slash)
                    i += 2
                } else if byte == quote {
                    guard i + 2 < end, bytes[i + 1] == comma, bytes[i + 2] == quote else { return nil }
                    result.append(String(decoding: current, as: UTF8.self))
                    current.removeAll(keepingCapacity: true)
                    i += 3
                } else {
                    current.append(byte)
                    i += 1
                }
            }
            result.append(String(decoding: current, as: UTF8.self))
            return result
        }

        /// JSONSerialization hands back bridged strings; copy them into native ones.
        static func parseKeywordsSlowly(_ raw: String) -> [String] {
            let parsed = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String] ?? []
            return parsed.map { String(decoding: Array($0.utf8), as: UTF8.self) }
        }
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
            // decoded as the whole catalog is, so a page's photos are those it later loads
            let decoder = AssetRowDecoder(columns: Self.columnNames)
            assets = try db.queryRows(
                """
                SELECT \(Self.columns)
                FROM assets AS a
                WHERE \(sql.predicate)
                ORDER BY \(Self.orderClause(for: query.sort))
                LIMIT ? OFFSET ?;
                """,
                sql.params + [.int(safeLimit), .int(safeOffset)],
                transform: decoder.asset(from:)
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
            } else if filters.type == "VIDEO" {
                append(Self.videoPredicate)
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
            if condition.value == "VIDEO" {
                return AssetSQL(predicate: Self.videoPredicate, params: [])
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
              .text("online"), .text(Self.iso(Date())),
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

    // ---------- sidecars changed by other apps ----------
    /// Each photo's sidecar modification time (seconds since 1970) as of our last read or write.
    func loadXMPSyncTimes() throws -> [String: Double] {
        var result: [String: Double] = [:]
        for row in try db.query("SELECT asset_id, modified_at FROM xmp_sync;") {
            if let id = row.text("asset_id"), let time = row.double("modified_at") { result[id] = time }
        }
        return result
    }

    func saveXMPSyncTimes(_ times: [String: Double]) throws {
        guard !times.isEmpty else { return }
        try db.transaction {
            for (id, time) in times {
                try db.run("""
                INSERT INTO xmp_sync(asset_id, modified_at) VALUES(?, ?)
                ON CONFLICT(asset_id) DO UPDATE SET modified_at=excluded.modified_at;
                """, [.text(id), .double(time)])
            }
        }
    }

    // ---------- develop history and snapshots ----------
    /// A photo's develop steps, oldest first.
    func loadDevelopHistory(_ assetId: String) throws -> [DevelopHistoryStep] {
        try db.query("""
        SELECT seq, name, created_at, settings FROM develop_history WHERE asset_id=? ORDER BY seq;
        """, [.text(assetId)]).compactMap { row in
            guard let seq = row.int("seq"), let name = row.text("name"), let json = row.text("settings") else { return nil }
            return DevelopHistoryStep(seq: seq, name: name, date: Self.date(row.text("created_at")) ?? .distantPast,
                                      json: json)
        }
    }

    /// Adds a step to each photo's history, dropping the oldest beyond the limit. Returns the
    /// steps as stored.
    @discardableResult
    func appendDevelopHistory(_ steps: [String: (name: String, settings: DevelopSettings)], date: Date = .now) throws
        -> [String: DevelopHistoryStep] {
        var stored: [String: DevelopHistoryStep] = [:]
        let created = Self.iso(date)
        try db.transaction {
            for (id, step) in steps {
                let json = DevelopHistoryStep.json(step.settings)
                // one statement numbers and inserts the step
                guard let seq = try db.queryMap("""
                INSERT INTO develop_history(asset_id, seq, name, created_at, settings)
                SELECT ?, COALESCE(MAX(seq), 0) + 1, ?, ?, ? FROM develop_history WHERE asset_id=?
                RETURNING seq;
                """, [.text(id), .text(step.name), .text(created), .text(json), .text(id)],
                                        transform: { $0.int("seq") }).first ?? nil else { continue }
                // trimming only once the history is long enough to need it
                if seq > DevelopHistoryStep.limit {
                    try db.run("DELETE FROM develop_history WHERE asset_id=? AND seq<=?;",
                               [.text(id), .int(seq - DevelopHistoryStep.limit)])
                }
                stored[id] = DevelopHistoryStep(seq: seq, name: step.name, date: date, json: json)
            }
        }
        return stored
    }

    /// Takes each photo's newest step away (an undone edit).
    func removeLastDevelopHistory(_ assetIds: [String]) throws {
        try db.transaction {
            for id in assetIds {
                try db.run("""
                DELETE FROM develop_history WHERE asset_id=?
                  AND seq=(SELECT MAX(seq) FROM develop_history WHERE asset_id=?);
                """, [.text(id), .text(id)])
            }
        }
    }

    func clearDevelopHistory(_ assetId: String) throws {
        try db.run("DELETE FROM develop_history WHERE asset_id=?;", [.text(assetId)])
    }

    /// A photo's snapshots, oldest first.
    func loadDevelopSnapshots(_ assetId: String) throws -> [DevelopSnapshot] {
        let decoder = JSONDecoder()
        return try db.query("""
        SELECT id, name, created_at, settings FROM develop_snapshots WHERE asset_id=? ORDER BY created_at, rowid;
        """, [.text(assetId)]).compactMap { row in
            guard let id = row.text("id"), let name = row.text("name"), let json = row.text("settings"),
                  let settings = try? decoder.decode(DevelopSettings.self, from: Data(json.utf8)) else { return nil }
            return DevelopSnapshot(id: id, name: name, date: Self.date(row.text("created_at")) ?? .distantPast,
                                   settings: settings)
        }
    }

    func saveDevelopSnapshot(_ snapshot: DevelopSnapshot, for assetId: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = String(decoding: try encoder.encode(snapshot.settings), as: UTF8.self)
        try db.run("""
        INSERT INTO develop_snapshots(id, asset_id, name, created_at, settings) VALUES(?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET name=excluded.name, settings=excluded.settings;
        """, [.text(snapshot.id), .text(assetId), .text(snapshot.name), .text(Self.iso(snapshot.date)), .text(json)])
    }

    func deleteDevelopSnapshot(_ id: String) throws {
        try db.run("DELETE FROM develop_snapshots WHERE id=?;", [.text(id)])
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
        SET root_id=COALESCE(?,root_id), state=?, total_count=?, imported_count=?, skipped_count=?, failed_count=?,
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

    func loadImportCheckpoints(sessionId: String) throws -> [ImportFileCheckpoint] {
        try db.query("SELECT * FROM import_files WHERE session_id=?;", [.text(sessionId)])
            .compactMap(Self.importCheckpoint(from:))
    }

    /// Photos removed from the catalog whose originals lie in `folder`: a referenced photo's ID
    /// comes from its path, so these are the rows an import of the folder would find taken.
    func removedAssetIds(under folder: URL) throws -> Set<String> {
        var ids: Set<String> = []
        for path in Set([folder.path, folder.resolvingSymlinksInPath().path]) {
            let prefix = path.hasSuffix("/") ? path : path + "/"
            for row in try db.query("""
            SELECT id FROM assets WHERE deleted=1 AND is_demo=0 AND substr(local_path, 1, length(?)) = ?;
            """, [.text(prefix), .text(prefix)]) {
                if let id = row.text("id") { ids.insert(id) }
            }
        }
        return ids
    }

    /// Returns only this transaction's additions. Counters come from the persisted session;
    /// processing progress, failure details and phase remain owned by the caller.
    func saveImportBatch(_ results: [ImportFileResult], run: ImportRun,
                         options: ImportOptionsSnapshot) throws -> CommittedImportBatch {
        var committedRun = run
        var fresh: [Asset] = []
        var writes: [String: ImportFileCheckpoint] = [:]
        var source: SourceRootRecord?
        var settings: [String: DevelopSettings] = [:]
        var revived: Set<String> = []
        let revivable = options.revivableIds ?? []
        // a file system call: outside the transaction, a slow volume would hold the catalog's lock
        let volume = VolumeMonitor.volumeIdentifier(for: URL(fileURLWithPath: run.sourcePath))
        try db.transaction {
            guard let session = try db.query("SELECT * FROM import_sessions WHERE id=?;", [.text(run.id.uuidString)])
                .first.flatMap(Self.importSession(from:)) else {
                throw DBError.step("Import session not found: \(run.id.uuidString)")
            }
            committedRun.saved = session.importedCount
            committedRun.skipped = session.skippedCount
            committedRun.failed = session.failedCount
            var newIds: Set<String> = []
            var newKeys: Set<String> = []
            let skipExact = options.duplicateStrategy == ImportDuplicateStrategy.skipExact.rawValue
            for result in results {
                let previous: ImportFileCheckpoint?
                if let pending = writes[result.source.path] {
                    previous = pending
                } else {
                    previous = try db.query("SELECT * FROM import_files WHERE session_id=? AND source_path=?;",
                                            [.text(run.id.uuidString), .text(result.source.path)])
                        .first.flatMap(Self.importCheckpoint(from:))
                }
                if let previous, previous.source == result.source, previous.outcome != .failed { continue }

                var outcome: ImportFileCheckpoint.Outcome = result.reason == nil ? .skipped : .failed
                if let asset = result.asset, !asset.isDemo, !newIds.contains(asset.id),
                   case let existing = try db.query("SELECT deleted FROM assets WHERE id=?;", [.text(asset.id)]).first,
                   // a photo removed before this import began comes back; one removed while it runs (even
                   // after it came back) stays removed
                   existing == nil || (existing?.bool("deleted") == true && revivable.contains(asset.id)
                                       && previous?.outcome != .saved) {
                    let key = HashService.exactDuplicateKey(asset)
                    var duplicate = key.map { newKeys.contains($0) } ?? false
                    if skipExact, !duplicate, let hash = asset.contentHash, let key {
                        // Only inspect this indexed hash bucket; retain Swift's byte rounding.
                        duplicate = try db.query("""
                        SELECT file_mb FROM assets INDEXED BY idx_assets_hash
                        WHERE content_hash=? AND is_demo=0 AND deleted=0;
                        """, [.text(hash)]).contains {
                            HashService.exactDuplicateKey(fileMB: $0.double("file_mb") ?? 0, contentHash: hash) == key
                        }
                    }
                    if !skipExact || !duplicate {
                        fresh.append(asset)
                        newIds.insert(asset.id)
                        if existing != nil { revived.insert(asset.id) }
                        if let key { newKeys.insert(key) }
                        outcome = .saved
                    }
                }
                if previous?.outcome == .saved { committedRun.saved -= 1 }
                if previous?.outcome == .skipped { committedRun.skipped -= 1 }
                if previous?.outcome == .failed { committedRun.failed -= 1 }
                if outcome == .saved { committedRun.saved += 1 }
                if outcome == .skipped { committedRun.skipped += 1 }
                if outcome == .failed { committedRun.failed += 1 }
                writes[result.source.path] = ImportFileCheckpoint(source: result.source, assetId: result.asset?.id,
                                                                 outcome: outcome, reason: result.reason)
            }
            fresh = ImportPostActionService.apply(to: fresh, actions: options.postActions)
            let rootId = run.sourceId ?? fresh.first?.folderId ?? results.compactMap(\.asset).first?.folderId
            if let rootId {
                let folder = URL(fileURLWithPath: run.sourcePath)
                let bookmark = try db.query("SELECT bookmark_data FROM source_roots WHERE id=?;", [.text(rootId)])
                    .first?.blob("bookmark_data")
                source = SourceRootRecord(id: rootId, displayName: folder.lastPathComponent, pathHint: folder.path,
                                          bookmarkData: bookmark ?? options.bookmark, managementMode: run.mode.rawValue,
                                          status: "online", volumeIdentifier: volume)
            }
            committedRun.sourceId = rootId
            settings = try writeImportBatchRows(fresh, revived: revived, checkpoints: Array(writes.values),
                                                run: committedRun, source: source, options: options)
        }
        return CommittedImportBatch(assets: fresh, checkpoints: writes.values.sorted { $0.source.path < $1.source.path },
                                    run: committedRun, source: source, developSettings: settings, revivedIds: revived)
    }

    /// A checkpoint only becomes resumable together with its assets and initial edits.
    private func writeImportBatchRows(_ assets: [Asset], revived: Set<String>, checkpoints: [ImportFileCheckpoint],
                                      run: ImportRun, source: SourceRootRecord?, options: ImportOptionsSnapshot) throws
        -> [String: DevelopSettings] {
        try upsertRows(assets.filter { !revived.contains($0.id) }, updatingExisting: false)
        // a removed photo's row comes back in place, with the albums it was in
        try upsertRows(assets.filter { revived.contains($0.id) }, updatingExisting: true)
        if let source {
            try addSourceRoot(id: source.id, displayName: source.displayName, path: source.pathHint,
                              bookmark: source.bookmarkData, mode: run.mode,
                              volumeIdentifier: source.volumeIdentifier)
        }
        let now = Self.iso(.now)
        var initialSettings: [String: DevelopSettings] = [:]
        for asset in assets {
            // a returning photo keeps the edits it had rather than taking the import's
            if revived.contains(asset.id), try !db.query("""
            SELECT 1 FROM develop_settings WHERE asset_id=? UNION ALL SELECT 1 FROM develop_history WHERE asset_id=? LIMIT 1;
            """, [.text(asset.id), .text(asset.id)]).isEmpty { continue }
            let steps = options.developSteps(for: asset)
            if let settings = steps.last?.settings, !settings.isNeutral {
                try db.run("INSERT INTO develop_settings(asset_id, settings, updated_at) VALUES(?,?,?);",
                           [.text(asset.id), .text(DevelopHistoryStep.json(settings)), .text(now)])
                initialSettings[asset.id] = settings
            }
            for (index, step) in steps.enumerated() {
                try db.run("INSERT INTO develop_history(asset_id,seq,name,created_at,settings) VALUES(?,?,?,?,?);",
                           [.text(asset.id), .int(index + 1), .text(step.name), .text(now),
                            .text(DevelopHistoryStep.json(step.settings))])
            }
        }
        if let albumId = options.albumId, !assets.isEmpty {
            try db.run("""
            INSERT INTO albums(id,type,name,sort_order,created_at,updated_at)
            VALUES(?,'album',?,(SELECT COALESCE(MAX(sort_order),0)+1 FROM albums),?,?)
            ON CONFLICT(id) DO UPDATE SET updated_at=excluded.updated_at;
            """, [.text(albumId), .text(options.albumName), .text(now), .text(now)])
            let position = try db.query("SELECT COALESCE(MAX(position),-1)+1 AS n FROM album_assets WHERE album_id=?;",
                                        [.text(albumId)]).first?.int("n") ?? 0
            for (offset, asset) in assets.enumerated() {
                try db.run("INSERT OR IGNORE INTO album_assets(album_id,asset_id,position,added_at) VALUES(?,?,?,?);",
                           [.text(albumId), .text(asset.id), .int(position + offset), .text(now)])
            }
        }
        for checkpoint in checkpoints {
            try db.run("""
            INSERT INTO import_files(session_id,source_path,file_size,modified_at,asset_id,outcome,reason)
            VALUES(?,?,?,?,?,?,?)
            ON CONFLICT(session_id,source_path) DO UPDATE SET
              file_size=excluded.file_size,modified_at=excluded.modified_at,asset_id=excluded.asset_id,
              outcome=excluded.outcome,reason=excluded.reason;
            """, [.text(run.id.uuidString), .text(checkpoint.source.path),
                  checkpoint.source.byteCount.map(SQLValue.int) ?? .null,
                  checkpoint.source.modifiedAt.map(SQLValue.double) ?? .null,
                  checkpoint.assetId.map(SQLValue.text) ?? .null, .text(checkpoint.outcome.rawValue),
                  checkpoint.reason.map(SQLValue.text) ?? .null])
        }
        try updateImportSession(id: run.id.uuidString, rootId: source?.id,
                                state: run.phase == .paused ? "paused" : "running", totalCount: run.total,
                                importedCount: run.saved, skippedCount: run.skipped, failedCount: run.failed)
        return initialSettings
    }

    private static func importCheckpoint(from row: Row) -> ImportFileCheckpoint? {
        guard let path = row.text("source_path"), let raw = row.text("outcome"),
              let outcome = ImportFileCheckpoint.Outcome(rawValue: raw) else { return nil }
        return ImportFileCheckpoint(source: ImportSourceFile(path: path, byteCount: row.int("file_size"),
                                                             modifiedAt: row.double("modified_at")),
                                    assetId: row.text("asset_id"), outcome: outcome, reason: row.text("reason"))
    }

    // ---------- jobs (§10.2 / §13) ----------
    func startImportJob(id: String, sessionId: String, sourcePath: String, mode: ImportMode,
                        autoTag: Bool, archiveRule: ManagedArchiveRule? = nil,
                        readSidecar: Bool? = nil, previewMaxPixel: Int? = nil,
                        options: ImportOptionsSnapshot? = nil,
                        priority: Int = 10, createdAt: Date = .now) throws {
        let payload = Self.importJobPayload(sessionId: sessionId, sourcePath: sourcePath,
                                            mode: mode, autoTag: autoTag,
                                            archiveRule: archiveRule, readSidecar: readSidecar,
                                            previewMaxPixel: previewMaxPixel, options: options)
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
            "createdAt": existing["createdAt"] as? String ?? Self.iso(Date()),
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
                                         readSidecar: Bool?, previewMaxPixel: Int?,
                                         options: ImportOptionsSnapshot?) -> String {
        let payload = ImportJobPayload(sessionId: sessionId, sourcePath: sourcePath,
                                       mode: mode.rawValue, autoTag: autoTag,
                                       archiveRule: archiveRule?.rawValue,
                                       readSidecar: readSidecar,
                                       previewMaxPixel: previewMaxPixel, options: options)
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
            a.masterId.map { SQLValue.text($0) } ?? .null,
            a.copyName.map { SQLValue.text($0) } ?? .null,
            a.duration.map { SQLValue.double($0) } ?? .null,
        ]
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
