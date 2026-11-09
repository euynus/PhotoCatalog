import CoreServices
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PhotoCatalog

/// FSEvents batches that arrive during a rescan queue one rescan behind it, which quick-hashes
/// the files those batches named — or every file, once one of them may not name its changes.
final class CoalescedRescanHashingTests: CatalogTestCase {
    private static let fileModified = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified
        | kFSEventStreamEventFlagItemIsFile)

    /// An 80×60 JPEG of `shade` whose EXIF comment is `comment`: two comments of one length give
    /// two files of one size with different bytes.
    private func makeJPEG(at url: URL, shade: Int, comment: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let context = try XCTUnwrap(CGContext(data: nil, width: 80, height: 60, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let level = CGFloat(shade % 16) / 16
        context.setFillColor(CGColor(red: level, green: 1 - level, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString,
                                                                         1, nil))
        let properties = [kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: comment]] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    /// Saves other bytes over `url` keeping its size and modification time, as an editor's save
    /// within the same second might: only a quick hash finds the change.
    private func changeKeepingSizeAndTime(_ url: URL, shade: Int) throws {
        let before = try FileManager.default.attributesOfItem(atPath: url.path)
        try makeJPEG(at: url, shade: shade, comment: "variant-2")
        try FileManager.default.setAttributes([.modificationDate: try XCTUnwrap(before[.modificationDate])],
                                              ofItemAtPath: url.path)
        let after = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(after[.size] as? Int64, before[.size] as? Int64, "the change keeps the size")
    }

    /// a, b and c cataloged in a watched folder (its watcher stopped, so only the events a test
    /// hands in reach the app); b and c then change keeping their size and time.
    @MainActor
    private func appWithThreePhotos() throws -> (app: AppState, files: [URL], known: [String: Asset]) {
        let source = scratch.appendingPathComponent("Source")
        let files = ["a.jpg", "b.jpg", "c.jpg"].map { source.appendingPathComponent($0) }
        for (index, file) in files.enumerated() { try makeJPEG(at: file, shade: index * 3, comment: "variant-1") }
        let package = scratch.appendingPathComponent("Library.photolibrary")
        let store = try CatalogStore(packageURL: package)
        try store.addSourceRoot(id: "source-1", displayName: "Source", path: source.path, bookmark: nil)
        let imported = ImportCoordinator(store: store)
            .importFiles(files, from: source, sourceRootId: "source-1", folderName: "Source")
        XCTAssertEqual(imported.count, 3)
        try store.upsert(imported)
        let app = openCatalog(package)
        app.watcher?.stop()
        try changeKeepingSizeAndTime(files[1], shade: 3)
        try changeKeepingSizeAndTime(files[2], shade: 6)
        return (app, files, Dictionary(uniqueKeysWithValues: imported.map { ($0.filename, $0) }))
    }

    @MainActor
    private func quickHash(_ app: AppState, _ photo: Asset?) -> String? {
        app.assets.first { $0.id == photo?.id }?.quickHash
    }

    /// A batch naming b arrives while a's rescan runs: the rescan after it reads b again, and
    /// c, changed with no event of its own, waits for a rescan that hashes everything.
    @MainActor
    func testQueuedRescanHashesOnlyThePathsItsBatchesNamed() async throws {
        let (app, files, known) = try appWithThreePhotos()

        app.watchedFilesChanged([(files[0].path, Self.fileModified)])
        XCTAssertTrue(app.isIncrementalRescanning)
        app.watchedFilesChanged([(files[1].path, Self.fileModified)])
        XCTAssertTrue(app.needsIncrementalRescan, "a rescan is queued behind")
        XCTAssertEqual(app.pendingRescanHashing, [files[1].path])
        try await waitUntil("both rescans finished") { !app.isIncrementalRescanning }

        XCTAssertNotEqual(quickHash(app, known["b.jpg"]), known["b.jpg"]?.quickHash, "b was read again")
        XCTAssertEqual(quickHash(app, known["c.jpg"]), known["c.jpg"]?.quickHash, "c wasn't hashed")
        XCTAssertNil(app.pendingRescanHashing)
    }

    /// Batches queued behind a rescan, one of which may not name its changes (events dropped):
    /// the rescan after it hashes every file, whatever the others named.
    @MainActor
    func testQueuedRescanHashesEverythingWhenABatchMayHaveMissedChanges() async throws {
        let (app, files, known) = try appWithThreePhotos()

        app.watchedFilesChanged([(files[0].path, Self.fileModified)])
        XCTAssertTrue(app.isIncrementalRescanning)
        let dropped = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagKernelDropped)
        app.watchedFilesChanged([(files[0].deletingLastPathComponent().path, dropped)])
        app.watchedFilesChanged([(files[1].path, Self.fileModified)])
        XCTAssertTrue(app.needsIncrementalRescan)
        XCTAssertNil(app.pendingRescanHashing, "every file")
        try await waitUntil("both rescans finished") { !app.isIncrementalRescanning }

        XCTAssertNotEqual(quickHash(app, known["b.jpg"]), known["b.jpg"]?.quickHash)
        XCTAssertNotEqual(quickHash(app, known["c.jpg"]), known["c.jpg"]?.quickHash, "c was hashed too")
    }
}
