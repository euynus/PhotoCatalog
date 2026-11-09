// ============================================================
//  Import option lists — the choices Settings and the Import sheet both offer
// ============================================================
import Foundation

extension ManagedArchiveRule {
    var title: String {
        switch self {
        case .date: L("按日期")
        case .camera: L("按相机")
        }
    }
}

extension ImportDuplicateStrategy {
    var title: String {
        switch self {
        case .groupExact: L("分组")
        case .skipExact: L("跳过")
        case .keep: L("保留")
        }
    }
}

/// One ordered list per import setting, so the two sheets offer the same choices in the same
/// order. Computed, like the literals they replace, so labels follow the language setting.
enum ImportOptionLists {
    static var modes: [SegOption] {
        [ImportMode.referenced, .managed].map { SegOption(value: $0.rawValue, label: $0.displayName) }
    }

    static var archiveRules: [SegOption] {
        [ManagedArchiveRule.date, .camera].map { SegOption(value: $0.rawValue, label: $0.title) }
    }

    /// Grouping, the default, comes first: not allCases' order (keep, skipExact, groupExact).
    static var duplicateStrategies: [SegOption] {
        [ImportDuplicateStrategy.groupExact, .skipExact, .keep].map { SegOption(value: $0.rawValue, label: $0.title) }
    }
}
