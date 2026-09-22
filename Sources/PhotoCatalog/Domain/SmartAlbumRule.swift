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
}

enum SmartFields {
    /// Ordered to match the prototype's SA_FIELDS object.
    static let all: [SmartField] = [
        SmartField(key: "rating", label: "评分", ops: [">=", "<=", "="], input: .rating),
        SmartField(key: "flag", label: "旗标", ops: ["="], input: .flag),
        SmartField(key: "colorLabel", label: "颜色标签", ops: ["="], input: .color),
        SmartField(key: "keywords", label: "关键词", ops: ["包含", "不包含"], input: .text),
        SmartField(key: "camera", label: "相机", ops: ["包含", "="], input: .text),
        SmartField(key: "lens", label: "镜头", ops: ["包含", "="], input: .text),
        SmartField(key: "type", label: "文件类型", ops: ["="], input: .type),
        SmartField(key: "captureYear", label: "拍摄年份", ops: ["=", ">=", "<="], input: .year),
        SmartField(key: "captureDate", label: "拍摄日期", ops: ["=", ">=", "<="], input: .date),
        SmartField(key: "datePreset", label: "日期范围", ops: ["="], input: .datePreset),
        SmartField(key: "gps", label: "GPS", ops: ["="], input: .gps),
        SmartField(key: "status", label: "文件状态", ops: ["="], input: .status),
        SmartField(key: "search", label: "全文搜索", ops: ["包含"], input: .text),
    ]
    static func field(_ key: String) -> SmartField { all.first { $0.key == key } ?? all[0] }
}

enum SmartMatcher {
    static func matchesDatePreset(_ assetDate: Date, _ preset: String, now: Date = .now) -> Bool {
        if preset == "any" { return true }
        guard let interval = CaptureDates.presetInterval(preset, now: now) else { return false }
        return CaptureDates.contains(assetDate, in: interval)
    }

    static func eval(_ a: Asset, _ c: SmartCondition) -> Bool {
        switch c.field {
        case "rating":
            let v = Int(c.value) ?? 0
            if c.op == ">=" { return a.rating >= v }
            if c.op == "<=" { return a.rating <= v }
            return a.rating == v
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
            return c.value == "RAW" ? a.isRaw : a.type == c.value
        case "captureYear":
            let y = Calendar.captureWallClock.component(.year, from: a.date)
            let v = Int(c.value) ?? 0
            if c.op == ">=" { return y >= v }
            if c.op == "<=" { return y <= v }
            return y == v
        case "datePreset":
            return matchesDatePreset(a.date, c.value)
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
            // keep this haystack in sync with AppState.computeList (which includes project/client),
            // so a smart album saved from a search matches the live filtered list
            let haystack = ([a.filename, a.camera, a.lens, a.title, a.caption, a.location,
                             a.project, a.client] + a.keywords).joined(separator: " ")
            return haystack.localizedStandardContains(c.value)
        default:
            return true
        }
    }

    static func matches(_ asset: Asset, _ rule: SmartRule) -> Bool {
        if rule.match == "all" {
            return rule.conditions.allSatisfy { eval(asset, $0) }
        }
        return rule.conditions.contains { eval(asset, $0) }
    }

    static func count(_ assets: [Asset], _ rule: SmartRule) -> Int {
        var total = 0
        for asset in assets where matches(asset, rule) {
            total += 1
        }
        return total
    }

    static func match(_ assets: [Asset], _ rule: SmartRule) -> [Asset] {
        assets.filter { matches($0, rule) }
    }
}
