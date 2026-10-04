import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// No real-library access: tiny files exercise storage and restored edit-resource readers.
/// Call from SelfCheck.run(); intentionally independent of AppState and UserDefaults.
enum FullBackupCheck {
    static func run() {
        do {
            let checks: [(String, () throws -> Void)] = [
                ("standard aliases", checkStandardAliases),
                ("round trip", checkRoundTrip),
                ("resource readers", checkResourceReaders),
                ("failure cleanup", checkFailures),
                ("untrusted backups", checkUntrustedBackups),
                ("cancellation and publication", checkCancellationAndPublication),
            ]
            for (name, check) in checks {
                print("[full-backup] \(name)")
                fflush(stdout)
                try check()
            }
            print("--- full backup assertions passed ---")
        } catch {
            fatalError("Full backup check failed: \(error)")
        }
    }

    private static func checkStandardAliases() throws {
        for alias in ["/var", "/tmp"] {
            let aliased = URL(fileURLWithPath: alias, isDirectory: true)
            let physical = URL(fileURLWithPath: "/private" + alias, isDirectory: true)
            let resolvedAlias = try FullBackupFiles.directory(aliased)
            let resolvedPhysical = try FullBackupFiles.directory(physical)
            assert(resolvedAlias.path == physical.path,
                   "standard macOS aliases resolve to their physical directories")
            assert(resolvedPhysical.path == physical.path,
                   "Foundation must not turn an already physical path into a rejected alias")
            let name = ".pc-missing-" + UUID().uuidString
            let destination = try FullBackupFiles.checked(aliased.appendingPathComponent(name), allowMissingLeaf: true)
            assert(destination.path == physical.appendingPathComponent(name).path,
                   "new backup destinations under system aliases remain physical")
            assert(FullBackupFiles.contains(aliased, physical.appendingPathComponent(name))
                   && FullBackupFiles.contains(physical, aliased.appendingPathComponent(name)),
                   "containment checks cannot be bypassed by mixing alias and physical paths")
            assert(!FullBackupFiles.contains(aliased.appendingPathComponent(name),
                                            physical.appendingPathComponent(name + "-sibling")),
                   "normalized containment still respects directory boundaries")
        }
    }

    private final class Fixture {
        let root: URL
        let originals: URL
        let luts: URL
        let fills: URL
        let store: CatalogStore
        let asset: Asset
        let copy: Asset
        let jpeg: Asset
        let video: Asset
        let backup: URL

        init() throws {
            let fm = FileManager.default
            let root = try FullBackupFiles.directory(fm.temporaryDirectory)
                .appendingPathComponent("pc-full-backup-check-" + UUID().uuidString)
            let originals = root.appendingPathComponent("Source")
            let luts = root.appendingPathComponent("LUTs")
            let fills = root.appendingPathComponent("Fills")
            let backup = root.appendingPathComponent("Good.photobackup")
            try fm.createDirectory(at: originals, withIntermediateDirectories: true)
            try fm.createDirectory(at: luts, withIntermediateDirectories: false)
            try fm.createDirectory(at: fills, withIntermediateDirectories: false)
            var finished = false
            defer { if !finished { try? fm.removeItem(at: root) } }
            let store = try CatalogStore(packageURL: root.appendingPathComponent("Source.photolibrary"))
            try store.db.execChecked("PRAGMA wal_autocheckpoint=0;")
            let asset = FullBackupCheck.asset(id: "original", file: originals.appendingPathComponent("Frame.CR3"))
            let copy = asset.virtualCopy(id: "virtual", name: "Alternate")
            let jpeg = FullBackupCheck.asset(id: "jpeg", file: originals.appendingPathComponent("Frame.JPG"))
            let video = FullBackupCheck.asset(id: "video", file: originals.appendingPathComponent("Frame.MOV"))
            for item in [asset, jpeg, video] {
                try Data("original bytes for \(item.id)".utf8).write(to: URL(fileURLWithPath: item.localPath!))
            }
            try FullBackupCheck.writeFill(at: URL(fileURLWithPath: jpeg.localPath!), gray: 0.5)
            try Data("photo sidecar".utf8).write(to: originals.appendingPathComponent("Frame.xmp"))
            try Data("video sidecar".utf8).write(to: originals.appendingPathComponent("Frame.MOV.xmp"))
            var deleted = asset.virtualCopy(id: "deleted", name: "Deleted")
            deleted.deleted = true
            deleted.localPath = originals.appendingPathComponent("missing-deleted.CR3").path
            var demo = asset.virtualCopy(id: "demo", name: "Demo")
            demo.isDemo = true
            demo.localPath = originals.appendingPathComponent("missing-demo.CR3").path
            try store.upsert([asset, copy, jpeg, video, deleted, demo])
            try store.addSourceRoot(id: "source", displayName: "Source", path: originals.path,
                                    bookmark: Data([1, 2, 3]), volumeIdentifier: "old-volume")
            for id in ["current", "history", "snapshot"] {
                try Data(Self.cube.utf8).write(to: luts.appendingPathComponent(id + ".cube"))
            }
            var settings = DevelopSettings()
            settings.exposure = 0.75
            settings.lutId = "current"
            var stroke = BrushStroke()
            stroke.append(CGPoint(x: 0.5, y: 0.5))
            var spot = SpotRemoval(target: CGPoint(x: 0.5, y: 0.5), source: CGPoint(x: 0.5, y: 0.5), radius: 0.05)
            spot.mode = .remove
            spot.strokes = [stroke]
            settings.spots = [spot]
            let originalURL = URL(fileURLWithPath: asset.localPath!)
            try FullBackupCheck.writeFill(at: fills.appendingPathComponent(
                GenerativeFill.key(index: 0, settings: settings, url: originalURL) + ".png"), gray: 0.2)
            try store.saveDevelopSettings([asset.id: settings])
            settings.lutId = "history"
            settings.spots[0].target.x = 0.6
            try FullBackupCheck.writeFill(at: fills.appendingPathComponent(
                GenerativeFill.key(index: 0, settings: settings, url: originalURL) + ".png"), gray: 0.4)
            try store.appendDevelopHistory([asset.id: ("Historical LUT", settings)])
            settings.lutId = "snapshot"
            settings.spots[0].target.x = 0.7
            try FullBackupCheck.writeFill(at: fills.appendingPathComponent(
                GenerativeFill.key(index: 0, settings: settings, url: originalURL) + ".png"), gray: 0.6)
            try store.saveDevelopSnapshot(DevelopSnapshot(id: "saved-edit", name: "Saved", date: Date(), settings: settings),
                                          for: asset.id)
            let presets = store.configURL.appendingPathComponent("Presets")
            try fm.createDirectory(at: presets, withIntermediateDirectories: true)
            try Data("preset content".utf8).write(to: presets.appendingPathComponent("Portrait.xmp"))
            try Data([0, 1, 2, 3]).write(to: store.configURL.appendingPathComponent("edit-resource.bin"))
            try store.startImportSession(id: "interrupted")
            try store.startImportSession(id: "failed-history")
            try store.updateImportSession(id: "failed-history", state: "failed", totalCount: 1,
                                          importedCount: 0, skippedCount: 0, failedCount: 1,
                                          finishedAt: Date(), errorMessage: "Prior failure")
            try store.db.run("""
            INSERT INTO import_files(session_id,source_path,asset_id,outcome)
            VALUES('interrupted',?,'original','saved');
            """, [.text(asset.localPath!)])
            try store.db.run("""
            INSERT INTO jobs(id,type,payload_json,created_at,updated_at)
            VALUES('old-job','import',?, '2026-01-01','2026-01-01');
            """, [.text("{\"sourcePath\":\"\(originals.path)\"}")])
            self.root = root
            self.originals = originals
            self.luts = luts
            self.fills = fills
            self.backup = backup
            self.store = store
            self.asset = asset
            self.copy = copy
            self.jpeg = jpeg
            self.video = video
            finished = true
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func makeBackup(progress: (FullBackupService.Progress) -> Void = { _ in }) throws -> FullBackupService.Report {
            try FullBackupService.backup(store, to: backup, externalLUTDirectory: luts,
                                         externalFillDirectory: fills, progress: progress)
        }

        static let cube = """
        TITLE "Backup fixture"
        LUT_3D_SIZE 2
        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1
        """
    }

    private static func asset(id: String, file: URL) -> Asset {
        Asset(id: id, pid: 1, ori: "l", thumb: "/old/cache/thumb.jpg", preview: "/old/cache/preview.jpg",
              filename: file.lastPathComponent, type: file.pathExtension, isRaw: file.pathExtension == "CR3",
              folderId: "source", folderName: "Source", date: Date(timeIntervalSince1970: 1_700_000_000),
              width: 8, height: 8, orientation: 1, camera: "Fixture", lens: "Fixture", focal: 50,
              aperture: 2.8, shutter: "1/100", iso: 100, colorSpace: "sRGB", fileMB: 0.001,
              rating: 4, flag: .none, keywords: ["backup"], title: "Before snapshot", caption: "Fixture",
              location: "", gps: (0, 0), status: .ready, importedAt: Date(), localPath: file.path, isDemo: false)
    }

    private static func checkRoundTrip() throws {
        let fixture = try Fixture(), fm = FileManager.default
        let originalHashes = try hashes(in: fixture.originals)
        let sourceIdentity = try libraryIdentity(fixture.store.packageURL)
        var changedAfterSnapshot = false
        print("[full-backup] round trip: create")
        fflush(stdout)
        let report = try fixture.makeBackup { progress in
            if progress.phase == .copying && !changedAfterSnapshot {
                changedAfterSnapshot = true
                try! fixture.store.db.run("UPDATE assets SET title='After snapshot' WHERE id='original';")
            }
        }
        assert(changedAfterSnapshot && report.assetCount == 4 && report.originalCount == 3,
               "virtual copies share one physical backup and excluded originals are not required")
        assert(report.sidecarCount == 2 && report.configurationCount == 2 && report.lutCount == 3 && report.fillCount == 3,
               "shared/photo video sidecars, Config, historical LUTs and actual generated pixels are covered")
        try assertStandaloneDatabase(in: fixture.backup.appendingPathComponent(FullBackupService.libraryDirectory))
        assert(fixture.store.db.scalarText("PRAGMA journal_mode;") == "wal"
               && fm.fileExists(atPath: fixture.store.packageURL.appendingPathComponent("catalog.sqlite-wal").path),
               "staging cleanup leaves the live source in WAL mode")
        let backupHashes = try hashes(in: fixture.backup)
        let expectedFills = Set(try hashes(in: fixture.fills).values)
        print("[full-backup] round trip: verify")
        fflush(stdout)
        let verified = try FullBackupService.verify(fixture.backup)
        assert(verified.bytes == report.bytes && (try! hashes(in: fixture.backup)) == backupHashes,
               "verification includes all committed WAL rows without changing the backup")
        assert((try! hashes(in: fixture.originals)) == originalHashes, "backup never changes originals or sidecars")

        // The source disk and app-wide LUTs can be gone before recovery.
        try fm.moveItem(at: fixture.originals, to: fixture.root.appendingPathComponent("Offline-source"))
        try fm.removeItem(at: fixture.luts)
        try fm.removeItem(at: fixture.fills)
        let target = fixture.root.appendingPathComponent("Restored.photolibrary")
        print("[full-backup] round trip: restore")
        fflush(stdout)
        try FullBackupService.restore(fixture.backup, to: target)
        try assertStandaloneDatabase(in: target)
        let restored = try CatalogStore(packageURL: target)
        let assets = try restored.loadAssets()
        let real = assets.filter { !$0.isDemo && !$0.deleted }
        let original = real.first { $0.id == fixture.asset.id }!
        let copy = real.first { $0.id == fixture.copy.id }!
        assert(real.count == 4 && original.localPath == copy.localPath && copy.masterId == original.id,
               "restored virtual copies keep their identity and a shared original")
        assert(original.title == "Before snapshot" && original.rating == 4,
               "the catalog is the consistent snapshot, not later live edits")
        for item in real {
            assert(item.localPath!.hasPrefix(target.path + "/Originals/"), "restored original paths are in the new catalog")
            assert(fm.fileExists(atPath: item.localPath!), "each restored original exists")
            assert(item.thumb.hasPrefix(target.path + "/Cache/") && item.preview.hasPrefix(target.path + "/Cache/"),
                   "cache paths do not point into the old library")
        }
        let photoSidecar = XMPSidecar.sidecarURL(for: URL(fileURLWithPath: original.localPath!))
        let movie = real.first { $0.id == fixture.video.id }!
        let videoSidecar = XMPSidecar.sidecarURL(for: URL(fileURLWithPath: movie.localPath!))
        assert(try! Data(contentsOf: photoSidecar) == Data("photo sidecar".utf8), "photo sidecar roundtrips")
        assert(try! Data(contentsOf: videoSidecar) == Data("video sidecar".utf8), "video sidecar stays separate")
        let roots = try restored.loadSourceRoots()
        assert(roots.allSatisfy { $0.pathHint.hasPrefix(target.path + "/Originals") && $0.bookmarkData == nil
            && $0.volumeIdentifier == nil && $0.managementMode == "managed" }, "old bookmarks/volumes cannot redirect the restored library")
        assert(try! restored.loadDevelopSettings()[original.id]?.lutId == "current", "current edits persist")
        assert(try! restored.loadDevelopHistory(original.id).first?.settings.lutId == "history", "historical edits persist")
        assert(try! restored.loadDevelopSnapshots(original.id).first?.settings.lutId == "snapshot", "saved edits persist")
        for id in ["current", "history", "snapshot"] {
            let lut = FullBackupService.packagedLUTURL(for: id, originalURL: URL(fileURLWithPath: original.localPath!))
            assert(lut != nil && lut!.path.hasPrefix(target.path + "/Config/"), "LUT is resolved inside the recovered library")
            assert(LUTLibrary.parse(try! String(contentsOf: lut!, encoding: .utf8)) != nil, "restored LUT is usable")
        }
        let edits = [try restored.loadDevelopSettings()[original.id]!,
                     try restored.loadDevelopHistory(original.id).first!.settings,
                     try restored.loadDevelopSnapshots(original.id).first!.settings]
        let fillHashes = Set(edits.compactMap { settings -> String? in
            guard let file = FullBackupService.packagedFillURL(for: 0, settings: settings,
                                                              originalURL: URL(fileURLWithPath: original.localPath!)) else { return nil }
            return HashService.contentHash(file)
        })
        assert(fillHashes == expectedFills, "generated output PNGs and their placement metadata survive without running a model")
        let readerPixels = Set(edits.compactMap { settings -> Int? in
            guard let fill = GenerativeFill.fill(for: 0, settings: settings,
                url: URL(fileURLWithPath: original.localPath!), isRaw: true, make: false) else { return nil }
            assert(fill.image.width == GenerativeFill.side && fill.region == CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
                   "the actual fill reader returns the backed-up pixels and placement metadata")
            return pixel(fill.image)[0]
        })
        assert(readerPixels.count == 3, "current, historical and snapshot fills load without invoking a model")
        assert(try! Data(contentsOf: restored.configURL.appendingPathComponent("edit-resource.bin")) == Data([0, 1, 2, 3]),
               "catalog-owned resources are copied exactly")
        assert(restored.db.scalarInt("SELECT count(*) FROM jobs;") == 0
               && restored.db.scalarText("SELECT state FROM import_sessions WHERE id='interrupted';") == "cancelled",
               "restore never resumes old external-volume work")
        assert(restored.db.scalarInt("SELECT count(*) FROM import_files WHERE session_id='interrupted';") == 1,
               "schema v25 checkpoints remain as history even though their jobs cannot resume")
        assert(restored.db.scalarText("SELECT error_message FROM import_sessions WHERE id='failed-history' AND state='failed';") == "Prior failure",
               "terminal failed import history keeps its original state and reason")
        assert(restored.db.scalarInt("SELECT count(*) FROM assets WHERE (deleted=1 OR is_demo=1) AND local_path IS NOT NULL;") == 0,
               "excluded records keep no dangerous original paths")
        assert(try! libraryIdentity(target) != sourceIdentity, "restored library has a new identity")
        assert(fixture.store.db.scalarText("SELECT title FROM assets WHERE id='original';") == "After snapshot"
               && fixture.store.db.scalarInt("SELECT count(*) FROM jobs;") == 1
               && (try! libraryIdentity(fixture.store.packageURL)) == sourceIdentity, "restore did not modify the source catalog")
        assert((try! hashes(in: fixture.backup)) == backupHashes, "restore does not modify its backup")
        let second = fixture.root.appendingPathComponent("Second.photobackup")
        print("[full-backup] round trip: back up restored library")
        fflush(stdout)
        let rebased = try FullBackupService.backup(restored, to: second, externalLUTDirectory: fixture.luts,
                                                  externalFillDirectory: fixture.fills)
        assert(rebased.lutCount == 3 && rebased.fillCount == 3, "recovered edits use their packaged resources, not global files")
        assertNoStaging(fixture.root)
    }

    private static func assertStandaloneDatabase(in library: URL) throws {
        let database = library.appendingPathComponent("catalog.sqlite")
        let header = try Data(contentsOf: database).prefix(20)
        assert(header.count == 20 && header[18] == 1 && header[19] == 1,
               "published databases use rollback journaling, not a WAL-dependent header")
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecar = try FullBackupFiles.metadata(URL(fileURLWithPath: database.path + suffix))
            assert(sidecar == nil,
                   "published databases have no SQLite sidecar: \(suffix)")
        }
    }

    private static func checkResourceReaders() throws {
        let fixture = try Fixture(), fm = FileManager.default
        _ = try fixture.makeBackup()
        let globalBefore = LUTLibrary.cube(id: "current")?.data
        let first = fixture.root.appendingPathComponent("First.photolibrary")
        let second = fixture.root.appendingPathComponent("Second.photolibrary")
        try FullBackupService.restore(fixture.backup, to: first)
        try FullBackupService.restore(fixture.backup, to: second)
        let a = try CatalogStore(packageURL: first), b = try CatalogStore(packageURL: second)
        let assetsA = try a.loadAssets(), assetsB = try b.loadAssets()
        let photoA = URL(fileURLWithPath: assetsA.first { $0.id == "jpeg" }!.localPath!)
        let photoB = URL(fileURLWithPath: assetsB.first { $0.id == "jpeg" }!.localPath!)
        let lutA = FullBackupService.packagedLUTURL(for: "current", originalURL: photoA)!
        let lutB = FullBackupService.packagedLUTURL(for: "current", originalURL: photoB)!
        let red = "LUT_3D_SIZE 2\n" + Array(repeating: "1 0 0", count: 8).joined(separator: "\n")
        let blue = "LUT_3D_SIZE 2\n" + Array(repeating: "0 0 1", count: 8).joined(separator: "\n")
        try Data(red.utf8).write(to: lutA, options: .atomic)
        try Data(blue.utf8).write(to: lutB, options: .atomic)
        let colorA = try renderedLUT(photoA), colorB = try renderedLUT(photoB)
        assert(colorA[0] > colorA[2] + 100 && colorB[2] > colorB[0] + 100,
               "the real renderer resolves the same LUT id separately in each restored library")
        let priorDate = try lutA.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        try Data(blue.utf8).write(to: lutA, options: .atomic)
        try fm.setAttributes([.modificationDate: priorDate], ofItemAtPath: lutA.path)
        let replaced = try renderedLUT(photoA)
        assert(replaced[2] > replaced[0] + 100, "same-size same-mtime LUT replacement invalidates the file-identity cache")
        assert(LUTLibrary.cube(id: "current")?.data == globalBefore, "packaged LUT lookup never contaminates the global library")

        let originalA = URL(fileURLWithPath: assetsA.first { $0.id == "original" }!.localPath!)
        let originalB = URL(fileURLWithPath: assetsB.first { $0.id == "original" }!.localPath!)
        let settings = try a.loadDevelopSettings()["original"]!
        let fillA = FullBackupService.packagedFillURL(for: 0, settings: settings, originalURL: originalA)!
        let fillB = FullBackupService.packagedFillURL(for: 0, settings: settings, originalURL: originalB)!
        let otherHash = HashService.contentHash(fillB)
        let loadedA = GenerativeFill.fill(for: 0, settings: settings, url: originalA, isRaw: true, make: false)!
        let loadedB = GenerativeFill.fill(for: 0, settings: settings, url: originalB, isRaw: true, make: false)!
        assert(pixel(loadedA.image) == pixel(loadedB.image), "both restored readers start with the exact generated pixels")
        let priorFillDate = try fillA.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        let replacement = fixture.root.appendingPathComponent("Replacement.png")
        try writeFill(at: replacement, gray: 0.9)
        try Data(contentsOf: replacement).write(to: fillA, options: .atomic)
        try fm.setAttributes([.modificationDate: priorFillDate], ofItemAtPath: fillA.path)
        let changed = GenerativeFill.fill(for: 0, settings: settings, url: originalA, isRaw: true, make: false)!
        assert(pixel(changed.image)[0] > pixel(loadedA.image)[0] + 100, "replaced fill resources invalidate cached pixels")
        assert(GenerativeFill.forget(index: 0, settings: settings, url: originalA), "forget removes this restored copy's fill")
        assert(!fm.fileExists(atPath: fillA.path)
               && GenerativeFill.fill(for: 0, settings: settings, url: originalA, isRaw: true, make: false) == nil,
               "forget does not serve the old packaged PNG again, including from memory")
        assert(HashService.contentHash(fillB) == otherHash
               && GenerativeFill.fill(for: 0, settings: settings, url: originalB, isRaw: true, make: false) != nil,
               "forget leaves the other restored library and its cached fill untouched")
        assert(rejects { try FullBackupService.backup(a, to: fixture.root.appendingPathComponent("Missing-fill.photobackup"),
            externalLUTDirectory: fixture.luts, externalFillDirectory: fixture.fills) },
               "a forgotten resource must be regenerated before another complete backup can succeed")
    }

    private static func renderedLUT(_ original: URL) throws -> [Int] {
        var settings = DevelopSettings()
        settings.lutId = "current"
        settings.lutAmount = 100
        guard let source = DevelopRenderer.Source(url: original, isRaw: false, maxPixel: 16),
              let image = source.image(settings), let rendered = DevelopRenderer.render(image) else {
            throw FullBackupError.invalidCatalog("Restored LUT did not render")
        }
        return pixel(rendered)
    }

    private static func pixel(_ image: CGImage) -> [Int] {
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return data.map(Int.init)
    }

    private static func checkFailures() throws {
        let fixture = try Fixture(), fm = FileManager.default
        _ = try fixture.makeBackup()
        let good = try hashes(in: fixture.backup)
        assert(rejects { try fixture.makeBackup() }, "an existing good backup cannot be overwritten")
        assert(rejects { try FullBackupService.backup(fixture.store, to: fixture.store.packageURL) }, "source cannot be its own backup")
        assert(rejects { try FullBackupService.backup(fixture.store, to: fixture.store.packageURL.appendingPathComponent("Backup")) },
               "backup cannot be inside the source catalog")
        assert(rejects { try FullBackupService.backup(fixture.store, to: fixture.originals.appendingPathComponent("Backup")) },
               "backup cannot be inside a watched original directory")
        assert(rejects { try FullBackupService.restore(fixture.backup, to: fixture.store.packageURL) }, "restore cannot overwrite its source")
        assert(rejects { try FullBackupService.restore(fixture.backup, to: fixture.backup.appendingPathComponent("Nested.photolibrary")) },
               "restore cannot be inside the backup")
        let candidate = fixture.root.appendingPathComponent("Incomplete.photobackup")
        let original = URL(fileURLWithPath: fixture.asset.localPath!)
        let heldOriginal = fixture.root.appendingPathComponent("Held-original")
        try fm.moveItem(at: original, to: heldOriginal)
        assert(rejects { try FullBackupService.backup(fixture.store, to: candidate, externalLUTDirectory: fixture.luts,
                                                     externalFillDirectory: fixture.fills) },
               "missing original fails closed")
        try fm.moveItem(at: heldOriginal, to: original)
        let historicalLUT = fixture.luts.appendingPathComponent("history.cube")
        try fm.removeItem(at: historicalLUT)
        assert(rejects { try FullBackupService.backup(fixture.store, to: candidate, externalLUTDirectory: fixture.luts,
                                                     externalFillDirectory: fixture.fills) },
               "even a missing history-only LUT makes the backup incomplete")
        try Data(Fixture.cube.utf8).write(to: historicalLUT)
        let historical = try fixture.store.loadDevelopHistory(fixture.asset.id).first!.settings
        let fillURL = fixture.fills.appendingPathComponent(
            GenerativeFill.key(index: 0, settings: historical, url: original) + ".png")
        let fillData = try Data(contentsOf: fillURL)
        try fm.removeItem(at: fillURL)
        assert(rejects { try FullBackupService.backup(fixture.store, to: candidate, externalLUTDirectory: fixture.luts,
                                                     externalFillDirectory: fixture.fills) },
               "missing generated pixels are an incomplete backup, never silently regenerated")
        try fillData.write(to: fillURL)
        try fm.moveItem(at: original, to: heldOriginal)
        try fm.createSymbolicLink(at: original, withDestinationURL: URL(fileURLWithPath: fixture.jpeg.localPath!))
        assert(rejects { try FullBackupService.backup(fixture.store, to: candidate, externalLUTDirectory: fixture.luts,
                                                     externalFillDirectory: fixture.fills) },
               "original symlinks are not followed")
        try fm.removeItem(at: original)
        try fm.moveItem(at: heldOriginal, to: original)
        let link = fixture.store.configURL.appendingPathComponent("outside-resource")
        try fm.createSymbolicLink(at: link, withDestinationURL: fixture.originals)
        assert(rejects { try FullBackupService.backup(fixture.store, to: candidate, externalLUTDirectory: fixture.luts,
                                                     externalFillDirectory: fixture.fills) },
               "Config directory symlinks cannot escape coverage")
        try fm.removeItem(at: link)
        let parentLink = fixture.root.appendingPathComponent("Linked-destination")
        try fm.createSymbolicLink(at: parentLink, withDestinationURL: fixture.root)
        assert(rejects { try FullBackupService.backup(fixture.store, to: parentLink.appendingPathComponent("Unsafe")) },
               "symlinked destination ancestors are rejected")
        assert(!fm.fileExists(atPath: candidate.path) && (try! hashes(in: fixture.backup)) == good,
               "failure exposes no incomplete package and preserves the previous good backup")
        assertNoStaging(fixture.root)
    }

    private static func checkUntrustedBackups() throws {
        let fixture = try Fixture(), fm = FileManager.default
        _ = try fixture.makeBackup()
        let manifest = try readManifest(fixture.backup)
        let original = manifest.files.first { $0.kind == .original }!
        let output = fixture.root.appendingPathComponent("Must-not-exist.photolibrary")
        let tampered = fixture.root.appendingPathComponent("Tampered.photobackup")
        func reset() throws {
            if fm.fileExists(atPath: tampered.path) { try fm.removeItem(at: tampered) }
            try fm.copyItem(at: fixture.backup, to: tampered)
        }
        assert(FullBackupService.supportsSchema(25) && FullBackupService.supportsSchema(CatalogStore.latestSchemaVersion)
               && !FullBackupService.supportsSchema(24) && !FullBackupService.supportsSchema(CatalogStore.latestSchemaVersion + 1),
               "backup format v1 retains schema v25 support as the app schema advances")
        try reset()
        let finderMetadata = tampered.appendingPathComponent(".DS_Store")
        try Data("Finder metadata".utf8).write(to: finderMetadata)
        let library = tampered.appendingPathComponent(FullBackupService.libraryDirectory)
        try Data("Finder metadata".utf8).write(to: library.appendingPathComponent(".DS_Store"))
        _ = try FullBackupService.verify(tampered)
        try FullBackupService.restore(tampered, to: fixture.root.appendingPathComponent("Finder-safe.photolibrary"))
        try fm.removeItem(at: finderMetadata)
        try fm.createSymbolicLink(at: finderMetadata, withDestinationURL: URL(fileURLWithPath: fixture.asset.localPath!))
        assert(rejects { try FullBackupService.verify(tampered) }, "ignored Finder metadata must still be a regular file")
        try reset()
        try fm.createDirectory(at: library.appendingPathComponent(".DS_Store"), withIntermediateDirectories: false)
        assert(rejects { try FullBackupService.verify(tampered) }, "Finder metadata cannot be an untracked directory")
        try reset()
        try Data("untracked".utf8).write(to: library.appendingPathComponent("._catalog.sqlite"))
        assert(rejects { try FullBackupService.verify(tampered) }, "AppleDouble files are not silently accepted")
        try reset()
        try Data("untracked".utf8).write(to: tampered.appendingPathComponent("._full-backup.json"))
        assert(rejects { try FullBackupService.verify(tampered) }, "backup root enumeration also sees AppleDouble files")
        try reset()
        let damaged = tampered.appendingPathComponent(FullBackupService.libraryDirectory).appendingPathComponent(original.path)
        try Data(repeating: 0x58, count: Int(original.size)).write(to: damaged)
        assert(rejects { try FullBackupService.restore(tampered, to: output) }, "same-size byte corruption fails SHA-256")
        try reset()
        try fm.removeItem(at: damaged)
        assert(rejects { try FullBackupService.verify(tampered) }, "missing payload fails verification")
        try reset()
        try fm.removeItem(at: damaged)
        try fm.createSymbolicLink(at: damaged, withDestinationURL: URL(fileURLWithPath: fixture.asset.localPath!))
        assert(rejects { try FullBackupService.restore(tampered, to: output) }, "backup payload symlinks are rejected")
        for path in ["../outside", "/absolute", "Config/../../outside", "Config//file", "Config/./file", "Config\\escape"] {
            try reset()
            var forged = manifest
            forged.files[0].path = path
            try writeManifest(forged, at: tampered)
            assert(rejects { try FullBackupService.restore(tampered, to: output) }, "manifest traversal is rejected: \(path)")
        }
        try reset()
        var forged = manifest
        forged.assets.removeAll { $0.id == "virtual" }
        try writeManifest(forged, at: tampered)
        assert(rejects { try FullBackupService.verify(tampered) }, "a plausible manifest cannot omit an active catalog asset")
        try reset()
        forged = manifest
        var alias = forged.files.first { $0.kind == .configuration }!
        alias.path = alias.path.uppercased()
        forged.files.append(alias)
        try writeManifest(forged, at: tampered)
        assert(rejects { try FullBackupService.restore(tampered, to: output) }, "case aliases cannot overwrite the same restore file")
        assert(!fm.fileExists(atPath: output.path), "no invalid restore is exposed")
        assertNoStaging(fixture.root)
    }

    private static func checkCancellationAndPublication() throws {
        let fixture = try Fixture(), fm = FileManager.default
        let cancelled = fixture.root.appendingPathComponent("Cancelled.photobackup")
        let flag = CancellationFlag()
        assert(rejects { try FullBackupService.backup(fixture.store, to: cancelled, externalLUTDirectory: fixture.luts,
                                                     externalFillDirectory: fixture.fills,
                                                     cancellation: flag) { progress in
            if progress.phase == .copying { flag.set() }
        } }, "cancellation discards the private partial backup")
        assert(flag.isSet && !fm.fileExists(atPath: cancelled.path), "cancelled backup never becomes visible")
        _ = try fixture.makeBackup()
        let target = fixture.root.appendingPathComponent("Cancelled.photolibrary")
        let restoreFlag = CancellationFlag()
        assert(rejects { try FullBackupService.restore(fixture.backup, to: target, cancellation: restoreFlag) { progress in
            if progress.phase == .restoring { restoreFlag.set() }
        } }, "cancellation discards the private partial restore")
        assert(!fm.fileExists(atPath: target.path), "cancelled restore never becomes visible")
        let raced = fixture.root.appendingPathComponent("Race.photobackup")
        var placedCompetitor = false
        assert(rejects { try FullBackupService.backup(fixture.store, to: raced, externalLUTDirectory: fixture.luts,
                                                     externalFillDirectory: fixture.fills) { progress in
            if progress.phase == .verifying && progress.completedFiles == progress.totalFiles {
                try! fm.createDirectory(at: raced, withIntermediateDirectories: false)
                try! Data("keep me".utf8).write(to: raced.appendingPathComponent("existing"))
                placedCompetitor = true
            }
        } }, "atomic publication cannot replace a target created after preflight")
        assert(placedCompetitor && (try! Data(contentsOf: raced.appendingPathComponent("existing"))) == Data("keep me".utf8),
               "a racing writer's directory remains untouched")
        let restoredRace = fixture.root.appendingPathComponent("Race.photolibrary")
        assert(rejects { try FullBackupService.restore(fixture.backup, to: restoredRace) { progress in
            if progress.phase == .restoring && progress.completedFiles == progress.totalFiles {
                try! fm.createDirectory(at: restoredRace, withIntermediateDirectories: false)
                try! Data("keep library".utf8).write(to: restoredRace.appendingPathComponent("existing"))
            }
        } }, "restoring also refuses a target created after preflight")
        assert((try! Data(contentsOf: restoredRace.appendingPathComponent("existing"))) == Data("keep library".utf8),
               "the competing restore target is preserved")
        assertNoStaging(fixture.root)
    }

    private static func rejects<T>(_ body: () throws -> T) -> Bool {
        do { _ = try body(); return false } catch { return true }
    }

    private static func writeFill(at url: URL, gray: CGFloat) throws {
        let side = GenerativeFill.side
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw FullBackupError.invalidCatalog("Could not create fill fixture")
        }
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        guard let image = context.makeImage() else { throw FullBackupError.invalidCatalog("Could not draw fill fixture") }
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription: "0.25,0.25,0.5,0.5"],
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw FullBackupError.invalidCatalog("Could not write fill fixture") }
    }

    private static func hashes(in root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for file in try FullBackupFiles.files(in: root, cancellation: nil) {
            result[String(file.path.dropFirst(root.path.count + 1))] = HashService.contentHash(file)
        }
        return result
    }

    private static func libraryIdentity(_ root: URL) throws -> String {
        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("manifest.json")))
            as! [String: Any]
        return metadata["uuid"] as! String
    }

    private static func readManifest(_ backup: URL) throws -> FullBackupService.Manifest {
        try JSONDecoder().decode(FullBackupService.Manifest.self,
                                 from: Data(contentsOf: backup.appendingPathComponent(FullBackupService.manifestName)))
    }

    private static func writeManifest(_ manifest: FullBackupService.Manifest, at backup: URL) throws {
        try JSONEncoder().encode(manifest).write(to: backup.appendingPathComponent(FullBackupService.manifestName))
    }

    private static func assertNoStaging(_ parent: URL) {
        let names = try! FileManager.default.contentsOfDirectory(atPath: parent.path)
        assert(!names.contains { $0.hasPrefix(".pc-full-backup-") }, "only this operation's staging is cleaned up")
    }
}
