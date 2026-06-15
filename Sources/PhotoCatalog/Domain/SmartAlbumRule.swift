// ============================================================
//  Smart album rule model + matcher
//  Ported from app/sheets.jsx (SA_FIELDS / evalCond / matchAssets).
// ============================================================
import Foundation

struct SmartCondition: Identifiable, Equatable {
    let id = UUID()
    var field: String
    var op: String
    var value: String
}

struct SmartRule: Equatable {
    var match: String = "all"   // all (AND) / any (OR)
    var conditions: [SmartCondition]
}

/// Field descriptor for the rule builder UI.
struct SmartField {
    enum Input { case rating, flag, color, text, type, year, status }
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
        SmartField(key: "type", label: "文件类型", ops: ["="], input: .type),
        SmartField(key: "captureYear", label: "拍摄年份", ops: ["=", ">=", "<="], input: .year),
        SmartField(key: "status", label: "文件状态", ops: ["="], input: .status),
    ]
    static func field(_ key: String) -> SmartField { all.first { $0.key == key } ?? all[0] }
}

enum SmartMatcher {
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
            let has = a.keywords.contains { $0.contains(c.value) }
            return c.op == "包含" ? has : !has
        case "camera":
            if c.op == "=" { return a.camera == c.value }
            return a.camera.lowercased().contains(c.value.lowercased())
        case "type":
            return c.value == "RAW" ? a.isRaw : a.type == c.value
        case "captureYear":
            let y = Calendar.current.component(.year, from: a.date)
            let v = Int(c.value) ?? 0
            if c.op == ">=" { return y >= v }
            if c.op == "<=" { return y <= v }
            return y == v
        case "status":
            return a.status.rawValue == c.value
        default:
            return true
        }
    }

    static func match(_ assets: [Asset], _ rule: SmartRule) -> [Asset] {
        assets.filter { a in
            let results = rule.conditions.map { eval(a, $0) }
            return rule.match == "all" ? results.allSatisfy { $0 } : results.contains { $0 }
        }
    }
}
