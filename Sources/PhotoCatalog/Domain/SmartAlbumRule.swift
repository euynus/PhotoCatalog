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
    static func matchesDatePreset(_ assetDate: Date, _ preset: String, now: Date = .now) -> Bool {
        if preset == "any" { return true }
        guard let interval = CaptureDates.presetInterval(preset, now: now) else { return false }
        return CaptureDates.contains(assetDate, in: interval)
    }

    /// A condition with what it compares against worked out once: the number of a rating or
    /// year, the interval of a capture date or date range. Worked out per photo, a date condition
    /// cost about 2 µs a photo, over a second for each count of a 500k catalog.
    struct Condition {
        let condition: SmartCondition
        private let number: Int
        private let interval: DateInterval?

        init(_ c: SmartCondition, now: Date = .now) {
            condition = c
            number = Int(c.value) ?? 0
            switch c.field {
            case "captureDate": interval = CaptureDates.interval(for: c.value)
            case "datePreset": interval = c.value == "any" ? nil : CaptureDates.presetInterval(c.value, now: now)
            default: interval = nil
            }
        }

        func matches(_ a: Asset) -> Bool {
            let c = condition
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
                switch c.value {
                case "RAW": return a.isRaw
                case "VIDEO": return a.isVideo
                default: return a.type == c.value
                }
            case "captureYear":
                let y = Calendar.captureWallClock.component(.year, from: a.date)
                if c.op == ">=" { return y >= number }
                if c.op == "<=" { return y <= number }
                return y == number
            case "datePreset":
                if c.value == "any" { return true }
                guard let interval else { return false }
                return CaptureDates.contains(a.date, in: interval)
            case "captureDate":
                guard let interval else { return false }
                if c.op == ">=" { return a.date >= interval.start }
                if c.op == "<=" { return a.date < interval.end }
                return CaptureDates.contains(a.date, in: interval)
            case "gps":
                return c.value == "yes" ? a.hasGPS : !a.hasGPS
            case "status":
                return a.status.rawValue == c.value
            case "search":
                // keep this haystack in sync with AppState.computeList (which includes project/client),
                // so a smart album saved from a search matches the live filtered list
                let haystack = ([a.filename, a.camera, a.lens, a.title, a.caption, a.location,
                                 a.project, a.client] + a.keywords).joined(separator: " ")
                return haystack.localizedStandardContains(c.value)
            default:
                return true
            }
        }
    }

    /// A rule with its conditions worked out once, to match many photos.
    struct Prepared {
        private let all: Bool
        private let conditions: [Condition]

        init(_ rule: SmartRule, now: Date = .now) {
            all = rule.match == "all"
            conditions = rule.conditions.map { Condition($0, now: now) }
        }

        func matches(_ asset: Asset) -> Bool {
            all ? conditions.allSatisfy { $0.matches(asset) } : conditions.contains { $0.matches(asset) }
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
        var total = 0
        for asset in assets where prepared.matches(asset) {
            total += 1
        }
        return total
    }

    static func match(_ assets: [Asset], _ rule: SmartRule) -> [Asset] {
        let prepared = Prepared(rule)
        return assets.filter(prepared.matches)
    }
}
