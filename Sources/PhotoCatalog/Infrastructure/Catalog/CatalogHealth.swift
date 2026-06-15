// ============================================================
//  CatalogHealth — integrity & health check (PRD §6.1 CAT-005, §6.12 BAK-005)
// ============================================================
import Foundation

struct HealthReport {
    var dbIntegrityOK = true
    var assetCount = 0
    var missingOriginals = 0
    var missingThumbnails = 0
    var missingPreviews = 0
    var unavailableSourceRoots = 0
    var activeJobs = 0
    var failedJobs = 0
    var cacheBytes: Int64 = 0
    var backupCount = 0

    var cacheMB: Double { Double(cacheBytes) / (1024 * 1024) }
    var isHealthy: Bool {
        dbIntegrityOK
            && missingOriginals == 0
            && missingThumbnails == 0
            && missingPreviews == 0
            && unavailableSourceRoots == 0
            && failedJobs == 0
    }

    var summary: String {
        "数据库\(dbIntegrityOK ? "完好" : "异常") · \(assetCount) 张资产 · "
            + "缺失原件 \(missingOriginals) · 缩略图 \(missingThumbnails) · 预览 \(missingPreviews) · "
            + "源异常 \(unavailableSourceRoots) · 任务 \(activeJobs)/\(failedJobs) · "
            + String(format: "缓存 %.0f MB", cacheMB) + " · 备份 \(backupCount)"
    }
}

enum CatalogHealth {
    static func check(_ store: CatalogStore, assets: [Asset]) -> HealthReport {
        var r = HealthReport()
        r.dbIntegrityOK = (store.db.scalarText("PRAGMA integrity_check;") ?? "") == "ok"
        let real = assets.filter { !$0.isDemo && !$0.deleted }
        r.assetCount = store.assetCount()
        let fm = FileManager.default
        r.missingOriginals = real.filter {
            guard let p = $0.localPath else { return false }
            return !fm.fileExists(atPath: p)
        }.count
        r.missingThumbnails = real.filter {
            !$0.thumb.isEmpty && !$0.thumb.hasPrefix("http") && !fm.fileExists(atPath: $0.thumb)
        }.count
        r.missingPreviews = real.filter {
            !$0.preview.isEmpty && !$0.preview.hasPrefix("http") && !fm.fileExists(atPath: $0.preview)
        }.count
        r.unavailableSourceRoots = ((try? store.loadSourceRoots()) ?? []).filter {
            $0.status != "online" || !fm.fileExists(atPath: $0.pathHint)
        }.count
        r.activeJobs = ((try? store.loadJobs(states: ["running", "paused"])) ?? []).count
        r.failedJobs = ((try? store.loadJobs(states: ["failed"])) ?? []).count
        r.cacheBytes = directorySize(store.cacheURL)
        r.backupCount = BackupService.listBackups(store).count
        return r
    }

    static func directorySize(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in en {
            if let v = try? f.resourceValues(forKeys: Set(keys)), v.isRegularFile == true {
                total += Int64(v.fileSize ?? 0)
            }
        }
        return total
    }
}
