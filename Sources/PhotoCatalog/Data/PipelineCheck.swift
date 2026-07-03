// ============================================================
//  Headless end-to-end check for the real import pipeline.
//  Generates test images, then exercises
//  scan → metadata → thumbnails → hash → persist → reload → export → backup.
// ============================================================
import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

enum PipelineCheck {
    static func run() {
        var failures = 0
        func check(_ cond: Bool, _ label: String) {
            print((cond ? "  ✓ " : "  ✗ FAIL ") + label)
            if !cond { failures += 1 }
        }

        print("=== PhotoCatalog real-pipeline self-check ===")
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("pc-pipeline-\(UUID().uuidString)")
        let src = tmp.appendingPathComponent("source")
        let exportDir = tmp.appendingPathComponent("export")
        try? fm.createDirectory(at: src, withIntermediateDirectories: true)

        // 1. generate 6 distinct test JPEGs + 1 exact duplicate
        let fixedGPS = (lat: 31.2345, lon: 121.4567, altitude: 88.5)
        let gpsProperties: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: fixedGPS.lat,
            kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: fixedGPS.lon,
            kCGImagePropertyGPSLongitudeRef: "E",
            kCGImagePropertyGPSAltitude: fixedGPS.altitude,
            kCGImagePropertyGPSAltitudeRef: 0,
        ]
        for i in 0..<6 {
            writeTestImage(to: src.appendingPathComponent(String(format: "IMG_%04d.jpg", i)),
                           width: i % 2 == 0 ? 800 : 600, height: i % 2 == 0 ? 600 : 800, seed: i,
                           gps: i == 0 ? gpsProperties : nil)
        }
        try? fm.copyItem(at: src.appendingPathComponent("IMG_0000.jpg"),
                         to: src.appendingPathComponent("IMG_0000_copy.jpg"))
        let nestedCatalog = src.appendingPathComponent("Nested.photolibrary")
        try? fm.createDirectory(at: nestedCatalog, withIntermediateDirectories: true)
        writeTestImage(to: nestedCatalog.appendingPathComponent("SHOULD_SKIP.jpg"),
                       width: 320, height: 240, seed: 88)
        // a non-image file that must be ignored
        try? "not an image".data(using: .utf8)?.write(to: src.appendingPathComponent("notes.txt"))
        let fixedModifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let fixedCreatedAt = Date(timeIntervalSince1970: 1_600_000_000)
        try? fm.setAttributes([
            .modificationDate: fixedModifiedAt,
            .creationDate: fixedCreatedAt,
        ], ofItemAtPath: src.appendingPathComponent("IMG_0000.jpg").path)

        // 2. scanner
        let scanned = FileScanner.scan(src)
        check(scanned.count == 7, "scanner found 7 images (ignored notes.txt and nested catalog) — got \(scanned.count)")

        // 3. import pipeline (metadata + thumbnails + hashes)
        guard let store = try? CatalogStore(packageURL: tmp.appendingPathComponent("Lib.photolibrary")) else {
            print("  ✗ FAIL could not create catalog"); exit(1)
        }
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
        let coordinator = ImportCoordinator(store: store)
        var progressSnapshots: [ImportProgress] = []
        let assets = coordinator.importFolder(src) { progressSnapshots.append($0) }
        check(assets.count == 7, "imported 7 assets — got \(assets.count)")
        // re-import the same referenced folder reusing known assets: each file is reused, not
        // re-made (the rating-5 sentinel survives, where a fresh makeAsset would set rating 0)
        let knownForReimport = Dictionary(
            assets.map { a -> (String, Asset) in var m = a; m.rating = 5; return (a.id, m) },
            uniquingKeysWith: { first, _ in first })
        let reimported = coordinator.importFolder(src, knownAssetsById: knownForReimport)
        check(reimported.count == assets.count && reimported.allSatisfy { $0.rating == 5 },
              "re-import reuses cataloged referenced assets instead of re-processing")
        // capture wall-clock: an EXIF DateTimeOriginal is read as a fixed UTC wall-clock, so it
        // decomposes to the exact recorded components regardless of the test machine's timezone
        let exifSrc = tmp.appendingPathComponent("exif-date")
        try? fm.createDirectory(at: exifSrc, withIntermediateDirectories: true)
        writeTestImage(to: exifSrc.appendingPathComponent("DATED.jpg"), width: 320, height: 240, seed: 7,
                       exif: [kCGImagePropertyExifDateTimeOriginal: "2021:07:15 14:30:00"])
        if let dated = coordinator.importFolder(exifSrc).first {
            let c = Calendar.captureWallClock.dateComponents([.year, .month, .day, .hour, .minute],
                                                             from: dated.date)
            check(c.year == 2021 && c.month == 7 && c.day == 15 && c.hour == 14 && c.minute == 30,
                  "EXIF capture time read as fixed wall-clock — got \(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0) \(c.hour ?? 0):\(c.minute ?? 0)")
        } else {
            check(false, "EXIF-dated image imported")
        }
        let timestampedAsset = assets.first { $0.filename == "IMG_0000.jpg" }
        check(timestampedAsset?.fileModifiedAt.map { abs($0.timeIntervalSince(fixedModifiedAt)) < 1 } == true
              && timestampedAsset?.fileCreatedAt != nil,
              "file mtime/ctime read from filesystem")
        check(timestampedAsset?.gpsAltitude.map { abs($0 - fixedGPS.altitude) < 0.1 } == true
              && (timestampedAsset?.gps.0 ?? 0) > 31,
              "GPS latitude/longitude/altitude read")
        check(progressSnapshots.first?.total == 7 && progressSnapshots.last?.processed == 7,
              "import progress reported total + processed counts")
        check(progressSnapshots.contains { $0.latestAsset != nil }, "import progress reported latest processed asset")
        let badSrc = tmp.appendingPathComponent("bad-source")
        try? fm.createDirectory(at: badSrc, withIntermediateDirectories: true)
        try? Data("broken image bytes".utf8).write(to: badSrc.appendingPathComponent("BROKEN.jpg"))
        var failureSnapshots: [ImportProgress] = []
        let brokenAssets = coordinator.importFolder(badSrc) { failureSnapshots.append($0) }
        let brokenFailure = failureSnapshots.last?.latestFailure
        check(brokenAssets.isEmpty && failureSnapshots.last?.failed == 1
              && brokenFailure?.filename == "BROKEN.jpg" && brokenFailure?.reason.isEmpty == false,
              "import progress reported failed file and reason")
        let missingURL = badSrc.appendingPathComponent("MISSING.jpg")
        var retrySnapshots: [ImportProgress] = []
        _ = coordinator.importFiles([missingURL], from: badSrc) { retrySnapshots.append($0) }
        check(retrySnapshots.last?.failed == 1 && retrySnapshots.last?.latestFailure?.path == missingURL.path,
              "import retry reports missing file failure")
        let pauseControl = ImportControl()
        let pauseStarted = DispatchSemaphore(value: 0)
        let pauseReleased = DispatchSemaphore(value: 0)
        pauseControl.pause()
        DispatchQueue.global(qos: .utility).async {
            pauseStarted.signal()
            pauseControl.waitIfPaused()
            pauseReleased.signal()
        }
        _ = pauseStarted.wait(timeout: .now() + 1)
        let blockedWhilePaused = pauseReleased.wait(timeout: .now() + 0.05) == .timedOut
        pauseControl.resume()
        let resumedAfterContinue = pauseReleased.wait(timeout: .now() + 1) == .success
        check(blockedWhilePaused && resumedAfterContinue, "import pause control blocks and resumes")
        let withDims = assets.allSatisfy { $0.width > 0 && $0.height > 0 }
        check(withDims, "every asset has real pixel dimensions from Image I/O")
        let thumbsExist = assets.allSatisfy {
            fm.fileExists(atPath: $0.thumb) && fm.fileExists(atPath: $0.preview)
        }
        check(thumbsExist, "thumbnails + previews written to disk cache")
        let thumb256Exist = assets.allSatisfy {
            fm.fileExists(atPath: coordinator.thumbnails.cachePath(assetId: $0.id, kind: .thumb256).path)
        }
        check(thumb256Exist, "256px thumbnails written to disk cache")
        let defaultPreview2048Exist = assets.allSatisfy {
            $0.preview == coordinator.thumbnails.cachePath(assetId: $0.id, kind: .preview2048).path
        }
        check(defaultPreview2048Exist, "default previews use 2048px cache")
        let rawSrc = tmp.appendingPathComponent("raw-source")
        try? fm.createDirectory(at: rawSrc, withIntermediateDirectories: true)
        let cr3URL = rawSrc.appendingPathComponent("CANON.CR3")
        writeTestImage(to: cr3URL, width: 720, height: 480, seed: 45)
        check(FileScanner.isSupported(cr3URL), "scanner accepts CR3 extension")
        let rawAssets = coordinator.importFolder(rawSrc)
        let cr3Asset = rawAssets.first
        check(rawAssets.count == 1 && cr3Asset?.type == "CR3" && cr3Asset?.isRaw == true,
              "CR3 import is classified as RAW")
        check(cr3Asset.map { fm.fileExists(atPath: $0.thumb) && fm.fileExists(atPath: $0.preview) } == true,
              "CR3 import writes thumbnail + preview cache")
        if let cr3Asset, let localPath = cr3Asset.localPath {
            let thumbURL = URL(fileURLWithPath: cr3Asset.thumb)
            let originalURL = URL(fileURLWithPath: localPath)
            let missingOriginalURL = rawSrc.appendingPathComponent("MISSING.CR3")
            let previewURL = URL(fileURLWithPath: cr3Asset.preview)
            writeBlackImage(to: thumbURL, width: 64, height: 64)
            let detectedBlackCache = coordinator.thumbnails.cachedRepresentationNeedsRegeneration(
                at: thumbURL,
                original: originalURL,
                kind: .thumb512
            )
            let repairedThumb = coordinator.thumbnails.ensureCached(from: missingOriginalURL,
                                                                     fallbackPreview: previewURL,
                                                                     assetId: cr3Asset.id,
                                                                     kind: .thumb512)
            check(detectedBlackCache && repairedThumb?.path == cr3Asset.thumb
                  && !imageIsUniformBlack(at: thumbURL),
                  "CR3 black thumbnail cache regenerates from preview fallback")
        } else {
            check(false, "CR3 black thumbnail cache regenerates from preview fallback")
        }
        let preview1600Src = tmp.appendingPathComponent("preview-1600")
        try? fm.createDirectory(at: preview1600Src, withIntermediateDirectories: true)
        writeTestImage(to: preview1600Src.appendingPathComponent("SMALL_PREVIEW.jpg"),
                       width: 640, height: 480, seed: 42)
        let preview1600Assets = coordinator.importFolder(preview1600Src, previewMaxPixel: 1600)
        if let preview1600Asset = preview1600Assets.first {
            let expectedPreview = coordinator.thumbnails.cachePath(assetId: preview1600Asset.id,
                                                                   kind: .preview1600).path
            check(preview1600Asset.preview == expectedPreview && fm.fileExists(atPath: expectedPreview),
                  "configurable previews use 1600px cache")
        } else {
            check(false, "configurable previews use 1600px cache")
        }
        let treeSrc = tmp.appendingPathComponent("tree-source")
        let tripsDir = treeSrc.appendingPathComponent("Trips")
        let tokyoDir = tripsDir.appendingPathComponent("Tokyo")
        try? fm.createDirectory(at: tokyoDir, withIntermediateDirectories: true)
        writeTestImage(to: tripsDir.appendingPathComponent("TRIP.jpg"), width: 600, height: 400, seed: 43)
        writeTestImage(to: tokyoDir.appendingPathComponent("TOKYO.jpg"), width: 600, height: 400, seed: 44)
        let treeAssets = coordinator.importFolder(treeSrc)
        if let sourceId = treeAssets.first?.folderId {
            let tree = FolderTreeService.build(
                sourceFolders: [Folder(id: sourceId, name: "tree-source")],
                assets: treeAssets,
                sourceRootPaths: [sourceId: treeSrc.path])
            let trips = tree.first { $0.name == "Trips" && $0.depth == 1 }
            let tokyo = tree.first { $0.name == "Tokyo" && $0.depth == 2 }
            check(tree.count == 3 && trips != nil && tokyo != nil,
                  "folder tree derives nested source folders")
            if let trips, let tokyo {
                let tripsCount = treeAssets.filter { FolderTreeService.matches($0, item: trips) }.count
                let tokyoCount = treeAssets.filter { FolderTreeService.matches($0, item: tokyo) }.count
                check(tripsCount == 2 && tokyoCount == 1,
                      "folder tree filters nested source folders")
                let treeCounts = FolderTreeService.counts(for: tree, assets: treeAssets)
                check(treeCounts[trips.id] == 2 && treeCounts[tokyo.id] == 1,
                      "folder tree count index matches nested folders")
            } else {
                check(false, "folder tree filters nested source folders")
                check(false, "folder tree count index matches nested folders")
            }
        } else {
            check(false, "folder tree derives nested source folders")
            check(false, "folder tree filters nested source folders")
            check(false, "folder tree count index matches nested folders")
        }
        check(assets.allSatisfy { $0.contentHash != nil && $0.quickHash != nil }, "content + quick hashes computed")
        let groupedDedup = ImportDeduplicationService.apply(imported: assets, existingAssets: [],
                                                            existingIds: [], strategy: .groupExact)
        check(groupedDedup.fresh.count == 7 && groupedDedup.skipped == 0,
              "import duplicate strategy keeps exact duplicates for grouping")
        let skippedDedup = ImportDeduplicationService.apply(imported: assets, existingAssets: [],
                                                            existingIds: [], strategy: .skipExact)
        check(skippedDedup.fresh.count == 6 && skippedDedup.skipped == 1,
              "import duplicate strategy skips exact duplicates")
        var sameHashDifferentSize = assets[1]
        sameHashDifferentSize.contentHash = assets[0].contentHash
        sameHashDifferentSize.fileMB = assets[0].fileMB + 1
        let sizeAwareDedup = ImportDeduplicationService.apply(
            imported: [sameHashDifferentSize],
            existingAssets: [assets[0]],
            existingIds: [],
            strategy: .skipExact)
        check(sizeAwareDedup.fresh.count == 1 && sizeAwareDedup.skipped == 0,
              "import duplicate strategy requires matching size and content hash")
        let postKeywords = ImportPostActionService.normalizeKeywords("客户精选，旅行,客户精选")
        let postAssets = ImportPostActionService.apply(
            to: [assets[0]],
            actions: ImportPostActions(keywords: postKeywords, colorLabel: .green))
        check(postAssets.first?.keywords == ["客户精选", "旅行"] && postAssets.first?.colorLabel == .green,
              "import post actions apply keywords and color label")
        let postHierarchy = ImportPostActionService.normalizeKeywords("旅行/日本/东京")
        check(postHierarchy == ["旅行", "旅行/日本", "旅行/日本/东京"],
              "import post actions expand hierarchical keywords")
        var knownByPath: [String: Asset] = [:]
        for asset in assets {
            if let path = asset.localPath {
                knownByPath[path] = asset
                knownByPath[URL(fileURLWithPath: path).resolvingSymlinksInPath().path] = asset
            }
        }
        let changedURL = src.appendingPathComponent("IMG_0001.jpg")
        let originalQuickHash = knownByPath[changedURL.path]?.quickHash
            ?? knownByPath[changedURL.resolvingSymlinksInPath().path]?.quickHash
        try? fm.removeItem(at: changedURL)
        writeTestImage(to: changedURL, width: 320, height: 240, seed: 99)
        let changedAssets = coordinator.scanChanged(in: src, knownAssetsByPath: knownByPath)
        let changedAsset = changedAssets.first { $0.filename == changedURL.lastPathComponent }
        check(changedAsset?.width == 320 && changedAsset?.height == 240
              && originalQuickHash != nil && changedAsset?.quickHash != originalQuickHash,
              "incremental scan refreshes modified originals")
        let touchedURL = src.appendingPathComponent("IMG_0002.jpg")
        let touchedKnown = knownByPath[touchedURL.path]
            ?? knownByPath[touchedURL.resolvingSymlinksInPath().path]
        let touchedModifiedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try? fm.setAttributes([.modificationDate: touchedModifiedAt], ofItemAtPath: touchedURL.path)
        let touchedAssets = coordinator.scanChanged(in: src, knownAssetsByPath: knownByPath)
        let touchedAsset = touchedAssets.first { $0.filename == touchedURL.lastPathComponent }
        check(touchedAsset?.quickHash == touchedKnown?.quickHash
              && touchedAsset?.fileModifiedAt.map { abs($0.timeIntervalSince(touchedModifiedAt)) < 1 } == true,
              "incremental scan refreshes timestamp-only modifications")

        // 4. persist + reload roundtrip
        try? store.upsert(assets)
        let reloaded = (try? store.loadAssets()) ?? []
        check(reloaded.count == 7, "reloaded 7 assets from SQLite — got \(reloaded.count)")
        check(reloaded.allSatisfy { $0.perceptualHash != nil }, "perceptual hash computed at import + persisted")
        let reloadedTimestamped = reloaded.first { $0.filename == "IMG_0000.jpg" }
        check(reloadedTimestamped?.fileModifiedAt.map { abs($0.timeIntervalSince(fixedModifiedAt)) < 1 } == true
              && reloadedTimestamped?.fileCreatedAt != nil,
              "file mtime/ctime persisted")
        check(reloadedTimestamped?.hasICCProfile == timestampedAsset?.hasICCProfile,
              "ICC profile flag persisted")
        check(reloadedTimestamped?.gpsAltitude.map { abs($0 - fixedGPS.altitude) < 0.1 } == true,
              "GPS altitude persisted")
        let album = Album(id: "album-test", name: "Pipeline Picks",
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
        try? store.removeSourceRoot(id: "src-test-root")
        let removedRoot = (try? store.loadSourceRoots())?.first { $0.id == "src-test-root" }
        check(removedRoot == nil, "source root removal persisted")
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

        // 5. edit persistence
        if let id = assets.first?.id {
            try? store.updateAsset({
                var a = assets[0]
                a.rating = 5
                a.keywords = ["测试"]
                a.author = "作者A"
                a.copyright = "Copyright A"
                a.makerNotes = "LensID=NIKKOR Z"
                a.project = "Project A"
                a.client = "Client A"
                return a
            }())
            let again = (try? store.loadAssets()) ?? []
            let edited = again.first { $0.id == id }
            check(edited?.rating == 5 && edited?.keywords == ["测试"]
                  && edited?.author == "作者A" && edited?.copyright == "Copyright A"
                  && edited?.project == "Project A" && edited?.client == "Client A",
                  "rating + keyword + rights + project edit persisted across reload")
            check(edited?.makerNotes == "LensID=NIKKOR Z", "maker notes persisted across reload")
        }

        // 6. exact-duplicate detection (the identical pair)
        let dupes = HashService.exactDuplicateGroups(assets)
        check(dupes.contains { $0.items.count == 2 }, "exact-duplicate group found for the identical pair")
        let falseDupes = HashService.exactDuplicateGroups([assets[0], sameHashDifferentSize])
        check(falseDupes.isEmpty, "exact-duplicate detection requires matching size and content hash")
        let suspectPair = assets.enumerated().compactMap { index, lhs -> (Asset, Asset)? in
            assets.dropFirst(index + 1).first { rhs in
                lhs.width == rhs.width && lhs.height == rhs.height && lhs.contentHash != rhs.contentHash
            }.map { (lhs, $0) }
        }.first
        if let (suspectA, pairB) = suspectPair {
            var suspectB = pairB
            suspectB.date = suspectA.date
            suspectB.filename = "IMG_0000-edit.jpg"
            suspectB.quickHash = suspectA.quickHash
            let suspected = HashService.suspectedDuplicateGroups([suspectA, suspectB])
            check(suspected.contains { $0.method == "suspected" && $0.items.count == 2 },
                  "suspected duplicate group found from quick hash, dimensions, and capture time")
        } else {
            check(false, "suspected duplicate group sample")
        }
        if let group = dupes.first(where: { $0.items.count == 2 }) {
            var resolvedAssets = assets
            let keepId = group.items[0].id
            let report = DuplicateResolutionService.resolve(group, keepId: keepId, in: &resolvedAssets,
                                                            action: .removeFromCatalog)
            let removed = resolvedAssets.filter { report.removedIds.contains($0.id) && $0.deleted }
            let kept = resolvedAssets.first { $0.id == keepId }
            check(report.affectedCount == 1 && removed.count == 1 && kept?.deleted == false,
                  "duplicate resolution removed non-kept catalog item")
        } else { check(false, "duplicate resolution sample group") }

        // 7. export originals
        let report = ExportService.copyOriginals(assets, to: exportDir)
        check(report.copied == 7, "exported 7 originals — copied \(report.copied), failed \(report.failed)")
        if let first = assets.first, let firstPath = first.localPath {
            let sourceURL = URL(fileURLWithPath: firstPath)
            let dateParts = Calendar.captureWallClock.dateComponents([.year, .month, .day],
                                                                     from: first.date)
            let dateExportDir = tmp.appendingPathComponent("export-date")
            let dateReport = ExportService.copyOriginals(assets, to: dateExportDir,
                                                         directoryStructure: .date)
            let dateTarget = dateExportDir
                .appendingPathComponent(String(format: "%04d", dateParts.year ?? 0))
                .appendingPathComponent(String(format: "%02d", dateParts.month ?? 1))
                .appendingPathComponent(String(format: "%02d", dateParts.day ?? 1))
                .appendingPathComponent(sourceURL.lastPathComponent)
            check(dateReport.copied == 7 && fm.fileExists(atPath: dateTarget.path),
                  "exported originals into date folders")

            let sourceExportDir = tmp.appendingPathComponent("export-source")
            let sourceReport = ExportService.copyOriginals(
                assets,
                to: sourceExportDir,
                directoryStructure: .sourceFolder,
                sourceRootPathsByFolderId: [first.folderId: src.path])
            let sourceTarget = sourceExportDir
                .appendingPathComponent(src.lastPathComponent)
                .appendingPathComponent(sourceURL.lastPathComponent)
            check(sourceReport.copied == 7 && fm.fileExists(atPath: sourceTarget.path),
                  "exported originals into source folders")

            let albumExportDir = tmp.appendingPathComponent("export-album")
            let albumAssets = Array(assets.prefix(3))
            let albumNames = Dictionary(uniqueKeysWithValues: album.assetIds.map { ($0, album.name) })
            let albumReport = ExportService.copyOriginals(albumAssets, to: albumExportDir,
                                                          directoryStructure: .album,
                                                          albumNamesByAssetId: albumNames)
            let albumTarget = albumExportDir
                .appendingPathComponent(album.name)
                .appendingPathComponent(sourceURL.lastPathComponent)
            check(albumReport.copied == 3 && fm.fileExists(atPath: albumTarget.path),
                  "exported originals into album folders")
        } else {
            check(false, "exported originals into structured folders")
        }
        let metadataJSON = exportDir.appendingPathComponent("metadata.json")
        let metadataCSV = exportDir.appendingPathComponent("metadata.csv")
        var metadataAssets = assets
        metadataAssets[0].author = "Export Author"
        metadataAssets[0].copyright = "Export Copyright"
        metadataAssets[0].makerNotes = "Export MakerNotes"
        metadataAssets[0].project = "Export Project"
        metadataAssets[0].client = "Export Client"
        let exportedJSON = ExportService.exportMetadataJSON(metadataAssets, to: metadataJSON)
        let jsonText = (try? String(contentsOf: metadataJSON, encoding: .utf8)) ?? ""
        check(exportedJSON && jsonText.contains("\"author\"") && jsonText.contains("Export Author")
              && jsonText.contains("\"copyright\"") && jsonText.contains("Export Copyright")
              && jsonText.contains("\"makerNotes\"") && jsonText.contains("Export MakerNotes")
              && jsonText.contains("\"project\"") && jsonText.contains("Export Project")
              && jsonText.contains("\"client\"") && jsonText.contains("Export Client"),
              "exported JSON metadata")
        let jsonRows = (try? JSONSerialization.jsonObject(with: Data(jsonText.utf8)) as? [[String: Any]]) ?? []
        let jsonWithGPS = jsonRows.first { $0["filename"] as? String == metadataAssets[0].filename }
        let jsonMissingGPS = jsonRows.first { $0["filename"] as? String == metadataAssets[1].filename }
        let exportedCSV = ExportService.exportMetadataCSV(metadataAssets, to: metadataCSV)
        let csvText = (try? String(contentsOf: metadataCSV, encoding: .utf8)) ?? ""
        check(exportedCSV && csvText.contains("author,copyright,makerNotes,project,client")
              && csvText.contains("Export Author") && csvText.contains("Export Copyright")
              && csvText.contains("Export MakerNotes") && csvText.contains("Export Project")
              && csvText.contains("Export Client"),
              "exported CSV metadata")
        let missingGPSCSVFields = csvText.split(separator: "\n", omittingEmptySubsequences: false)
            .first { $0.contains(metadataAssets[1].filename) }?
            .split(separator: ",", omittingEmptySubsequences: false)
        check((jsonWithGPS?["gpsLatitude"] as? NSNumber) != nil
              && jsonMissingGPS?["gpsLatitude"] is NSNull
              && jsonMissingGPS?["gpsLongitude"] is NSNull
              && (missingGPSCSVFields?.count ?? 0) > 18
              && missingGPSCSVFields?[17].isEmpty == true
              && missingGPSCSVFields?[18].isEmpty == true,
              "exported metadata omits missing GPS coordinates")
        // regression: attacker-controlled metadata starting with = must be neutralized for
        // spreadsheets, while a legitimate negative number stays a number.
        var injectionAssets = assets
        injectionAssets[0].caption = "=HYPERLINK(\"http://evil\")"
        injectionAssets[1].caption = "\n=HYPERLINK(\"http://evil\")"
        injectionAssets[0].gpsAltitude = -12.5
        let injectionCSV = exportDir.appendingPathComponent("metadata-injection.csv")
        _ = ExportService.exportMetadataCSV(injectionAssets, to: injectionCSV)
        let injectionText = (try? String(contentsOf: injectionCSV, encoding: .utf8)) ?? ""
        check(injectionText.contains("'=HYPERLINK") && injectionText.contains("'\n=HYPERLINK")
              && injectionText.contains("-12.5"),
              "CSV neutralizes formula injection yet preserves negative numbers")
        let previewExportDir = tmp.appendingPathComponent("export-previews")
        let previewReport = ExportService.exportPreviews(assets, to: previewExportDir)
        let previewTargetName = URL(fileURLWithPath: assets[0].filename)
            .deletingPathExtension().lastPathComponent + "-preview.jpg"
        check(previewReport.copied == 7
              && fm.fileExists(atPath: previewExportDir.appendingPathComponent(previewTargetName).path),
              "exported cached previews")
        if let first = assets.first, let originalPath = first.localPath {
            try? fm.removeItem(at: URL(fileURLWithPath: first.preview))
            try? fm.removeItem(at: URL(fileURLWithPath: first.thumb))
            let rebuiltPreviewDir = tmp.appendingPathComponent("export-previews-rebuilt")
            let rebuiltReport = ExportService.exportPreviews([first], to: rebuiltPreviewDir,
                                                             thumbnails: coordinator.thumbnails)
            check(rebuiltReport.copied == 1
                  && fm.fileExists(atPath: first.preview)
                  && fm.fileExists(atPath: originalPath)
                  && fm.fileExists(atPath: rebuiltPreviewDir.appendingPathComponent(previewTargetName).path),
                  "exported previews regenerate missing cache")
            _ = coordinator.thumbnails.ensureCached(from: URL(fileURLWithPath: originalPath),
                                                     assetId: first.id,
                                                     kind: .thumb512)
        } else {
            check(false, "exported previews regenerate missing cache")
        }
        if var fileOpAsset = assets.first, let sourcePath = fileOpAsset.localPath {
            let sourceCopy = tmp.appendingPathComponent("file-op-source.jpg")
            try? fm.copyItem(at: URL(fileURLWithPath: sourcePath), to: sourceCopy)
            fileOpAsset.filename = sourceCopy.lastPathComponent
            fileOpAsset.localPath = sourceCopy.path
            let copyDir = tmp.appendingPathComponent("file-op-copy")
            let copyReport = OriginalFileOperationService.perform(.copy, assets: [fileOpAsset],
                                                                   destination: copyDir)
            check(copyReport.copied == 1
                  && fm.fileExists(atPath: copyDir.appendingPathComponent(sourceCopy.lastPathComponent).path)
                  && fm.fileExists(atPath: sourceCopy.path),
                  "original file operation copies originals")
            let moveDir = tmp.appendingPathComponent("file-op-move")
            let moveReport = OriginalFileOperationService.perform(.move, assets: [fileOpAsset],
                                                                   destination: moveDir)
            let movedURL = moveReport.updatedLocations[fileOpAsset.id]
            check(moveReport.moved == 1 && movedURL != nil
                  && fm.fileExists(atPath: movedURL!.path)
                  && !fm.fileExists(atPath: sourceCopy.path),
                  "original file operation moves originals")
        } else {
            check(false, "original file operation copies and moves originals")
        }

        // 8. backup
        let backup = try? BackupService.backup(store)
        check(backup != nil && fm.fileExists(atPath: backup!.path), "catalog backup written")
        if let backup {
            let restorePackage = tmp.appendingPathComponent("restored.photolibrary")
            try? BackupService.restore(backup, intoPackageAt: restorePackage)
            let restoredStore = try? CatalogStore(packageURL: restorePackage)
            let restoredCount = (try? restoredStore?.loadAssets().count) ?? 0
            check(restoredCount == 7, "catalog backup restored — got \(restoredCount) assets")
        } else {
            check(false, "catalog backup restored")
        }

        // 9. FTS5 full-text search
        check(!store.search("IMG").isEmpty, "FTS5 search returns matches for 'IMG'")

        // 10. catalog health check
        let health = CatalogHealth.check(store, assets: assets)
        check(health.dbIntegrityOK && health.assetCount >= 7,
              "health check: db \(health.dbIntegrityOK ? "ok" : "BAD"), \(health.assetCount) assets")
        check(health.isHealthy && health.missingOriginals == 0 && health.missingThumbnails == 0
              && health.missingPreviews == 0 && health.unavailableSourceRoots == 0
              && health.activeJobs == 0 && health.failedJobs == 0,
              "health check: refs, sources, and jobs ok")
        func assetWithCache(_ base: Asset, thumb: String, preview: String) -> Asset {
            Asset(id: base.id, pid: base.pid, ori: base.ori, thumb: thumb, preview: preview,
                  filename: base.filename, type: base.type, isRaw: base.isRaw, folderId: base.folderId,
                  folderName: base.folderName, date: base.date, width: base.width, height: base.height,
                  orientation: base.orientation, camera: base.camera, lens: base.lens, focal: base.focal,
                  aperture: base.aperture, shutter: base.shutter, iso: base.iso,
                  colorSpace: base.colorSpace, hasICCProfile: base.hasICCProfile, fileMB: base.fileMB,
                  fileModifiedAt: base.fileModifiedAt, fileCreatedAt: base.fileCreatedAt,
                  rating: base.rating, flag: base.flag, colorLabel: base.colorLabel,
                  keywords: base.keywords, title: base.title, caption: base.caption,
                  author: base.author, copyright: base.copyright, makerNotes: base.makerNotes,
                  project: base.project, client: base.client, location: base.location, gps: base.gps,
                  gpsAltitude: base.gpsAltitude, status: base.status, importedAt: base.importedAt,
                  deleted: base.deleted, localPath: base.localPath,
                  captureDateSource: base.captureDateSource, contentHash: base.contentHash,
                  quickHash: base.quickHash, isDemo: base.isDemo, faces: base.faces,
                  perceptualHash: base.perceptualHash)
        }
        var emptyCacheAssets = assets
        emptyCacheAssets[0] = assetWithCache(emptyCacheAssets[0], thumb: "", preview: "")
        let emptyCacheHealth = CatalogHealth.check(store, assets: emptyCacheAssets)
        check(emptyCacheHealth.missingThumbnails == 1 && emptyCacheHealth.missingPreviews == 1
              && !emptyCacheHealth.isHealthy,
              "health check reports empty cache references")
        try? store.updateJob(id: "job-test", state: "failed", lockedAt: nil, lastError: "test failure")
        let failedJobHealth = CatalogHealth.check(store, assets: assets)
        check(failedJobHealth.failedJobs == 1 && !failedJobHealth.isHealthy,
              "health check reports failed jobs")
        try? store.updateJob(id: "job-test", state: "succeeded", lockedAt: nil)
        if let first = assets.first, let originalPath = first.localPath, !first.preview.isEmpty {
            try? fm.removeItem(at: URL(fileURLWithPath: first.preview))
            let missingPreviewHealth = CatalogHealth.check(store, assets: assets)
            check(missingPreviewHealth.missingPreviews == 1 && !missingPreviewHealth.isHealthy,
                  "health check reports missing previews")
            let restoredPreview = coordinator.thumbnails.ensureCached(from: URL(fileURLWithPath: originalPath),
                                                                       assetId: first.id,
                                                                       kind: .preview2048)
            let restoredHealth = CatalogHealth.check(store, assets: assets)
            check(restoredPreview?.path == first.preview && fm.fileExists(atPath: first.preview),
                  "missing preview cache regenerates on demand")
            check(restoredHealth.missingPreviews == 0 && restoredHealth.isHealthy,
                  "health check recovers after preview regeneration")
        } else {
            check(false, "health check reports missing previews")
        }
        let cacheBaseline = CatalogHealth.directorySize(store.cacheURL)
        let pruneDir = store.cacheURL.appendingPathComponent("PruneTest")
        try? fm.createDirectory(at: pruneDir, withIntermediateDirectories: true)
        for i in 0..<3 {
            let file = pruneDir.appendingPathComponent("old-\(i).bin")
            try? Data(repeating: UInt8(i), count: 2_048).write(to: file)
            try? fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(i))],
                                  ofItemAtPath: file.path)
        }
        let pruneReport = CacheService.prune(store.cacheURL, maxBytes: cacheBaseline + 2_048)
        check(pruneReport.removedFiles >= 2 && pruneReport.afterBytes <= cacheBaseline + 2_048,
              "cache prune enforces size limit")

        // 11. perceptual dHash (near pair similar, far pair dissimilar)
        let pa = src.appendingPathComponent("near_a.jpg")
        let pb = src.appendingPathComponent("near_b.jpg")
        let pf = src.appendingPathComponent("far.jpg")
        writeStructured(to: pa, variant: 0)
        writeStructured(to: pb, variant: 1)
        writeStructured(to: pf, variant: 2)
        if let ha = PerceptualHash.dHash(path: pa.path),
           let hb = PerceptualHash.dHash(path: pb.path),
           let hc = PerceptualHash.dHash(path: pf.path) {
            check(PerceptualHash.hamming(ha, hb) <= 10,
                  "dHash near pair similar (hamming \(PerceptualHash.hamming(ha, hb)) ≤ 10)")
            check(PerceptualHash.hamming(ha, hc) > 10,
                  "dHash far pair dissimilar (hamming \(PerceptualHash.hamming(ha, hc)) > 10)")
        } else { check(false, "dHash computed") }

        // 12. XMP sidecar write/read roundtrip
        var sample = assets[1]
        sample.rating = 4; sample.keywords = ["旅行", "测试"]; sample.title = "标题A"
        sample.caption = "说明B"; sample.colorLabel = .red
        sample.author = "作者B"; sample.copyright = "Copyright B"
        sample.date = XMPSidecar.exifDateFormatter.date(from: "2019-03-08T09:15:00") ?? sample.date
        let xmpURL = tmp.appendingPathComponent("sample.xmp")
        XMPSidecar.write(sample, to: xmpURL)
        if let sc = XMPSidecar.read(xmpURL) {
            check(sc.rating == 4 && sc.keywords == ["旅行", "测试"] && sc.title == "标题A"
                  && sc.caption == "说明B" && sc.colorLabel == .red
                  && sc.author == "作者B" && sc.copyright == "Copyright B"
                  && sc.captureDate == sample.date,
                  "XMP sidecar write/read roundtrip")
        } else { check(false, "XMP sidecar read") }

        // 13. import applies an existing XMP sidecar (§6.5 META-006)
        let xsrc = tmp.appendingPathComponent("xmpsource")
        try? fm.createDirectory(at: xsrc, withIntermediateDirectories: true)
        let ximg = xsrc.appendingPathComponent("PHOTO.jpg")
        writeTestImage(to: ximg, width: 700, height: 500, seed: 5)
        var seed = assets[0]; seed.rating = 3; seed.keywords = ["导入测试"]; seed.colorLabel = .blue
        seed.title = "T"; seed.caption = ""
        seed.author = "Sidecar Author"; seed.copyright = "Sidecar Copyright"
        XMPSidecar.write(seed, to: XMPSidecar.sidecarURL(for: ximg))
        let xa = coordinator.importFolder(xsrc).first
        check(xa?.rating == 3 && xa?.keywords == ["导入测试"] && xa?.colorLabel == .blue
              && xa?.author == "Sidecar Author" && xa?.copyright == "Sidecar Copyright",
              "import applied XMP sidecar metadata")

        // 14. managed import copies originals into Originals/
        if let mstore = try? CatalogStore(packageURL: tmp.appendingPathComponent("Managed.photolibrary")) {
            let massets = ImportCoordinator(store: mstore).importFolder(src, mode: .managed)
            let managed = !massets.isEmpty && massets.allSatisfy {
                ($0.localPath?.contains("/Originals/") ?? false) && fm.fileExists(atPath: $0.localPath ?? "")
            }
            check(managed, "managed import copied \(massets.count) originals into Originals/")
        } else { check(false, "managed catalog") }

        // 15. batch rename moves the original on disk
        let ren = assets[2]
        if let renURL = RenameService.rename([ren], prefix: "RENAMED")[ren.id] {
            check(fm.fileExists(atPath: renURL.path) && renURL.lastPathComponent.hasPrefix("RENAMED_"),
                  "batch rename moved original to \(renURL.lastPathComponent)")
        } else { check(false, "batch rename") }
        _ = ren

        // 16. on-device Vision analysis + faces column roundtrip
        let vres = VisionService.analyze(src.appendingPathComponent("IMG_0001.jpg"))
        check(vres.faces == 0, "Vision ran on-device (0 faces on synthetic image, \(vres.sceneLabels.count) tags)")
        if let va = coordinator.importFolder(xsrc, autoTag: true).first {
            try? store.upsert([va])
            let back = (try? store.loadAssets())?.first { $0.id == va.id }
            check(back != nil && back?.faces == va.faces, "auto-tagged asset persisted (faces column)")
        } else { check(false, "auto-tag import") }

        // 17. relocated-original matching from a user-selected folder
        if let sample = assets.first, let path = sample.localPath {
            let relocated = tmp.appendingPathComponent("relocated")
            try? fm.createDirectory(at: relocated, withIntermediateDirectories: true)
            let copy = relocated.appendingPathComponent(sample.filename)
            try? fm.copyItem(at: URL(fileURLWithPath: path), to: copy)
            let found = RelocationService.replacement(for: sample, selected: relocated)
            let foundPath = found?.standardizedFileURL.path
            let copyPath = copy.standardizedFileURL.path
            check(foundPath == copyPath,
                  "relocation matched moved original by folder selection - found \(found?.path ?? "nil"), expected \(copy.path)")
        } else { check(false, "relocation sample asset") }

        // 18. missing detection after deleting an original
        if let p = assets.first(where: { fm.fileExists(atPath: $0.localPath ?? "") })?.localPath {
            try? fm.removeItem(at: URL(fileURLWithPath: p))
            check(!fm.fileExists(atPath: p), "simulated missing original (file removed)")
        }

        // 19. offline external-volume classification (§6.4 ORG-007)
        check(VolumeMonitor.volumeRoot(of: "/Volumes/Photos/2026/a.jpg") == "/Volumes/Photos",
              "external volume root extracted")
        check(VolumeMonitor.volumeRoot(of: "/Users/me/Pictures/a.jpg") == nil, "internal path has no volume root")
        check(VolumeMonitor.pathByReplacingVolumeRoot(
            in: "/Volumes/OldName/Photos/2026/a.jpg",
            oldRoot: "/Volumes/OldName",
            newRoot: "/Volumes/NewName"
        ) == "/Volumes/NewName/Photos/2026/a.jpg", "external volume root replacement")
        check(VolumeMonitor.volumeIdentifier(for: tmp)?.isEmpty == false, "filesystem volume identifier read")
        check(VolumeMonitor.status(forInaccessible: "/Volumes/NoSuchDrive_\(UUID().uuidString)/x.jpg") == .offline,
              "unmounted volume → offline")
        check(VolumeMonitor.status(forInaccessible: "/Users/me/gone_\(UUID().uuidString).jpg") == .missing,
              "internal gone → missing")

        try? fm.removeItem(at: tmp)
        print(failures == 0 ? "--- pipeline OK ---" : "--- \(failures) FAILURE(S) ---")
        exit(failures == 0 ? 0 : 1)
    }

    private static func writeTestImage(to url: URL, width: Int, height: Int, seed: Int,
                                       gps: [CFString: Any]? = nil, exif: [CFString: Any]? = nil) {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        let top = CGColor(red: Double((seed * 47) % 255) / 255, green: 0.45, blue: 0.6, alpha: 1)
        let bottom = CGColor(red: 0.2, green: Double((seed * 83) % 255) / 255, blue: 0.7, alpha: 1)
        ctx.setFillColor(top)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(bottom)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        guard let cg = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        var properties: [CFString: Any] = [:]
        if let gps { properties[kCGImagePropertyGPSDictionary] = gps }
        if let exif { properties[kCGImagePropertyExifDictionary] = exif }
        CGImageDestinationAddImage(dest, cg, properties.isEmpty ? nil : properties as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    private static func writeBlackImage(to url: URL, width: Int, height: Int) {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        ctx.setFillColor(CGColor.black)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cg = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
    }

    private static func imageIsUniformBlack(at url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 32,
              ] as CFDictionary)
        else { return true }
        let width = cg.width
        let height = cg.height
        let bytesPerPixel = 4
        var data = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        guard let context = CGContext(data: &data,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width * bytesPerPixel,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return true }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        var index = 0
        while index < data.count {
            if data[index] > 2 || data[index + 1] > 2 || data[index + 2] > 2 {
                return false
            }
            index += bytesPerPixel
        }
        return true
    }

    /// variant 0: vertical bands · 1: bands + small corner mark (near-dup) · 2: horizontal bands (far).
    private static func writeStructured(to url: URL, variant: Int) {
        let w = 120, h = 90
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        let mid = CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        let bright = CGColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1)
        let dark = CGColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1)
        ctx.setFillColor(mid)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        if variant == 2 {
            for y in stride(from: 0, to: h, by: 15) {
                ctx.setFillColor((y / 15) % 2 == 0 ? bright : dark)
                ctx.fill(CGRect(x: 0, y: y, width: w, height: 15))
            }
        } else {
            for x in stride(from: 0, to: w, by: 15) {
                ctx.setFillColor((x / 15) % 2 == 0 ? bright : dark)
                ctx.fill(CGRect(x: x, y: 0, width: 15, height: h))
            }
            if variant == 1 {
                ctx.setFillColor(mid)
                ctx.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
            }
        }
        guard let cg = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
    }
}
