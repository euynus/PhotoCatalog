// ============================================================
//  Smart album rule model + matcher
//  Ported from app/sheets.jsx (SA_FIELDS / evalCond / matchAssets).
// ============================================================
import Foundation

struct SmartCondition: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    var field: String
    var op: String
    var value: String

    init(id: UUID = UUID(), field: String, op: String, value: String) {
        self.id = id
        self.field = field
        self.op = op
        self.value = value
    }
}

struct SmartRule: Equatable, Codable, Sendable {
    var match: String = "all"   // all (AND) / any (OR)
    var conditions: [SmartCondition]
}

/// Field descriptor for the rule builder UI.
struct SmartField {
    enum Input { case rating, flag, color, text, type, year, status, datePreset, date, gps }
    let key: String
    let label: String
    let ops: [String]
    let input: Input

    /// An operator as the rule builder shows it; rules store the operator itself.
    /// An operator in words: "at least" for a rating, "on or after" for a date.
    static func opLabel(_ op: String, field: String) -> String {
        let dated = field == "captureYear" || field == "captureDate"
        switch op {
        case "包含": return L("包含")
        case "不包含": return L("不包含", table: "Context")
        case ">=": return dated ? L("不早于") : L("至少")
        case "<=": return dated ? L("不晚于") : L("至多")
        case "=": return field == "rating" ? L("等于") : L("是")
        default: return op
        }
    }
}

enum SmartFields {
    /// Ordered to match the prototype's SA_FIELDS object.
    static let all: [SmartField] = [
        SmartField(key: "rating", label: L("评分"), ops: [">=", "<=", "="], input: .rating),
        SmartField(key: "flag", label: L("旗标"), ops: ["="], input: .flag),
        SmartField(key: "colorLabel", label: L("颜色标签"), ops: ["="], input: .color),
        SmartField(key: "keywords", label: L("关键词"), ops: ["包含", "不包含"], input: .text),
        SmartField(key: "camera", label: L("相机"), ops: ["包含", "="], input: .text),
        SmartField(key: "lens", label: L("镜头"), ops: ["包含", "="], input: .text),
        SmartField(key: "type", label: L("文件类型"), ops: ["="], input: .type),
        SmartField(key: "captureYear", label: L("拍摄年份"), ops: ["=", ">=", "<="], input: .year),
        SmartField(key: "captureDate", label: L("拍摄日期"), ops: ["=", ">=", "<="], input: .date),
        SmartField(key: "datePreset", label: L("日期范围"), ops: ["="], input: .datePreset),
        SmartField(key: "gps", label: "GPS", ops: ["="], input: .gps),
        SmartField(key: "status", label: L("文件状态"), ops: ["="], input: .status),
        SmartField(key: "search", label: L("全文搜索"), ops: ["包含"], input: .text),
    ]
    static func field(_ key: String) -> SmartField { all.first { $0.key == key } ?? all[0] }
}

enum SmartMatcher {
    static func matchesDatePreset(_ assetDate: Date, _ preset: String, now: Date = .now,
                                  timeZone: TimeZone = .current) -> Bool {
        if preset == "any" { return true }
        guard let interval = CaptureDates.presetInterval(preset, now: now, timeZone: timeZone) else { return false }
        return CaptureDates.contains(assetDate, in: interval)
    }

    /// A condition compiled once into what it tests: the number of a rating, the flag, label or
    /// status it names, the interval of a year, capture date or date range. Matching never looks
    /// at the field's name again. Per photo, the string switch, a calendar call for a year and a
    /// locale-aware search of every keyword made recounting a 500k catalog take seconds.
    struct Condition: Sendable {
        let condition: SmartCondition
        private let test: Test
        /// Where a `Memo` keeps this condition's answers by value, for a locale-aware text test.
        fileprivate var slot: Int?

        private enum Comparison: Sendable {
            case atLeast, atMost, equal

            init(_ op: String) {
                self = op == ">=" ? .atLeast : op == "<=" ? .atMost : .equal
            }

            func holds(_ value: Int, _ number: Int) -> Bool {
                switch self {
                case .atLeast: value >= number
                case .atMost: value <= number
                case .equal: value == number
                }
            }
        }

        private enum Test: Sendable {
            case always, never
            case rating(Comparison, Int)
            case flag(Flag)
            case color(ColorLabel?)
            case keywords(String, has: Bool)
            case camera(String), cameraContains(String)
            case lens(String), lensContains(String)
            case type(String)
            case year(Comparison, Int, YearBounds?)
            case within(DateInterval)
            case from(Date), before(Date)
            case gps(Bool)
            case status(AssetStatus)
            case search(String)
        }

        /// A capture year as an interval of capture times. Comparing a time with it is comparing
        /// the calendar's year only for times from AD 1 to 9999: before that the calendar counts
        /// BC years down, so a time outside them (or not a number) asks the calendar, as before.
        private struct YearBounds: Sendable {
            let start: Date, end: Date

            static let comparable: DateInterval? = {
                guard let first = start(of: 1), let last = start(of: 10_000) else { return nil }
                return DateInterval(start: first, end: last)
            }()

            init?(year: Int) {
                guard (1...9998).contains(year), let start = Self.start(of: year),
                      let end = Self.start(of: year + 1) else { return nil }
                self.start = start
                self.end = end
            }

            private static func start(of year: Int) -> Date? {
                Calendar.captureWallClock.date(from: DateComponents(era: 1, year: year, month: 1, day: 1))
            }
        }

        init(_ c: SmartCondition, now: Date = .now) {
            condition = c
            let number = Int(c.value) ?? 0
            switch c.field {
            case "rating":
                test = .rating(Comparison(c.op), number)
            case "flag":
                test = Flag(rawValue: c.value).map { .flag($0) } ?? .never
            case "colorLabel":
                // "" is no label; a value that names none matches nothing
                test = c.value.isEmpty ? .color(nil) : ColorLabel(rawValue: c.value).map { .color($0) } ?? .never
            case "keywords":
                test = .keywords(c.value, has: c.op == "包含")
            case "camera":
                test = c.op == "=" ? .camera(c.value) : .cameraContains(c.value)
            case "lens":
                test = c.op == "=" ? .lens(c.value) : .lensContains(c.value)
            case "type":
                test = .type(c.value)
            case "captureYear":
                test = .year(Comparison(c.op), number, YearBounds(year: number))
            case "datePreset":
                if c.value == "any" {
                    test = .always
                } else {
                    test = CaptureDates.presetInterval(c.value, now: now).map { .within($0) } ?? .never
                }
            case "captureDate":
                if let interval = CaptureDates.interval(for: c.value) {
                    test = c.op == ">=" ? .from(interval.start) : c.op == "<=" ? .before(interval.end) : .within(interval)
                } else {
                    test = .never
                }
            case "gps":
                test = .gps(c.value == "yes")
            case "status":
                test = AssetStatus(rawValue: c.value).map { .status($0) } ?? .never
            case "search":
                test = .search(c.value)
            default:
                test = .always
            }
            switch test {
            case .keywords, .cameraContains, .lensContains: slot = 0
            default: slot = nil
            }
        }

        func matches(_ a: Asset) -> Bool {
            var memo = Memo()
            return matches(a, memo: &memo)
        }

        func matches(_ a: Asset, memo: inout Memo) -> Bool {
            switch test {
            case .always: return true
            case .never: return false
            case .rating(let comparison, let number): return comparison.holds(a.rating, number)
            case .flag(let flag): return a.flag == flag
            case .color(let label): return a.colorLabel == label
            case .keywords(let needle, let has):
                return a.keywords.contains { memo.text($0, contains: needle, slot: slot) } == has
            case .camera(let name): return a.camera == name
            case .cameraContains(let needle): return memo.text(a.camera, contains: needle, slot: slot)
            case .lens(let name): return a.lens == name
            case .lensContains(let needle): return memo.text(a.lens, contains: needle, slot: slot)
            case .type(let type): return a.matchesType(type)
            case .year(let comparison, let number, let bounds):
                let date = a.date
                guard let bounds, let comparable = YearBounds.comparable,
                      date >= comparable.start, date < comparable.end else {
                    return comparison.holds(Calendar.captureWallClock.component(.year, from: date), number)
                }
                switch comparison {
                case .atLeast: return date >= bounds.start
                case .atMost: return date < bounds.end
                case .equal: return date >= bounds.start && date < bounds.end
                }
            case .within(let interval): return CaptureDates.contains(a.date, in: interval)
            case .from(let start): return a.date >= start
            case .before(let end): return a.date < end
            case .gps(let has): return a.hasGPS == has
            case .status(let status): return a.status == status
            // the joined text, as the search box searches it: a match can run across two fields
            case .search(let needle): return memo.search(a.searchHaystack, for: needle)
            }
        }
    }

    /// What one pass over many photos found for a rule's locale-aware text tests, by value:
    /// keywords, cameras and lenses repeat across thousands of photos, and the same text always
    /// gives the same answer. Each pass, and each thread of one, keeps its own.
    struct Memo {
        private var found: [[String: Bool]] = []
        /// Full-text search (no answer to keep: each photo's text is its own), with the locale it
        /// searches in bridged once for the pass.
        private var searching: LocalizedSearch?

        init() {}

        init(for rule: Prepared) {
            found = Array(repeating: [:], count: rule.textTests)
        }

        fileprivate mutating func text(_ text: String, contains needle: String, slot: Int?) -> Bool {
            guard let slot, slot < found.count else { return text.localizedStandardContains(needle) }
            if let known = found[slot][text] { return known }
            let result = text.localizedStandardContains(needle)
            found[slot][text] = result
            return result
        }

        fileprivate mutating func search(_ text: String, for needle: String) -> Bool {
            let search = searching ?? LocalizedSearch()
            searching = search
            return search.text(text, contains: needle)
        }
    }

    /// A rule with its conditions compiled once, to match many photos.
    struct Prepared: Sendable {
        private let all: Bool
        private let conditions: [Condition]
        /// How many of its conditions are text tests a `Memo` remembers.
        fileprivate let textTests: Int

        init(_ rule: SmartRule, now: Date = .now) {
            all = rule.match == "all"
            var textTests = 0
            conditions = rule.conditions.map { condition in
                var compiled = Condition(condition, now: now)
                if compiled.slot != nil {
                    compiled.slot = textTests
                    textTests += 1
                }
                return compiled
            }
            self.textTests = textTests
        }

        func matches(_ asset: Asset) -> Bool {
            var memo = Memo()
            return matches(asset, memo: &memo)
        }

        /// The same answer, with text tests' answers kept in `memo` (made for this rule).
        func matches(_ asset: Asset, memo: inout Memo) -> Bool {
            all ? conditions.allSatisfy { $0.matches(asset, memo: &memo) }
                : conditions.contains { $0.matches(asset, memo: &memo) }
        }
    }

    static func eval(_ a: Asset, _ c: SmartCondition) -> Bool {
        Condition(c).matches(a)
    }

    static func matches(_ asset: Asset, _ rule: SmartRule) -> Bool {
        Prepared(rule).matches(asset)
    }

    static func count(_ assets: [Asset], _ rule: SmartRule) -> Int {
        let prepared = Prepared(rule)
        var memo = Memo(for: prepared)
        var total = 0
        for asset in assets where prepared.matches(asset, memo: &memo) {
            total += 1
        }
        return total
    }

    static func match(_ assets: [Asset], _ rule: SmartRule) -> [Asset] {
        let prepared = Prepared(rule)
        var memo = Memo(for: prepared)
        return assets.filter { prepared.matches($0, memo: &memo) }
    }

    /// How many photos a rule matches, and the first of them.
    struct Preview: Sendable {
        let count: Int
        let first: [Asset]
    }

    /// What the rule builder shows: the photos as the library shows them (not trashed, a RAW's
    /// JPEG folded into it) that the rule matches, so it counts what the sidebar will. Counted in
    /// one pass that keeps only the first `limit`. Nil when the task running it is cancelled.
    static func preview(_ assets: [Asset], _ rule: SmartRule, pairing: AssetPairing, limit: Int) -> Preview? {
        let prepared = Prepared(rule)
        var memo = Memo(for: prepared)
        var count = 0
        var first: [Asset] = []
        for (offset, asset) in assets.enumerated() {
            if offset % 4096 == 0, Task.isCancelled { return nil }
            guard pairing.shows(asset), prepared.matches(asset, memo: &memo) else { continue }
            count += 1
            if first.count < limit { first.append(asset) }
        }
        return Preview(count: count, first: first)
    }
}
