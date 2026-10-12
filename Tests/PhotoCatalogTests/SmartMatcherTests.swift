import XCTest
@testable import PhotoCatalog

final class SmartMatcherTests: XCTestCase {
    func testDatePresetsUseCaptureWallClockBoundaries() throws {
        let formatter = ISO8601DateFormatter()
        // "now" is an instant, read on this Mac's clock: pinned to UTC here so it is 18:00 on 31 July
        let now = try XCTUnwrap(formatter.date(from: "2026-07-31T18:00:00Z"))
        let utc = TimeZone.captureWallClock
        let julyCapture = try XCTUnwrap(formatter.date(from: "2026-07-31T12:00:00Z"))
        let augustCapture = try XCTUnwrap(formatter.date(from: "2026-08-01T00:00:00Z"))

        XCTAssertTrue(SmartMatcher.matchesDatePreset(julyCapture, "thisMonth", now: now, timeZone: utc))
        XCTAssertFalse(SmartMatcher.matchesDatePreset(augustCapture, "thisMonth", now: now, timeZone: utc))
        XCTAssertTrue(SmartMatcher.matchesDatePreset(julyCapture, "thisYear", now: now, timeZone: utc))
    }
}
