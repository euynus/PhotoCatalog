import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoCatalog

extension CatalogTestCase {
    /// An 80×60 image of `type` stamped the way a camera stamps it: `make`/`model` and the
    /// capture time `taken` ("yyyy:MM:dd HH:mm:ss"). `shade` varies the pixels.
    func makeShot(at url: URL, type: UTType = .jpeg, make: String, model: String, taken: String,
                  shade: Int = 0) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let context = CGContext(data: nil, width: 80, height: 60, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw NSError(domain: "CardImportTests", code: 1)
        }
        let level = CGFloat(shade % 16) / 16
        context.setFillColor(CGColor(red: level, green: 0.5, blue: 1 - level, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        let properties: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: make, kCGImagePropertyTIFFModel: model],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: taken],
        ]
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw NSError(domain: "CardImportTests", code: 2)
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "CardImportTests", code: 3) }
    }

    /// The contents of every file under `folder`, at any depth.
    func contentsOfFiles(under folder: URL) -> [Data] {
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        return (enumerator?.allObjects as? [URL] ?? []).compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
            return try? Data(contentsOf: url)
        }
    }
}

/// Copying photos off a memory card (or a camera) into the destination folders.
final class CardImportTests: CatalogTestCase {
    /// A card import saves its options as the next one's: the user's are put back afterwards.
    private var savedOptions: Any?

    override func setUp() {
        super.setUp()
        savedOptions = UserDefaults.standard.object(forKey: "pc_cardImportOptions")
    }

    override func tearDown() {
        if let savedOptions {
            UserDefaults.standard.set(savedOptions, forKey: "pc_cardImportOptions")
        } else {
            UserDefaults.standard.removeObject(forKey: "pc_cardImportOptions")
        }
        super.tearDown()
    }

    private func cardFile(_ url: URL) -> CardFile {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return CardFile(url: url, size: Int64(size), modified: .now, isRaw: false)
    }

    /// A different photo by the same name and of the same size as one already in the
    /// destination (a counter that came round again, a fixed-size RAW format) is copied.
    func testDifferentPhotoWithSameNameAndSizeIsCopied() throws {
        let photo = scratch.appendingPathComponent("Card/DCIM/100CANON/IMG_0001.JPG")
        try makeShot(at: photo, make: "Canon", model: "Canon EOS R5", taken: "2026:10:12 10:00:00", shade: 3)
        let day = scratch.appendingPathComponent("Photos/2026/2026-10-12")
        let earlier = day.appendingPathComponent("IMG_0001.JPG")
        // the same bytes but for the capture time: the same size, another photo
        let bytes = try Data(contentsOf: photo)
        var otherBytes = bytes
        let taken = try XCTUnwrap(otherBytes.range(of: Data("2026:10:12 10:00:00".utf8)))
        otherBytes.replaceSubrange(taken, with: Data("2026:10:12 11:00:00".utf8))
        XCTAssertEqual(otherBytes.count, bytes.count)
        XCTAssertNotEqual(otherBytes, bytes)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        try otherBytes.write(to: earlier)

        let options = CardImportOptions(destination: scratch.appendingPathComponent("Photos"))
        let copy = try CardCopier(options: options, files: [cardFile(photo)]).copy(photo)

        XCTAssertNotEqual(copy.path, earlier.path, "the photo isn't taken for the one already there")
        XCTAssertEqual(try Data(contentsOf: copy), bytes, "the card's photo is copied")
        XCTAssertEqual(try Data(contentsOf: earlier), otherBytes, "the photo already there is left alone")
    }

    /// Two cards' photos by the same name, shot on different days, backed up on the same day:
    /// both backups are kept.
    func testBackupNeverOverwritesAnotherPhotosBackup() throws {
        let first = scratch.appendingPathComponent("Card A/DCIM/100CANON/IMG_0001.JPG")
        let second = scratch.appendingPathComponent("Card B/DCIM/100CANON/IMG_0001.JPG")
        try makeShot(at: first, make: "Canon", model: "Canon EOS R5", taken: "2026:10:11 09:00:00", shade: 2)
        try makeShot(at: second, make: "Canon", model: "Canon EOS R5", taken: "2026:10:12 09:00:00", shade: 9)
        var options = CardImportOptions(destination: scratch.appendingPathComponent("Photos"))
        let backup = scratch.appendingPathComponent("Backup")
        options.backupEnabled = true
        options.backup = backup

        _ = try CardCopier(options: options, files: [cardFile(first)]).copy(first)
        _ = try CardCopier(options: options, files: [cardFile(second)]).copy(second)

        let backedUp = contentsOfFiles(under: backup)
        XCTAssertEqual(backedUp.count, 2, "each photo has its own backup")
        XCTAssertTrue(backedUp.contains(try Data(contentsOf: first)), "the first card's backup survives the second")
        XCTAssertTrue(backedUp.contains(try Data(contentsOf: second)))
    }

    /// A Canon IMG_1234.CR3 is in the day's folder; an iPhone's IMG_1234.HEIC from that day
    /// joins it under a name of its own, so it never passes for the RAW's JPEG.
    func testAnotherCamerasPhotoByTheSameNameGetsItsOwnName() throws {
        let day = scratch.appendingPathComponent("Photos/2026/2026-10-12")
        // a TIFF under a RAW's name: Image I/O reads it by its content
        try makeShot(at: day.appendingPathComponent("IMG_1234.CR3"), type: .tiff,
                     make: "Canon", model: "Canon EOS R5", taken: "2026:10:12 10:00:00", shade: 1)
        let phone = scratch.appendingPathComponent("iPhone/DCIM/100APPLE/IMG_1234.HEIC")
        try makeShot(at: phone, type: .heic, make: "Apple", model: "iPhone 15 Pro", taken: "2026:10:12 18:30:00",
                     shade: 7)

        let options = CardImportOptions(destination: scratch.appendingPathComponent("Photos"))
        let copy = try CardCopier(options: options, files: [cardFile(phone)]).copy(phone)

        XCTAssertEqual(copy.deletingLastPathComponent().path, day.path)
        XCTAssertNotEqual(copy.deletingPathExtension().lastPathComponent.lowercased(), "img_1234",
                          "the iPhone photo doesn't share the Canon RAW's name")
    }

    /// Renamed {date}_{seq}: a second camera's import that day numbers from the start again,
    /// and its first photo mustn't take the name of the first camera's first RAW.
    func testRenamedPhotoFromAnotherCameraGetsItsOwnName() throws {
        let canon = scratch.appendingPathComponent("Card/DCIM/100CANON/IMG_0007.CR3")
        try makeShot(at: canon, type: .tiff, make: "Canon", model: "Canon EOS R5", taken: "2026:10:12 10:00:00",
                     shade: 1)
        let phone = scratch.appendingPathComponent("iPhone/DCIM/100APPLE/IMG_4410.HEIC")
        try makeShot(at: phone, type: .heic, make: "Apple", model: "iPhone 15 Pro", taken: "2026:10:12 18:30:00",
                     shade: 7)
        var options = CardImportOptions(destination: scratch.appendingPathComponent("Photos"))
        options.rename = true
        options.renameTemplate = "{date}_{seq}"

        let raw = try CardCopier(options: options, files: [cardFile(canon)]).copy(canon)
        let other = try CardCopier(options: options, files: [cardFile(phone)]).copy(phone)

        XCTAssertEqual(raw.lastPathComponent, "20261012_0001.CR3")
        XCTAssertNotEqual(other.deletingPathExtension().lastPathComponent, "20261012_0001",
                          "the iPhone photo doesn't share the Canon RAW's name")
    }

    /// The JPEG of a RAW already in the destination (the same camera, the same second) keeps
    /// the RAW's name, so the two still make one photo.
    func testJpegOfARawAlreadyCopiedKeepsItsName() throws {
        let day = scratch.appendingPathComponent("Photos/2026/2026-10-12")
        try makeShot(at: day.appendingPathComponent("IMG_1234.CR3"), type: .tiff,
                     make: "Canon", model: "Canon EOS R5", taken: "2026:10:12 10:00:00", shade: 1)
        let jpeg = scratch.appendingPathComponent("Card/DCIM/100CANON/IMG_1234.JPG")
        try makeShot(at: jpeg, make: "Canon", model: "Canon EOS R5", taken: "2026:10:12 10:00:00", shade: 1)

        let options = CardImportOptions(destination: scratch.appendingPathComponent("Photos"))
        let copy = try CardCopier(options: options, files: [cardFile(jpeg)]).copy(jpeg)

        XCTAssertEqual(copy.path, day.appendingPathComponent("IMG_1234.JPG").path)
    }

    /// The same photo copied again (an import picked up after an interruption) reuses its copy
    /// and its backup rather than making second ones.
    func testSamePhotoCopiedAgainReusesItsCopyAndBackup() throws {
        let photo = scratch.appendingPathComponent("Card/DCIM/100CANON/IMG_0002.JPG")
        try makeShot(at: photo, make: "Canon", model: "Canon EOS R5", taken: "2026:10:12 10:05:00", shade: 5)
        var options = CardImportOptions(destination: scratch.appendingPathComponent("Photos"))
        options.backupEnabled = true
        options.backup = scratch.appendingPathComponent("Backup")

        let copy = try CardCopier(options: options, files: [cardFile(photo)]).copy(photo)
        let again = try CardCopier(options: options, files: [cardFile(photo)]).copy(photo)

        XCTAssertEqual(again.path, copy.path)
        XCTAssertEqual(contentsOfFiles(under: scratch.appendingPathComponent("Photos")).count, 1)
        XCTAssertEqual(contentsOfFiles(under: scratch.appendingPathComponent("Backup")).count, 1)
    }

    /// A photo is copied under a hidden partial name, which no folder scan takes for a photo, and
    /// moved into place whole; a partial an earlier attempt left (cut short by a crash) is
    /// replaced, and the photo and its backup keep their own names.
    func testCopyGoesThroughAPartialFileAndReplacesAStaleOne() throws {
        let fm = FileManager.default
        let photo = scratch.appendingPathComponent("Card/DCIM/100CANON/IMG_0003.JPG")
        try makeShot(at: photo, make: "Canon", model: "Canon EOS R5", taken: "2026:10:12 10:10:00", shade: 4)
        let bytes = try Data(contentsOf: photo)
        let day = scratch.appendingPathComponent("Photos/2026/2026-10-12")
        try fm.createDirectory(at: day, withIntermediateDirectories: true)
        let stale = day.appendingPathComponent(".IMG_0003.JPG.partial")
        try bytes.prefix(100).write(to: stale)
        XCTAssertEqual(FileScanner.scan(day), [], "a partial file isn't a photo")
        var options = CardImportOptions(destination: scratch.appendingPathComponent("Photos"))
        let backup = scratch.appendingPathComponent("Backup")
        options.backupEnabled = true
        options.backup = backup

        let copy = try CardCopier(options: options, files: [cardFile(photo)]).copy(photo)

        XCTAssertEqual(copy.path, day.appendingPathComponent("IMG_0003.JPG").path)
        XCTAssertEqual(try Data(contentsOf: copy), bytes)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: day.path), ["IMG_0003.JPG"], "no partial file is left")
        XCTAssertEqual(contentsOfFiles(under: backup), [bytes], "the backup is whole, with no partial beside it")
    }

    /// A photo copied off a card, then removed from the catalog and moved to the Trash, leaves
    /// its name in the destination free: a new shot by that name (the counter come round again)
    /// that the next card import copies there is a new photo, not the removed one back.
    @MainActor
    func testNewShotCopiedToTrashedPhotosNameIsANewPhoto() async throws {
        let shot = scratch.appendingPathComponent("Card/DCIM/100CANON/IMG_0001.JPG")
        try makeShot(at: shot, make: "Canon", model: "Canon EOS R5", taken: "2026:10:12 10:00:00", shade: 1)
        let package = scratch.appendingPathComponent("Library.photolibrary")
        let store = try CatalogStore(packageURL: package)
        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))
        let options = CardImportOptions(destination: scratch.appendingPathComponent("Photos"))
        app.importFromCard(nil, files: [cardFile(shot)], options: options)
        try await waitUntil("first card import finished") { !app.importing }
        let first = try XCTUnwrap(app.assets.first { !$0.isDemo && !$0.deleted && $0.filename == "IMG_0001.JPG" })
        let copy = try XCTUnwrap(first.localPath)
        XCTAssertTrue(app.mutate([first.id], writingSidecars: false) { $0.rating = 3; $0.title = "First" })
        // Move to Trash: the copy goes, the photo leaves the catalog
        XCTAssertTrue(app.mutate([first.id], writingSidecars: false) { $0.deleted = true })
        try FileManager.default.removeItem(atPath: copy)
        try makeShot(at: shot, make: "Canon", model: "Canon EOS R5", taken: "2026:10:12 18:00:00", shade: 9)

        app.importFromCard(nil, files: [cardFile(shot)], options: options)
        try await waitUntil("second card import finished") { !app.importing }

        let second = try XCTUnwrap(app.assets.first { !$0.isDemo && !$0.deleted && $0.localPath == copy },
                                   "the new shot is copied to the trashed photo's name")
        XCTAssertNotEqual(second.id, first.id, "the new shot took the removed photo's place")
        XCTAssertNotEqual(second.rating, 3)
        XCTAssertEqual(app.assets.first { $0.id == first.id }?.deleted, true)
        let row = try store.db.query("SELECT deleted, rating, title FROM assets WHERE id=?;", [.text(first.id)]).first
        XCTAssertEqual(row?.bool("deleted"), true)
        XCTAssertEqual(row?.int("rating"), 3)
        XCTAssertEqual(row?.text("title"), "First")
    }

    /// A card photo that couldn't be read fails the import; Retry Failed copies it off the card
    /// (and backs it up) like the others, rather than cataloging it on the card.
    @MainActor
    func testRetryFailedAfterCardImportCopiesThePhotoOffTheCard() async throws {
        let card = scratch.appendingPathComponent("Card/DCIM/100CANON")
        let first = card.appendingPathComponent("IMG_0001.JPG")
        let late = card.appendingPathComponent("IMG_0002.JPG")
        try makeShot(at: first, make: "Canon", model: "Canon EOS R5", taken: "2026:10:12 10:00:00", shade: 1)
        let package = scratch.appendingPathComponent("Library.photolibrary")
        _ = try CatalogStore(packageURL: package)
        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))
        let destination = scratch.appendingPathComponent("Photos")
        let backup = scratch.appendingPathComponent("Backup")
        var options = CardImportOptions(destination: destination)
        options.backupEnabled = true
        options.backup = backup

        // the second photo can't be read this time (a card read error)
        app.importFromCard(nil, files: [cardFile(first), CardFile(url: late, size: 0, modified: .now, isRaw: false)],
                           options: options)
        try await waitUntil("card import finished") { !app.importing }
        XCTAssertEqual(app.importRun?.failures.map(\.filename), ["IMG_0002.JPG"])

        try makeShot(at: late, make: "Canon", model: "Canon EOS R5", taken: "2026:10:12 10:00:05", shade: 4)
        app.retryFailedImport()
        try await waitUntil("retry finished") { !app.importing }

        let retried = try XCTUnwrap(app.assets.first { !$0.isDemo && !$0.deleted && $0.filename == "IMG_0002.JPG" })
        let path = try XCTUnwrap(retried.localPath)
        XCTAssertTrue(path.hasPrefix(destination.path + "/"), "the photo is copied off the card: \(path)")
        XCTAssertFalse(app.assets.contains { $0.localPath?.hasPrefix(card.path) == true }, "nothing is cataloged on the card")
        XCTAssertTrue(contentsOfFiles(under: backup).contains(try Data(contentsOf: late)), "the photo is backed up")
    }
}
