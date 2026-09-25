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
    private let head2: UInt64
    /// Encoded bytes after the first 24 — empty for most camera file names.
    private let tail: [UInt8]

    /// Digit runs: this marker (between punctuation and letters), their length, then the digits
    /// without leading zeros — a longer run is a bigger number.
    private static let numberMarker: UInt8 = 0x61

    init(_ name: String) {
        if let key = name.utf8.withContiguousStorageIfAvailable({ Self(utf8: $0) }) {
            self = key
        } else {
            self = Array(name.utf8).withUnsafeBufferPointer { Self(utf8: $0) }
        }
    }

    /// Encodes into a stack buffer: a name costs no allocation unless it is unusually long.
    private init(utf8 source: UnsafeBufferPointer<UInt8>) {
        (head0, head1, head2, tail) = withUnsafeTemporaryAllocation(of: UInt8.self, capacity: source.count * 2 + 2) {
            out -> (UInt64, UInt64, UInt64, [UInt8]) in
            var length = 0
            var index = 0
            while index < source.count {
                let byte = source[index]
                if (0x30...0x39).contains(byte) {
                    var end = index
                    while end < source.count, (0x30...0x39).contains(source[end]) { end += 1 }
                    var first = index
                    while first < end - 1, source[first] == 0x30 { first += 1 }   // "007" is "7", "000" is "0"
                    out[length] = Self.numberMarker
                    out[length + 1] = UInt8(min(end - first, 255))
                    length += 2
                    for digit in first..<end {
                        out[length] = source[digit]
                        length += 1
                    }
                    index = end
                    continue
                }
                switch byte {
                case 0x41...0x5A: out[length] = byte + 0x21   // upper → lower, above the number marker
                case 0x61...0x7A: out[length] = byte + 1      // letters above the number marker
                case 0x7B...0x7E: out[length] = byte - 0x20   // { | } ~ with the other symbols
                case 0x00...0x1F: out[length] = 0x01          // never 0: zero is the packing pad
                default: out[length] = byte                   // punctuation below digits, non-ASCII after letters
                }
                length += 1
                index += 1
            }
            func pack(_ offset: Int) -> UInt64 {
                var value: UInt64 = 0
                for index in offset..<offset + 8 { value = value << 8 | UInt64(index < length ? out[index] : 0) }
                return value
            }
            return (pack(0), pack(8), pack(16), length > 24 ? Array(out[24..<length]) : [])
        }
    }

    static func < (lhs: FileNameSortKey, rhs: FileNameSortKey) -> Bool {
        if lhs.head0 != rhs.head0 { return lhs.head0 < rhs.head0 }
        if lhs.head1 != rhs.head1 { return lhs.head1 < rhs.head1 }
        if lhs.head2 != rhs.head2 { return lhs.head2 < rhs.head2 }
        return lhs.tail.lexicographicallyPrecedes(rhs.tail)
    }
}
