import XCTest
@testable import PhotoCatalog

/// Capture times are wall clock anchored to UTC; "now" is an instant. These pin how the two meet.
final class CaptureDateTests: XCTestCase {
    private let china = TimeZone(secondsFromGMT: 8 * 3600)!
    private let newYork = TimeZone(secondsFromGMT: -5 * 3600)!

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
}
