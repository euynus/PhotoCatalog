import XCTest
@testable import PhotoCatalog

/// A prune ranks previews by when their photos were taken, newest kept, as the background pass
/// makes them, and not by when they were written: the pass writes the newest photos' first.
final class CachePruneOrderTests: XCTestCase {
    private var cache: URL!
    private let day: TimeInterval = 86_400

    override func setUp() {
        super.setUp()
        cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-cache-prune-order-\(UUID().uuidString)/Cache")
    }

    override func tearDown() {
        if let cache { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        super.tearDown()
    }

    @discardableResult
    private func write(_ relative: String, bytes: Int = 10_000, written: Date) throws -> URL {
        let url = cache.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: url.path)
        return url
    }

    /// Photos "p-1" (the newest) to "p-6", their previews written newest first, as a background
    /// pass writes them, and a prune running while it does.
    func testAPruneDuringABackfillKeepsTheNewestPhotosPreviews() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var dates: [String: Date] = [:]
        var previews: [String: URL] = [:]
        for n in 1...6 {
            let id = "p-\(n)"
            dates[id] = start.addingTimeInterval(-Double(n) * day)
            // the newest photo's preview written first, so it is the oldest file
            previews[id] = try write("Previews/2048/0\(n)/aa/\(id).jpg", written: start.addingTimeInterval(Double(n) * 60))
        }
        let thumbnail = try write("Thumbnails/512/06/aa/p-6.jpg", bytes: 1_000, written: start)

        let report = CacheService.prune(cache, captureDates: dates) { _ in 31_000 }

        XCTAssertEqual(report.removedFiles, 3)
        let kept = Set(previews.filter { FileManager.default.fileExists(atPath: $0.value.path) }.keys)
        XCTAssertEqual(kept, ["p-1", "p-2", "p-3"], "the newest photos' previews are kept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnail.path), "previews still go before thumbnails")
    }

    /// Files of no photo in the catalog go first; a developed preview is its photo's, though its
    /// name carries the settings and the photo's id has dashes; developed previews still go after
    /// plain ones.
    func testOrphansGoFirstAndDevelopedPreviewsAreTheirPhotos() throws {
        let now = Date()
        let dates = ["a-new": now, "b-old": now.addingTimeInterval(-30 * day)]
        let orphan = try write("Previews/2048/00/aa/gone.jpg", written: now)
        let oldPlain = try write("Previews/2048/01/aa/b-old.jpg", written: now.addingTimeInterval(-60))
        let newPlain = try write("Previews/2048/02/aa/a-new.jpg", written: now.addingTimeInterval(-120))
        let oldEdited = try write("Edited/Previews/2048/01/aa/b-old-1x2y3z.jpg", written: now.addingTimeInterval(-60))
        let newEdited = try write("Edited/Previews/2048/02/aa/a-new-4u5v6w.jpg", written: now.addingTimeInterval(-120))

        // room for two of the five
        let report = CacheService.prune(cache, captureDates: dates) { _ in 20_000 }

        XCTAssertEqual(report.removedFiles, 3)
        for removed in [orphan, oldPlain, newPlain] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: removed.path), removed.lastPathComponent)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldEdited.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newEdited.path))

        // and of the developed ones, the older photo's goes first
        _ = CacheService.prune(cache, captureDates: dates) { _ in 10_000 }
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldEdited.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newEdited.path))
    }

    /// A file of no photo written since the cutoff (the photos read for the prune, or the import
    /// running began) is a photo being added: it's kept longest, after the dated photos' files.
    /// One of no photo written before the cutoff is an orphan, and still goes first.
    func testAFileOfNoPhotoWrittenSinceTheCutoffIsKeptAsTheNewest() throws {
        let cutoff = Date(timeIntervalSince1970: 1_800_000_000)
        let dates = ["old": cutoff.addingTimeInterval(-30 * day), "new": cutoff.addingTimeInterval(-day)]
        let orphan = try write("Previews/2048/00/aa/gone.jpg", written: cutoff.addingTimeInterval(-60))
        let incoming = try write("Previews/2048/01/aa/incoming.jpg", written: cutoff.addingTimeInterval(60))
        let old = try write("Previews/2048/02/aa/old.jpg", written: cutoff.addingTimeInterval(-120))
        let new = try write("Previews/2048/03/aa/new.jpg", written: cutoff.addingTimeInterval(-120))

        // room for one of the four
        let report = CacheService.prune(cache, captureDates: dates, orphansWrittenBefore: cutoff) { _ in 10_000 }

        XCTAssertEqual(report.removedFiles, 3)
        for removed in [orphan, old, new] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: removed.path), removed.lastPathComponent)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: incoming.path), "a new photo's preview went before older ones")
    }

    /// Without dates, as before: the oldest written go first.
    func testWithoutDatesTheOldestWrittenGoFirst() throws {
        let now = Date()
        let older = try write("Previews/2048/01/aa/x.jpg", written: now.addingTimeInterval(-600))
        let newer = try write("Previews/2048/02/aa/y.jpg", written: now)

        _ = CacheService.prune(cache, maxBytes: 10_000)

        XCTAssertFalse(FileManager.default.fileExists(atPath: older.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newer.path))
    }
}

/// A prune while an import runs: the import writes its photos' cache files before it adds the
/// photos, so files of no photo in the catalog written since it began are kept, while older ones
/// (orphans) and the previews of photos taken longest ago go first.
final class CachePruneDuringImportTests: CatalogTestCase {
    @MainActor
    func testAPruneDuringAnImportKeepsTheImportsNewFiles() async throws {
        let (store, package, imported, _) = try importPhoto("a.jpg", shade: 2)
        let app = openCatalog(package)
        let asset = try XCTUnwrap(app.assets.first { $0.id == imported.id })
        let now = Date()
        func file(_ name: String, megabytes: Double, written: Date) throws -> URL {
            let url = store.preview2048URL.appendingPathComponent("zz/\(name).jpg")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: Int(megabytes * 1_048_576)).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: url.path)
            return url
        }
        let orphan = try file("gone", megabytes: 1, written: now.addingTimeInterval(-3_600))
        // written by the import, its photo not yet added
        let incoming = try file("incoming", megabytes: 0.9, written: now.addingTimeInterval(-30))
        try Data(count: 1_048_576).write(to: URL(fileURLWithPath: asset.preview))

        var run = ImportRun(source: scratch.appendingPathComponent("Card"), mode: .referenced,
                            startedAt: now.addingTimeInterval(-60))
        run.phase = .importing
        app.importRun = run
        app.importing = true
        defer { app.importing = false }
        app.cacheLimitMB = 1
        app.pruneCacheToLimit()
        try await waitUntil("the prune finished") { app.toastCenter.toasts.last?.icon == "trash" }

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path), "an orphan written before the import was kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: asset.preview))
        XCTAssertTrue(FileManager.default.fileExists(atPath: incoming.path), "the photo being imported lost its preview")
        XCTAssertTrue(FileManager.default.fileExists(atPath: asset.thumb), "previews still go before thumbnails")
    }
}
