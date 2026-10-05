import CryptoKit
import Darwin
import Foundation
import ImageIO
import SQLite3

enum FullBackupError: Error, CustomStringConvertible {
    case targetExists(String)
    case unsafePath(String)
    case missingFile(String)
    case sourceChanged(String)
    case integrityMismatch(String)
    case invalidManifest(String)
    case invalidCatalog(String)

    var description: String {
        switch self {
        case .targetExists(let path): return "Backup/restore target already exists: \(path)"
        case .unsafePath(let path): return "Unsafe backup/restore path: \(path)"
        case .missingFile(let path): return "Required backup file is missing: \(path)"
        case .sourceChanged(let path): return "File changed during backup/verification: \(path)"
        case .integrityMismatch(let path): return "Backup size or SHA-256 mismatch: \(path)"
        case .invalidManifest(let reason): return "Invalid full-backup manifest: \(reason)"
        case .invalidCatalog(let reason): return "Invalid full-backup catalog: \(reason)"
        }
    }
}

/// Synchronous, off-main-thread operations. Callers must retain security-scoped access and
/// persist committed catalog edits before starting; uncommitted UI drafts are excluded.
/// SQLite is a consistent read snapshot; files
/// are pinned and checked during copying, not a filesystem-wide point-in-time snapshot.
///
/// Coverage: catalog metadata/history, active real originals (one copy per source path),
/// neighboring XMPs, all regular Config files, and LUTs and generated fill PNGs referenced
/// by active edits/history/snapshots. Generated pixels must exist; never regenerate them.
/// Excludes deleted/demo originals, global preferences/preset lists, credentials, jobs to
/// resume, unrelated external files and regenerable thumbnail/preview/analysis caches.
enum FullBackupService {
    static let manifestName = "full-backup.json"
    static let libraryDirectory = "Library"
    static let lutDirectory = "Config/FullBackupLUTs"
    static let fillDirectory = "Config/FullBackupFills"
    static let minimumSchemaVersion = 25

    static func supportsSchema(_ version: Int) -> Bool {
        (minimumSchemaVersion...CatalogStore.latestSchemaVersion).contains(version)
    }

    enum Phase: String, Sendable { case snapshot, copying, verifying, restoring, complete }

    struct Progress: Sendable {
        let phase: Phase
        let completedFiles: Int
        let totalFiles: Int
        let bytes: Int64
    }

    struct Report: Sendable {
        let url: URL
        let assetCount: Int
        let originalCount: Int
        let sidecarCount: Int
        let configurationCount: Int
        let lutCount: Int
        let fillCount: Int
        let bytes: Int64
    }

    struct Manifest: Codable, Sendable {
        var format = "PhotoCatalogFullBackup"
        var version = 1
        let createdAt: Date
        let sourceCatalogPath: String
        let schemaVersion: Int
        var assets: [AssetReference]
        var files: [FileEntry]
    }

    struct AssetReference: Codable, Sendable {
        let id: String
        let sourcePath: String
        let original: String
    }

    struct FileEntry: Codable, Sendable {
        enum Kind: String, Codable, Sendable { case database, catalogManifest, original, sidecar, configuration, lut, fill }
        var path: String
        let kind: Kind
        var size: Int64
        var sha256: String
    }

    /// `destination` is a NEW backup package, not the directory to put a backup inside.
    /// No previous backup is replaced, including when publication races another writer.
    @discardableResult
    static func backup(_ store: CatalogStore, to destination: URL,
                       externalLUTDirectory: URL = LUTLibrary.folder,
                       externalFillDirectory: URL = GenerativeFill.folder,
                       cancellation: CancellationFlag? = nil,
                       progress: (Progress) -> Void = { _ in }) throws -> Report {
        try FullBackupFiles.checkCancellation(cancellation)
        let source = try FullBackupFiles.directory(store.packageURL)
        let target = try safeDestination(destination, excluding: [source])
        let staging = try FullBackupFiles.Staging(destination: target)
        let library = staging.url.appendingPathComponent(libraryDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: false)
        progress(Progress(phase: .snapshot, completedFiles: 0, totalFiles: 0, bytes: 0))
        let snapshot = library.appendingPathComponent("catalog.sqlite")
        try snapshotDatabase(from: source.appendingPathComponent("catalog.sqlite"), to: snapshot,
                             cancellation: cancellation)
        let index = try inspectCatalog(snapshot)
        try removeClosedStagingSHM(at: snapshot)
        let plan = try copyPlan(index, source: source, externalLUTDirectory: externalLUTDirectory,
                                externalFillDirectory: externalFillDirectory,
                                destination: target, cancellation: cancellation)
        var files: [FileEntry] = [], copiedBytes: Int64 = 0
        for item in plan.files {
            try FullBackupFiles.checkCancellation(cancellation)
            let output = library.appendingPathComponent(item.path)
            try FullBackupFiles.createParents(for: output, within: library)
            if let identity = item.identity { try FullBackupFiles.requireUnchanged(item.source, since: identity) }
            let digest = try FullBackupFiles.fingerprint(item.source, copyingTo: output, cancellation: cancellation)
            if item.kind == .fill { try validateFill(output) }
            files.append(FileEntry(path: item.path, kind: item.kind, size: digest.size, sha256: digest.sha256))
            copiedBytes += digest.size
            progress(Progress(phase: .copying, completedFiles: files.count, totalFiles: plan.files.count, bytes: copiedBytes))
        }
        let databaseHash = try FullBackupFiles.fingerprint(snapshot, cancellation: cancellation)
        files.append(FileEntry(path: "catalog.sqlite", kind: .database,
                               size: databaseHash.size, sha256: databaseHash.sha256))
        let manifest = Manifest(createdAt: Date(), sourceCatalogPath: source.path,
                                schemaVersion: index.schemaVersion, assets: plan.assets, files: files)
        try validate(manifest)
        try validateCatalog(index, against: manifest)
        try validateLibraryManifest(library, schema: manifest.schemaVersion)
        let manifestData = try encoded(manifest)
        guard manifestData.count <= 256 * 1024 * 1024 else { throw FullBackupError.invalidManifest("Manifest is too large") }
        try FullBackupFiles.writeNew(manifestData, to: staging.url.appendingPathComponent(manifestName))
        try verifyFiles(manifest, in: library, cancellation: cancellation, progress: progress)
        try validateInventory(manifest, in: library, cancellation: cancellation)
        try FullBackupFiles.checkCancellation(cancellation)
        try staging.publish()
        let report = report(manifest, at: target)
        progress(Progress(phase: .complete, completedFiles: files.count, totalFiles: files.count, bytes: report.bytes))
        return report
    }

    /// Verification never opens the backup with SQLite. Catalog queries operate on a
    /// disposable verified copy, so even a WAL-mode header cannot create sidecars in it.
    static func verify(_ backup: URL, cancellation: CancellationFlag? = nil,
                       progress: (Progress) -> Void = { _ in }) throws -> Report {
        let (root, manifest) = try readManifest(backup)
        let library = root.appendingPathComponent(libraryDirectory)
        try verifyFiles(manifest, in: library, cancellation: cancellation, progress: progress)
        let scratch = try FullBackupFiles.Staging(destination: FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-backup-verify-" + UUID().uuidString))
        let database = scratch.url.appendingPathComponent("catalog.sqlite")
        let digest = try FullBackupFiles.fingerprint(library.appendingPathComponent("catalog.sqlite"),
                                                     copyingTo: database, cancellation: cancellation)
        guard let entry = manifest.files.first(where: { $0.kind == .database }),
              entry.size == digest.size, entry.sha256 == digest.sha256 else {
            throw FullBackupError.integrityMismatch("catalog.sqlite")
        }
        try validateCatalog(inspectCatalog(database), against: manifest)
        try validateLibraryManifest(library, schema: manifest.schemaVersion)
        try validateInventory(manifest, in: library, cancellation: cancellation)
        return report(manifest, at: root)
    }

    /// Restores to a NEW .photolibrary. Nothing writes to the backup, source catalog,
    /// original locations, global LUT directory or any existing restore target.
    @discardableResult
    static func restore(_ backup: URL, to destination: URL, cancellation: CancellationFlag? = nil,
                        progress: (Progress) -> Void = { _ in }) throws -> Report {
        try FullBackupFiles.checkCancellation(cancellation)
        let (root, manifest) = try readManifest(backup)
        guard destination.pathExtension.lowercased() == "photolibrary" else {
            throw FullBackupError.unsafePath(destination.path)
        }
        let target = try safeDestination(destination,
            excluding: [root, URL(fileURLWithPath: manifest.sourceCatalogPath)])
        let library = root.appendingPathComponent(libraryDirectory)
        try validateInventory(manifest, in: library, cancellation: cancellation)
        let staging = try FullBackupFiles.Staging(destination: target)
        var bytes: Int64 = 0
        for (offset, file) in manifest.files.enumerated() {
            try FullBackupFiles.checkCancellation(cancellation)
            let output = staging.url.appendingPathComponent(file.path)
            try FullBackupFiles.createParents(for: output, within: staging.url)
            let digest = try FullBackupFiles.fingerprint(library.appendingPathComponent(file.path),
                                                        copyingTo: output, cancellation: cancellation)
            guard digest.size == file.size, digest.sha256 == file.sha256 else {
                throw FullBackupError.integrityMismatch(file.path)
            }
            if file.kind == .fill { try validateFill(output) }
            bytes += digest.size
            progress(Progress(phase: .restoring, completedFiles: offset + 1,
                              totalFiles: manifest.files.count, bytes: bytes))
        }
        try validateInventory(manifest, in: staging.url, cancellation: cancellation)
        let index = try inspectCatalog(staging.url.appendingPathComponent("catalog.sqlite"))
        try validateCatalog(index, against: manifest)
        try validateLibraryManifest(staging.url, schema: manifest.schemaVersion)
        try rewriteRestoredCatalog(at: staging.url, finalURL: target, manifest: manifest,
                                   index: index, cancellation: cancellation)
        try removeClosedStagingSHM(at: staging.url.appendingPathComponent("catalog.sqlite"))
        try validateLibraryManifest(staging.url, schema: CatalogStore.latestSchemaVersion)
        try validateInventory(manifest, in: staging.url, cancellation: cancellation)
        try FullBackupFiles.checkCancellation(cancellation)
        try staging.publish()
        progress(Progress(phase: .complete, completedFiles: manifest.files.count,
                          totalFiles: manifest.files.count, bytes: bytes))
        return report(manifest, at: target)
    }

    /// Renderer hook: prefer this file over the global LUT for a restored original. Keeping
    /// the original LUT id preserves presets/history without overwriting another library's LUT.
    static func packagedLUTURL(for id: String, originalURL: URL) -> URL? {
        guard FullBackupFiles.validComponent(id), originalURL.isFileURL else { return nil }
        guard let root = containingCatalog(originalURL) else { return nil }
        let url = root.appendingPathComponent(lutDirectory).appendingPathComponent(id + ".cube")
        return try? FullBackupFiles.regularFile(url)
    }

    /// GenerativeFill hook: load the PNG (including its region metadata) before consulting
    /// the global cache or invoking the model. The portable key excludes the old disk path.
    static func packagedFillURL(for index: Int, settings: DevelopSettings, originalURL: URL) -> URL? {
        guard settings.spots.indices.contains(index), let root = containingCatalog(originalURL),
              FullBackupFiles.contains(root.appendingPathComponent("Originals"), originalURL) else { return nil }
        let relative = String(originalURL.path.dropFirst(root.path.count + 1))
        let path = fillPath(original: relative, index: index, settings: settings)
        return try? FullBackupFiles.regularFile(root.appendingPathComponent(path))
    }

    private static func containingCatalog(_ originalURL: URL) -> URL? {
        guard originalURL.isFileURL else { return nil }
        var root = originalURL.deletingLastPathComponent()
        while root.path != "/" {
            if root.pathExtension.lowercased() == "photolibrary" { return root }
            root.deleteLastPathComponent()
        }
        return nil
    }

    private struct IndexedAsset {
        let id: String
        let path: String
        let folderID: String
        let folderName: String
    }

    private struct CatalogIndex {
        let schemaVersion: Int
        let assets: [IndexedAsset]
        let roots: [String]
        let lutIDs: Set<String>
        let fills: [RequiredFill]
    }

    private struct RequiredFill {
        let assetID: String
        let index: Int
        let settings: DevelopSettings
    }

    private struct PlannedFile {
        let source: URL
        let path: String
        let kind: FileEntry.Kind
        let identity: stat?
    }

    private static func copyPlan(_ index: CatalogIndex, source: URL, externalLUTDirectory: URL,
                                 externalFillDirectory: URL,
                                 destination: URL, cancellation: CancellationFlag?) throws
        -> (files: [PlannedFile], assets: [AssetReference]) {
        var files: [String: PlannedFile] = [:], originals: [String: String] = [:]
        var assets: [AssetReference] = []
        func add(_ url: URL, path: String, kind: FileEntry.Kind) throws {
            guard FullBackupFiles.validRelativePath(path) else { throw FullBackupError.unsafePath(path) }
            let url = try FullBackupFiles.regularFile(url)
            let key = FullBackupFiles.pathKey(path)
            if let previous = files[key] {
                guard previous.source == url, previous.path == path else {
                    throw FullBackupError.invalidManifest("Colliding filenames: \(path)")
                }
                return
            }
            let identity = kind == .original ? try FullBackupFiles.metadata(url) : nil
            files[key] = PlannedFile(source: url, path: path, kind: kind, identity: identity)
        }
        for root in index.roots where root.hasPrefix("/") {
            // A missing/offline root can be stale after relinking; each original is still
            // required below. Do not resolve or use old bookmarks to redirect any writes.
            let url = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath()
            guard !FullBackupFiles.contains(url, destination) else { throw FullBackupError.unsafePath(destination.path) }
        }
        for asset in index.assets {
            try FullBackupFiles.checkCancellation(cancellation)
            let original = try FullBackupFiles.regularFile(URL(fileURLWithPath: asset.path))
            let directory = original.deletingLastPathComponent()
            guard !FullBackupFiles.contains(directory, destination) else { throw FullBackupError.unsafePath(destination.path) }
            let canonical = (try? original.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath) ?? original.path
            let path: String
            if let existing = originals[canonical] {
                path = existing
            } else {
                let directoryID = SHA256.hash(data: Data(directory.path.utf8)).map { String(format: "%02x", $0) }.joined()
                path = "Originals/\(directoryID)/\(original.lastPathComponent)"
                try add(original, path: path, kind: .original)
                originals[canonical] = path
                // Preserve both conventional XMP names. Keeping same-directory photos and
                // videos together also preserves Live Photo/RAW+JPEG sidecar selection.
                let sidecars = [original.deletingPathExtension().appendingPathExtension("xmp"),
                                original.appendingPathExtension("xmp")]
                for sidecar in Set(sidecars) {
                    if try FullBackupFiles.metadata(sidecar) != nil {
                        try add(sidecar, path: "Originals/\(directoryID)/\(sidecar.lastPathComponent)", kind: .sidecar)
                    }
                }
            }
            assets.append(AssetReference(id: asset.id, sourcePath: asset.path, original: path))
        }
        try add(source.appendingPathComponent("manifest.json"), path: "manifest.json", kind: .catalogManifest)
        let config = source.appendingPathComponent("Config")
        if try FullBackupFiles.metadata(config) != nil {
            for file in try FullBackupFiles.files(in: config, cancellation: cancellation) {
                if file.lastPathComponent == ".DS_Store" { continue }
                let path = String(file.path.dropFirst(source.path.count + 1))
                try add(file, path: path, kind: .configuration)
            }
        }
        for id in index.lutIDs.sorted() {
            let path = "\(lutDirectory)/\(id).cube"
            let local = source.appendingPathComponent(path)
            let file = try FullBackupFiles.metadata(local) != nil
                ? local : externalLUTDirectory.appendingPathComponent(id + ".cube")
            _ = try FullBackupFiles.regularFile(file)
            if let existing = files[FullBackupFiles.pathKey(path)] {
                guard existing.source == file else { throw FullBackupError.invalidManifest("Conflicting LUT: \(id)") }
                files[FullBackupFiles.pathKey(path)] = PlannedFile(source: file, path: path, kind: .lut, identity: nil)
            } else {
                try add(file, path: path, kind: .lut)
            }
        }
        let references = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        for fill in index.fills {
            try FullBackupFiles.checkCancellation(cancellation)
            guard let asset = references[fill.assetID] else { throw FullBackupError.invalidCatalog("Orphan fill") }
            let original = URL(fileURLWithPath: asset.sourcePath)
            let path = fillPath(original: asset.original, index: fill.index, settings: fill.settings)
            let globalKey = GenerativeFill.key(index: fill.index, settings: fill.settings, url: original)
            let resource = packagedFillURL(for: fill.index, settings: fill.settings, originalURL: original)
                ?? externalFillDirectory.appendingPathComponent(globalKey + ".png")
            try validateFill(resource)
            if let existing = files[FullBackupFiles.pathKey(path)] {
                guard existing.source == resource else { throw FullBackupError.invalidManifest("Conflicting generated fill") }
                files[FullBackupFiles.pathKey(path)] = PlannedFile(source: resource, path: path, kind: .fill, identity: nil)
            } else {
                try add(resource, path: path, kind: .fill)
            }
        }
        return (files.values.sorted { $0.path < $1.path }, assets)
    }

    private static func inspectCatalog(_ url: URL) throws -> CatalogIndex {
        _ = try FullBackupFiles.regularFile(url)
        let db = try Database(path: url.path)
        try db.execChecked("PRAGMA trusted_schema=OFF;")
        guard try db.query("PRAGMA integrity_check;").map({ $0.text("integrity_check") }) == ["ok"] else {
            throw FullBackupError.invalidCatalog("SQLite integrity check failed")
        }
        let schema = try db.query("SELECT MAX(version) AS version FROM schema_migrations;").first?.int("version")
        guard let schema, supportsSchema(schema) else {
            throw FullBackupError.invalidCatalog("Unsupported schema: \(schema ?? 0)")
        }
        guard try db.query("SELECT name FROM sqlite_master WHERE type IN ('trigger','view');").isEmpty else {
            throw FullBackupError.invalidCatalog("Unexpected triggers or views")
        }
        let assets: [IndexedAsset] = try db.queryMap("""
        SELECT id, local_path, folder_id, folder_name FROM assets WHERE deleted=0 AND is_demo=0 ORDER BY id;
        """) { row in
            guard let id = row.text("id"), FullBackupFiles.validComponent(id),
                  let path = row.text("local_path"), path.hasPrefix("/"), !path.utf8.contains(0),
                  let folderID = row.text("folder_id"), !folderID.isEmpty else {
                throw FullBackupError.invalidCatalog("Active asset has an invalid id, path or source root")
            }
            return IndexedAsset(id: id, path: path, folderID: folderID, folderName: row.text("folder_name") ?? folderID)
        }
        var lutIDs = Set<String>(), fills: [RequiredFill] = []
        for table in ["develop_settings", "develop_history", "develop_snapshots"] {
            _ = try db.queryMap("""
            SELECT d.asset_id, d.settings FROM \(table) d JOIN assets a ON a.id=d.asset_id WHERE a.deleted=0 AND a.is_demo=0;
            """) { row -> String? in
                guard let json = row.text("settings"),
                      let document = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
                    throw FullBackupError.invalidCatalog("Unreadable develop settings")
                }
                if let value = document["lutId"], !(value is NSNull) {
                    guard let id = value as? String, FullBackupFiles.validComponent(id) else {
                        throw FullBackupError.invalidCatalog("Invalid LUT reference")
                    }
                    lutIDs.insert(id)
                }
                if document["spots"] != nil {
                    let settings = try JSONDecoder().decode(DevelopSettings.self, from: Data(json.utf8))
                    for (offset, spot) in settings.spots.enumerated()
                    where spot.mode == .remove && spot.strokes.contains(where: { $0.pointCount > 0 }) {
                        guard let assetID = row.text("asset_id") else { throw FullBackupError.invalidCatalog("Orphan fill") }
                        fills.append(RequiredFill(assetID: assetID, index: offset, settings: settings))
                    }
                }
                return nil
            }
        }
        let roots = try db.queryMap("SELECT path_hint FROM source_roots;") { $0.text("path_hint") }
        guard try db.query("PRAGMA foreign_key_check;").isEmpty,
              db.walCheckpointTruncate(),
              try db.query("PRAGMA journal_mode=DELETE;").first?.text("journal_mode") == "delete" else {
            throw FullBackupError.invalidCatalog("Cannot validate/flush staging database")
        }
        return CatalogIndex(schemaVersion: schema, assets: assets, roots: roots, lutIDs: lutIDs, fills: fills)
    }

    private static func rewriteRestoredCatalog(at staging: URL, finalURL: URL, manifest: Manifest,
                                               index: CatalogIndex, cancellation: CancellationFlag?) throws {
        // CatalogStore initializes only this new private copy, including its standard cache
        // directories. Cached image paths name their future location and regenerate on demand.
        let store = try CatalogStore(packageURL: staging)
        if index.schemaVersion < CatalogStore.latestSchemaVersion {
            // CatalogStore migrated only our private copy. Its automatic pre-migration
            // snapshots still contain old paths/jobs; the immutable full backup is retained.
            for file in try FullBackupFiles.files(in: store.backupsURL, cancellation: cancellation) {
                try FileManager.default.removeItem(at: file)
            }
        }
        let thumbnails = ThumbnailService(store: store)
        let references = Dictionary(uniqueKeysWithValues: manifest.assets.map { ($0.id, $0) })
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let folders = Dictionary(grouping: index.assets, by: \.folderID)
        try store.db.execChecked("PRAGMA trusted_schema=OFF;")
        try store.db.transaction {
            try store.db.run("UPDATE assets SET local_path=NULL, thumb='', preview='', status='missing';")
            for asset in index.assets {
                try FullBackupFiles.checkCancellation(cancellation)
                guard let reference = references[asset.id] else { throw FullBackupError.invalidManifest("Missing asset") }
                func finalPath(_ url: URL) -> String {
                    finalURL.appendingPathComponent(String(url.path.dropFirst(staging.path.count + 1))).path
                }
                try store.db.run("UPDATE assets SET local_path=?,thumb=?,preview=?,status='ready' WHERE id=?;", [
                    .text(finalURL.appendingPathComponent(reference.original).path),
                    .text(finalPath(thumbnails.cachePath(assetId: asset.id, kind: .thumb512))),
                    .text(finalPath(thumbnails.cachePath(assetId: asset.id, kind: .preview2048))), .text(asset.id),
                ])
            }
            try store.db.run("""
            UPDATE source_roots SET path_hint=?,bookmark_data=NULL,volume_identifier=NULL,
                                    management_mode='managed',status='online';
            """, [.text(finalURL.appendingPathComponent("Originals").path)])
            for (id, assets) in folders {
                let directories = assets.compactMap { references[$0.id]?.original }
                    .map { Array($0.split(separator: "/").dropLast()) }
                var common = directories[0]
                for directory in directories.dropFirst() {
                    common = Array(zip(common, directory).prefix(while: { $0.0 == $0.1 }).map(\.0))
                }
                let path = finalURL.appendingPathComponent(common.joined(separator: "/")).path
                try store.db.run("""
                INSERT INTO source_roots(id,display_name,path_hint,management_mode,status,created_at)
                VALUES(?,?,?,'managed','online',?)
                ON CONFLICT(id) DO UPDATE SET path_hint=excluded.path_hint;
                """, [.text(id), .text(assets[0].folderName), .text(path), .text(timestamp)])
            }
            // A restored catalog must not resume jobs whose payloads point to an old volume.
            try store.db.run("DELETE FROM jobs;")
            try store.db.run("""
            UPDATE import_sessions SET state='cancelled',finished_at=?,error_message=?
            WHERE state NOT IN ('completed','cancelled','failed');
            """, [.text(timestamp), .text("Not resumed after full restore")])
        }
        guard try store.db.query("PRAGMA integrity_check;").map({ $0.text("integrity_check") }) == ["ok"],
              store.db.walCheckpointTruncate(),
              try store.db.query("PRAGMA journal_mode=DELETE;").first?.text("journal_mode") == "delete" else {
            throw FullBackupError.invalidCatalog("Restored catalog did not flush")
        }
        let url = staging.appendingPathComponent("manifest.json")
        guard var metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw FullBackupError.invalidCatalog("Invalid library manifest")
        }
        metadata["uuid"] = UUID().uuidString
        metadata["schemaVersion"] = CatalogStore.latestSchemaVersion
        metadata["restoredAt"] = ISO8601DateFormatter().string(from: Date())
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }

    /// Only after private staging connections have closed and confirmed DELETE mode.
    /// macOS SQLite can leave its unused shared-memory index after the WAL is removed.
    private static func removeClosedStagingSHM(at database: URL) throws {
        for suffix in ["-wal", "-journal"] {
            guard try FullBackupFiles.metadata(URL(fileURLWithPath: database.path + suffix)) == nil else {
                throw FullBackupError.invalidCatalog("Staging database still has a journal")
            }
        }
        let shm = URL(fileURLWithPath: database.path + "-shm")
        if try FullBackupFiles.metadata(shm) != nil {
            try FileManager.default.removeItem(at: FullBackupFiles.regularFile(shm))
        }
    }

    private static func safeDestination(_ destination: URL, excluding sources: [URL]) throws -> URL {
        let destination = try FullBackupFiles.checked(destination, allowMissingLeaf: true)
        for source in sources where FullBackupFiles.contains(source.standardizedFileURL, destination) {
            throw FullBackupError.unsafePath(destination.path)
        }
        var parent = destination.deletingLastPathComponent()
        while parent.path != "/" {
            guard parent.pathExtension.lowercased() != "photolibrary" else { throw FullBackupError.unsafePath(destination.path) }
            parent.deleteLastPathComponent()
        }
        guard try FullBackupFiles.metadata(destination) == nil else { throw FullBackupError.targetExists(destination.path) }
        return destination
    }

    private static func readManifest(_ backup: URL) throws -> (URL, Manifest) {
        let root = try FullBackupFiles.directory(backup)
        let entries = try FullBackupFiles.entries(in: root)
        for entry in entries where entry.lastPathComponent == ".DS_Store" {
            _ = try FullBackupFiles.regularFile(entry)
        }
        guard Set(entries.map(\.lastPathComponent).filter { $0 != ".DS_Store" }) == [manifestName, libraryDirectory] else {
            throw FullBackupError.invalidManifest("Unexpected or missing package entries")
        }
        let url = try FullBackupFiles.regularFile(root.appendingPathComponent(manifestName))
        guard let info = try FullBackupFiles.metadata(url), info.st_size <= 256 * 1024 * 1024 else {
            throw FullBackupError.invalidManifest("Manifest is too large")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        try validate(manifest)
        return (root, manifest)
    }

    private static func validate(_ manifest: Manifest) throws {
        guard manifest.format == "PhotoCatalogFullBackup", manifest.version == 1,
              supportsSchema(manifest.schemaVersion),
              manifest.sourceCatalogPath.hasPrefix("/"), !manifest.sourceCatalogPath.utf8.contains(0) else {
            throw FullBackupError.invalidManifest("Unsupported format or schema")
        }
        var names = Set<String>(), originals = Set<String>(), total: Int64 = 0
        for file in manifest.files {
            guard FullBackupFiles.validRelativePath(file.path), (file.path as NSString).lastPathComponent != ".DS_Store",
                  file.size >= 0,
                  file.sha256.utf8.count == 64, file.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  names.insert(FullBackupFiles.pathKey(file.path)).inserted else {
                throw FullBackupError.invalidManifest("Invalid or colliding file: \(file.path)")
            }
            let sum = total.addingReportingOverflow(file.size)
            guard !sum.overflow else { throw FullBackupError.invalidManifest("Invalid total size") }
            total = sum.partialValue
            let validLocation: Bool
            switch file.kind {
            case .database: validLocation = file.path == "catalog.sqlite"
            case .catalogManifest: validLocation = file.path == "manifest.json"
            case .original: validLocation = file.path.hasPrefix("Originals/"); originals.insert(file.path)
            case .sidecar: validLocation = file.path.hasPrefix("Originals/") && file.path.lowercased().hasSuffix(".xmp")
            case .configuration: validLocation = file.path.hasPrefix("Config/")
            case .lut: validLocation = file.path.hasPrefix(lutDirectory + "/") && file.path.hasSuffix(".cube")
            case .fill: validLocation = file.path.hasPrefix(fillDirectory + "/") && file.path.hasSuffix(".png")
            }
            guard validLocation else { throw FullBackupError.invalidManifest("Invalid file role: \(file.path)") }
        }
        for path in names {
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty && parent != "." {
                guard !names.contains(parent) else { throw FullBackupError.invalidManifest("File/directory collision") }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        guard manifest.files.filter({ $0.kind == .database }).count == 1,
              manifest.files.filter({ $0.kind == .catalogManifest }).count == 1 else {
            throw FullBackupError.invalidManifest("Missing catalog payload")
        }
        var ids = Set<String>()
        for asset in manifest.assets {
            guard ids.insert(asset.id).inserted, FullBackupFiles.validComponent(asset.id),
                  asset.sourcePath.hasPrefix("/"), !asset.sourcePath.utf8.contains(0), originals.contains(asset.original) else {
                throw FullBackupError.invalidManifest("Invalid or uncovered asset: \(asset.id)")
            }
        }
        guard Set(manifest.assets.map(\.original)) == originals else {
            throw FullBackupError.invalidManifest("Unreferenced original payload")
        }
    }

    private static func validateCatalog(_ index: CatalogIndex, against manifest: Manifest) throws {
        guard index.schemaVersion == manifest.schemaVersion, index.assets.count == manifest.assets.count else {
            throw FullBackupError.invalidManifest("Catalog asset coverage differs")
        }
        let references = Dictionary(uniqueKeysWithValues: manifest.assets.map { ($0.id, $0) })
        var originalsBySource: [String: String] = [:]
        for asset in index.assets {
            guard let reference = references[asset.id], reference.sourcePath == asset.path,
                  FullBackupFiles.pathKey((reference.original as NSString).lastPathComponent)
                    == FullBackupFiles.pathKey((asset.path as NSString).lastPathComponent) else {
                throw FullBackupError.invalidManifest("Catalog asset mapping differs: \(asset.id)")
            }
            let key = FullBackupFiles.pathKey(URL(fileURLWithPath: asset.path).standardizedFileURL.path)
            if let previous = originalsBySource[key], previous != reference.original {
                throw FullBackupError.invalidManifest("Virtual copies do not share their original")
            }
            originalsBySource[key] = reference.original
        }
        let luts = Set(manifest.files.filter { $0.kind == .lut }.map(\.path))
        guard luts == Set(index.lutIDs.map { "\(lutDirectory)/\($0).cube" }) else {
            throw FullBackupError.invalidManifest("Catalog LUT coverage differs")
        }
        let expectedFills = try Set(index.fills.map { fill -> String in
            guard let original = references[fill.assetID]?.original else { throw FullBackupError.invalidManifest("Orphan fill") }
            return fillPath(original: original, index: fill.index, settings: fill.settings)
        })
        guard Set(manifest.files.filter { $0.kind == .fill }.map(\.path)) == expectedFills else {
            throw FullBackupError.invalidManifest("Generated fill coverage differs")
        }
    }

    private static func validateLibraryManifest(_ library: URL, schema: Int) throws {
        let url = try FullBackupFiles.regularFile(library.appendingPathComponent("manifest.json"))
        guard let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              metadata["schemaVersion"] as? Int == schema, metadata["uuid"] is String else {
            throw FullBackupError.invalidCatalog("Library manifest does not match database")
        }
    }

    private static func validateInventory(_ manifest: Manifest, in library: URL,
                                          cancellation: CancellationFlag?) throws {
        let actual = try FullBackupFiles.files(in: library, cancellation: cancellation)
            .filter { $0.lastPathComponent != ".DS_Store" }
            .map { String($0.path.dropFirst(library.path.count + 1)) }
        let actualPaths = Set(actual), expectedPaths = Set(manifest.files.map(\.path))
        guard actualPaths == expectedPaths else {
            func names(_ paths: Set<String>) -> String {
                let shown = paths.sorted().prefix(12).map(\.debugDescription).joined(separator: ", ")
                return "\(paths.count) [\(shown)\(paths.count > 12 ? ", ..." : "")]"
            }
            throw FullBackupError.invalidManifest("File inventory differs; missing \(names(expectedPaths.subtracting(actualPaths))); extra \(names(actualPaths.subtracting(expectedPaths)))")
        }
    }

    private static func verifyFiles(_ manifest: Manifest, in library: URL, cancellation: CancellationFlag?,
                                    progress: (Progress) -> Void) throws {
        try validateInventory(manifest, in: library, cancellation: cancellation)
        var bytes: Int64 = 0
        for (offset, file) in manifest.files.enumerated() {
            let digest = try FullBackupFiles.fingerprint(library.appendingPathComponent(file.path), cancellation: cancellation)
            guard digest.size == file.size, digest.sha256 == file.sha256 else { throw FullBackupError.integrityMismatch(file.path) }
            if file.kind == .fill { try validateFill(library.appendingPathComponent(file.path)) }
            bytes += digest.size
            progress(Progress(phase: .verifying, completedFiles: offset + 1, totalFiles: manifest.files.count, bytes: bytes))
        }
    }

    private static func encoded(_ manifest: Manifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(manifest)
    }

    private static func report(_ manifest: Manifest, at url: URL) -> Report {
        Report(url: url, assetCount: manifest.assets.count,
               originalCount: manifest.files.filter { $0.kind == .original }.count,
               sidecarCount: manifest.files.filter { $0.kind == .sidecar }.count,
               configurationCount: manifest.files.filter { $0.kind == .configuration }.count,
               lutCount: manifest.files.filter { $0.kind == .lut }.count,
               fillCount: manifest.files.filter { $0.kind == .fill }.count,
               bytes: manifest.files.reduce(0) { $0 + $1.size })
    }

    private static func fillPath(original: String, index: Int, settings: DevelopSettings) -> String {
        // GenerativeFill.key's dependencies, with the backed-up original's stable relative path
        // in place of its absolute path and modification time
        let text = original + "|" + GenerativeFill.pixelDependencies(index: index, settings: settings)
        let key = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(fillDirectory)/\(key).png"
    }

    private static func validateFill(_ url: URL) throws {
        let url = try FullBackupFiles.regularFile(url)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width == GenerativeFill.side, image.height == GenerativeFill.side,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let region = (properties[kCGImagePropertyPNGDictionary] as? [CFString: Any])?[kCGImagePropertyPNGDescription] as? String else {
            throw FullBackupError.invalidCatalog("Required generated fill is unreadable: \(url.path)")
        }
        let values = region.split(separator: ",").compactMap { Double($0) }
        guard values.count == 4, values.allSatisfy(\.isFinite), values[0] >= 0, values[1] >= 0,
              values[2] > 0, values[3] > 0, values[0] + values[2] <= 1.000001, values[1] + values[3] <= 1.000001 else {
            throw FullBackupError.invalidCatalog("Required generated fill has an invalid region: \(url.path)")
        }
    }

    /// Database intentionally exposes no SQLite handle. Use the system online-backup API
    /// through a separate read-only connection so committed WAL data is never missed and
    /// writers do not race a checkpoint/copy of the live file.
    private static func snapshotDatabase(from source: URL, to target: URL,
                                          cancellation: CancellationFlag?) throws {
        _ = try FullBackupFiles.regularFile(source)
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: source.path + suffix)
            if try FullBackupFiles.metadata(sidecar) != nil { _ = try FullBackupFiles.regularFile(sidecar) }
        }
        try FullBackupFiles.writeNew(Data(), to: target)
        var read: OpaquePointer?, write: OpaquePointer?
        defer { sqlite3_close(read); sqlite3_close(write) }
        guard sqlite3_open_v2(source.path, &read, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK else {
            throw FullBackupError.invalidCatalog("Cannot open source snapshot")
        }
        guard sqlite3_open_v2(target.path, &write, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK else {
            throw FullBackupError.invalidCatalog("Cannot create snapshot")
        }
        sqlite3_busy_timeout(read, 100)
        guard sqlite3_exec(read, "BEGIN; SELECT count(*) FROM sqlite_master;", nil, nil, nil) == SQLITE_OK else {
            throw FullBackupError.invalidCatalog("Cannot start read snapshot")
        }
        defer { sqlite3_exec(read, "ROLLBACK;", nil, nil, nil) }
        guard let backup = sqlite3_backup_init(write, "main", read, "main") else {
            throw FullBackupError.invalidCatalog("SQLite backup initialization failed")
        }
        var finished = false
        defer { if !finished { sqlite3_backup_finish(backup) } }
        var busyAttempts = 0
        while true {
            try FullBackupFiles.checkCancellation(cancellation)
            let status = sqlite3_backup_step(backup, 256)
            if status == SQLITE_DONE { break }
            if status == SQLITE_BUSY || status == SQLITE_LOCKED {
                busyAttempts += 1
                guard busyAttempts <= 160 else { throw FullBackupError.invalidCatalog("SQLite snapshot remained busy") }
                Thread.sleep(forTimeInterval: 0.025)
            } else if status != SQLITE_OK {
                throw FullBackupError.invalidCatalog("SQLite snapshot failed (\(status))")
            }
        }
        let status = sqlite3_backup_finish(backup)
        finished = true
        guard status == SQLITE_OK else { throw FullBackupError.invalidCatalog("SQLite snapshot could not finish") }
    }
}
