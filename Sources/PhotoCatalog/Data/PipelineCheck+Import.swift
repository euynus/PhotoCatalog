import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

extension PipelineCheck.Run {
    /// 1. generate 6 distinct test JPEGs + 1 exact duplicate
    func testImages() {
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
        let fixedCreatedAt = Date(timeIntervalSince1970: 1_600_000_000)
        try? fm.setAttributes([
            .modificationDate: fixedModifiedAt,
            .creationDate: fixedCreatedAt,
        ], ofItemAtPath: src.appendingPathComponent("IMG_0000.jpg").path)
    }

    /// 2. scanner
    func scanner() {
        let scanned = FileScanner.scan(src)
        check(scanned.count == 7, "scanner found 7 images (ignored notes.txt and nested catalog) — got \(scanned.count)")
    }

    /// 3. import pipeline (metadata + thumbnails + hashes)
    func importPipeline() {
        catalogPackage()
        sourceFolderImport()
        rawImport()
        configurablePreviews()
        folderTree()
        deduplicationAndPostActions()
        incrementalScan()
    }

    /// Part of step 3: imports the source folder (and again, reusing what it knows), and checks
    /// what an import reads, reports and caches.
    func sourceFolderImport() {
        coordinator = ImportCoordinator(store: store)
        var progressSnapshots: [ImportProgress] = []
        assets = coordinator.importFolder(src) { progressSnapshots.append($0) }
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
        timestampedAsset = assets.first { $0.filename == "IMG_0000.jpg" }
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
    }

    /// Part of step 3: a CR3, its cache files, and what renders from it.
    func rawImport() {
        let rawSrc = tmp.appendingPathComponent("raw-source")
        try? fm.createDirectory(at: rawSrc, withIntermediateDirectories: true)
        let cr3URL = rawSrc.appendingPathComponent("CANON.CR3")
        writeTestImage(to: cr3URL, width: 720, height: 480, seed: 45)
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
            writeBlackImage(to: previewURL, width: 96, height: 64)
            let detectedBlackPreview = coordinator.thumbnails.cachedRepresentationNeedsRegeneration(
                at: previewURL,
                original: originalURL,
                kind: .preview2048
            )
            let repairedPreview = coordinator.thumbnails.ensureCached(from: originalURL,
                                                                       assetId: cr3Asset.id,
                                                                       kind: .preview2048)
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
            check(detectedBlackPreview && repairedPreview?.path == cr3Asset.preview
                  && !imageIsUniformBlack(at: previewURL),
                  "CR3 black preview cache regenerates from original")
            check(detectedBlackCache && repairedThumb?.path == cr3Asset.thumb
                  && !imageIsUniformBlack(at: thumbURL),
                  "CR3 black thumbnail cache regenerates from preview fallback")
            // The size shortcut in cachedRepresentationNeedsRegeneration must never hide a
            // black render: full-size black JPEGs, encoded like the cache, stay under the bound.
            let blackProbe = fm.temporaryDirectory.appendingPathComponent("pc-black-\(UUID().uuidString).jpg")
            defer { try? fm.removeItem(at: blackProbe) }
            let blackBoundHolds = [ThumbnailService.Kind.thumb256, .thumb512, .preview2048].allSatisfy { kind in
                writeBlackImage(to: blackProbe, width: kind.maxPixel, height: kind.maxPixel, quality: 0.82)
                let size = (try? blackProbe.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
                return size <= ThumbnailService.maxUniformBlackBytes(for: kind)
                    && coordinator.thumbnails.cachedRepresentationNeedsRegeneration(
                        at: blackProbe, original: originalURL, kind: kind)
            }
            check(blackBoundHolds, "full-size black renders stay under the decode-skip size bound")

            var brighter = DevelopSettings()
            brighter.exposure = 1
            let edited = coordinator.thumbnails.ensureEdited(from: originalURL, isRaw: true, settings: brighter,
                                                             assetId: cr3Asset.id, kind: .thumb512)
            check(edited.map { $0.path.contains("/Cache/Edited/") && $0.lastPathComponent.contains(brighter.fingerprint)
                               && meanLuminance(at: $0) > meanLuminance(at: thumbURL) + 0.05 } == true
                  && fm.fileExists(atPath: thumbURL.path),
                  "developed thumbnails render adjustments into their own cache files")
            var turned = DevelopSettings()
            turned.rotation = 1
            let rotated = coordinator.thumbnails.ensureEdited(from: thumbURL, isRaw: false, settings: turned,
                                                              assetId: cr3Asset.id, kind: .thumb512)
            let thumbSize = pixelSize(at: thumbURL)
            check(rotated.flatMap(pixelSize) == thumbSize.map { CGSize(width: $0.height, height: $0.width) }
                  && thumbSize.map { $0.width != $0.height } == true,
                  "a quarter turn renders from the cached thumbnail with its sides swapped")

            var exportSettings = ExportSettings()
            exportSettings.resize = .longEdge
            exportSettings.edge = 512
            let rawItem = RenderedExportItem(
                assetId: cr3Asset.id, sourcePath: localPath, isRaw: true, develop: turned,
                originalSize: CGSize(width: cr3Asset.width, height: cr3Asset.height), baseName: "CR3", date: cr3Asset.date,
                camera: cr3Asset.camera, title: "", caption: "", keywords: [], rating: 0, author: "", copyright: "")
            let exported = RenderedExportService.render(rawItem, settings: exportSettings)
            check(exported.map { max($0.width, $0.height) == 512 } == true
                  && exported.map { ($0.width > $0.height) == ((thumbSize?.height ?? 0) > (thumbSize?.width ?? 0)) } == true,
                  "a CR3 exports at the requested size with its develop rotation")
        } else {
            check(false, "CR3 black preview cache regenerates from original")
            check(false, "CR3 black thumbnail cache regenerates from preview fallback")
        }
    }

    /// Part of step 3: previews made at 1600px.
    func configurablePreviews() {
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
    }

    /// Part of step 3: the folder tree of an imported folder with subfolders.
    func folderTree() {
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
    }

    /// Part of step 3: hashes and the import post actions. (The duplicate strategies are applied as
    /// a batch is saved; ImportPersistenceCheck checks them there.)
    func deduplicationAndPostActions() {
        check(assets.allSatisfy { $0.contentHash != nil && $0.quickHash != nil }, "content + quick hashes computed")
        // a photo with the first one's content hash but another size, for the duplicate groups later
        sameHashDifferentSize = assets[1]
        sameHashDifferentSize.contentHash = assets[0].contentHash
        sameHashDifferentSize.fileMB = assets[0].fileMB + 1
        let postKeywords = ImportPostActionService.normalizeKeywords("客户精选，旅行,客户精选")
        let postAssets = ImportPostActionService.apply(
            to: [assets[0]],
            actions: ImportPostActions(keywords: postKeywords, colorLabel: .green))
        check(postAssets.first?.keywords == ["客户精选", "旅行"] && postAssets.first?.colorLabel == .green,
              "import post actions apply keywords and color label")
        let templated = ImportPostActionService.apply(
            to: [assets[0]],
            actions: ImportPostActions(keywords: [], colorLabel: nil, author: " 摄影师 ", copyright: "© {year} 摄影师"))
        let captureYear = Calendar.captureWallClock.component(.year, from: assets[0].date)
        check(templated.first?.author == "摄影师" && templated.first?.copyright == "© \(captureYear) 摄影师",
              "the import metadata template sets author and copyright, {year} from the capture date")
        let postHierarchy = ImportPostActionService.normalizeKeywords("旅行/日本/东京")
        check(postHierarchy == ["旅行", "旅行/日本", "旅行/日本/东京"],
              "import post actions expand hierarchical keywords")
    }

    /// Part of step 3: an incremental scan after originals change.
    func incrementalScan() {
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
    }

    /// 16. on-device Vision analysis + faces column roundtrip
    func visionAnalysis() {
        let vres = VisionService.analyze(src.appendingPathComponent("IMG_0001.jpg"))
        check(vres.faces == 0, "Vision ran on-device (0 faces on synthetic image, \(vres.sceneLabels.count) tags)")
        if let va = coordinator.importFolder(xsrc, autoTag: true).first {
            try? store.upsert([va])
            let back = (try? store.loadAssets())?.first { $0.id == va.id }
            check(back != nil && back?.faces == va.faces, "auto-tagged asset persisted (faces column)")
        } else { check(false, "auto-tag import") }
    }
}
