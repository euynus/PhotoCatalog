import XCTest
@testable import PhotoCatalog

final class AppStateSelectionTests: XCTestCase {
    private var previousOpenLast: Any?

    override func setUp() {
        super.setUp()
        previousOpenLast = UserDefaults.standard.object(forKey: "pc_openLast")
        UserDefaults.standard.set(false, forKey: "pc_openLast")
    }

    override func tearDown() {
        if let previousOpenLast {
            UserDefaults.standard.set(previousOpenLast, forKey: "pc_openLast")
        } else {
            UserDefaults.standard.removeObject(forKey: "pc_openLast")
        }
        super.tearDown()
    }

    @MainActor
    func testCompareSelectionTracksSearchResults() {
        let app = AppState()
        app.onboarded = true
        app.switchView(.compare)

        XCTAssertEqual(app.compareIds.count, 3)
        let firstId = app.compareIds[0]
        let firstFilename = app.assets.first { $0.id == firstId }?.filename
        XCTAssertNotNil(firstFilename)

        app.setSearch(firstFilename ?? "")
        XCTAssertEqual(app.compareIds, [firstId])
        XCTAssertEqual(app.selectedIds, Set([firstId]))

        app.setSearch("NO_SUCH_PHOTO_123")
        XCTAssertTrue(app.compareIds.isEmpty)
        XCTAssertTrue(app.selectedIds.isEmpty)
        XCTAssertNil(app.primaryId)
    }

    @MainActor
    func testMetadataKeyboardShortcutsApplyToCurrentSelection() throws {
        let app = AppState()
        app.onboarded = true
        let id = try XCTUnwrap(app.primaryId)

        XCTAssertTrue(app.handleKey("5", hasCommand: false))
        XCTAssertEqual(app.assets.first { $0.id == id }?.rating, 5)

        XCTAssertTrue(app.handleKey("0", hasCommand: false))
        XCTAssertEqual(app.assets.first { $0.id == id }?.rating, 0)

        XCTAssertTrue(app.handleKey("p", hasCommand: false))
        XCTAssertEqual(app.assets.first { $0.id == id }?.flag, .pick)
        XCTAssertTrue(app.handleKey("x", hasCommand: false))
        XCTAssertEqual(app.assets.first { $0.id == id }?.flag, .reject)
        XCTAssertTrue(app.handleKey("u", hasCommand: false))
        XCTAssertEqual(app.assets.first { $0.id == id }?.flag, Flag.none)

        XCTAssertTrue(app.handleKey("6", hasCommand: false))
        XCTAssertEqual(app.assets.first { $0.id == id }?.colorLabel, .red)
        XCTAssertTrue(app.handleKey("9", hasCommand: false))
        XCTAssertEqual(app.assets.first { $0.id == id }?.colorLabel, .blue)
    }

    @MainActor
    func testMetadataKeyboardShortcutsRequireASelection() {
        let app = AppState()
        app.onboarded = true
        let ratings = Dictionary(uniqueKeysWithValues: app.assets.map { ($0.id, $0.rating) })
        let flags = Dictionary(uniqueKeysWithValues: app.assets.map { ($0.id, $0.flag) })
        let colors = Dictionary(uniqueKeysWithValues: app.assets.map { ($0.id, $0.colorLabel) })

        app.setSearch("NO_SUCH_PHOTO_123")
        XCTAssertNil(app.primaryId)
        XCTAssertTrue(app.selectedIds.isEmpty)

        XCTAssertFalse(app.handleKey("5", hasCommand: false))
        XCTAssertFalse(app.handleKey("p", hasCommand: false))
        XCTAssertFalse(app.handleKey("6", hasCommand: false))
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: app.assets.map { ($0.id, $0.rating) }), ratings)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: app.assets.map { ($0.id, $0.flag) }), flags)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: app.assets.map { ($0.id, $0.colorLabel) }), colors)
    }

    @MainActor
    func testNavigationAndSheetKeyboardGuards() throws {
        let app = AppState()
        app.onboarded = true
        app.gridWidth = 900
        let firstId = try XCTUnwrap(app.primaryId)

        XCTAssertTrue(app.handleKey("right", hasCommand: false))
        XCTAssertNotEqual(app.primaryId, firstId)

        app.sheet = "settings"
        let selectedId = try XCTUnwrap(app.primaryId)
        let currentRating = app.assets.first { $0.id == selectedId }?.rating
        XCTAssertFalse(app.handleKey("5", hasCommand: false))
        XCTAssertEqual(app.assets.first { $0.id == selectedId }?.rating, currentRating)
        XCTAssertTrue(app.handleKey("escape", hasCommand: false))
        XCTAssertNil(app.sheet)
    }
}
