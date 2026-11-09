// ============================================================
//  Color labels — the six a photo can carry
// ============================================================
import Foundation

/// Color-label palette — port of `COLOR_LABELS` in data.jsx. Their colors are the theme's
/// (`hex`, in Theme.swift).
enum ColorLabel: String, CaseIterable, Identifiable, Hashable, Sendable {
    case red, orange, yellow, green, blue, purple
    var id: String { rawValue }
    var name: String {
        switch self {
        case .red: return L("红")
        case .orange: return L("橙")
        case .yellow: return L("黄")
        case .green: return L("绿")
        case .blue: return L("蓝")
        case .purple: return L("紫")
        }
    }
}
