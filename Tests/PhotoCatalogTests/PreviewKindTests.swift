import Foundation
import XCTest
@testable import PhotoCatalog

/// previewKind(forCachePath:) searches the path's bytes, and must answer as Foundation's
/// `contains` did for every path, whatever its characters.
final class PreviewKindTests: XCTestCase {
    // The test as it was, kept as the oracle.
    private func oldKind(_ path: String, fallbackMaxPixel: Int) -> ThumbnailService.Kind {
        if path.contains("/Previews/1600/") { return .preview1600 }
        if path.contains("/Previews/2048/") { return .preview2048 }
        return ThumbnailService.previewKind(maxPixel: fallbackMaxPixel)
    }

    private func assertSameAsOld(_ path: String, file: StaticString = #filePath, line: UInt = #line) {
        for fallback in [1600, 2048] {
            XCTAssertEqual(ThumbnailService.previewKind(forCachePath: path, fallbackMaxPixel: fallback),
                           oldKind(path, fallbackMaxPixel: fallback),
                           "\(path.debugDescription), fallback \(fallback)", file: file, line: line)
        }
    }

    func testCachePaths() {
        let library = "/Users/me/Pictures/PhotoCatalog Library.photolibrary/Cache"
        XCTAssertEqual(ThumbnailService.previewKind(forCachePath: library + "/Previews/1600/ab/cd/r1.jpg",
                                                    fallbackMaxPixel: 2048), .preview1600)
        XCTAssertEqual(ThumbnailService.previewKind(forCachePath: library + "/Previews/2048/ab/cd/r1.jpg",
                                                    fallbackMaxPixel: 1600), .preview2048)
        XCTAssertEqual(ThumbnailService.previewKind(forCachePath: library + "/Thumbnails/512/ab/cd/r1.jpg",
                                                    fallbackMaxPixel: 1600), .preview1600)
        XCTAssertEqual(ThumbnailService.previewKind(forCachePath: "", fallbackMaxPixel: 2048), .preview2048)
        // both: 1600 is looked for first
        XCTAssertEqual(ThumbnailService.previewKind(forCachePath: "/a/Previews/2048/b/Previews/1600/c.jpg",
                                                    fallbackMaxPixel: 2048), .preview1600)
        XCTAssertEqual(ThumbnailService.previewKind(forCachePath: "/Volumes/写真/Bibliothèque.photolibrary/Cache"
                                                    + "/Previews/1600/ab/cd/r1.jpg", fallbackMaxPixel: 2048),
                       .preview1600)
    }

    func testPathShapesMatchTheOldSearch() {
        let paths = [
            "", "/", "/Previews/1600/", "/Previews/2048/", "Previews/1600/", "/Previews/1600", "/Previews/160",
            "/x/Previews/1600/", "/x/Previews/2048/", "/x/Previews/1600", "/x/Previews/2048", "/x/Previews/20",
            "/x/Previews/1600/ab/cd/r0123456789abcdef.jpg", "/x/Previews/2048/ab/cd/r0123456789abcdef.jpg",
            "/x/Thumbnails/256/ab/cd/r1.jpg", "/x/Thumbnails/512/ab/cd/r1.jpg",
            "/x/Previews/2048/y/Previews/1600/z.jpg", "/x/Previews/1600/y/Previews/2048/z.jpg",
            "/x/previews/1600/y.jpg", "/x/Previews/1601/y.jpg", "/x//Previews/1600//y.jpg",
            "https://images.unsplash.com/photo-1500000000000?w=1600", "/x/Previews/1600/Previews/2048/",
            // non-ASCII around the markers
            "/Volumes/写真/Bibliothèque.photolibrary/Cache/Previews/1600/ab/cd/r1.jpg",
            "/Volumes/Bibliothe\u{300}que/Cache/Previews/2048/ab/cd/é.jpg",
            "/x/Previews/1600/\u{301}ab", "/x\u{0600}/Previews/1600/ab", "/x/Previews/1600\u{301}/ab",
            "/x/Previews/1600/\u{200d}a", "/x/Previews/1600/\u{301}/Previews/2048/a",
            "/x/Previews/1600/\u{301}/Previews/1600/a", "/x\u{0600}/Previews/2048/a/Previews/1600/b",
            "/x/Pre\u{301}views/1600/a", "/x/Pre\u{ad}views/1600/a", "/x/Previews/16\u{200b}00/a",
            "/x/Previews/１６００/a", "/x/Previews／1600/a", "/x/Previews/1600/😀", "😀/Previews/2048/😀",
            "/x/Previews/1600/\r\n", "\r\n/Previews/2048/", "é/Previews/1600/é",
            // a marker near the end
            "/Volumes/写真/Previews/1600/", "/Volumes/写真/Previews/2048", "/Volumes/写真/Previews/204",
        ]
        for path in paths { assertSameAsOld(path) }
    }

    /// Paths bridged from NSString: a non-ASCII one has no UTF-8 storage of its own and takes
    /// Foundation's search.
    func testBridgedPaths() {
        let texts = ["/Volumes/写真/Cache/Previews/2048/ab/cd/r.jpg", "/Volumes/abc/Cache/Previews/1600/ab/cd/r.jpg",
                     "/Volumes/é/Cache/Thumbnails/512/ab/cd/r.jpg", "/x/Previews/1600/\u{301}ab"]
        for text in texts {
            assertSameAsOld(NSString(string: text) as String)
            assertSameAsOld(NSMutableString(string: text) as String)
            assertSameAsOld(URL(fileURLWithPath: text).path)
        }
    }

    /// Random paths built from the markers, pieces of them, and characters that join or don't.
    func testRandomPathsMatchTheOldSearch() {
        let pieces = ["/Previews/1600/", "/Previews/2048/", "/Previews/", "1600", "2048", "/", "Previews", "Cache",
                      "ab", "x", ".jpg", " ", "é", "e\u{301}", "\u{301}", "\u{300}", "\u{200d}", "\u{0600}",
                      "\u{ad}", "写真", "😀", "👩‍👩‍👧", "\r", "\n", "１６００", "P", "1", "6", "0"]
        var generator = SplitMix64(seed: 0x9e7)
        for _ in 0..<20_000 {
            let length = Int(generator.next() % 12)
            let path = (0..<length).map { _ in pieces[Int(generator.next() % UInt64(pieces.count))] }.joined()
            assertSameAsOld(path)
        }
    }
}

/// A small seeded generator, so a failure repeats.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}
