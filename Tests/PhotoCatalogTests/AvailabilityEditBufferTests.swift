import XCTest
@testable import PhotoCatalog

/// Edits of a thousand photos where they are — a drive going offline and back, a thousand
/// photos removed and brought back by undo, a thousand rated — write into the photos' own
/// array: nothing they read the photos through outlives the write and copies the whole array,
/// and what's derived from every photo is what a recount gives.
final class AvailabilityEditBufferTests: DerivedCacheTestCase {
    @MainActor
    private func address(_ app: AppState) -> UnsafePointer<Asset>? {
        app.assets.withUnsafeBufferPointer { $0.baseAddress }
    }

    @MainActor
    func testThousandPhotoEditsWriteIntoThePhotosOwnArray() throws {
        let app = try catalog()
        let undo = UndoManager()
        undo.groupsByEvent = false   // no run loop here to close event groups
        app.undoManager = undo
        let more = (0..<1_100).map { index in
            photo("d\(index)", "drive/\(index / 100)/IMG_\(2_000 + index / 2).\(index % 2 == 0 ? "CR3" : "JPG")",
                  offset: Double(index / 2) * 600, rating: index % 4, keywords: index % 3 == 0 ? ["trip"] : [])
        }
        app.appendAssets(more)
        work(app)
        _ = app.list
        let photos = address(app)
        XCTAssertNotNil(photos)

        func available(_ status: AssetStatus) -> [AssetAvailabilityUpdate] {
            app.assets.filter { $0.id.hasPrefix("d") }.map {
                AssetAvailabilityUpdate(assetId: $0.id, status: status, localPath: $0.localPath, checkedPath: $0.localPath)
            }
        }
        func step(_ name: String, _ change: () -> Void) {
            work(app)
            change()
            XCTAssertEqual(address(app), photos, "\(name): written in place, not copied")
            XCTAssertEqual(app.cachesDifferingFromRecount(), [], "\(name): as a recount gives")
            XCTAssertEqual(app.sidebarCounts, app.recountedSidebarCounts(), name)
            XCTAssertEqual(Set(app.list.map(\.id)), Set(app.assets.filter(app.assetPairing.shows).map(\.id)), name)
        }

        step("1,100 photos offline") { app.applyAvailabilityChanges(available(.offline)) }
        XCTAssertEqual(app.assets.filter { $0.status == .offline }.count, 1_100)
        step("and back") { app.applyAvailabilityChanges(available(.ready)) }

        let thousand = Set((0..<1_000).map { "d\($0)" })
        step("1,000 photos removed") {
            undo.beginUndoGrouping()
            XCTAssertTrue(app.mutate(thousand, undoName: "Remove") { $0.deleted = true })
            undo.endUndoGrouping()
        }
        XCTAssertEqual(app.assets.filter { $0.deleted && $0.id.hasPrefix("d") }.count, 1_000)
        step("their undo") { undo.undo() }
        XCTAssertFalse(app.assets.contains { $0.deleted && $0.id.hasPrefix("d") })
        step("1,000 photos rated") {
            undo.beginUndoGrouping()
            XCTAssertTrue(app.setRating(5, on: thousand))
            undo.endUndoGrouping()
        }
        step("1,000 photos flagged and keyworded") {
            XCTAssertTrue(app.mutate(thousand) { $0.flag = .pick; $0.keywords.append("drive") })
        }
        step("their rating undone") { undo.undo() }
    }
}
