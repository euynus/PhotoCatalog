import XCTest
@testable import PhotoCatalog

/// A card import names its copies from one listing of each destination folder, and picks the
/// same names as looking each one up in a fresh listing would.
final class CopyNamingIndexTests: CatalogTestCase {
    private let fm = FileManager.default
    /// One morning: every file's time (its capture time, as tiny files have no metadata) falls
    /// on this day.
    private lazy var morning: Date = {
        var components = DateComponents(year: 2026, month: 10, day: 12, hour: 8)
        components.timeZone = .current
        return Calendar(identifier: .gregorian).date(from: components) ?? .now
    }()

    private func write(_ text: String, to url: URL, at time: Date) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try fm.setAttributes([.modificationDate: time], ofItemAtPath: url.path)
    }

    private func cardFile(_ url: URL, _ time: Date) -> CardFile {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return CardFile(url: url, size: Int64(size), modified: time, isRaw: url.pathExtension == "CR2")
    }

    /// Three card folders whose photos share names (each folder's shots taken hours apart), some
    /// of them RAW+JPEG pairs: 612 files, in the order an import takes them. (Looking each name up
    /// in a fresh listing grows with the square of the files: 1,785 took 41 s in a Debug build.)
    private func makeCard() throws -> [CardFile] {
        var files: [CardFile] = []
        for (folder, count, pairEvery, hoursLater) in [("100CANON", 210, 3, 0), ("101CANON", 170, 4, 3),
                                                       ("102CANON", 100, 5, 6)] {
            for number in 1...count {
                let time = morning.addingTimeInterval(Double(hoursLater * 3600 + number * 4))
                let stem = String(format: "IMG_%04d", number)
                for ext in number % pairEvery == 0 ? ["CR2", "JPG"] : ["JPG"] {
                    let url = scratch.appendingPathComponent("Card/DCIM/\(folder)/\(stem).\(ext)")
                    try write("\(folder) \(stem) \(ext)", to: url, at: time)
                    files.append(cardFile(url, time))
                }
            }
        }
        return files.sorted { ($0.modified, $0.name) < ($1.modified, $1.name) }
    }

    /// What the day's folder holds before the import: copies of card photos made before,
    /// other shots by the same names, another file of a RAW+JPEG shot, and sidecars.
    private func seed(_ day: URL) throws {
        let first = scratch.appendingPathComponent("Card/DCIM/100CANON")
        for number in stride(from: 1, through: 200, by: 10) {
            let name = String(format: "IMG_%04d.JPG", number)
            try fm.createDirectory(at: day, withIntermediateDirectories: true)
            try fm.copyItem(at: first.appendingPathComponent(name), to: day.appendingPathComponent(name))
        }
        for number in stride(from: 5, through: 200, by: 10) {
            try write("another shot \(number)", to: day.appendingPathComponent(String(format: "IMG_%04d.JPG", number)),
                      at: morning.addingTimeInterval(9 * 3600))
        }
        for number in stride(from: 3, through: 200, by: 9) {
            try write("the shot's HEIC \(number)", to: day.appendingPathComponent(String(format: "IMG_%04d.HEIC", number)),
                      at: morning.addingTimeInterval(Double(number * 4)))
        }
        for number in stride(from: 2, through: 100, by: 7) {
            try write("<x:xmpmeta/>", to: day.appendingPathComponent(String(format: "IMG_%04d.xmp", number)), at: morning)
        }
    }

    /// Every file under `folder` by its path there, with its contents.
    private func listing(of folder: URL) -> [String: Data] {
        let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        var files: [String: Data] = [:]
        for case let url as URL in enumerator?.allObjects ?? [] {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            files[String(url.path.dropFirst(folder.path.count))] = try? Data(contentsOf: url)
        }
        return files
    }

    func testIndexedNamesMatchFreshListingsWithOneListingPerFolder() throws {
        let card = try makeCard()
        var listings: [Bool: [String: Data]] = [:]
        var indexedListings = 0
        for indexing in [false, true] {
            let options = CardImportOptions(destination: scratch.appendingPathComponent(indexing ? "Indexed" : "Fresh"),
                                            organize: .day)
            let copier = CardCopier(options: options, files: card, indexingFolders: indexing)
            let day = copier.folder(for: MetadataReader.read(card[0].url).captureDate)
            try seed(day)
            for file in card { _ = try copier.copy(file.url) }
            listings[indexing] = listing(of: options.destination)
            if indexing { indexedListings = copier.folderListings }
        }

        let indexed = try XCTUnwrap(listings[true]), fresh = try XCTUnwrap(listings[false])
        XCTAssertEqual(indexed.count, fresh.count)
        XCTAssertEqual(indexed.keys.sorted(), fresh.keys.sorted(), "the same names")
        XCTAssertTrue(indexed == fresh, "the same photos under them")
        XCTAssertEqual(Set(indexed.keys.map { ($0 as NSString).deletingLastPathComponent }).count, 1,
                       "every photo went in the day's folder")
        XCTAssertEqual(indexedListings, 1, "the folder was listed once")
        // the import met each case it names around
        XCTAssertTrue(indexed.keys.contains { $0.hasSuffix("-2.JPG") }, "names taken twice over")
        XCTAssertTrue(indexed.keys.contains { $0.hasSuffix("IMG_0003.CR2") }, "a RAW beside its shot's HEIC")
        let copiedBefore = try Data(contentsOf: scratch.appendingPathComponent("Card/DCIM/100CANON/IMG_0011.JPG"))
        XCTAssertEqual(indexed.values.filter { $0 == copiedBefore }.count, 1, "a photo copied before isn't copied again")
    }

    /// A file put at the name the index picks after the folder was listed — another app's, of
    /// the very size of the photo — is never taken for the photo: that copy fails instead.
    func testFileDroppedInAfterTheListingIsNeverAdopted() throws {
        let first = scratch.appendingPathComponent("Card/DCIM/100CANON/IMG_0001.JPG")
        let second = scratch.appendingPathComponent("Card/DCIM/100CANON/IMG_0002.JPG")
        try write("first photo", to: first, at: morning)
        try write("second photo", to: second, at: morning.addingTimeInterval(10))
        let options = CardImportOptions(destination: scratch.appendingPathComponent("Photos"), organize: .day)
        let copier = CardCopier(options: options, files: [cardFile(first, morning), cardFile(second, morning)])
        let copied = try copier.copy(first)

        let dropped = copied.deletingLastPathComponent().appendingPathComponent("IMG_0002.JPG")
        try write("other photo!", to: dropped, at: morning.addingTimeInterval(3600))
        XCTAssertEqual(try Data(contentsOf: dropped).count, try Data(contentsOf: second).count)

        XCTAssertThrowsError(try copier.copy(second))
        XCTAssertEqual(try String(contentsOf: dropped, encoding: .utf8), "other photo!", "the other file is left alone")
        XCTAssertEqual(copier.folderListings, 1)
    }

    func testFolderIndexAddsWhatTheImportPlaces() throws {
        let folder = scratch.appendingPathComponent("Folder")
        try write("x", to: folder.appendingPathComponent("IMG_0001.CR2"), at: morning)
        try write("x", to: folder.appendingPathComponent("IMG_0001.xmp"), at: morning)
        var index = CopyNaming.FolderIndex()
        XCTAssertEqual(index.files(named: "img_0001", in: folder).map(\.lastPathComponent), ["IMG_0001.CR2"])
        XCTAssertEqual(index.files(named: "IMG_0002", in: folder), [])

        try write("x", to: folder.appendingPathComponent("IMG_0001.JPG"), at: morning)
        index.added(folder.appendingPathComponent("IMG_0001.JPG"))
        index.added(folder.appendingPathComponent("IMG_0001.JPG"))
        XCTAssertEqual(Set(index.files(named: "IMG_0001", in: folder)),
                       Set(CopyNaming.files(named: "IMG_0001", in: folder)), "as a fresh listing finds them")
        XCTAssertTrue(index.holds(folder.appendingPathComponent("img_0001.jpg")))
        XCTAssertFalse(index.holds(folder.appendingPathComponent("IMG_0002.JPG")))
        XCTAssertEqual(index.listings, 1)
    }
}
