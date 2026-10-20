import Foundation

struct CaptureDateBucket: Identifiable, Sendable, Equatable {
    let id: String
    let label: String
    let count: Int
    let children: [CaptureDateBucket]
}

enum CaptureDates {
    static let presets = [
        ("today", L("今天")), ("yesterday", L("昨天")),
        ("last7Days", L("最近 7 天")), ("last30Days", L("最近 30 天")),
        ("thisMonth", L("本月")), ("thisYear", L("今年")),
    ]

    static func key(_ date: Date, depth: Int = 2) -> String {
        let parts = Calendar.captureWallClock.dateComponents([.year, .month, .day], from: date)
        let year = String(format: "%04d", parts.year ?? 0)
        if depth == 0 { return year }
        let month = year + String(format: "-%02d", parts.month ?? 0)
        return depth == 1 ? month : month + String(format: "-%02d", parts.day ?? 0)
    }

    static func interval(for key: String) -> DateInterval? {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        let values = parts.compactMap { Int($0) }
        guard (1...3).contains(parts.count), values.count == parts.count,
              (1...9999).contains(values[0]) else { return nil }
        let year = values[0]
        let month = values.count > 1 ? values[1] : 1
        let day = values.count > 2 ? values[2] : 1
        let calendar = Calendar.captureWallClock
        guard let start = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let actual = calendar.dateComponents([.year, .month, .day], from: start)
        guard actual.year == year, actual.month == month, actual.day == day else { return nil }
        let component: Calendar.Component = values.count == 1 ? .year : values.count == 2 ? .month : .day
        return calendar.dateInterval(of: component, for: start)
    }

    /// The days from `start` through `end`, both included. A range with one end is open at the
    /// other ("since September": no end); one with neither is none.
    static func interval(from start: Date?, through end: Date?) -> DateInterval? {
        guard start != nil || end != nil,
              start?.timeIntervalSince1970.isFinite ?? true, end?.timeIntervalSince1970.isFinite ?? true else { return nil }
        let calendar = Calendar.captureWallClock
        let first = start.map { calendar.startOfDay(for: $0) } ?? .distantPast
        var afterLast = Date.distantFuture
        if let end {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)) else { return nil }
            afterLast = nextDay
        }
        guard first < afterLast else { return nil }
        return DateInterval(start: first, end: afterLast)
    }

    /// Today as a capture day: this Mac's date, not UTC's (which is still yesterday from midnight
    /// to 08:00 in China).
    static func startOfToday(now: Date = .now, timeZone: TimeZone = .current) -> Date {
        Calendar.captureWallClock.startOfDay(for: now.captureWallClock(in: timeZone))
    }

    /// `now` is an instant; the windows are of capture days, counted from this Mac's today.
    static func presetInterval(_ preset: String, now instant: Date = .now, timeZone: TimeZone = .current) -> DateInterval? {
        let calendar = Calendar.captureWallClock
        let now = instant.captureWallClock(in: timeZone)
        switch preset {
        case "thisMonth": return calendar.dateInterval(of: .month, for: now)
        case "thisYear": return calendar.dateInterval(of: .year, for: now)
        case "today": return calendar.dateInterval(of: .day, for: now)
        case "yesterday":
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else { return nil }
            return calendar.dateInterval(of: .day, for: yesterday)
        case "last7Days", "last30Days":
            let today = calendar.startOfDay(for: now)
            guard let start = calendar.date(byAdding: .day, value: preset == "last7Days" ? -6 : -29, to: today) else { return nil }
            return interval(from: start, through: today)
        default: return nil
        }
    }

    static func contains(_ date: Date, in interval: DateInterval) -> Bool {
        date >= interval.start && date < interval.end
    }

    static func groups(_ assets: [Asset]) -> [CaptureDateBucket] {
        groups(dayCounts: dayCounts(assets, pairing: .empty))
    }

    /// The year / month / day tree of photos counted by day (see `dayCounts`).
    static func groups(dayCounts days: [Int: Int]) -> [CaptureDateBucket] {
        // Days of the years 1600 to 9999, as photos' nearly always are, are dated with integer
        // arithmetic and the tree made from the dates: a calendar call, a key formatted and split
        // again per day and level took ~30 ms for ten years of photos, after every import batch.
        guard days.keys.allSatisfy(gregorianDays.contains) else { return calendarGroups(dayCounts: days) }
        let dated = days.map { (date: civilDate(ofDay: $0.key), count: $0.value) }.sorted { $0.date > $1.date }
        var labels: [Int: String] = [:]   // one call to localize each year, month and day
        func label(_ value: Int, depth: Int) -> String {
            let key = depth * 10_000 + value
            if let known = labels[key] { return known }
            let made = Self.label(value, depth: depth)
            labels[key] = made
            return made
        }
        func padded(_ value: Int) -> String { value < 10 ? "0\(value)" : String(value) }
        var years: [CaptureDateBucket] = []
        var next = 0
        while next < dated.count {
            let year = dated[next].date.year, yearId = String(year)
            var months: [CaptureDateBucket] = []
            while next < dated.count, dated[next].date.year == year {
                let month = dated[next].date.month, monthId = yearId + "-" + padded(month)
                var monthDays: [CaptureDateBucket] = []
                while next < dated.count, dated[next].date.year == year, dated[next].date.month == month {
                    let (date, count) = dated[next]
                    monthDays.append(CaptureDateBucket(id: monthId + "-" + padded(date.day), label: label(date.day, depth: 2),
                                                       count: count, children: []))
                    next += 1
                }
                months.append(CaptureDateBucket(id: monthId, label: label(month, depth: 1),
                                                count: monthDays.reduce(0) { $0 + $1.count }, children: monthDays))
            }
            years.append(CaptureDateBucket(id: yearId, label: label(year, depth: 0),
                                           count: months.reduce(0) { $0 + $1.count }, children: months))
        }
        return years
    }

    /// `groups(dayCounts:)` by way of the calendar and each day's formatted key: how any day is
    /// dated (the years before the Gregorian calendar was in use, or after 9999 included).
    static func calendarGroups(dayCounts days: [Int: Int]) -> [CaptureDateBucket] {
        let counts = days.map { (key: key(Date(timeIntervalSince1970: Double($0.key) * 86_400)), count: $0.value) }
        return buckets(counts, depth: 0)
    }

    /// The days since 1970 from 1600-01-01 to 9999-12-31: four-digit years, all Gregorian.
    private static let gregorianDays = -135_140 ... 2_932_896

    /// A UTC day's Gregorian date (Hinnant's civil-from-days), as `key` dates it in `gregorianDays`.
    private static func civilDate(ofDay day: Int) -> (year: Int, month: Int, day: Int) {
        let shifted = day + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153
        let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, dayOfYear - (153 * shiftedMonth + 2) / 5 + 1)
    }

    /// How many of the photos as shown were taken on each day, by days since 1970, counted in
    /// chunks on every core. Capture times are UTC wall clock, so a photo's day is integer
    /// arithmetic; a Calendar call per photo was most of the half second this took at 500k photos.
    static func dayCounts(_ assets: [Asset], pairing: AssetPairing, chunk: Int = 65_536) -> [Int: Int] {
        func count(_ range: Range<Int>) -> [Int: Int] {
            var days: [Int: Int] = [:]
            for position in range where pairing.isShown(assets[position], at: position) {
                guard let day = day(of: assets[position].date) else { continue }
                days[day, default: 0] += 1
            }
            return days
        }
        let chunk = max(chunk, 1)
        let chunks = assets.isEmpty ? 0 : (assets.count - 1) / chunk + 1
        guard chunks > 1 else { return count(assets.indices) }
        let lock = NSLock()
        var days: [Int: Int] = [:]
        DispatchQueue.concurrentPerform(iterations: chunks) { index in
            let part = count(index * chunk ..< min(assets.count, (index + 1) * chunk))
            lock.withLock { days.merge(part, uniquingKeysWith: +) }
        }
        return days
    }

    /// A capture time's day as `dayCounts` counts it, or nil for a time that isn't one.
    static func day(of date: Date) -> Int? {
        let seconds = date.timeIntervalSince1970
        return seconds.isFinite ? Int((seconds / 86_400).rounded(.down)) : nil
    }

    /// Reuse the cached hierarchy instead of scanning every photo for each pinned date.
    static func count(for dateKey: String, in groups: [CaptureDateBucket]) -> Int {
        guard let range = interval(for: dateKey) else { return 0 }
        let depth = dateKey.split(separator: "-").count - 1
        let parts = key(range.start, depth: depth).split(separator: "-")
        var level = groups
        for index in parts.indices {
            let id = parts.prefix(index + 1).joined(separator: "-")
            guard let bucket = level.first(where: { $0.id == id }) else { return 0 }
            if index == depth { return bucket.count }
            level = bucket.children
        }
        return 0
    }

    /// A tree level's label: "2026年" / "2026", "3月" / "Mar", "25日" / "25".
    private static func label(_ value: Int, depth: Int) -> String {
        switch depth {
        // as text: a number argument would be formatted with grouping ("2,026")
        case 0: return L("\(String(value))年")
        case 1: return monthNames.indices.contains(value - 1) ? monthNames[value - 1] : "\(value)"
        default: return L("\(String(value))日")
        }
    }

    private static let monthNames = DateFormatter().shortStandaloneMonthSymbols ?? []

    private static func buckets(_ days: [(key: String, count: Int)], depth: Int) -> [CaptureDateBucket] {
        let grouped = Dictionary(grouping: days) { $0.key.split(separator: "-").prefix(depth + 1).joined(separator: "-") }
        return grouped.keys.sorted(by: >).map { key in
            let members = grouped[key] ?? []
            let suffix = Int(key.split(separator: "-").last ?? "") ?? 0
            return CaptureDateBucket(id: key, label: label(suffix, depth: depth),
                                     count: members.reduce(0) { $0 + $1.count },
                                     children: depth < 2 ? buckets(members, depth: depth + 1) : [])
        }
    }
}
