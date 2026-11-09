import CoreServices
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PhotoCatalog

/// Which cataloged files a rescan quick-hashes: those an FSEvents batch names, or all of them
/// when the batch may not name every change (and for ⌘R). The others are compared by size and
/// modification time.
final class RescanHashingTests: CatalogTestCase {
    private static let fileModified = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified
        | kFSEventStreamEventFlagItemIsFile)

    /// Counts the quick hashes a rescan asks for, and of which files.
    private final class HashCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var hashed: [URL] = []
        var names: [String] { lock.withLock { hashed.map(\.lastPathComponent).sorted() } }

        func quickHash(_ url: URL, _ size: Int64) -> String? {
            lock.withLock { hashed.append(url) }
            return HashService.quickHash(url, fileSize: size)
        }
    }

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
    /// within the same second might.
    private func changeKeepingSizeAndTime(_ url: URL, shade: Int) throws {
        let before = try FileManager.default.attributesOfItem(atPath: url.path)
        try makeJPEG(at: url, shade: shade, comment: "variant-2")
        try FileManager.default.setAttributes([.modificationDate: try XCTUnwrap(before[.modificationDate])],
                                              ofItemAtPath: url.path)
        let after = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(after[.size] as? Int64, before[.size] as? Int64, "the change keeps the size")
    }

    /// Three photos cataloged in `source`; b and c then change keeping their size and time.
    private func catalogThreePhotos(in source: URL) throws
        -> (coordinator: ImportCoordinator, known: [Asset], byPath: [String: Asset]) {
        let files = ["a.jpg", "b.jpg", "c.jpg"].map { source.appendingPathComponent($0) }
        for (index, file) in files.enumerated() { try makeJPEG(at: file, shade: index * 3, comment: "variant-1") }
        let store = try CatalogStore(packageURL: scratch.appendingPathComponent("Library-\(UUID().uuidString).photolibrary"))
        let coordinator = ImportCoordinator(store: store)
        let known = coordinator.importFiles(files, from: source)
        XCTAssertEqual(known.count, 3)
        // keyed by every alias of each path, as the rescan keys them
        var byPath: [String: Asset] = [:]
        for asset in known {
            for alias in PathIdentity.aliases(forPath: try XCTUnwrap(asset.localPath)) { byPath[alias] = asset }
        }
        try changeKeepingSizeAndTime(files[1], shade: 3)
        try changeKeepingSizeAndTime(files[2], shade: 6)
        return (coordinator, known, byPath)
    }

    private func ids(of names: Set<String>, in known: [Asset]) -> Set<String> {
        Set(known.filter { names.contains($0.filename) }.map(\.id))
    }

    func testBatchNamingOneFileQuickHashesOnlyThatFile() throws {
        let source = scratch.appendingPathComponent("Source")
        let (coordinator, known, byPath) = try catalogThreePhotos(in: source)
        let hashing = AppState.hashedPaths(for: [(source.appendingPathComponent("b.jpg").path, Self.fileModified)])
        XCTAssertEqual(hashing, [source.appendingPathComponent("b.jpg").path])

        let counter = HashCounter()
        let changed = coordinator.scanChanged(in: source, knownAssetsByPath: byPath,
                                              scanned: ImportCoordinator.scanWithAliases(source),
                                              hashing: hashing, quickHash: { counter.quickHash($0, $1) })

        XCTAssertEqual(counter.names, ["b.jpg"], "only the file the batch names is hashed")
        XCTAssertEqual(Set(changed.map(\.id)), ids(of: ["b.jpg"], in: known),
                       "c's change, with no event of its own, waits for a rescan that hashes everything")
    }

    func testFolderOrMissedChangesEventHashesEverything() throws {
        let source = scratch.appendingPathComponent("Source")
        let (coordinator, known, byPath) = try catalogThreePhotos(in: source)
        let named = (path: source.appendingPathComponent("b.jpg").path, flags: Self.fileModified)
        // a folder, said by its flags or found on disk when the flags don't say
        XCTAssertNil(AppState.hashedPaths(for: [named, (source.path, 0)]))
        XCTAssertNil(AppState.hashedPaths(for: [named, (source.appendingPathComponent("Sub").path,
                                                        FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated
                                                                                | kFSEventStreamEventFlagItemIsDir))]))
        for flag in [kFSEventStreamEventFlagMustScanSubDirs, kFSEventStreamEventFlagUserDropped,
                     kFSEventStreamEventFlagKernelDropped, kFSEventStreamEventFlagRootChanged] {
            XCTAssertNil(AppState.hashedPaths(for: [named, (source.path, FSEventStreamEventFlags(flag))]), "flag \(flag)")
        }
        XCTAssertNil(AppState.hashedPaths(for: []))
        XCTAssertEqual(AppState.hashedPaths(for: [(source.appendingPathComponent("b.jpg").path, 0)]),
                       [source.appendingPathComponent("b.jpg").path], "a file without flags is a file")

        let counter = HashCounter()
        let changed = coordinator.scanChanged(in: source, knownAssetsByPath: byPath,
                                              scanned: ImportCoordinator.scanWithAliases(source),
                                              hashing: nil, quickHash: { counter.quickHash($0, $1) })

        XCTAssertEqual(counter.names, ["a.jpg", "b.jpg", "c.jpg"])
        XCTAssertEqual(Set(changed.map(\.id)), ids(of: ["b.jpg", "c.jpg"], in: known))
    }

    /// FSEvents reports real paths: /private/var/folders for a photo cataloged under
    /// /var/folders, as /private/tmp for /tmp.
    func testRealPathEventMatchesPhotoCatalogedUnderItsLink() throws {
        let plainFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-rescan-hashing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: plainFolder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: plainFolder) }
        let canonical = try XCTUnwrap(try plainFolder.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath)
        try XCTSkipIf(canonical == plainFolder.path, "the temporary directory has no second name here")
        let source = plainFolder.appendingPathComponent("Source")
        let (coordinator, known, byPath) = try catalogThreePhotos(in: source)
        XCTAssertEqual(known.first { $0.filename == "b.jpg" }?.localPath, source.appendingPathComponent("b.jpg").path)

        let counter = HashCounter()
        let changed = coordinator.scanChanged(
            in: source, knownAssetsByPath: byPath, scanned: ImportCoordinator.scanWithAliases(source),
            hashing: AppState.hashedPaths(for: [(canonical + "/Source/b.jpg", Self.fileModified)]),
            quickHash: { counter.quickHash($0, $1) })

        XCTAssertEqual(counter.names, ["b.jpg"])
        XCTAssertEqual(Set(changed.map(\.id)), ids(of: ["b.jpg"], in: known))
    }

    /// The watcher hands on what FSEvents says about each path: a file's event and a folder's.
    @MainActor
    func testWatcherDeliversEventFlags() async throws {
        let folder = scratch.appendingPathComponent("Watched")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var events: [FileWatcher.Event] = []
        let watcher = FileWatcher(paths: [folder.path], latency: 0.05) { events.append(contentsOf: $0) }
        watcher.start()
        defer { watcher.stop() }
        try Data("a".utf8).write(to: folder.appendingPathComponent("a.jpg"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Sub"), withIntermediateDirectories: true)

        func reported(_ name: String, _ flag: Int) -> Bool {
            events.contains { event in
                (event.path as NSString).lastPathComponent == name && event.flags & FSEventStreamEventFlags(flag) != 0
            }
        }
        try await waitUntil("the file's and the folder's events are reported") {
            reported("a.jpg", kFSEventStreamEventFlagItemIsFile) && reported("Sub", kFSEventStreamEventFlagItemIsDir)
        }
        XCTAssertFalse(reported("a.jpg", kFSEventStreamEventFlagItemIsDir))
    }

    /// The app end to end: an event for b reads b again, and c, changed with no event of its own,
    /// is read at the next ⌘R.
    @MainActor
    func testEventRescanReadsTheNamedFileAndCommandRReadsTheRest() async throws {
        let source = scratch.appendingPathComponent("Source")
        let files = ["a.jpg", "b.jpg", "c.jpg"].map { source.appendingPathComponent($0) }
        for (index, file) in files.enumerated() { try makeJPEG(at: file, shade: index * 3, comment: "variant-1") }
        let package = scratch.appendingPathComponent("Library.photolibrary")
        let store = try CatalogStore(packageURL: package)
        try store.addSourceRoot(id: "source-1", displayName: "Source", path: source.path, bookmark: nil)
        let known = ImportCoordinator(store: store)
            .importFiles(files, from: source, sourceRootId: "source-1", folderName: "Source")
        XCTAssertEqual(known.count, 3)
        try store.upsert(known)
        let b = try XCTUnwrap(known.first { $0.filename == "b.jpg" })
        let c = try XCTUnwrap(known.first { $0.filename == "c.jpg" })

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))
        app.watcher?.stop()
        try await waitUntil("launch checks finished") { !app.isCheckingOriginals && !app.isIncrementalRescanning }
        try changeKeepingSizeAndTime(files[1], shade: 3)
        try changeKeepingSizeAndTime(files[2], shade: 6)

        app.watchedFilesChanged([(files[1].path, Self.fileModified)])
        XCTAssertTrue(app.isIncrementalRescanning)
        try await waitUntil("rescan finished") { !app.isIncrementalRescanning }
        XCTAssertNotEqual(app.assets.first { $0.id == b.id }?.quickHash, b.quickHash, "b was read again")
        XCTAssertEqual(app.assets.first { $0.id == c.id }?.quickHash, c.quickHash, "c wasn't hashed")
        XCTAssertNotEqual(try store.loadAssets().first { $0.id == b.id }?.quickHash, b.quickHash)

        try await rescanToCompletion(app)
        XCTAssertNotEqual(app.assets.first { $0.id == c.id }?.quickHash, c.quickHash, "⌘R hashes every file")
        XCTAssertNotEqual(try store.loadAssets().first { $0.id == c.id }?.quickHash, c.quickHash)
    }
}
