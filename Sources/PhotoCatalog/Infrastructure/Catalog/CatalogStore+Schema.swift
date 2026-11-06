import Foundation

extension CatalogStore {
    // ---------- schema ----------
    func migrate() throws {
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
}
