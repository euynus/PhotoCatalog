import XCTest
@testable import PhotoCatalog

/// A catalog's develop settings decode in parallel chunks when there are many; the result is the
/// same as decoding them one after another, and a row that doesn't decode is skipped on its own.
final class DevelopSettingsLoadTests: CatalogTestCase {
    private func settings(_ index: Int) -> DevelopSettings {
        var settings = DevelopSettings()
        settings.exposure = Double(index % 40) / 10 - 2
        settings.contrast = Double(index % 7) * 5
        if index.isMultiple(of: 5) { settings.crop = DevelopCrop(x: 0.1, y: 0.05, width: 0.7, height: 0.8) }
        return settings
    }

    private func rows(count: Int, malformedAt malformed: Int) -> [(String, Data)] {
        (0..<count).map { index in
            let json = index == malformed ? "{\"exposure\": " : DevelopHistoryStep.json(settings(index))
            return ("photo-\(index)", Data(json.utf8))
        }
    }

    func testChunkedDecodingMatchesTheSerialPath() {
        let rows = rows(count: 1_200, malformedAt: 700)
        let serial = CatalogStore.decodeDevelopSettings(rows, serialBelow: .max)
        XCTAssertEqual(serial.count, 1_199, "only the malformed row is skipped")
        XCTAssertNil(serial["photo-700"])
        XCTAssertEqual(serial["photo-35"], settings(35))

        for chunk in [1, 3, 512, rows.count] {
            XCTAssertEqual(CatalogStore.decodeDevelopSettings(rows, chunk: chunk), serial, "chunks of \(chunk)")
        }
    }

    func testSmallCatalogsDecodeSerially() {
        let rows = rows(count: 20, malformedAt: 3)
        let decoded = CatalogStore.decodeDevelopSettings(rows, chunk: 1)
        XCTAssertEqual(decoded.count, 19)
        XCTAssertEqual(decoded, CatalogStore.decodeDevelopSettings(rows, serialBelow: .max))
        XCTAssertTrue(CatalogStore.decodeDevelopSettings([]).isEmpty)
    }

    func testLoadingACatalogReadsEveryRowThatDecodes() throws {
        let store = try CatalogStore(packageURL: scratch.appendingPathComponent("Load.photolibrary"))
        let saved = Dictionary(uniqueKeysWithValues: (0..<1_100).map { ("photo-\($0)", settings($0)) })
        try store.saveDevelopSettings(saved)
        try store.db.run("INSERT INTO develop_settings(asset_id, settings, updated_at) VALUES('broken', '{oops', '');")

        let loaded = try store.loadDevelopSettings()

        XCTAssertEqual(loaded.count, saved.filter { !$0.value.isNeutral }.count)
        XCTAssertNil(loaded["broken"])
        XCTAssertEqual(loaded, saved.filter { !$0.value.isNeutral })
    }
}
