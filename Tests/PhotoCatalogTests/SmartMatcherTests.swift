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

/// The compiled matcher (typed conditions, a year as an interval, text tests remembered by value)
/// answers exactly as the rules read field by field did, for every field, operator and odd value.
extension SmartMatcherTests {
    /// The matcher as it was: the field's name switched on per photo, a calendar call per year,
    /// a locale-aware search per keyword, camera and lens.
    static func fieldByField(_ a: Asset, _ c: SmartCondition, now: Date) -> Bool {
        let number = Int(c.value) ?? 0
        switch c.field {
        case "rating":
            if c.op == ">=" { return a.rating >= number }
            if c.op == "<=" { return a.rating <= number }
            return a.rating == number
        case "flag":
            return a.flag.rawValue == c.value
        case "colorLabel":
            return (a.colorLabel?.rawValue ?? "") == c.value || (c.value.isEmpty && a.colorLabel == nil)
        case "keywords":
            let has = a.keywords.contains { $0.localizedStandardContains(c.value) }
            return c.op == "包含" ? has : !has
        case "camera":
            if c.op == "=" { return a.camera == c.value }
            return a.camera.localizedStandardContains(c.value)
        case "lens":
            if c.op == "=" { return a.lens == c.value }
            return a.lens.localizedStandardContains(c.value)
        case "type":
            return a.matchesType(c.value)
        case "captureYear":
            let y = Calendar.captureWallClock.component(.year, from: a.date)
            if c.op == ">=" { return y >= number }
            if c.op == "<=" { return y <= number }
            return y == number
        case "datePreset":
            if c.value == "any" { return true }
            guard let interval = CaptureDates.presetInterval(c.value, now: now) else { return false }
            return CaptureDates.contains(a.date, in: interval)
        case "captureDate":
            guard let interval = CaptureDates.interval(for: c.value) else { return false }
            if c.op == ">=" { return a.date >= interval.start }
            if c.op == "<=" { return a.date < interval.end }
            return CaptureDates.contains(a.date, in: interval)
        case "gps":
            return c.value == "yes" ? a.hasGPS : !a.hasGPS
        case "status":
            return a.status.rawValue == c.value
        case "search":
            return a.searchHaystack.localizedStandardContains(c.value)
        default:
            return true
        }
    }

    /// Photos that differ in every field a rule reads: accents, case and width in keywords and
    /// cameras, capture times either side of a year's first and last instant, BC and far-future
    /// times, today and the days around it.
    static func variedPhotos(now: Date) throws -> [Asset] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func utc(_ text: String) throws -> Date { try XCTUnwrap(formatter.date(from: text)) }
        let today = CaptureDates.startOfToday(now: now)
        var dates: [Date] = [
            try utc("2022-12-31T23:59:59.000Z"), try utc("2022-12-31T23:59:59.999Z"),
            try utc("2023-01-01T00:00:00.000Z"), try utc("2023-01-01T00:00:00.001Z"),
            try utc("2023-06-15T12:00:00.000Z"), try utc("2023-12-31T23:59:59.500Z"),
            try utc("2024-01-01T00:00:00.000Z"), try utc("2024-02-29T08:00:00.000Z"),
            try utc("0001-01-01T00:00:00.000Z"), try utc("0001-01-01T00:00:00.500Z"),
            try utc("9999-12-31T23:59:59.000Z"),
            Date(timeIntervalSince1970: -70_000_000_000), Date(timeIntervalSince1970: 300_000_000_000),
            .distantPast, .distantFuture,
        ]
        for days in [0, -1, -6, -7, -29, -30, -31, -200, 1] {
            dates.append(today.addingTimeInterval(Double(days) * 86_400))
            dates.append(today.addingTimeInterval(Double(days) * 86_400 + 86_399.5))
        }
        let keywords: [[String]] = [["Café", "旅行/主题1", "家庭"], ["cafe"], ["CAFÉ au lait"], ["Travel"], [],
                                    ["旅行"], ["résumé", "naïve"], ["人像", "旅行/主题12"], ["ｃａｆｅ"]]
        let cameras = ["Canon EOS R5", "CANON EOS 5D Mark IV", "canon", "Cañon", "SONY ILCE-7M4", "", "iPhone 15 Pro"]
        let lenses = ["RF50mm F1.2 L USM", "FE 35mm F1.4 GM", "", "rf24-70mm f2.8"]
        let types: [(String, Bool)] = [("CR3", true), ("JPG", false), ("MOV", false), ("HEIC", false)]
        let flags: [Flag] = [.none, .pick, .reject]
        let labels: [ColorLabel?] = [nil, .red, .blue]
        let statuses: [AssetStatus] = [.ready, .offline, .missing]
        return dates.enumerated().map { index, date in
            let (type, raw) = types[index % types.count]
            var asset = Asset(id: "p\(index)", pid: index, ori: "l", thumb: "", preview: "",
                              filename: "IMG_\(1000 + index).\(type)", type: type, isRaw: raw,
                              folderId: "f\(index % 3)", folderName: "F", date: date, width: 6000, height: 4000,
                              orientation: 1, camera: cameras[index % cameras.count], lens: lenses[index % lenses.count],
                              focal: 50, aperture: 2, shutter: "1/100", iso: 100, colorSpace: "sRGB", fileMB: 1,
                              rating: index % 6, flag: flags[index % flags.count], colorLabel: labels[index % labels.count],
                              keywords: keywords[index % keywords.count],
                              title: index % 4 == 0 ? "Wedding at the Café" : "", caption: "",
                              location: index % 5 == 0 ? "30.500, 114.300" : "",
                              gps: index % 7 == 0 ? (35.6, 139.7) : (0, 0),
                              status: statuses[index % statuses.count], importedAt: now)
            asset.project = index % 3 == 0 ? "Wedding" : ""
            return asset
        }
    }

    static let variedConditions: [SmartCondition] = {
        var conditions: [SmartCondition] = []
        func add(_ field: String, _ ops: [String], _ values: [String]) {
            for op in ops {
                for value in values { conditions.append(SmartCondition(field: field, op: op, value: value)) }
            }
        }
        add("rating", [">=", "<=", "=", "?"], ["0", "3", "5", "x"])
        add("flag", ["="], ["pick", "none", "reject", "bogus", ""])
        add("colorLabel", ["="], ["", "red", "blue", "bogus"])
        add("keywords", ["包含", "不包含", "?"], ["cafe", "CAFÉ", "旅行", "主题1", "travel", "e", "", "zzz"])
        add("camera", ["包含", "=", "?"], ["canon", "Canon EOS R5", "EOS", "cañon", "", "sony"])
        add("lens", ["包含", "="], ["rf", "FE 35mm F1.4 GM", "F2.8", ""])
        add("type", ["="], ["RAW", "VIDEO", "JPG", "CR3", "bogus"])
        add("captureYear", ["=", ">=", "<=", "?"],
            ["2023", "2022", "2024", "1", "2", "9998", "9999", "0", "-5", "10000", "abc"])
        add("datePreset", ["="], ["today", "yesterday", "last7Days", "last30Days", "thisMonth", "thisYear", "any", "bogus"])
        add("captureDate", ["=", ">=", "<="], ["2023", "2023-01", "2023-01-01", "2023-02-30", "bad", "2024-02-29"])
        add("gps", ["="], ["yes", "no"])
        add("status", ["="], ["ready", "offline", "missing", "bogus"])
        add("search", ["包含"], ["cafe", "R5 RF50", "wedding", "IMG_10", "", "zzz", "114.3"])
        add("bogus", ["="], ["anything"])
        return conditions
    }()

    func testCompiledConditionsMatchAsTheFieldByFieldRulesDid() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-31T18:00:00Z"))
        let photos = try Self.variedPhotos(now: now)
        for condition in Self.variedConditions {
            let compiled = SmartMatcher.Prepared(SmartRule(match: "all", conditions: [condition]), now: now)
            var memo = SmartMatcher.Memo(for: compiled)
            for photo in photos {
                let expected = Self.fieldByField(photo, condition, now: now)
                XCTAssertEqual(compiled.matches(photo), expected,
                               "\(condition.field) \(condition.op) \(condition.value) on \(photo.id) (\(photo.date))")
                XCTAssertEqual(compiled.matches(photo, memo: &memo), expected,
                               "remembered: \(condition.field) \(condition.op) \(condition.value) on \(photo.id)")
            }
        }
    }

    /// Several text tests in one rule keep their answers apart, and a memo carried across photos
    /// (as a recount does) gives each photo its own answer.
    func testRulesWithSeveralTextTestsMatchAsBefore() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-31T18:00:00Z"))
        let photos = try Self.variedPhotos(now: now)
        let texts = Self.variedConditions.filter { ["keywords", "camera", "lens", "search"].contains($0.field) }
        let others = Self.variedConditions.filter { ["rating", "captureYear", "datePreset"].contains($0.field) }
        for (offset, text) in texts.enumerated() {
            let partner = texts[(offset * 7 + 3) % texts.count]
            let other = others[offset % others.count]
            for match in ["all", "any"] {
                let conditions = [text, other, partner]
                let compiled = SmartMatcher.Prepared(SmartRule(match: match, conditions: conditions), now: now)
                var memo = SmartMatcher.Memo(for: compiled)
                for photo in photos + photos {
                    let each = conditions.map { Self.fieldByField(photo, $0, now: now) }
                    let expected = match == "all" ? !each.contains(false) : each.contains(true)
                    XCTAssertEqual(compiled.matches(photo, memo: &memo), expected,
                                   "\(match): \(conditions.map { "\($0.field) \($0.op) \($0.value)" }) on \(photo.id)")
                }
            }
        }
    }
}
