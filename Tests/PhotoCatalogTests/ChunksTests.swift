import XCTest
@testable import PhotoCatalog

/// `Chunks.map` splits `0..<count` into ranges of `chunk` and gives each range's result in
/// range order, however many threads worked them out.
final class ChunksTests: XCTestCase {
    /// The ranges `Chunks.map` should hand its body, worked out one by one.
    private func expectedRanges(_ count: Int, chunk: Int) -> [Range<Int>] {
        let chunk = max(chunk, 1)
        return stride(from: 0, to: count, by: chunk).map { $0 ..< min(count, $0 + chunk) }
    }

    func testRangesTileThePositionsInOrder() {
        for chunk in [1, 2, 3, 7, 64] {
            for count in [0, 1, chunk, chunk + 1, 3 * chunk + 2] {
                let ranges = Chunks.map(count, chunk: chunk) { $0 }
                XCTAssertEqual(ranges, expectedRanges(count, chunk: chunk), "\(count) positions in chunks of \(chunk)")
                // contiguous, from 0 to count, none empty
                XCTAssertEqual(ranges.first?.lowerBound ?? 0, 0)
                XCTAssertEqual(ranges.last?.upperBound ?? 0, count)
                for (before, after) in zip(ranges, ranges.dropFirst()) { XCTAssertEqual(before.upperBound, after.lowerBound) }
                XCTAssertFalse(ranges.contains(where: \.isEmpty))
            }
        }
    }

    func testNoPositionsGiveNoParts() {
        var called = false
        XCTAssertEqual(Chunks.map(0, chunk: 4) { _ -> Int in
            called = true
            return 1
        }, [])
        XCTAssertFalse(called, "the body never runs for no positions")
    }

    /// One range, however large the chunk, is worked out on the calling thread.
    func testOneRangeRunsOnTheCallingThread() {
        for (count, chunk) in [(1, 1), (5, 5), (5, 6), (5, .max)] {
            let parts = Chunks.map(count, chunk: chunk) { range -> (Range<Int>, Bool) in (range, Thread.isMainThread) }
            XCTAssertEqual(parts.map { $0.0 }, [0 ..< count], "\(count) positions in chunks of \(chunk)")
            XCTAssertEqual(parts.map { $0.1 }, [true], "\(count) positions in chunks of \(chunk)")
        }
    }

    /// A chunk under 1 is taken as 1, and a chunk past the positions as one range of them all.
    func testChunkSizesOutOfRange() {
        XCTAssertEqual(Chunks.map(3, chunk: 0) { $0 }, [0 ..< 1, 1 ..< 2, 2 ..< 3])
        XCTAssertEqual(Chunks.map(3, chunk: -5) { $0 }, [0 ..< 1, 1 ..< 2, 2 ..< 3])
        XCTAssertEqual(Chunks.map(3, chunk: .max) { $0 }, [0 ..< 3])
    }

    /// Results that own memory come back whole, in range order: each range's slot is written once.
    func testPartsOwningMemoryComeBackInOrder() {
        let count = 10_007
        for chunk in [1, 13, 1_000, 4_096] {
            let parts = Chunks.map(count, chunk: chunk) { range in range.map { "photo \($0)" } }
            XCTAssertEqual(parts.count, (count - 1) / chunk + 1)
            XCTAssertEqual(Chunks.joined(parts), (0..<count).map { "photo \($0)" }, "chunks of \(chunk)")
        }
    }

    func testJoinedKeepsOrder() {
        XCTAssertEqual(Chunks.joined([[Int]]()), [])
        XCTAssertEqual(Chunks.joined([[1, 2]]), [1, 2])
        XCTAssertEqual(Chunks.joined([[1], [], [2, 3], [4]]), [1, 2, 3, 4])
    }
}
