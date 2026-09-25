// ============================================================
//  Localization — UI text in the user's language
// ============================================================
import Foundation

/// UI text in the user's language. The Chinese source string is the key; translations live in
/// `Resources/Localization/<language>.lproj/Localizable.strings`, which the build script copies
/// into the app. SwiftUI literals (`Text("…")`, `Button("…")`) localize by themselves; this is
/// for text built as a `String`: toasts, alerts, menus and labels handed to other views.
/// Interpolations become format arguments: `L("已导入 \(count) 张照片")` looks up
/// "已导入 %lld 张照片". The same Chinese text can mean two things in English (色调 is both
/// the Tone panel and the Tint slider); the rarer meaning passes `table: "Context"`.
func L(_ key: String.LocalizationValue, table: String? = nil) -> String {
    String(localized: key, table: table)
}
