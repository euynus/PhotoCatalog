import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

extension PipelineCheck.Run {
    /// Part of step 3: creates the catalog the later steps use, then checks its package, its
    /// manifest, launch arguments that name it, and schema migrations on scratch catalogs.
    func catalogPackage() {
        guard let store = try? CatalogStore(packageURL: tmp.appendingPathComponent("Lib.photolibrary")) else {
            print("  ✗ FAIL could not create catalog"); exit(1)
        }
        self.store = store
        check(fm.fileExists(atPath: store.cacheURL.path)
              && fm.fileExists(atPath: store.configURL.path)
              && fm.fileExists(atPath: store.logsURL.path)
              && fm.fileExists(atPath: store.tempURL.path),
              "catalog package created cache/config/logs/temp directories")
        let manifestURL = store.packageURL.appendingPathComponent("manifest.json")
        let manifest = (try? Data(contentsOf: manifestURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let manifestSchema = manifest?["schemaVersion"] as? Int
        let currentSchema = store.db.scalarInt("SELECT COALESCE(MAX(version),0) FROM schema_migrations;")
        check(manifestSchema == currentSchema, "catalog manifest records current schema version")
        let launchPath = store.packageURL.path
        let launchFileURL = store.packageURL.absoluteString
        check(AppState.launchCatalogURL(from: ["PhotoCatalog", "--ignored", launchPath])?.path == launchPath
              && AppState.launchCatalogURL(from: ["PhotoCatalog", launchFileURL])?.path == launchPath,
              "launch arguments recognize .photolibrary paths")
        let staleManifestLibrary = tmp.appendingPathComponent("StaleManifest.photolibrary")
        do {
            let staleStore = try CatalogStore(packageURL: staleManifestLibrary)
            let staleManifestURL = staleStore.packageURL.appendingPathComponent("manifest.json")
            let staleManifest: [String: Any] = [
                "libraryVersion": 1, "schemaVersion": 1,
                "createdAt": "2026-01-01T00:00:00Z", "appBuild": "1.0.0", "uuid": "stable-id",
            ]
            let data = try JSONSerialization.data(withJSONObject: staleManifest, options: .prettyPrinted)
            try data.write(to: staleManifestURL)
        } catch {
            check(false, "stale manifest fixture created")
        }
        if let reopened = try? CatalogStore(packageURL: staleManifestLibrary),
           let data = try? Data(contentsOf: reopened.packageURL.appendingPathComponent("manifest.json")),
           let updated = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let schema = updated["schemaVersion"] as? Int
            let current = reopened.db.scalarInt("SELECT COALESCE(MAX(version),0) FROM schema_migrations;")
            check(schema == current && updated["uuid"] as? String == "stable-id",
                  "stale catalog manifest updates schema while preserving identity")
        } else {
            check(false, "stale catalog manifest updates schema while preserving identity")
        }
        let legacySearchLibrary = tmp.appendingPathComponent("LegacySearch.photolibrary")
        do {
            let legacyStore = try CatalogStore(packageURL: legacySearchLibrary)
            var legacyAsset = DemoData.assets[0]
            legacyAsset.isDemo = false
            legacyAsset.deleted = false
            legacyAsset.title = "Migration Search Needle"
            try legacyStore.upsert([legacyAsset])
            try legacyStore.db.run("DELETE FROM schema_migrations WHERE version>=16;")
            try legacyStore.db.execChecked("DROP TABLE asset_search;")
            try legacyStore.db.execChecked("""
            CREATE VIRTUAL TABLE asset_search USING fts5(
              asset_id UNINDEXED, filename, title, caption, keywords, camera, lens,
              tokenize='unicode61');
            """)
            try legacyStore.db.run("""
            INSERT INTO asset_search(asset_id, filename, title, caption, keywords, camera, lens)
            VALUES(?,?,?,?,?,?,?);
            """, [.text(legacyAsset.id), .text(legacyAsset.filename), .text(legacyAsset.title),
                  .text(legacyAsset.caption), .text(legacyAsset.keywords.joined(separator: " ")),
                  .text(legacyAsset.camera), .text(legacyAsset.lens)])
        } catch {
            check(false, "schema 15 search fixture created")
        }
        if let migrated = try? CatalogStore(packageURL: legacySearchLibrary) {
            let version = migrated.db.scalarInt("SELECT COALESCE(MAX(version),0) FROM schema_migrations;")
            let backups = (try? fm.contentsOfDirectory(at: migrated.backupsURL,
                                                       includingPropertiesForKeys: nil)) ?? []
            check(version == CatalogStore.latestSchemaVersion && !(migrated.search("tion Sea") ?? []).isEmpty,
                  "schema 15 migration rebuilds the substring search index")
            check(backups.contains { $0.lastPathComponent.hasPrefix("catalog-pre-migration-v15-") },
                  "schema 15 migration keeps a pre-migration backup")
        } else {
            check(false, "schema 15 migration rebuilds the substring search index")
            check(false, "schema 15 migration keeps a pre-migration backup")
        }
        let futureLibrary = tmp.appendingPathComponent("Future.photolibrary")
        try? fm.createDirectory(at: futureLibrary, withIntermediateDirectories: true)
        do {
            let futureDB = try Database(path: futureLibrary.appendingPathComponent("catalog.sqlite").path)
            futureDB.exec("CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT);")
            try futureDB.run("INSERT INTO schema_migrations(version, applied_at) VALUES(999, ?);",
                             [.text("2026-01-01T00:00:00Z")])
        } catch {
            check(false, "future schema fixture created")
        }
        do {
            _ = try CatalogStore(packageURL: futureLibrary)
            check(false, "future catalog schema rejected")
        } catch CatalogStoreError.incompatibleSchema(let current, let supported) {
            check(current == 999 && supported < current, "future catalog schema rejected")
        } catch {
            check(false, "future catalog schema rejected")
        }
        let rollbackLibrary = tmp.appendingPathComponent("Rollback.photolibrary")
        try? fm.createDirectory(at: rollbackLibrary, withIntermediateDirectories: true)
        do {
            let rollbackDB = try Database(path: rollbackLibrary.appendingPathComponent("catalog.sqlite").path)
            try rollbackDB.execChecked("CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT);")
            try rollbackDB.execChecked("CREATE TABLE assets (id TEXT PRIMARY KEY, gps_altitude REAL);")
            try rollbackDB.run("INSERT INTO schema_migrations(version, applied_at) VALUES(8, ?);",
                               [.text("2026-01-01T00:00:00Z")])
        } catch {
            check(false, "rollback fixture created")
        }
        do {
            _ = try CatalogStore(packageURL: rollbackLibrary)
            check(false, "failed migration rolls back partial schema")
            check(false, "failed migration keeps pre-migration backup")
        } catch {
            let rollbackDB = try? Database(path: rollbackLibrary.appendingPathComponent("catalog.sqlite").path)
            let version = rollbackDB?.scalarInt("SELECT COALESCE(MAX(version),0) FROM schema_migrations;") ?? -1
            let columns = Set(((try? rollbackDB?.query("PRAGMA table_info(assets);")) ?? [])
                .compactMap { $0.text("name") })
            let backups = (try? fm.contentsOfDirectory(at: rollbackLibrary.appendingPathComponent("Backups"),
                                                       includingPropertiesForKeys: nil)) ?? []
            check(version == 8 && columns.contains("gps_altitude") && !columns.contains("has_icc_profile"),
                  "failed migration rolls back partial schema")
            check(backups.contains { $0.lastPathComponent.hasPrefix("catalog-pre-migration-v8-") },
                  "failed migration keeps pre-migration backup")
        }
    }

    /// 4. persist + reload roundtrip
    func persistReloadRoundtrip() {
        try? store.upsert(assets)
        let reloaded = (try? store.loadAssets()) ?? []
        check(reloaded.count == 7, "reloaded 7 assets from SQLite — got \(reloaded.count)")
        let firstPage = try? store.loadAssetPage(offset: 0, limit: 3)
        let secondPage = try? store.loadAssetPage(offset: 3, limit: 3)
        let pagedIds = (firstPage?.assets ?? []).map(\.id) + (secondPage?.assets ?? []).map(\.id)
        check(firstPage?.totalCount == 7 && firstPage?.assets.count == 3
              && secondPage?.assets.count == 3 && Set(pagedIds).count == 6,
              "asset paging returns a stable total and non-overlapping pages")
        check(reloaded.allSatisfy { $0.perceptualHash != nil }, "perceptual hash computed at import + persisted")
        let reloadedTimestamped = reloaded.first { $0.filename == "IMG_0000.jpg" }
        check(reloadedTimestamped?.fileModifiedAt.map { abs($0.timeIntervalSince(fixedModifiedAt)) < 1 } == true
              && reloadedTimestamped?.fileCreatedAt != nil,
              "file mtime/ctime persisted")
        check(reloadedTimestamped?.hasICCProfile == timestampedAsset?.hasICCProfile,
              "ICC profile flag persisted")
        check(reloadedTimestamped?.gpsAltitude.map { abs($0 - fixedGPS.altitude) < 0.1 } == true,
              "GPS altitude persisted")
        album = Album(id: "album-test", name: "Pipeline Picks",
                      assetIds: Array(assets.prefix(3).map(\.id)))
        try? store.saveAlbum(album)
        let loadedAlbum = (try? store.loadAlbums())?.first { $0.id == album.id }
        check(loadedAlbum?.assetIds == album.assetIds, "manual album persisted membership")
        // regression: a metadata edit (upsert) must NOT drop the asset from manual albums.
        // INSERT OR REPLACE would delete-then-insert and cascade album_assets via the FK.
        var editedInAlbum = assets[0]
        editedInAlbum.rating = 5
        try? store.upsert([editedInAlbum])
        let albumAfterEdit = (try? store.loadAlbums())?.first { $0.id == album.id }
        check(albumAfterEdit?.assetIds == album.assetIds,
              "manual album membership survives a metadata edit (no FK cascade on upsert)")
        // the quick collection is kept as an album under a reserved id, and loads apart from albums
        let quickIds = [reloaded[1].id, reloaded[2].id]
        let reopenedQuick: Set<String>? = MainActor.assumeIsolated {
            let app = AppState.selfCheckFixture(store: store)
            app.runsBackgroundMaintenance = false
            app.applyLoadedCatalogForScaleCheck(reloaded, from: store)
            app.selectedIds = Set(quickIds)
            app.toggleQuickCollection()
            let reopened = AppState.selfCheckFixture(store: store)
            reopened.runsBackgroundMaintenance = false
            reopened.applyLoadedCatalogForScaleCheck(reloaded, from: store)
            let listedAsAlbum = reopened.albums.contains { $0.id == AppState.quickCollectionID }
            return listedAsAlbum ? nil : reopened.quickCollection
        }
        check(reopenedQuick == Set(quickIds), "the quick collection survives reopening, apart from albums")
        virtualCopyLifecycle(reloaded)
        externalEditor(reloaded)
        externallyChangedSidecars(reloaded)
        albumSetNesting(reloaded)
        photoRenaming(reloaded)
        catalogRecords()
    }

    /// Part of step 4: smart albums, source roots, import sessions and import jobs persist.
    func catalogRecords() {
        let smartRule = SmartRule(match: "all", conditions: [
            SmartCondition(field: "type", op: "=", value: assets[0].type),
        ])
        let smartAlbum = SmartAlbum(id: "smart-test", name: "Pipeline Smart",
                                    rule: smartRule, count: 0)
        try? store.saveSmartAlbum(smartAlbum)
        let loadedSmart = (try? store.loadSmartAlbums())?.first { $0.id == smartAlbum.id }
        check(loadedSmart?.rule == smartRule, "smart album persisted rule")
        try? store.addSourceRoot(id: "src-test-root", displayName: "source", path: src.path,
                                 bookmark: nil, volumeIdentifier: "volume-a")
        let roots = (try? store.loadSourceRoots()) ?? []
        check(roots.contains { $0.id == "src-test-root" && $0.pathHint == src.path
            && $0.volumeIdentifier == "volume-a"
        },
              "source root persisted and reloaded")
        try? store.updateSourceRootStatus(id: "src-test-root", status: "offline")
        let updatedRoot = (try? store.loadSourceRoots())?.first { $0.id == "src-test-root" }
        check(updatedRoot?.status == "offline", "source root status update persisted")
        let reauthPath = src.appendingPathComponent("reauthorized")
        try? fm.createDirectory(at: reauthPath, withIntermediateDirectories: true)
        try? store.updateSourceRootAccess(id: "src-test-root", displayName: "reauthorized",
                                          path: reauthPath.path, bookmark: Data([1, 2, 3]),
                                          volumeIdentifier: "volume-b")
        let reauthorizedRoot = (try? store.loadSourceRoots())?.first { $0.id == "src-test-root" }
        check(reauthorizedRoot?.pathHint == reauthPath.path && reauthorizedRoot?.status == "online"
              && reauthorizedRoot?.bookmarkData == Data([1, 2, 3])
              && reauthorizedRoot?.volumeIdentifier == "volume-b",
              "source root reauthorization persisted")
        try? store.removeSourceRootAndSoftDeleteAssets(id: "src-test-root")
        let removedRoot = (try? store.loadSourceRoots())?.first { $0.id == "src-test-root" }
        check(removedRoot == nil && store.assetCount() == assets.count,
              "empty source root removal persists without deleting unrelated assets")
        try? store.addSourceRoot(id: "src-test-root", displayName: "source", path: src.path,
                                 bookmark: nil, volumeIdentifier: "volume-a")
        try? store.startImportSession(id: "session-test")
        try? store.updateImportSession(id: "session-test", rootId: "src-test-root", state: "completed",
                                       totalCount: 7, importedCount: 6, skippedCount: 1,
                                       failedCount: 0, finishedAt: .now)
        let session = (try? store.loadImportSessions())?.first { $0.id == "session-test" }
        check(session?.state == "completed" && session?.rootId == "src-test-root"
              && session?.totalCount == 7 && session?.importedCount == 6 && session?.skippedCount == 1,
              "import session persisted final counts")
        try? store.startImportJob(id: "job-test", sessionId: "session-test", sourcePath: src.path,
                                  mode: .managed, autoTag: true, archiveRule: .camera,
                                  readSidecar: false, previewMaxPixel: 1600)
        try? store.updateJob(id: "job-test", state: "paused")
        let job = (try? store.loadJobs(type: "scan", states: ["paused"]))?.first { $0.id == "job-test" }
        check(job?.state == "paused" && job?.payloadJSON.contains("\"sourcePath\":\"\(src.path)\"") == true
              && job?.payloadJSON.contains("\"autoTag\":true") == true
              && job?.payloadJSON.contains("\"archiveRule\":\"camera\"") == true
              && job?.payloadJSON.contains("\"readSidecar\":false") == true
              && job?.payloadJSON.contains("\"previewMaxPixel\":1600") == true,
              "import job persisted payload and state")
        try? store.updateJob(id: "job-test", state: "succeeded", lockedAt: nil)
    }

    /// 5. edit persistence
    func editPersistence() {
        if let id = assets.first?.id {
            try? store.upsert([{
                var a = assets[0]
                a.rating = 5
                a.keywords = ["测试"]
                a.author = "作者A"
                a.copyright = "Copyright A"
                a.makerNotes = "LensID=NIKKOR Z"
                a.project = "Project A"
                a.client = "Client A"
                a.title = "Print 5\"x7"
                return a
            }()])
            let again = (try? store.loadAssets()) ?? []
            let edited = again.first { $0.id == id }
            check(edited?.rating == 5 && edited?.keywords == ["测试"]
                  && edited?.author == "作者A" && edited?.copyright == "Copyright A"
                  && edited?.project == "Project A" && edited?.client == "Client A",
                  "rating + keyword + rights + project edit persisted across reload")
            check(edited?.makerNotes == "LensID=NIKKOR Z", "maker notes persisted across reload")
            let searchPage = try? store.loadAssetPage(
                matching: AssetQuery(search: "Print 5", sort: Sort(field: .name, descending: false)),
                limit: 10
            )
            check(searchPage?.totalCount == 1 && searchPage?.assets.first?.id == id,
                  "paged FTS search returns edited metadata")
            let smartPage = try? store.loadAssetPage(
                matching: AssetQuery(scope: .smart(rule: SmartRule(match: "all", conditions: [
                    SmartCondition(field: "keywords", op: "包含", value: "测试"),
                    SmartCondition(field: "rating", op: ">=", value: "5"),
                ]))),
                limit: 10
            )
            check(smartPage?.totalCount == 1 && smartPage?.assets.first?.id == id,
                  "paged smart-album query matches keyword and rating rules")
        }
    }

    /// 20. the whole-catalog decoder (raw columns, shared strings) matches the row decoder
    func catalogDecoder() {
        _ = try? store.upsert(assets.prefix(3).enumerated().map { index, base in
            var asset = base
            asset.keywords = KeywordService.normalize(["旅行/日本/东京", "quote\"inside", "人像"].prefix(index + 1).map { $0 })
            asset.gps = (30.5, 114.25)
            asset.author = "一位很长名字的摄影师 · Studio"
            return asset
        })
        let fast = ((try? store.loadAssets()) ?? []).sorted { $0.id < $1.id }
        let reference = ((try? store.loadAssetPage(limit: 1_000_000).assets) ?? []).sorted { $0.id < $1.id }
        func fields(_ a: Asset) -> String {
            "\(a.id)|\(a.pid)|\(a.ori)|\(a.thumb)|\(a.preview)|\(a.filename)|\(a.type)|\(a.isRaw)|\(a.folderId)|"
                + "\(a.folderName)|\(a.date.timeIntervalSince1970)|\(a.width)|\(a.height)|\(a.orientation)|\(a.camera)|"
                + "\(a.lens)|\(a.focal)|\(a.aperture)|\(a.shutter)|\(a.iso)|\(a.colorSpace)|\(a.hasICCProfile)|\(a.fileMB)|"
                + "\(String(describing: a.fileModifiedAt))|\(String(describing: a.fileCreatedAt))|\(a.rating)|\(a.flag)|"
                + "\(String(describing: a.colorLabel))|\(a.keywords)|\(a.title)|\(a.caption)|\(a.author)|\(a.copyright)|"
                + "\(a.makerNotes)|\(a.project)|\(a.client)|\(a.location)|\(a.gps.0),\(a.gps.1)|"
                + "\(String(describing: a.gpsAltitude))|\(a.status)|\(a.importedAt.timeIntervalSince1970)|\(a.deleted)|"
                + "\(String(describing: a.localPath))|\(a.captureDateSource)|\(String(describing: a.contentHash))|"
                + "\(String(describing: a.quickHash))|\(a.isDemo)|\(a.faces)|\(String(describing: a.perceptualHash))"
        }
        let mismatch = zip(fast, reference).first { fields($0) != fields($1) }
        check(fast.count == reference.count && !fast.isEmpty && mismatch == nil,
              "the fast catalog decoder reads every field exactly like the row decoder"
              + (mismatch.map { " (first difference: \(fields($0.0)) vs \(fields($0.1)))" } ?? ""))
    }
}
