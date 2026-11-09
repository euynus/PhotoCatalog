import XCTest
@testable import PhotoCatalog

/// The compiled date tests compare capture times as seconds: a time exactly on an interval's start
/// is in it, one exactly on its end is not, and a time that isn't a number is in none.
final class SmartMatcherDateBoundsTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-07-31T18:00:00Z")!

    private func photo(_ date: Date) -> Asset {
        .dayShot("p", "IMG_1.JPG", type: "JPG", isRaw: false, camera: "", date: date, importedAt: now,
                 localPath: "/tmp/IMG_1.JPG", isDemo: false)
    }

    private func matches(_ field: String, _ op: String, _ value: String, _ date: Date) -> Bool {
        SmartMatcher.Prepared(SmartRule(match: "all", conditions: [SmartCondition(field: field, op: op, value: value)]),
                              now: now).matches(photo(date))
    }

    /// Each condition on its interval's edges, a tick either side of them, and as the field-by-field
    /// rules read it.
    func testDatesOnTheBounds() throws {
        var cases: [(field: String, op: String, value: String, interval: DateInterval)] = []
        for op in ["=", ">=", "<="] {
            for value in ["2023", "2024-02", "2024-02-29"] {
                cases.append(("captureDate", op, value, try XCTUnwrap(CaptureDates.interval(for: value))))
            }
            cases.append(("captureYear", op, "2023", try XCTUnwrap(CaptureDates.interval(for: "2023"))))
        }
        for preset in ["today", "yesterday", "last7Days", "last30Days", "thisMonth", "thisYear"] {
            cases.append(("datePreset", "=", preset, try XCTUnwrap(CaptureDates.presetInterval(preset, now: now))))
        }
        for (field, op, value, interval) in cases {
            let start = interval.start.timeIntervalSinceReferenceDate, end = interval.end.timeIntervalSinceReferenceDate
            for seconds in [start.nextDown, start, start.nextUp, end.nextDown, end, end.nextUp] {
                // ">=" has no end and "<=" no start
                let expected = (op == "<=" || seconds >= start) && (op == ">=" || seconds < end)
                let date = Date(timeIntervalSinceReferenceDate: seconds)
                let condition = SmartCondition(field: field, op: op, value: value)
                XCTAssertEqual(matches(field, op, value, date), expected, "\(field) \(op) \(value) at \(seconds)")
                XCTAssertEqual(matches(field, op, value, date), SmartMatcherTests.fieldByField(photo(date), condition, now: now),
                               "\(field) \(op) \(value) at \(seconds), as before")
            }
        }
    }

    /// A capture time that isn't a number is in no date range, and its year is the calendar's answer.
    func testNotANumberDate() {
        let date = Date(timeIntervalSinceReferenceDate: .nan)
        for value in ["2023", "2023-01", "2023-01-01"] {
            for op in ["=", ">=", "<="] {
                XCTAssertFalse(matches("captureDate", op, value, date), "captureDate \(op) \(value)")
            }
        }
        for preset in ["today", "yesterday", "last7Days", "last30Days", "thisMonth", "thisYear"] {
            XCTAssertFalse(matches("datePreset", "=", preset, date), preset)
        }
        XCTAssertTrue(matches("datePreset", "=", "any", date))
        for value in ["1", "2023", "9999", "0", "-5"] {
            for op in ["=", ">=", "<="] {
                let condition = SmartCondition(field: "captureYear", op: op, value: value)
                XCTAssertEqual(matches("captureYear", op, value, date),
                               SmartMatcherTests.fieldByField(photo(date), condition, now: now), "captureYear \(op) \(value)")
            }
        }
    }
}
