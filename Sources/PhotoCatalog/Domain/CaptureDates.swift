import Foundation

struct CaptureDateBucket: Identifiable, Sendable {
    let id: String
    let label: String
    let count: Int
    let children: [CaptureDateBucket]
}

enum CaptureDates {
    static let presets = [
        ("today", "今天"), ("yesterday", "昨天"),
        ("last7Days", "最近 7 天"), ("last30Days", "最近 30 天"),
        ("thisMonth", "本月"), ("thisYear", "今年"),
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
        buckets(assets.filter { !$0.deleted && $0.date.timeIntervalSince1970.isFinite }, depth: 0)
    }

    private static func buckets(_ assets: [Asset], depth: Int) -> [CaptureDateBucket] {
        let grouped = Dictionary(grouping: assets) { key($0.date, depth: depth) }
        return grouped.keys.sorted(by: >).map { key in
            let members = grouped[key] ?? []
            let suffix = Int(key.split(separator: "-").last ?? "") ?? 0
            return CaptureDateBucket(id: key, label: "\(suffix)\(["年", "月", "日"][depth])",
                                     count: members.count,
                                     children: depth < 2 ? buckets(members, depth: depth + 1) : [])
        }
    }
}
