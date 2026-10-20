// ============================================================
//  LocalizedSearch — localizedStandardContains for many texts in a row
// ============================================================
import Foundation

/// `localizedStandardContains` for many texts in a row: the same search (case- and diacritic-
/// insensitive, in the current locale) through the same Objective-C method, with the locale
/// bridged to `NSLocale` once. Swift bridges the `Locale` on every call, under a lock all of
/// Foundation shares, so threads searching side by side waited for each other: a smart album's
/// full-text search of 500k photos took a second on any number of cores, and one thread
/// searched at half this speed. Make one per pass over the photos (each thread its own).
struct LocalizedSearch {
    private typealias RangeOfString = @convention(c) (NSString, Selector, NSString, UInt, NSRange, NSLocale?) -> NSRange
    private static let rangeOfString = #selector(NSString.range(of:options:range:locale:))
    private static let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    private let locale = Locale.current as NSLocale

    /// Whether `text` contains `needle`, as `text.localizedStandardContains(needle)` answers: it
    /// sends `rangeOfString:options:range:locale:` with these options, the whole text and the
    /// current locale.
    func text(_ text: String, contains needle: String) -> Bool {
        let haystack = text as NSString
        let method = unsafeBitCast(haystack.method(for: Self.rangeOfString), to: RangeOfString.self)
        let found = method(haystack, Self.rangeOfString, needle as NSString, Self.options.rawValue,
                           NSRange(location: 0, length: haystack.length), locale)
        return found.location != NSNotFound
    }
}
