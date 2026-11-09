import XCTest
@testable import PhotoCatalog

/// The cache's size from one walk: the whole cache and its plain thumbnails, and what a prune
/// leaves, files still being written included.
final class CacheUsageTests: XCTestCase {
    private var cache: URL!

    override func setUp() {
        super.setUp()
        // under the temporary directory as it's named, not resolved: /var/folders is a link
        cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-cache-usage-\(UUID().uuidString)/Cache")
    }

    override func tearDown() {
        if let cache { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        super.tearDown()
    }

    @discardableResult
    private func write(_ relative: String, bytes: Int, age: TimeInterval = 3_600) throws -> URL {
        let url = cache.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)],
                                              ofItemAtPath: url.path)
        return url
    }

    /// Plain thumbnails, previews, developed thumbnails and previews, a hidden file and one being
    /// written.
    private func seed() throws {
        try write("Thumbnails/256/ab/cd/a.jpg", bytes: 1_000)
        try write("Thumbnails/512/ab/cd/a.jpg", bytes: 3_000)
        try write("Thumbnails/.DS_Store", bytes: 70)
        try write("Previews/2048/ab/cd/a.jpg", bytes: 50_000, age: 7_200)
        try write("Previews/1600/ef/01/b.jpg", bytes: 40_000, age: 7_200)
        try write("Edited/Thumbnails/512/ab/cd/a-f.jpg", bytes: 5_000)
        try write("Edited/Previews/2048/ab/cd/a-f.jpg", bytes: 60_000, age: 7_200)
        try write("Previews/2048/ab/cd/.tmp-\(UUID().uuidString)-a.jpg", bytes: 20_000, age: 1)
    }

    func testUsageMatchesTheCacheAndItsThumbnailsFolder() throws {
        try seed()

        let usage = CacheService.usage(cache)

        XCTAssertEqual(usage.total, CatalogHealth.directorySize(cache))
        XCTAssertEqual(usage.thumbnails, CatalogHealth.directorySize(cache.appendingPathComponent("Thumbnails")))
        XCTAssertEqual(usage.thumbnails, 4_070, "Edited/Thumbnails is not the thumbnails folder")
    }

    func testUsageOfAMissingCacheIsNothing() {
        let usage = CacheService.usage(cache)
        XCTAssertEqual(usage.total, 0)
        XCTAssertEqual(usage.thumbnails, 0)
    }

    /// What a prune leaves and the files being written make the cache's size, whether it removed
    /// files or not.
    func testPruneReportsTheCachesSizeWithFilesBeingWritten() throws {
        try seed()

        let kept = CacheService.prune(cache, maxBytes: 10_000_000)
        XCTAssertEqual(kept.removedFiles, 0)
        XCTAssertEqual(kept.writingBytes, 20_000)
        XCTAssertEqual(kept.afterBytes + kept.writingBytes, CatalogHealth.directorySize(cache))

        let pruned = CacheService.prune(cache, maxBytes: 100_000)
        XCTAssertGreaterThan(pruned.removedFiles, 0)
        XCTAssertEqual(pruned.writingBytes, 20_000, "the file being written is left alone")
        XCTAssertEqual(pruned.afterBytes + pruned.writingBytes, CatalogHealth.directorySize(cache))
    }

    /// The cache under a linked folder (/var → /private/var) still tells developed previews from
    /// plain ones: plain previews go first, though the developed one is older.
    func testPruneTakesPlainPreviewsBeforeDevelopedOnes() throws {
        let plain = try write("Previews/2048/ab/cd/a.jpg", bytes: 50_000, age: 60)
        let developed = try write("Edited/Previews/2048/ab/cd/a-f.jpg", bytes: 50_000, age: 7_200)

        let report = CacheService.prune(cache, maxBytes: 60_000)

        XCTAssertEqual(report.removedFiles, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plain.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: developed.path))
    }
}
