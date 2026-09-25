// ============================================================
//  FileNameSortKey — Finder-like name order at integer-compare speed
// ============================================================
import Foundation

/// Orders file names as the Finder does: case-insensitive, digit runs by value ("IMG_9" before
/// "IMG_10"), punctuation before digits before letters. The name is encoded once into bytes
/// whose plain order is that order, and the first 16 bytes are packed into two integers, so a
/// comparison is usually two integer compares. (`localizedCompare` per comparison took ~5 s to
/// sort 500k names.) Non-ASCII characters keep numeric awareness but sort by code point.
struct FileNameSortKey: Comparable {
    private let head0: UInt64
    private let head1: UInt64
    /// Encoded bytes after the first 16 — empty for most camera file names.
    private let tail: [UInt8]

    /// Digit runs: this marker (between punctuation and letters), their length, then the digits
    /// without leading zeros — a longer run is a bigger number.
    private static let numberMarker: UInt8 = 0x61

    init(_ name: String) {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(name.utf8.count + 4)
        var digits: [UInt8] = []
        func flushDigits() {
            guard !digits.isEmpty else { return }
            var significant = digits.drop { $0 == 0x30 }
            if significant.isEmpty { significant = digits.suffix(1) }   // "000" is "0"
            bytes.append(Self.numberMarker)
            bytes.append(UInt8(min(significant.count, 255)))
            bytes.append(contentsOf: significant)
            digits.removeAll(keepingCapacity: true)
        }
        for byte in name.utf8 {
            if (0x30...0x39).contains(byte) {
                digits.append(byte)
                continue
            }
            flushDigits()
            switch byte {
            case 0x41...0x5A: bytes.append(byte + 0x21)   // upper → lower, above the number marker
            case 0x61...0x7A: bytes.append(byte + 1)      // letters above the number marker
            case 0x7B...0x7E: bytes.append(byte - 0x20)   // { | } ~ with the other symbols
            case 0x00...0x1F: bytes.append(0x01)          // never 0: zero is the packing pad
            default: bytes.append(byte)                   // punctuation below digits, non-ASCII after letters
            }
        }
        flushDigits()
        func pack(_ range: Range<Int>) -> UInt64 {
            var value: UInt64 = 0
            for index in range { value = value << 8 | UInt64(index < bytes.count ? bytes[index] : 0) }
            return value
        }
        head0 = pack(0..<8)
        head1 = pack(8..<16)
        tail = bytes.count > 16 ? Array(bytes[16...]) : []
    }

    static func < (lhs: FileNameSortKey, rhs: FileNameSortKey) -> Bool {
        if lhs.head0 != rhs.head0 { return lhs.head0 < rhs.head0 }
        if lhs.head1 != rhs.head1 { return lhs.head1 < rhs.head1 }
        return lhs.tail.lexicographicallyPrecedes(rhs.tail)
    }
}
