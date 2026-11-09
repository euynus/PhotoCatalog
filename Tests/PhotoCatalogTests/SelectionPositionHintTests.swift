import XCTest
@testable import PhotoCatalog

/// A click hands on the position its tile or filmstrip cell was drawn at: once it checks out
/// against the list as worked out, it is the next lookup's hint, so finding the photo again
/// (to rate it, or step from it) needs no pass over the list, and the list isn't worked out again.
final class SelectionPositionHintTests: CatalogTestCase {
    private let shot = Date(timeIntervalSince1970: 1_791_800_000)

    /// The photo the default sort (newest first) lists at `index`.
    private func photo(_ index: Int) -> Asset {
        Asset(id: "p\(index)", pid: 0, ori: "l", thumb: "", preview: "", filename: "IMG_\(index).JPG",
              type: "JPEG", isRaw: false, folderId: "day", folderName: "Day",
              date: shot.addingTimeInterval(-Double(index)), width: 6000, height: 4000, orientation: 1,
              camera: "Canon EOS R5", lens: "", focal: 50, aperture: 4, shutter: "1/100", iso: 100,
              colorSpace: "sRGB", fileMB: 1, rating: 0, flag: .none, keywords: [],
              title: "", caption: "", location: "", gps: (0, 0), status: .ready, importedAt: shot,
              localPath: scratch.appendingPathComponent("IMG_\(index).JPG").path)
    }

    /// All Photographs listing `count` photos, `p0` first, worked out once, with no index, hint
    /// or selection: a lookup that isn't answered by the hint has to pass over the list.
    @MainActor
    private func listed(_ count: Int) -> AppState {
        let app = AppState.selfCheckFixture()
        app.assets = (0..<count).map(photo)
        app.duplicateGroupsCache = []
        app.select(Selection(type: .lib, id: "all", name: "All"))
        XCTAssertEqual(app.list.map(\.id), (0..<count).map { "p\($0)" })
        app.listPositionsCache = nil
        app.listPositionHint = nil
        app.primaryId = nil
        app.selectedIds = []
        app.anchorId = nil
        return app
    }

    @MainActor
    private func assertHint(_ app: AppState, names id: String, at position: Int, _ context: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.listPositionHint?.id, id, context, file: file, line: line)
        XCTAssertEqual(app.listPositionHint?.position, position, context, file: file, line: line)
    }

    @MainActor
    func testAClickWithItsPositionFindsThePhotoWithoutAPass() {
        let clicks: [(String, @MainActor (AppState) -> Void)] = [
            ("filmstrip", { $0.setPrimary("p30", at: 30) }),
            ("grid click", { $0.selectCell("p30", at: 30, shift: false, meta: false) }),
            ("double-click", { $0.openLoupe("p30", at: 30) }),
        ]
        for (context, click) in clicks {
            let app = listed(50)
            let (computations, scanned) = (app.listComputations, app.listPositionScannedPhotos)
            click(app)
            XCTAssertEqual(app.primaryId, "p30", context)
            XCTAssertEqual(app.selectedIds, ["p30"], context)
            assertHint(app, names: "p30", at: 30, context)
            XCTAssertEqual(app.listPosition(of: "p30"), 30, context)
            XCTAssertEqual(app.listComputations, computations, "\(context): the list isn't worked out again")
            XCTAssertEqual(app.listPositionScannedPhotos, scanned, "\(context): no photo looked at one by one")
        }
    }

    @MainActor
    func testAWrongPositionLeavesTheHintAlone() {
        let app = listed(50)
        for wrong in [31, 50, 500, -1] {
            app.listPositionHint = ("p5", 5)
            app.setPrimary("p30", at: wrong)
            XCTAssertEqual(app.primaryId, "p30", "the click still selects")
            assertHint(app, names: "p5", at: 5, "position \(wrong)")
            let scanned = app.listPositionScannedPhotos
            XCTAssertEqual(app.listPosition(of: "p30"), 30, "found by a pass")
            XCTAssertEqual(app.listPositionScannedPhotos - scanned, 31)
        }
        app.listPositionHint = ("p5", 5)
        app.selectCell("p30", at: 29, shift: false, meta: false)
        app.openLoupe("p31", at: 30)
        assertHint(app, names: "p5", at: 5, "a position showing another photo")
    }

    /// A position is checked against the list already worked out: an action never works the list
    /// out again just to keep a hint, and a list whose inputs changed since isn't asked.
    @MainActor
    func testAPositionInAListNotYetWorkedOutIsDropped() {
        let app = listed(50)
        app.listPositionHint = ("p5", 5)
        app.search = "IMG_3"   // the list's inputs change; nothing has asked for it since
        let computations = app.listComputations
        app.setPrimary("p3", at: 3)
        XCTAssertEqual(app.listComputations, computations, "not worked out to check the position")
        assertHint(app, names: "p5", at: 5, "the cached list is another one")
    }

    @MainActor
    func testShiftClickWithAPositionSelectsTheSameRange() {
        for (anchor, clicked) in [(10, 20), (20, 10), (7, 7), (0, 49)] {
            let context = "from p\(anchor) to p\(clicked)"
            let app = listed(50)
            app.setPrimary("p\(anchor)")
            app.selectCell("p\(clicked)", shift: true, meta: false)
            let looked = (selected: app.selectedIds, primary: app.primaryId, anchor: app.anchorId)
            XCTAssertEqual(looked.selected, Set((min(anchor, clicked)...max(anchor, clicked)).map { "p\($0)" }), context)
            XCTAssertEqual(looked.primary, "p\(clicked)", context)
            XCTAssertEqual(looked.anchor, "p\(anchor)", "\(context): the anchor stays")

            // the anchor's place from the hint its own click left, the clicked one's from the click
            app.setPrimary("p\(anchor)", at: anchor)
            let scanned = app.listPositionScannedPhotos
            app.selectCell("p\(clicked)", at: clicked, shift: true, meta: false)
            XCTAssertEqual(app.selectedIds, looked.selected, context)
            XCTAssertEqual(app.primaryId, looked.primary, context)
            XCTAssertEqual(app.anchorId, looked.anchor, context)
            assertHint(app, names: "p\(clicked)", at: clicked, context)
            XCTAssertEqual(app.listPositionScannedPhotos, scanned, "\(context): no photo looked at one by one")
        }
    }

    /// ⌘-click with a position adds, and takes off, the same photos as without one.
    @MainActor
    func testCommandClickWithAPositionChangesTheSameSelection() {
        for withPositions in [false, true] {
            let context = withPositions ? "with positions" : "without"
            let app = listed(50)
            func click(_ index: Int) {
                app.selectCell("p\(index)", at: withPositions ? index : nil, shift: false, meta: true)
            }
            app.setPrimary("p3")
            click(12)
            click(20)
            XCTAssertEqual(app.selectedIds, ["p3", "p12", "p20"], context)
            XCTAssertEqual(app.primaryId, "p20", context)
            if withPositions { assertHint(app, names: "p20", at: 20, context) }
            click(20)   // the active photo off: the nearest selected one before it takes over
            XCTAssertEqual(app.selectedIds, ["p3", "p12"], context)
            XCTAssertEqual(app.primaryId, "p12", context)
            XCTAssertEqual(app.anchorId, "p12", context)
            click(3)    // another off: the active one stays
            XCTAssertEqual(app.selectedIds, ["p12"], context)
            XCTAssertEqual(app.primaryId, "p12", context)
            app.setPrimary("p40")
            click(40)   // the only one off: nothing active
            XCTAssertEqual(app.selectedIds, [], context)
            XCTAssertNil(app.primaryId, context)
        }
    }
}
