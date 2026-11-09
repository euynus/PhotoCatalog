import XCTest
@testable import PhotoCatalog

/// `PathString` reads a path's bytes before its characters. Whatever the path (ASCII or not,
/// combining marks or Prepend scalars beside a slash, runs of slashes, dots, the firmlinks), it
/// gives what the character-level helpers it replaced give: they're kept below as the oracle.
final class PathStringFastPathTests: XCTestCase {
    /// The helpers as they were, character by character.
    private enum Oracle {
        static func directory(of path: String) -> String {
            let trimmed = trimmingTrailingSlashes(path)
            guard let slash = trimmed.lastIndex(of: "/") else { return "." }
            return slash == trimmed.startIndex ? "/" : String(trimmed[..<slash])
        }

        static func lastComponent(_ path: String) -> String {
            let trimmed = trimmingTrailingSlashes(path)
            guard let slash = trimmed.lastIndex(of: "/") else { return trimmed }
            return String(trimmed[trimmed.index(after: slash)...])
        }

        static func standardized(_ path: String) -> String {
            let clean = !path.contains("//") && !path.contains("/./") && !path.contains("/../")
                && !path.hasSuffix("/.") && !path.hasSuffix("/..")
            guard clean else {
                return trimmingTrailingSlashes(URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL.path)
            }
            for firmlink in ["/private/var", "/private/tmp", "/private/etc"]
            where path == firmlink || path.hasPrefix(firmlink + "/") {
                return trimmingTrailingSlashes(String(path.dropFirst("/private".count)))
            }
            return trimmingTrailingSlashes(path)
        }

        static func trimmingTrailingSlashes(_ path: String) -> String {
            var result = Substring(path)
            while result.count > 1, result.hasSuffix("/") { result = result.dropLast() }
            return String(result)
        }

        /// FolderTreeService's.
        static func normalizedPath(_ path: String) -> String {
            guard path.count > 1 else { return path }
            return path.hasSuffix("/") ? String(path.dropLast()) : path
        }

        /// EditedVersions'.
        static func lastSlash(in path: String) -> Int? {
            let slash = path.utf8.withContiguousStorageIfAvailable { bytes -> Int? in
                guard let last = bytes.last, last != UInt8(ascii: "/"),
                      let slash = bytes.lastIndex(of: UInt8(ascii: "/")),
                      bytes[slash + 1] < 0x80, slash == 0 || bytes[slash - 1] < 0x80 else { return nil }
                return slash
            }
            return slash ?? nil
        }
    }

    /// The same text, unicode scalar for scalar: `==` holds NFC and NFD alike.
    private func assertSame(_ result: String, _ expected: String, _ message: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Array(result.unicodeScalars), Array(expected.unicodeScalars), message, file: file, line: line)
    }

    private func check(_ path: String, file: StaticString = #filePath, line: UInt = #line) {
        let shown = path.unicodeScalars.map { $0.isASCII ? String($0) : "\\u{\(String($0.value, radix: 16))}" }.joined()
        assertSame(PathString.directory(of: path), Oracle.directory(of: path), "directory of \(shown)", file: file, line: line)
        assertSame(PathString.lastComponent(path), Oracle.lastComponent(path), "last component of \(shown)",
                   file: file, line: line)
        assertSame(PathString.standardized(path), Oracle.standardized(path), "standardized \(shown)", file: file, line: line)
        assertSame(FolderTreeService.normalizedPath(path), Oracle.normalizedPath(path), "normalized \(shown)",
                   file: file, line: line)
        let slash = PathString.lastSlash(in: path)
        XCTAssertEqual(slash, Oracle.lastSlash(in: path), "last slash of \(shown)", file: file, line: line)
        // where it finds one, it's the slash the characters split at
        if let slash, let character = path.lastIndex(of: "/") {
            XCTAssertEqual(path.utf8.distance(from: path.utf8.startIndex, to: character), slash,
                           "last slash of \(shown)", file: file, line: line)
        } else if slash != nil {
            XCTFail("a slash among the bytes of \(shown) but not among its characters", file: file, line: line)
        }
    }

    func testChosenPaths() {
        let paths = [
            "", "/", "//", "///", "a", ".", "..", "/.", "/..", "./", "../", "a/", "/a", "/a/", "/a//", "/a///",
            "/a/b", "/a/b/", "/a/b.jpg", "/c.jpg", "a/b", "/a/.", "/a/..", "/a/./b", "/a/../b", "/a/.../b", "/a/.b",
            "/a/..b", "/a//b", "a//b", "/a/b/.", "/a/b/..", "/.hidden", "/a/.hidden.jpg",
            // beyond ASCII, and characters made of several scalars beside a slash
            "/Photos/日本/照片.jpg", "/a/caf\u{E9}/b.jpg", "/a/cafe\u{301}/b.jpg", "/a/b\u{301}/c", "/a/\u{301}c",
            "/a/\u{301}", "/a\u{301}/", "/\u{301}", "\u{301}/a", "/a\u{600}/c", "/a/\u{600}/c", "\u{600}/", "/\u{600}/",
            "/a\u{600}", "/a/b\u{200D}/c", "/a/\u{200D}c", "/👨‍👩‍👧/x", "/x/🇯🇵", "/a\r/\nb", "/a\r\n/b",
            "/a/\u{1100}\u{1161}/b", "/\u{0915}\u{094D}/\u{0937}", "/a/b\u{FE0F}/c",
            "/a/\u{301}/", "/a/.\u{301}", "/a/..\u{301}", "/a/\u{301}./b", "/a/.\u{301}/b", "/\u{301}/.", "/a//\u{301}",
            // the firmlinks, and paths that only look like them
            "/private/var", "/private/var/", "/private/var/x", "/private/var//x", "/private/tmp", "/private/tmp/a/b",
            "/private/etc", "/private/etc/", "/private/varx", "/private/var\u{301}/x", "/private/", "/private",
            "/privatevar/x", "/private/var/./x", "/private/tmp/../x", "/var/x", "/private/Var/x",
        ]
        for path in paths { check(path) }
    }

    func testRandomPaths() {
        var state: UInt64 = 0x5EED
        func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        let pieces = ["/", "/", "/", "/", ".", "..", "a", "Z", "0", " ", "-", "private", "var", "tmp", "IMG_1.JPG",
                      "caf\u{E9}", "e\u{301}", "\u{301}", "\u{308}", "\u{600}", "\u{110BD}", "\u{200D}", "\u{FE0F}",
                      "日本", "照片", "\u{1100}", "\u{1161}", "\u{AC00}", "👨‍👩‍👧", "\u{1F1EF}", "\u{1F1F5}", "\r", "\n",
                      "\u{0915}\u{094D}", "\u{212B}", "Å"]
        let starts = ["", "/", "/", "/private/", "/private/var/", "/private/tmp", "./"]
        for _ in 0..<4_000 {
            var path = starts[Int(next() % UInt64(starts.count))]
            for _ in 0 ..< next() % 9 { path += pieces[Int(next() % UInt64(pieces.count))] }
            check(path)
        }
    }

    /// A bridged NSString keeps no UTF-8 of its own: the helpers fall back to its characters.
    func testBridgedStrings() {
        for path in ["/a/b.jpg", "/a/cafe\u{301}/b.jpg", "/a\u{600}/c", "/private/var/x", "/a/./b", "/a/"] {
            check(NSString(string: path) as String)
        }
    }
}
