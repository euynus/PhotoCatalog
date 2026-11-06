import Foundation

extension CatalogStore {
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

    /// What the catalog has of a photo to tell whether a file is its: where its original is,
    /// whether it was removed, and what it knows of the file — the hash of its bytes, and the
    /// shot (camera, and capture time as the catalog has it).
    struct AssetPathRecord: Sendable {
        let localPath: String?
        let deleted: Bool
        let contentHash: String?
        let camera: String
        let captureDate: Date
    }

    /// That record for the photo with `id`, if the catalog has one — removed photos included,
    /// as their ids stay taken.
    func assetPathRecord(id: String) -> AssetPathRecord? {
        guard let row = try? db.query("""
        SELECT local_path, deleted, content_hash, camera, capture_date FROM assets WHERE id=?;
        """, [.text(id)]).first else { return nil }
        return AssetPathRecord(localPath: row.text("local_path"), deleted: row.bool("deleted"),
                               contentHash: row.text("content_hash"), camera: row.text("camera") ?? "",
                               captureDate: Date(timeIntervalSince1970: row.double("capture_date") ?? 0))
    }

    /// The photos removed from the catalog that have an original (virtual copies aside): folder
    /// watching leaves their files alone, as only an import brings a removed photo back.
    func removedOriginals() throws -> [Asset] {
        let decoder = AssetRowDecoder(columns: Self.columnNames)
        return try db.queryRows("""
        SELECT \(Self.columns) FROM assets
        WHERE deleted=1 AND is_demo=0 AND master_id IS NULL AND local_path IS NOT NULL;
        """, transform: decoder.asset(from:))
    }

    /// Files an import left out as exact duplicates of photos in the catalog (Skip Exact
    /// Duplicates): folder watching leaves them alone too, as only an import decides on them.
    func skippedDuplicatePaths() throws -> Set<String> {
        Set(try db.query("""
        SELECT DISTINCT source_path FROM import_files WHERE outcome='skipped' AND reason=?;
        """, [.text(ImportFileCheckpoint.skippedAsDuplicate)]).compactMap { $0.text("source_path") })
    }

    /// Photos removed from the catalog whose originals lie in `folder`: a removed photo keeps
    /// its id, which an import finds again for a file at the photo's path.
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
                var reason = result.reason
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
                    } else if outcome == .skipped {
                        reason = ImportFileCheckpoint.skippedAsDuplicate
                    }
                }
                if previous?.outcome == .saved { committedRun.saved -= 1 }
                if previous?.outcome == .skipped { committedRun.skipped -= 1 }
                if previous?.outcome == .failed { committedRun.failed -= 1 }
                if outcome == .saved { committedRun.saved += 1 }
                if outcome == .skipped { committedRun.skipped += 1 }
                if outcome == .failed { committedRun.failed += 1 }
                writes[result.source.path] = ImportFileCheckpoint(source: result.source, assetId: result.asset?.id,
                                                                 outcome: outcome, reason: reason)
            }
            fresh = ImportPostActionService.apply(to: fresh, actions: options.postActions)
            // a returning photo comes back as the catalog had it, as its develop settings do below
            if !revived.isEmpty {
                let decoder = AssetRowDecoder(columns: Self.columnNames)
                fresh = try fresh.map { asset in
                    guard revived.contains(asset.id), let removed = try db.queryRows(
                        "SELECT \(Self.columns) FROM assets WHERE id=?;", [.text(asset.id)],
                        transform: decoder.asset(from:)).first else { return asset }
                    return ImportCoordinator.returningPhoto(asset, removed: removed)
                }
            }
            let rootId = run.sourceId ?? fresh.first?.folderId ?? results.compactMap(\.asset).first?.folderId
            if let rootId {
                let folder = URL(fileURLWithPath: run.sourcePath)
                let bookmark = try db.query("SELECT bookmark_data FROM source_roots WHERE id=?;", [.text(rootId)])
                    .first?.blob("bookmark_data")
                // the mode the folder keeps (addSourceRoot's), not just this import's
                let mode = Self.managementMode(keeping: try existingManagementMode(id: rootId), importing: run.mode)
                source = SourceRootRecord(id: rootId, displayName: folder.lastPathComponent, pathHint: folder.path,
                                          bookmarkData: bookmark ?? options.bookmark, managementMode: mode,
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
}
