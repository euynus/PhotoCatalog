import XCTest
@testable import PhotoCatalog

/// Album and smart album changes carry the sidebar's counts on: the albums whose photos changed
/// are counted again, a rename, a move into a set or a deletion counts nothing, and only a changed
/// smart rule matches every photo again.
final class AlbumCountCarryTests: DerivedCacheTestCase {
    @MainActor
    func testAlbumAndSmartAlbumChangesCarryTheSidebarCountsOn() throws {
        let app = try catalog()
        app.confirmDestructiveAction = { _, _, _ in true }
        func check(_ name: String, matchingAgain: Bool = false, _ change: () -> Void,
                   file: StaticString = #filePath, line: UInt = #line) {
            _ = app.sidebarCounts
            let rebuilds = app.sidebarCountIndexRebuilds
            change()
            XCTAssertEqual(app.sidebarCounts, app.recountedSidebarCounts(), name, file: file, line: line)
            XCTAssertEqual(app.sidebarCountIndexRebuilds, rebuilds + (matchingAgain ? 1 : 0),
                           "\(name): \(matchingAgain ? "matched again" : "carried on")", file: file, line: line)
        }
        // the JPEG behind a RAW, a removed photo and one listed twice, as a recount counts them
        XCTAssertTrue(app.mutate(["b1"]) { $0.deleted = true })
        app.albums.append(Album(id: "second", name: "Second", assetIds: ["a1", "a2j", "a2r", "b1", "f1", "f1"]))
        XCTAssertEqual(app.countForAlbum(app.albums[1]), 4)

        let set = AlbumSet(id: "set", name: "Set")
        try app.store?.saveAlbumSet(set)
        app.albumSets.append(set)
        check("renamed") { XCTAssertTrue(app.renameAlbum("album", to: "Renamed")) }
        check("moved into a set") { app.moveToAlbumSet("album", setId: "set") }
        check("a smart album moved into a set") { app.moveToAlbumSet("rated", setId: "set") }
        check("the set deleted") { app.deleteAlbumSet("set") }
        check("photos added") { app.albums[0].assetIds += ["f2", "f3", "a6j", "nowhere"] }
        check("photos taken out") {
            app.select(Selection(type: .album, id: "album", name: "Album"))
            app.selectedIds = ["f2", "a4j"]
            app.removeSelectionFromCurrentAlbum()
        }
        XCTAssertEqual(app.albums[0].assetIds, ["a3j", "a4h", "n10", "f3", "a6j", "nowhere"])
        check("a new empty album") { app.albums.append(Album(id: "empty", name: "Empty", assetIds: [])) }
        XCTAssertEqual(app.sidebarCounts.albums["empty"], 0, "counted, as none")
        check("reordered") { app.albums.reverse() }
        check("deleted") { app.deleteAlbum("second") }
        XCTAssertNil(app.sidebarCounts.albums["second"])

        check("a smart album renamed") {
            app.smartAlbumEditingID = "trip"
            app.saveSmart(name: "Trips", rule: app.smartAlbums[1].rule, count: 0)
        }
        XCTAssertEqual(app.smartAlbums[1].name, "Trips")
        check("smart albums reordered") { app.smartAlbums.swapAt(0, 2) }
        check("a smart album deleted") { app.deleteSmartAlbum("canon") }
        XCTAssertNil(app.sidebarCounts.smartAlbums["canon"])
        XCTAssertFalse(app.sidebarCountIndexCache?.smartRules.contains { $0.id == "canon" } ?? true,
                       "its rule no longer matched against edits")
        // an edit after the deletion is matched only against the rules left
        check("a rating after it") { XCTAssertTrue(app.setRating(5, on: ["f4"])) }

        check("a rule changed", matchingAgain: true) {
            app.smartAlbumEditingID = "rated"
            app.saveSmart(name: "rated", rule: SmartRule(conditions: [SmartCondition(field: "rating", op: ">=", value: "4")]),
                          count: 0)
        }
        check("a smart album added", matchingAgain: true) {
            app.smartAlbums.append(SmartAlbum(id: "new", name: "New", rule: SmartRule(conditions: [
                SmartCondition(field: "flag", op: "=", value: "reject"),
            ]), count: 0))
        }
    }
}
