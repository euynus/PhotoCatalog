import XCTest
@testable import PhotoCatalog

final class SmartMatcherTests: XCTestCase {
    func testDatePresetsUseCaptureWallClockBoundaries() throws {
        let formatter = ISO8601DateFormatter()
        let now = try XCTUnwrap(formatter.date(from: "2026-07-31T18:00:00Z"))
        let julyCapture = try XCTUnwrap(formatter.date(from: "2026-07-31T12:00:00Z"))
        let augustCapture = try XCTUnwrap(formatter.date(from: "2026-08-01T00:00:00Z"))

        XCTAssertTrue(SmartMatcher.matchesDatePreset(julyCapture, "thisMonth", now: now))
        XCTAssertFalse(SmartMatcher.matchesDatePreset(augustCapture, "thisMonth", now: now))
        XCTAssertTrue(SmartMatcher.matchesDatePreset(julyCapture, "thisYear", now: now))
    }
}
