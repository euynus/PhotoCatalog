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
        // A rename preview renders every selected photo per keystroke, so a value is only made
        // when the name still has its token (the rating's localized lookup costs the most).
        // Tokens fill in this order, so a value holding a later token's text is filled too.
        var name = template
        func fill(_ token: String, _ value: () -> String) {
            guard name.range(of: token) != nil else { return }
            name = name.replacingOccurrences(of: token, with: value())
        }
        fill("{original}") { original }
        fill("{seq}") { String(format: "%04d", sequence) }
        fill("{date}") { format(date, "yyyyMMdd") }
        fill("{time}") { format(date, "HHmmss") }
        fill("{camera}") { camera }
        fill("{title}") { title }
        fill("{rating}") { L("\(rating)星") }
        let cleaned = sanitized(name)
        return cleaned.isEmpty ? original : cleaned
    }

    private static let illegalCharacters = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines)

    /// `name` as one file or folder name: path separators and the other characters a name
    /// can't hold everywhere (`:` `?` `*` `"` …, line breaks) become "-", ends trimmed.
    static func sanitized(_ name: String) -> String {
        let replaced = name.rangeOfCharacter(from: illegalCharacters) == nil
            ? name : name.components(separatedBy: illegalCharacters).joined(separator: "-")
        return replaced.trimmingCharacters(in: .whitespaces)
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
