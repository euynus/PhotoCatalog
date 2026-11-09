import CryptoKit
import Foundation
import XCTest
@testable import PhotoCatalog

/// `hexString` writes what `map { String(format: "%02x", $0) }.joined()` wrote: asset ids,
/// cache shards, backup manifests and model keys stored in that form must keep their names.
final class HexStringTests: XCTestCase {
    private func oldHex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    func testEveryByteValue() {
        let all = (0...255).map(UInt8.init)
        XCTAssertEqual(all.hexString, oldHex(all))
        XCTAssertEqual([UInt8]().hexString, "")
        XCTAssertEqual(Data().hexString, "")
        XCTAssertEqual([0x00, 0x0f, 0xa0, 0xff].hexString, "000fa0ff")
    }

    func testDigestsAndTheirPrefixesMatchTheOldFormat() {
        var generator = SplitMix64(seed: 0x5eed)
        for index in 0..<20_000 {
            let length = Int(generator.next() % 64)
            let input = Data((0..<length).map { _ in UInt8(truncatingIfNeeded: generator.next()) })
            let sha256 = SHA256.hash(data: input)
            XCTAssertEqual(sha256.hexString, oldHex(sha256))
            let sha1 = Insecure.SHA1.hash(data: input)
            XCTAssertEqual(sha1.hexString, oldHex(sha1))
            let count = index % 33
            XCTAssertEqual(sha256.prefix(count).hexString, oldHex(sha256.prefix(count)))
            XCTAssertEqual(Array(sha256).prefix(count).hexString, oldHex(Array(sha256).prefix(count)))
            XCTAssertEqual(input.hexString, oldHex(input))
        }
    }

    /// The asset-id form ImportCoordinator stores: the first 16 hex digits of a path's SHA-256.
    func testShortHashOfANonASCIIPath() {
        let digest = SHA256.hash(data: Data("/Volumes/卡/DCIM/Café é.CR3".utf8))
        XCTAssertEqual(String(digest.hexString.prefix(16)),
                       String(digest.compactMap { String(format: "%02x", $0) }.joined().prefix(16)))
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
