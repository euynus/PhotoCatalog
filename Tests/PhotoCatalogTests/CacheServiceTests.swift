import XCTest
@testable import PhotoCatalog

/// Pruning the thumbnail and preview cache.
final class CacheServiceTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pc-cache-prune-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("Previews/2048/ab"),
                                                 withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    private func write(_ name: String, bytes: Int, age: TimeInterval) throws -> URL {
        let url = root.appendingPathComponent("Previews/2048/ab").appendingPathComponent(name)
        try Data(count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)],
                                              ofItemAtPath: url.path)
        return url
    }

    /// A preview being written (its temporary file, moved into place once encoded) is left for
    /// its writer, while one a crash left long ago is cleared like any other file.
    func testPruneLeavesFilesBeingWrittenAlone() throws {
        let writing = try write(".tmp-\(UUID().uuidString)-p.jpg", bytes: 200_000, age: 1)
        let leftover = try write(".tmp-\(UUID().uuidString)-q.jpg", bytes: 200_000, age: 86_400)
        let preview = try write("p.jpg", bytes: 100_000, age: 3_600)

        _ = CacheService.prune(root, maxBytes: 150_000)

        XCTAssertTrue(FileManager.default.fileExists(atPath: writing.path), "a preview being written was deleted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path), "a crash's leftover is kept for good")
        XCTAssertTrue(FileManager.default.fileExists(atPath: preview.path),
                      "a finished preview went while the cache was under the limit without the leftover")
    }

    /// A Quick Look image is checked for black before it's written to the cache: black all over
    /// at any size, and not black once part of it shows something.
    func testBlackImageIsRecognizedBeforeItIsWritten() throws {
        func image(width: Int, height: Int, lit: CGRect?) throws -> CGImage {
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            if let lit {
                context.setFillColor(CGColor(red: 0.6, green: 0.5, blue: 0.4, alpha: 1))
                context.fill(lit)
            }
            return try XCTUnwrap(context.makeImage())
        }
        XCTAssertTrue(ThumbnailService.imageIsUniformBlack(try image(width: 2048, height: 1365, lit: nil)))
        XCTAssertTrue(ThumbnailService.imageIsUniformBlack(try image(width: 20, height: 12, lit: nil)))
        XCTAssertFalse(ThumbnailService.imageIsUniformBlack(
            try image(width: 2048, height: 1365, lit: CGRect(x: 0, y: 0, width: 512, height: 1365))))
    }
}
