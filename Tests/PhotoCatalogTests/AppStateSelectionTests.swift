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

    @MainActor
    func testSafeCommandKeyboardShortcuts() {
        let app = AppState()
        app.onboarded = true

        XCTAssertTrue(app.handleKey("f", hasCommand: true))
        XCTAssertEqual(app.searchFocusToken, 1)

        XCTAssertFalse(app.filterOpen)
        XCTAssertTrue(app.handleKey("f", hasCommand: true, hasShift: true))
        XCTAssertTrue(app.filterOpen)

        XCTAssertTrue(app.showInspector)
        XCTAssertTrue(app.handleKey("i", hasCommand: true))
        XCTAssertFalse(app.showInspector)

        XCTAssertEqual(app.thumbSize, 168)
        XCTAssertTrue(app.handleKey("=", hasCommand: true))
        XCTAssertEqual(app.thumbSize, 184)
        XCTAssertTrue(app.handleKey("-", hasCommand: true))
        XCTAssertEqual(app.thumbSize, 168)
        app.thumbSize = 220
        XCTAssertTrue(app.handleKey("0", hasCommand: true))
        XCTAssertEqual(app.thumbSize, 168)
    }

    @MainActor
    func testSelectionCommandKeyboardShortcuts() {
        let app = AppState()
        app.onboarded = true
        let visible = Set(app.list.map(\.id))
        XCTAssertFalse(visible.isEmpty)

        XCTAssertTrue(app.handleKey("a", hasCommand: true))
        XCTAssertEqual(app.selectedIds, visible)

        XCTAssertTrue(app.handleKey("a", hasCommand: true, hasShift: true))
        XCTAssertTrue(app.selectedIds.isEmpty)
        XCTAssertNil(app.primaryId)
    }

    @MainActor
    func testCommandKeyboardShortcutsRespectSheets() {
        let app = AppState()
        app.onboarded = true
        app.sheet = "settings"
        let initialFilterOpen = app.filterOpen
        let initialShowInspector = app.showInspector
        let initialThumbSize = app.thumbSize

        XCTAssertFalse(app.handleKey("f", hasCommand: true, hasShift: true))
        XCTAssertFalse(app.handleKey("i", hasCommand: true))
        XCTAssertFalse(app.handleKey("=", hasCommand: true))
        XCTAssertEqual(app.filterOpen, initialFilterOpen)
        XCTAssertEqual(app.showInspector, initialShowInspector)
        XCTAssertEqual(app.thumbSize, initialThumbSize)
        XCTAssertEqual(app.sheet, "settings")
    }

    @MainActor
    func testBatchCaptureTimeActionsApplyToSelection() throws {
        let app = AppState()
        app.onboarded = true
        let id = try XCTUnwrap(app.primaryId)
        let originalDate = try XCTUnwrap(app.assets.first { $0.id == id }?.date)

        app.shiftCaptureTime(hours: 1, minutes: -15)
        let shifted = try XCTUnwrap(app.assets.first { $0.id == id })
        XCTAssertEqual(shifted.date.timeIntervalSince(originalDate), 45 * 60, accuracy: 0.1)
        XCTAssertEqual(shifted.captureDateSource, "手动调整")

        let absolute = Date(timeIntervalSince1970: 1_700_000_000)
        app.setCaptureDate(absolute)
        let updated = try XCTUnwrap(app.assets.first { $0.id == id })
        XCTAssertEqual(updated.date, absolute)
        XCTAssertEqual(updated.captureDateSource, "手动设置")
    }

    @MainActor
    func testSearchFiltersAndSortKeepListConsistent() throws {
        let app = AppState()
        app.onboarded = true
        let filename = try XCTUnwrap(app.assets.first?.filename)

        app.setSearch(filename)
        XCTAssertFalse(app.list.isEmpty)
        XCTAssertTrue(app.list.allSatisfy { $0.filename.localizedStandardContains(filename) })
        XCTAssertEqual(app.primaryId, app.list.first?.id)

        app.setSearch("")
        var filters = Filters()
        filters.minRating = 2
        filters.type = "RAW"
        app.setFilters(filters)
        XCTAssertFalse(app.list.isEmpty)
        XCTAssertTrue(app.list.allSatisfy { $0.rating >= 2 && $0.isRaw })

        app.setFilters(Filters())
        app.setSort(Sort(field: .name, descending: false))
        let ascending = app.list.map(\.filename)
        XCTAssertEqual(ascending, ascending.sorted { $0.localizedCompare($1) == .orderedAscending })

        app.setSort(Sort(field: .name, descending: true))
        let descending = app.list.map(\.filename)
        XCTAssertEqual(descending, ascending.reversed())
    }

    @MainActor
    func testLibrarySelectionsFilterExpectedAssets() {
        let app = AppState()
        app.onboarded = true

        app.select(Selection(type: .lib, id: "unrated", name: "未评分"))
        XCTAssertFalse(app.list.isEmpty)
        XCTAssertTrue(app.list.allSatisfy { $0.rating == 0 && $0.flag != .reject })

        app.select(Selection(type: .lib, id: "missing", name: "缺失 / 离线"))
        XCTAssertFalse(app.list.isEmpty)
        XCTAssertTrue(app.list.allSatisfy { $0.status == .missing || $0.status == .offline })
        XCTAssertEqual(app.primaryId, app.list.first?.id)
    }
}
