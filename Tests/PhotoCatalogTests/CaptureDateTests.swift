import XCTest
@testable import PhotoCatalog

/// Capture times are wall clock anchored to UTC; "now" is an instant. These pin how the two meet.
final class CaptureDateTests: XCTestCase {
    private let china = TimeZone(secondsFromGMT: 8 * 3600)!
    private let newYork = TimeZone(secondsFromGMT: -5 * 3600)!
    private var folder: URL?

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func instant(_ iso: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: iso))
    }

    private func day(_ key: String) throws -> DateInterval {
        try XCTUnwrap(CaptureDates.interval(for: key))
    }

    // MARK: - #13 relative date presets follow this Mac's day

    func testDatePresetsUseTheLocalDayAfterUTCMidnight() throws {
        // 02:00 on 12 October in China is still 11 October in UTC
        let now = try instant("2026-10-11T18:00:00Z")
        XCTAssertEqual(CaptureDates.presetInterval("today", now: now, timeZone: china), try day("2026-10-12"))
        XCTAssertEqual(CaptureDates.presetInterval("yesterday", now: now, timeZone: china), try day("2026-10-11"))
        XCTAssertEqual(CaptureDates.presetInterval("last7Days", now: now, timeZone: china),
                       DateInterval(start: try day("2026-10-06").start, end: try day("2026-10-12").end))
        XCTAssertEqual(CaptureDates.presetInterval("last30Days", now: now, timeZone: china)?.start,
                       try day("2026-09-13").start)
        XCTAssertEqual(CaptureDates.startOfToday(now: now, timeZone: china), try day("2026-10-12").start)

        // a photo taken at 01:30 that night is today's, not tomorrow's
        let justTaken = try instant("2026-10-12T01:30:00Z")
        XCTAssertTrue(SmartMatcher.matchesDatePreset(justTaken, "today", now: now, timeZone: china))
        XCTAssertFalse(SmartMatcher.matchesDatePreset(justTaken, "yesterday", now: now, timeZone: china))
    }

    func testMonthAndYearPresetsRollOverAtLocalMidnight() throws {
        let november = try instant("2026-10-31T18:00:00Z")
        XCTAssertEqual(CaptureDates.presetInterval("thisMonth", now: november, timeZone: china), try day("2026-11"))
        let newYear = try instant("2026-12-31T18:00:00Z")
        XCTAssertEqual(CaptureDates.presetInterval("thisYear", now: newYear, timeZone: china), try day("2027"))
    }

    func testDatePresetsWestOfUTCStayOnTheLocalDay() throws {
        // 22:00 on 11 October in New York is already 12 October in UTC
        let now = try instant("2026-10-12T03:00:00Z")
        XCTAssertEqual(CaptureDates.presetInterval("today", now: now, timeZone: newYork), try day("2026-10-11"))
        XCTAssertEqual(CaptureDates.startOfToday(now: now, timeZone: newYork), try day("2026-10-11").start)
    }

    func testNaturalSearchTellsTheModelTheLocalDate() throws {
        let request = PhotoSearch.request("去年的照片", today: try instant("2026-12-31T18:00:00Z"), timeZone: china,
                                          vocabulary: PhotoSearch.Vocabulary(), chinese: true)
        XCTAssertTrue(request.system.contains("today is 2027-01-01"), request.system)
        XCTAssertTrue(request.system.contains(#""dateStart": "2026-06-01""#), "last year is the local year's")
    }

    // MARK: - #71 a range with one end is open at the other

    /// Photos taken at noon on each of these days, as catalog photos.
    private func photos(on days: [String]) throws -> [Asset] {
        try days.enumerated().map { index, key in
            var asset = DemoData.assets[index]
            asset.date = try day(key).start.addingTimeInterval(12 * 3600)
            asset.isDemo = false
            asset.deleted = false
            return asset
        }
    }

    func testNaturalSearchWithOnlyAStartDateFindsEverythingSince() throws {
        let reply = #"{"dateStart": "2025-09-01"}"#
        let filters = try XCTUnwrap(PhotoSearch.parse(reply, vocabulary: PhotoSearch.Vocabulary(),
                                                      query: "2025年9月以来的照片")).filters
        XCTAssertEqual(filters.date, "custom")
        XCTAssertNil(filters.dateEnd)

        let assets = try photos(on: ["2025-08-31", "2025-09-01", "2026-10-12"])
        let since = [assets[1].id, assets[2].id]
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pc-open-range-\(UUID().uuidString)")
        self.folder = folder
        let store = try CatalogStore(packageURL: folder.appendingPathComponent("Open.photolibrary"))
        try store.upsert(assets)
        let page = try store.loadAssetPage(matching: AssetQuery(filters: filters), offset: 0, limit: 10)
        XCTAssertEqual(Set(page.assets.map(\.id)), Set(since), "the catalog query finds the photos since")

        let rule = SmartRule(conditions: filters.smartConditions(search: ""))
        XCTAssertEqual(rule.conditions.map(\.op), [">="], "saved as a smart album, it keeps only its start")
        XCTAssertEqual(SmartMatcher.match(assets, rule).map(\.id), since)

        let interval = try XCTUnwrap(filters.captureDateInterval(), "a start alone is a range")
        XCTAssertEqual(assets.filter { CaptureDates.contains($0.date, in: interval) }.map(\.id), since)
    }

    func testARangeWithOnlyAnEndFindsEverythingBefore() throws {
        let filters = Filters(date: "custom", dateEnd: try day("2020-12-31").start)
        let assets = try photos(on: ["2019-05-04", "2020-12-31", "2021-01-01"])
        let interval = try XCTUnwrap(filters.captureDateInterval())
        XCTAssertEqual(assets.filter { CaptureDates.contains($0.date, in: interval) }.map(\.id),
                       [assets[0].id, assets[1].id])
        XCTAssertNil(Filters(date: "custom").captureDateInterval(), "a range with neither end still finds nothing")
    }

    // the filter bar's pickers, open or opened over such a range, leave the open end open

    func testFilterBarKeepsAnOpenEndOpenUntilItsPickerChanges() throws {
        let since = Filters(date: "custom", dateStart: try day("2025-09-01").start)
        let today = try day("2026-10-12").start
        var pickers = CaptureRangePickers(since, fallback: try day("2026-01-01").start, today: today)
        XCTAssertEqual(pickers.start, since.dateStart)
        XCTAssertEqual(pickers.end, today, "the open end shows today")
        XCTAssertEqual(pickers.applied(to: since), since, "showing the range changes nothing")

        pickers.start = try day("2025-10-01").start
        XCTAssertEqual(pickers.applied(to: since).dateStart, try day("2025-10-01").start)
        XCTAssertNil(pickers.applied(to: since).dateEnd, "moving the start leaves the end open")

        pickers.end = try day("2025-12-31").start
        XCTAssertEqual(pickers.applied(to: since).dateEnd, try day("2025-12-31").start, "picking an end sets it")
    }

    func testFilterBarKeepsAnOpenStartOpenUntilItsPickerChanges() throws {
        let before = Filters(date: "custom", dateEnd: try day("2020-12-31").start)
        var pickers = CaptureRangePickers(before, fallback: try day("2026-01-01").start,
                                          today: try day("2026-10-12").start)
        XCTAssertEqual(pickers.end, before.dateEnd)
        XCTAssertLessThanOrEqual(pickers.start, pickers.end, "the open start shows a day the end can follow")
        XCTAssertEqual(pickers.applied(to: before), before, "showing the range changes nothing")

        pickers.end = try day("2021-06-30").start
        XCTAssertNil(pickers.applied(to: before).dateStart, "moving the end leaves the start open")
        pickers.start = try day("2019-01-01").start
        XCTAssertEqual(pickers.applied(to: before).dateStart, try day("2019-01-01").start, "picking a start sets it")
    }

    func testFilterBarWritesAClosedRangeAsBefore() throws {
        let closed = Filters(date: "custom", dateStart: try day("2025-06-01").start, dateEnd: try day("2025-08-31").start)
        var pickers = CaptureRangePickers(closed, fallback: try day("2026-01-01").start, today: try day("2026-10-12").start)
        XCTAssertEqual(pickers.applied(to: closed), closed)
        pickers.end = try day("2025-09-30").start
        XCTAssertEqual(pickers.applied(to: closed).dateEnd, try day("2025-09-30").start)
    }

    /// The year / month / day tree dated with integer arithmetic is the one the calendar gives:
    /// leap days, century years and year ends included, and any day beyond 1600–9999 dated by it.
    func testDateTreeFromDayCountsIsTheCalendarsTree() {
        var days: [Int: Int] = [:]
        // every day of two years and more from 1600, 1900, 2000 and 2100, and days all the way to 9999
        for start in [-135_140, -25_567, 10_957, 47_482] {
            for day in start ..< start + 800 { days[day] = day % 7 + 1 }
        }
        for day in stride(from: -135_140, through: 2_932_896, by: 997) { days[day] = 2 }
        days[2_932_896] = 3
        let tree = CaptureDates.groups(dayCounts: days)
        XCTAssertEqual(tree, CaptureDates.calendarGroups(dayCounts: days))
        XCTAssertEqual(tree.first?.id, "9999")
        XCTAssertEqual(tree.last?.children.last?.children.last?.id, "1600-01-01")
        days[-200_000] = 1   // 1422: the calendar's way, for every day
        XCTAssertEqual(CaptureDates.groups(dayCounts: days), CaptureDates.calendarGroups(dayCounts: days))
    }
}
