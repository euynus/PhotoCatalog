// ============================================================
//  File-name templates shared by export and card import
// ============================================================
import Foundation

enum FileNameTemplate {
    /// Tokens: {original} {seq} {date} {time} {camera} {title} {rating}. Dates are the capture
    /// wall clock, so names carry the time the camera recorded whatever the Mac's timezone.
    /// Path characters are replaced; an empty result falls back to the original name.
    static func render(_ template: String, original: String, sequence: Int, date: Date, camera: String = "",
                       title: String = "", rating: Int = 0) -> String {
        let name = template
            .replacingOccurrences(of: "{original}", with: original)
            .replacingOccurrences(of: "{seq}", with: String(format: "%04d", sequence))
            .replacingOccurrences(of: "{date}", with: format(date, "yyyyMMdd"))
            .replacingOccurrences(of: "{time}", with: format(date, "HHmmss"))
            .replacingOccurrences(of: "{camera}", with: camera)
            .replacingOccurrences(of: "{title}", with: title)
            .replacingOccurrences(of: "{rating}", with: L("\(rating)星"))
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines)
        let cleaned = name.components(separatedBy: illegal).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? original : cleaned
    }

    static func format(_ date: Date, _ pattern: String) -> String {
        formatter(pattern).string(from: date)
    }

    /// One formatter per pattern, made once: a rename preview formats two dates per photo on
    /// every keystroke. Formatting from several threads is safe once a formatter is set up.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var formatters: [String: DateFormatter] = [:]

    private static func formatter(_ pattern: String) -> DateFormatter {
        lock.withLock {
            if let formatter = formatters[pattern] { return formatter }
            let formatter = DateFormatter()
            formatter.dateFormat = pattern
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .captureWallClock
            formatters[pattern] = formatter
            return formatter
        }
    }
}
