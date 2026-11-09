import XCTest
@testable import PhotoCatalog

/// The capture analysis counts raw values and whole days, and gives exactly what the per-photo
/// strings and calendar days gave, kept here as the oracle.
final class CaptureStatisticsOracleTests: XCTestCase {
    /// What the analysis reports, from either implementation.
    struct Report: Equatable {
        struct Distribution: Equatable {
            let parameter: CaptureParameter
            let values: [String]
            let counts: [Int]
            let missingCount: Int
        }

        let totalCount: Int
        let dayCount: Int
        let completeCount: Int
        let fileDateCount: Int
        let firstDate: Date?
        let lastDate: Date?
        let distributions: [Distribution]

        init(_ statistics: CaptureStatistics) {
            self.init(totalCount: statistics.totalCount, dayCount: statistics.dayCount,
                      completeCount: statistics.completeCount, fileDateCount: statistics.fileDateCount,
                      firstDate: statistics.firstDate, lastDate: statistics.lastDate,
                      distributions: statistics.distributions.map {
                          Distribution(parameter: $0.parameter, values: $0.values.map(\.value),
                                       counts: $0.values.map(\.count), missingCount: $0.missingCount)
                      })
        }

        init(totalCount: Int, dayCount: Int, completeCount: Int, fileDateCount: Int, firstDate: Date?,
             lastDate: Date?, distributions: [Distribution]) {
            self.totalCount = totalCount
            self.dayCount = dayCount
            self.completeCount = completeCount
            self.fileDateCount = fileDateCount
            self.firstDate = firstDate
            self.lastDate = lastDate
            self.distributions = distributions
        }
    }

    /// `CaptureStatistics.init(assets:)` as it was: six strings per photo through
    /// `CaptureParameter.value(in:)`, and each day as the calendar's start of day.
    static func legacy(assets: [Asset]) -> Report {
        let parameters = CaptureParameter.allCases
        var counts = Array(repeating: [String: Int](), count: parameters.count)
        var missing = Array(repeating: 0, count: parameters.count)
        var days = Set<Date>()
        var total = 0, complete = 0, fileDates = 0
        var first: Date?, last: Date?
        for asset in assets {
            guard !asset.deleted else { continue }
            total += 1
            if asset.date.timeIntervalSince1970.isFinite {
                days.insert(Calendar.captureWallClock.startOfDay(for: asset.date))
                first = first.map { min($0, asset.date) } ?? asset.date
                last = last.map { max($0, asset.date) } ?? asset.date
            }
            if asset.captureDateSource.hasPrefix("文件") { fileDates += 1 }
            var isComplete = true
            for (index, parameter) in parameters.enumerated() {
                if let value = parameter.value(in: asset) {
                    counts[index][value, default: 0] += 1
                } else {
                    missing[index] += 1
                    isComplete = false
                }
            }
            if isComplete { complete += 1 }
        }
        let distributions = parameters.enumerated().map { index, parameter in
            let values = counts[index].map { CaptureParameterCount(value: $0.key, count: $0.value) }.sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                if parameter != .camera, parameter != .lens, let left = Double($0.value), let right = Double($1.value) {
                    return left < right
                }
                return $0.value.localizedStandardCompare($1.value) == .orderedAscending
            }
            return Report.Distribution(parameter: parameter, values: values.map(\.value),
                                       counts: values.map(\.count), missingCount: missing[index])
        }
        return Report(totalCount: total, dayCount: days.count, completeCount: complete, fileDateCount: fileDates,
                      firstDate: first, lastDate: last, distributions: distributions)
    }

    static func photo(_ index: Int, date: Date, camera: String = "Canon EOS R5", lens: String = "RF50mm F1.2 L USM",
                      focal: Int = 50, aperture: Double = 1.2, shutter: String = "1/125", iso: Int = 100,
                      source: String = "EXIF · DateTimeOriginal", deleted: Bool = false) -> Asset {
        Asset(id: "c\(index)", pid: index, ori: "l", thumb: "", preview: "", filename: "IMG_\(index).JPG",
              type: "JPG", isRaw: false, folderId: "f", folderName: "F", date: date, width: 6000, height: 4000,
              orientation: 1, camera: camera, lens: lens, focal: focal, aperture: aperture, shutter: shutter,
              iso: iso, colorSpace: "sRGB", fileMB: 1, rating: 0, flag: .none, keywords: [], title: "", caption: "",
              location: "", gps: (0, 0), status: .ready, importedAt: Date(timeIntervalSince1970: 1_700_000_000),
              deleted: deleted, captureDateSource: source)
    }

    /// Capture times as cameras record them in many zones (the wall clock, anchored to UTC), either
    /// side of daylight-saving changes and midnight; before 1970, before AD 1 and after 9999 (where
    /// the calendar clamps), and times that aren't numbers.
    static func captureDates() throws -> [Date] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func utc(_ text: String) throws -> Date { try XCTUnwrap(formatter.date(from: text), text) }
        // the instants clocks changed in 2026: New York, London, Lord Howe, Chatham, Santiago
        let changes = try ["2026-03-08T07:00:00.000Z", "2026-11-01T06:00:00.000Z", "2026-03-29T01:00:00.000Z",
                           "2026-10-25T01:00:00.000Z", "2026-04-04T15:00:00.000Z", "2026-10-03T15:30:00.000Z",
                           "2026-04-04T14:00:00.000Z", "2026-09-26T14:00:00.000Z", "2026-04-05T03:00:00.000Z",
                           "2026-09-06T04:00:00.000Z"].map(utc)
        let zones = try ["America/New_York", "Europe/London", "Australia/Lord_Howe", "Pacific/Chatham",
                         "America/Santiago", "Asia/Shanghai", "Asia/Kathmandu", "Pacific/Kiritimati",
                         "Pacific/Pago_Pago", "America/St_Johns", "UTC"].map { try XCTUnwrap(TimeZone(identifier: $0)) }
        var dates: [Date] = []
        for change in changes {
            for offset in [-7_200.0, -3_600, -1, -0.001, 0, 0.001, 1, 1_800, 3_600, 7_200] {
                for zone in zones { dates.append(change.addingTimeInterval(offset).captureWallClock(in: zone)) }
            }
        }
        dates += try ["1969-12-31T23:59:59.999Z", "1970-01-01T00:00:00.000Z", "1900-02-28T12:00:00.000Z",
                      "1582-10-04T23:59:59.000Z", "1582-10-15T00:00:00.000Z", "0001-01-01T00:00:00.000Z",
                      "9999-12-31T23:59:59.999Z", "2024-02-29T23:59:59.999Z", "2024-03-01T00:00:00.000Z"].map(utc)
        dates += [-62_135_596_800, -62_135_596_800.5, -62_135_683_200, 253_402_300_800, 253_402_300_799.5,
                  -70_000_000_000, -210_866_803_200, -210_866_803_201, -1e12, -1e12 - 86_400, 1e13, 1.6e13, 1e14,
                  1e14 + 86_400, 1e24, -1e24, 1e300, -.greatestFiniteMagnitude, .greatestFiniteMagnitude,
                  .nan, .infinity, -.infinity].map { Date(timeIntervalSince1970: $0) }
        dates += [.distantPast, .distantFuture]
        return dates
    }

    static let cameras = ["Canon EOS R5", "Canon EOS R5 ", " Canon EOS R5", "canon eos r5", "Canon EOS R5\n", "",
                          " ", "   ", "\n", "\t", "\r\n", "\u{00A0}", "\u{2003}", "\u{3000}", "\u{0085}", "\u{2028}",
                          "\u{200B}", "\u{FEFF}", " \u{301}", "Canon\u{00A0}", "ＣＡＮＯＮ", "佳能 EOS R5", "SONY", "Sony",
                          "ILCE-7M4", "123", "1.4"]
    static let lenses = ["RF50mm F1.2 L USM", "", "  ", "\u{3000}FE 35mm\u{3000}", "FE 35mm", "fe 35mm", "\t\n",
                         "RF24-70mm F2.8", "2", "镜头"]
    static let focals = [50, 0, -5, 35, 24, 200, 1, 600, Int.max]
    static let apertures: [Double] = [1.2, .nan, .infinity, -.infinity, 0, -0.0, -2, 1.4, 2.8, 2.8000000000000003, 4,
                                      1e-300, .greatestFiniteMagnitude, 5.6, 16]
    static let shutters = ["1/125", "0.008", "1/0", "", "30s", "30 s", "30", "1/8000", "2.0", "2", " 1/125 ",
                           "1/125s", "nan", "inf", "-1", "1/2/3", "abc", "0", "1/3", "0.3333333333333333", "1e-3",
                           "１/１２５", "1/-2", "+1/125", "1/250", "0.004", "1 /125", "15\"", "1/125\n"]
    static let isos = [100, 0, -100, 200, 6_400, 102_400, 64, Int.max]
    static let sources = ["EXIF · DateTimeOriginal", "文件修改时间", "文件创建时间", "视频创建时间", "手动调整", "sidecar", "", "文件"]

    /// Every value of every parameter against every other, by strides that don't line up.
    static func mixedPhotos() throws -> [Asset] {
        let dates = try captureDates()
        let count = max(dates.count * 3, 4_000)
        return (0..<count).map { index in
            photo(index, date: dates[index % dates.count], camera: cameras[(index * 7) % cameras.count],
                  lens: lenses[(index * 3 + 1) % lenses.count], focal: focals[(index * 5 + 2) % focals.count],
                  aperture: apertures[(index * 11 + 3) % apertures.count],
                  shutter: shutters[(index * 13 + 4) % shutters.count], iso: isos[(index * 17 + 5) % isos.count],
                  source: sources[(index * 19) % sources.count], deleted: index % 23 == 7)
        }
    }

    func testStatisticsAreTheOldPerPhotoStatistics() throws {
        let photos = try Self.mixedPhotos()
        let report = Report(try CaptureStatistics(assets: photos))
        let expected = Self.legacy(assets: photos)
        XCTAssertEqual(report.totalCount, expected.totalCount)
        XCTAssertEqual(report.dayCount, expected.dayCount)
        XCTAssertEqual(report.completeCount, expected.completeCount)
        XCTAssertEqual(report.fileDateCount, expected.fileDateCount)
        XCTAssertEqual(report.firstDate, expected.firstDate)
        XCTAssertEqual(report.lastDate, expected.lastDate)
        XCTAssertEqual(report.distributions.map(\.parameter), expected.distributions.map(\.parameter))
        for (got, want) in zip(report.distributions, expected.distributions) {
            XCTAssertEqual(got.values, want.values, "\(got.parameter) values")
            XCTAssertEqual(got.counts, want.counts, "\(got.parameter) counts")
            XCTAssertEqual(got.missingCount, want.missingCount, "\(got.parameter) missing")
        }
        XCTAssertEqual(report, expected)
        // the fixture reaches what it is meant to: photos with every parameter, and without each
        XCTAssertGreaterThan(expected.completeCount, 0)
        XCTAssertTrue(expected.distributions.allSatisfy { $0.missingCount > 0 && $0.values.count > 1 })
    }

    /// Every way to slice the photos (one day, one zone's photos, the far dates alone) agrees too,
    /// so no day or value is counted right only because another hides it.
    func testEverySliceIsTheOldStatistics() throws {
        let photos = try Self.mixedPhotos()
        for size in [1, 2, 7, 64, 255, 256, 257, 1_000] {
            for start in stride(from: 0, to: photos.count, by: max(size, photos.count / 9)) {
                let slice = Array(photos[start..<min(start + size, photos.count)])
                XCTAssertEqual(Report(try CaptureStatistics(assets: slice)), Self.legacy(assets: slice),
                               "photos \(start)..<\(start + size)")
            }
        }
        for date in try Self.captureDates() {
            let sameTime = (0..<3).map { Self.photo($0, date: date) }
            XCTAssertEqual(Report(try CaptureStatistics(assets: sameTime)), Self.legacy(assets: sameTime), "\(date)")
        }
        let far = try Self.captureDates().enumerated().filter { abs($0.element.timeIntervalSince1970) > 3e11 }
            .map { Self.photo($0.offset, date: $0.element) }
        XCTAssertEqual(Report(try CaptureStatistics(assets: far)), Self.legacy(assets: far))
        XCTAssertEqual(Report(try CaptureStatistics(assets: [])), Self.legacy(assets: []))
    }

    /// Shown values stay the exact text each parameter gave: the list's identity, and what
    /// `label(for:)` parses again.
    func testValuesAreTheTextEachParameterGave() throws {
        let photos = try Self.mixedPhotos()
        let statistics = try CaptureStatistics(assets: photos)
        for distribution in statistics.distributions {
            let given = Set(photos.filter { !$0.deleted }.compactMap { distribution.parameter.value(in: $0) })
            XCTAssertEqual(Set(distribution.values.map(\.value)), given, "\(distribution.parameter)")
        }
        let shutter = try XCTUnwrap(statistics.distributions.first { $0.parameter == .shutter })
        let eighth = try XCTUnwrap(shutter.values.first { $0.value == String(0.008) })
        let alike = photos.filter { !$0.deleted && CaptureParameter.shutterSeconds($0.shutter) == 0.008 }
        XCTAssertEqual(eighth.count, alike.count, "1/125 and 0.008 share a bucket")
        XCTAssertGreaterThan(Set(alike.map(\.shutter)).count, 1)
    }
}
