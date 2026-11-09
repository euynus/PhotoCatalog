import Foundation
import CoreGraphics

extension PipelineCheck.Run {
    /// 6. exact-duplicate detection (the identical pair)
    func exactDuplicates() {
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
            let keepId = group.items[0].id
            let report = DuplicateResolutionService.resolve(group, current: assets, keepId: keepId,
                                                            action: .removeFromCatalog)
            let others = Set(group.items.map(\.id)).subtracting([keepId])
            check(report.affectedCount == 1 && report.removedIds == others,
                  "duplicate resolution removed non-kept catalog item")
        } else { check(false, "duplicate resolution sample group") }
    }

    /// 9. FTS5 substring search
    func substringSearch() {
        check(!(store.search("G_00") ?? []).isEmpty, "FTS5 search matches inside filenames")
        check((store.search("Project A") ?? []).contains(assets[0].id),
              "FTS5 search includes project metadata")
        check((store.search("5\"x7") ?? []).contains(assets[0].id),
              "FTS5 search safely matches quoted text")
    }

    /// 10. catalog health check
    func healthCheck() {
        let health = CatalogHealth.check(store, assets: assets)
        check(health.dbIntegrityOK && health.assetCount >= 7,
              "health check: db \(health.dbIntegrityOK ? "ok" : "BAD"), \(health.assetCount) assets")
        check(health.isHealthy && health.missingOriginals == 0 && health.missingThumbnails == 0
              && health.missingPreviews == 0 && health.unavailableSourceRoots == 0
              && health.activeJobs == 0 && health.failedJobs == 0,
              "health check: refs, sources, and jobs ok")
        var emptyCacheAssets = assets
        emptyCacheAssets[0] = emptyCacheAssets[0].rebuilt(thumb: "", preview: "")
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
    }

    /// 11. perceptual dHash (near pair similar, far pair dissimilar)
    func perceptualHashes() {
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
        check(PerceptualHash.canRunAutomaticAnalysis(assetCount: PerceptualHash.automaticAnalysisLimit)
              && !PerceptualHash.canRunAutomaticAnalysis(
                assetCount: PerceptualHash.automaticAnalysisLimit + 1
              ),
              "automatic perceptual comparison is bounded for large catalogs")
    }
}
