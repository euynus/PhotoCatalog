import XCTest
@testable import PhotoCatalog

/// Source folders' names and statuses come out the same however the photos are split into
/// chunks to count on every core.
final class FolderSummariesChunkTests: XCTestCase {
    private func photo(folder: String, name: String, status: AssetStatus,
                       deleted: Bool = false, demo: Bool = false) -> Asset {
        var asset = DemoData.assets[0]
        asset.folderId = folder
        asset.folderName = name
        asset.status = status
        asset.deleted = deleted
        asset.isDemo = demo
        return asset
    }

    /// Folders in runs, one split across chunks, one coming back later, with removed and demo
    /// photos that don't count.
    private var photos: [Asset] {
        [
            photo(folder: "a", name: "A first", status: .ready),
            photo(folder: "a", name: "A second", status: .ready),
            photo(folder: "spans", name: "Spans first", status: .ready),
            photo(folder: "spans", name: "Spans second", status: .missing),
            photo(folder: "spans", name: "Spans third", status: .offline),
            photo(folder: "spans", name: "Spans fourth", status: .ready),
            photo(folder: "b", name: "B removed", status: .offline, deleted: true),
            photo(folder: "b", name: "B first", status: .ready),
            photo(folder: "demo", name: "Demo", status: .offline, demo: true),
            photo(folder: "a", name: "A again", status: .missing),
            photo(folder: "c", name: "C first", status: .missing),
            photo(folder: "c", name: "C second", status: .ready),
            photo(folder: "b", name: "B again", status: .ready),
        ]
    }

    private func summaries(chunk: Int) -> [String: String] {
        AppState.folderSummaries(photos, chunk: chunk).mapValues { "\($0.name)|\($0.status)" }
    }

    func testChunkSizesGiveTheSameSummaries() {
        let whole = summaries(chunk: .max)
        for chunk in [1, 3, 7] {
            XCTAssertEqual(summaries(chunk: chunk), whole, "chunk \(chunk)")
        }
        XCTAssertEqual(summaries(chunk: 8_192), whole, "the default")
    }

    func testFolderAcrossAChunkBoundaryKeepsItsFirstPhotosName() {
        // chunk 3 puts "Spans first" in the first chunk and the rest in the second and third
        for chunk in [1, 3, .max] {
            XCTAssertEqual(summaries(chunk: chunk)["spans"], "Spans first|offline", "chunk \(chunk)")
            XCTAssertEqual(summaries(chunk: chunk)["a"], "A first|missing", "chunk \(chunk)")
            XCTAssertEqual(summaries(chunk: chunk)["b"], "B first|online", "a removed photo isn't the first")
        }
    }

    func testWorstStatusWins() {
        let result = summaries(chunk: 3)
        XCTAssertEqual(result["spans"], "Spans first|offline", "offline over missing over online")
        XCTAssertEqual(result["c"], "C first|missing")
        XCTAssertEqual(result["a"], "A first|missing", "a run later in the catalog still counts")
        XCTAssertNil(result["demo"], "demo photos aren't a source folder's")
        XCTAssertEqual(Set(result.keys), ["a", "b", "c", "spans"])
    }
}
