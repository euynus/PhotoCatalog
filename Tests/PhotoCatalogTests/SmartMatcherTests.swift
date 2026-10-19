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

    /// The rule builder's preview: every match counted, only the first few kept, trashed photos left out.
    func testPreviewCountsEveryMatchAndKeepsTheFirstFew() async throws {
        let shot = Date(timeIntervalSince1970: 1_791_800_000)
        let assets = (0..<40).map { index in
            var asset = Asset(id: "a\(index)", pid: 0, ori: "l", thumb: "", preview: "", filename: "IMG_\(index).JPG",
                              type: "JPEG", isRaw: false, folderId: "day", folderName: "Day", date: shot,
                              width: 6000, height: 4000, orientation: 1, camera: "", lens: "", focal: 50,
                              aperture: 4, shutter: "1/100", iso: 100, colorSpace: "sRGB", fileMB: 1,
                              rating: index % 2 == 0 ? 4 : 1, flag: .none, keywords: [], title: "", caption: "",
                              location: "", gps: (0, 0), status: .ready, importedAt: shot, localPath: nil)
            asset.deleted = index == 0
            return asset
        }
        let rule = SmartRule(conditions: [SmartCondition(field: "rating", op: ">=", value: "3")])

        let preview = try XCTUnwrap(SmartMatcher.preview(assets, rule, limit: 14))

        let live = assets.filter { !$0.deleted }
        XCTAssertEqual(preview.count, SmartMatcher.match(live, rule).count)
        XCTAssertEqual(preview.count, 19)
        XCTAssertEqual(preview.first.map(\.id), SmartMatcher.match(live, rule).prefix(14).map(\.id))
        XCTAssertEqual(try XCTUnwrap(SmartMatcher.preview(assets, rule, limit: 30)).first.count, 19)

        // a match the builder no longer needs (the rule changed, the sheet closed) stops
        let cancelled = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return SmartMatcher.preview(assets, rule, limit: 14)
        }.value
        XCTAssertNil(cancelled)
    }
}
