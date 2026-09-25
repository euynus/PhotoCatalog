import Foundation

struct CaptureDateBucket: Identifiable, Sendable {
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

    static func interval(from start: Date?, through end: Date?) -> DateInterval? {
        guard let start, let end,
              start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite else { return nil }
        let calendar = Calendar.captureWallClock
        let first = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        guard first <= last, let nextDay = calendar.date(byAdding: .day, value: 1, to: last) else { return nil }
        return DateInterval(start: first, end: nextDay)
    }

    static func presetInterval(_ preset: String, now: Date = .now) -> DateInterval? {
        let calendar = Calendar.captureWallClock
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
        // Capture times are UTC wall clock, so a photo's day is integer arithmetic; a Calendar
        // call per photo was most of the half second this took at 500k photos.
        var days: [Int: Int] = [:]
        for asset in assets where !asset.deleted {
            let seconds = asset.date.timeIntervalSince1970
            guard seconds.isFinite else { continue }
            days[Int((seconds / 86_400).rounded(.down)), default: 0] += 1
        }
        let counts = days.map { (key: key(Date(timeIntervalSince1970: Double($0.key) * 86_400)), count: $0.value) }
        return buckets(counts, depth: 0)
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
