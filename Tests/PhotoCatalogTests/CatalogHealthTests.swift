import XCTest
@testable import PhotoCatalog

final class CatalogHealthTests: XCTestCase {
    func testSummaryLabelsMissingCachesAndKeepsSubMegabytePrecision() {
        var report = HealthReport()
        report.assetCount = 7
        report.cacheBytes = 378 * 1024

        let cacheText = ByteCountFormatter.string(fromByteCount: report.cacheBytes, countStyle: .file)

        XCTAssertTrue(report.summary.contains("缺失缩略图 0"))
        XCTAssertTrue(report.summary.contains("缺失预览 0"))
        XCTAssertTrue(report.summary.contains("缓存 \(cacheText)"))
        XCTAssertFalse(report.summary.contains("缓存 0 MB"))
    }
}
