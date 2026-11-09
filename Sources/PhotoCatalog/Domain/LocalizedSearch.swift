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
    /// A photo's searched text as UTF-8, written again for each photo into the same storage.
    private var bytes: [UInt8] = []

    init() {
        bytes.reserveCapacity(256)
    }

    /// Whether `text` contains `needle`, as `text.localizedStandardContains(needle)` answers: it
    /// sends `rangeOfString:options:range:locale:` with these options, the whole text and the
    /// current locale.
    func text(_ text: String, contains needle: String) -> Bool {
        search(text as NSString, for: needle)
    }

    /// Whether the text a search looks through (`Asset.searchHaystack`) contains `needle`, as
    /// `text(_:contains:)` answers for it. The fields are written as UTF-8 into storage kept for
    /// the pass and searched as one Core Foundation string: joining them as a Swift string and
    /// bridging that made a new string and its bridged copy for every photo.
    mutating func haystack(of asset: Asset, contains needle: String) -> Bool {
        // joined as searchHaystack joins them: one space between items, empty ones included
        func add(_ text: String) {
            bytes.append(0x20)
            bytes.append(contentsOf: text.utf8)
        }
        bytes.removeAll(keepingCapacity: true)
        bytes.append(contentsOf: asset.filename.utf8)
        add(asset.camera)
        add(asset.lens)
        add(asset.title)
        add(asset.caption)
        add(asset.location)
        add(asset.project)
        add(asset.client)
        for keyword in asset.keywords { add(keyword) }
        // Core Foundation drops a byte order mark that starts the bytes, which would search other text
        let marked = bytes.count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF
        guard !marked, let haystack = bytes.withUnsafeBufferPointer({ buffer in
            CFStringCreateWithBytes(nil, buffer.baseAddress, buffer.count, CFStringBuiltInEncodings.UTF8.rawValue, false)
        }) else {
            return text(asset.searchHaystack, contains: needle)
        }
        return search(haystack as NSString, for: needle)
    }

    private func search(_ haystack: NSString, for needle: String) -> Bool {
        let method = unsafeBitCast(haystack.method(for: Self.rangeOfString), to: RangeOfString.self)
        let found = method(haystack, Self.rangeOfString, needle as NSString, Self.options.rawValue,
                           NSRange(location: 0, length: haystack.length), locale)
        return found.location != NSNotFound
    }
}
