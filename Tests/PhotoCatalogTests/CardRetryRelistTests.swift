import XCTest
@testable import PhotoCatalog

/// Retry Failed after a card import copies the failed photos with the import's copier again, but
/// looks at the destination folders as they are now: a file another app put there since the
/// first pass keeps its name, and the retried photo takes the next free one.
final class CardRetryRelistTests: CatalogTestCase {
    private func cardFile(_ url: URL) -> CardFile {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return CardFile(url: url, size: Int64(size), modified: .now, isRaw: false)
    }

    @MainActor
    func testRetryNamesAroundAFilePutInTheFolderSinceTheFirstPass() async throws {
        let card = scratch.appendingPathComponent("Card/DCIM/100CANON")
        let first = card.appendingPathComponent("IMG_0001.JPG")
        let late = card.appendingPathComponent("IMG_0002.JPG")
        try makeShot(at: first, make: "Canon", model: "Canon EOS R5", taken: "2026:10:12 10:00:00", shade: 1)
        let package = scratch.appendingPathComponent("Library.photolibrary")
        _ = try CatalogStore(packageURL: package)
        let app = openCatalog(package)
        let destination = scratch.appendingPathComponent("Photos")
        let day = destination.appendingPathComponent("2026/2026-10-12")
        let options = CardImportOptions(destination: destination)

        // the second photo can't be read this time (a card read error); the first's folder is listed
        app.importFromCard(nil, files: [cardFile(first), CardFile(url: late, size: 0, modified: .now, isRaw: false)],
                           options: options)
        try await waitUntil("card import finished") { !app.importing }
        XCTAssertEqual(app.importRun?.failures.map(\.filename), ["IMG_0002.JPG"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: day.appendingPathComponent("IMG_0001.JPG").path))

        // meanwhile another camera's photo by the same name lands in that folder
        let other = day.appendingPathComponent("IMG_0002.JPG")
        try makeShot(at: other, make: "Apple", model: "iPhone 17 Pro", taken: "2026:10:12 09:00:00", shade: 11)
        let otherBytes = try Data(contentsOf: other)
        try makeShot(at: late, make: "Canon", model: "Canon EOS R5", taken: "2026:10:12 10:00:05", shade: 4)
        app.retryFailedImport()
        try await waitUntil("retry finished") { !app.importing }

        XCTAssertEqual(app.importRun?.failures.map(\.filename) ?? [], [], "the retry doesn't fail on the name")
        let retried = try XCTUnwrap(app.assets.first { !$0.isDemo && !$0.deleted && $0.filename == "IMG_0002-1.JPG" },
                                    "the retried photo takes the next free name")
        XCTAssertEqual(retried.localPath, day.appendingPathComponent("IMG_0002-1.JPG").path)
        XCTAssertEqual(try Data(contentsOf: day.appendingPathComponent("IMG_0002-1.JPG")), try Data(contentsOf: late))
        XCTAssertEqual(try Data(contentsOf: other), otherBytes, "the other photo is left as it was")
    }
}
