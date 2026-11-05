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

    /// A managed import copied its photos into Originals: the card or folder they came from
    /// being gone is expected, not a problem. A referenced folder that's gone still is.
    func testManagedSourceWhoseImportFolderIsGoneIsNotUnavailable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-health-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try CatalogStore(packageURL: dir.appendingPathComponent("Library.photolibrary"))
        try store.addSourceRoot(id: "card", displayName: "Card", path: dir.appendingPathComponent("Ejected card").path,
                                bookmark: nil, mode: .managed)

        XCTAssertEqual(CatalogHealth.check(store, assets: []).unavailableSourceRoots, 0)

        try store.addSourceRoot(id: "folder", displayName: "Folder", path: dir.appendingPathComponent("Deleted").path,
                                bookmark: nil)
        XCTAssertEqual(CatalogHealth.check(store, assets: []).unavailableSourceRoots, 1)
    }

    /// An original the app can't read (a sandboxed copy that lost access to it still sees it) is
    /// a missing one to the health check, and to the scan of the originals' availability.
    func testAnOriginalThatCantBeReadIsMissing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-health-read-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try CatalogStore(packageURL: dir.appendingPathComponent("Library.photolibrary"))
        let original = dir.appendingPathComponent("IMG_0001.JPG")
        try Data("jpeg".utf8).write(to: original)
        var asset = DemoData.assets[0]
        asset.isDemo = false
        asset.localPath = original.path
        asset.status = .ready

        XCTAssertEqual(CatalogHealth.check(store, assets: [asset]).missingOriginals, 0)
        XCTAssertEqual(CatalogHealth.check(store, assets: [asset], canRead: { _ in false }).missingOriginals, 1)

        XCTAssertEqual(AssetAvailabilityService.changes(in: [asset], sourceRootsById: [:]), [])
        XCTAssertEqual(AssetAvailabilityService.changes(in: [asset], sourceRootsById: [:], canRead: { _ in false }),
                       [AssetAvailabilityUpdate(assetId: asset.id, status: .missing, localPath: original.path)])
    }
}
