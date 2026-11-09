// ============================================================
//  Chunks — passes over a catalog's photos, split among the cores
// ============================================================
import Foundation

/// The whole-catalog passes (counts, pairing keys, stacks) split their photos into ranges,
/// work the ranges out side by side and join the parts in order: what one pass gives.
enum Chunks {
    /// `body` of each range of `chunk` positions in `0..<count`, in range order. More than one
    /// range runs side by side on every core, one range on the calling thread, none for no positions.
    static func map<T>(_ count: Int, chunk: Int, _ body: (Range<Int>) -> T) -> [T] {
        guard count > 0 else { return [] }
        let chunk = max(chunk, 1)
        guard count > chunk else { return [body(0 ..< count)] }
        let chunks = (count - 1) / chunk + 1
        return [T](unsafeUninitializedCapacity: chunks) { buffer, initialized in
            // each range writes its own slot: no lock, and no array the threads retain by turns
            let slots = Slots(buffer: buffer)
            DispatchQueue.concurrentPerform(iterations: chunks) { index in
                let lower = index * chunk
                (slots.buffer.baseAddress! + index).initialize(to: body(lower ..< lower + min(chunk, count - lower)))
            }
            initialized = chunks
        }
    }

    /// The parts joined in order; one part as it is, without copying it.
    static func joined<T>(_ parts: [[T]]) -> [T] {
        guard parts.count > 1 else { return parts.first ?? [] }
        var joined: [T] = []
        joined.reserveCapacity(parts.reduce(0) { $0 + $1.count })
        for part in parts { joined += part }
        return joined
    }

    /// Memory the ranges share, each range writing a slot of its own.
    private struct Slots<Element>: @unchecked Sendable {
        let buffer: UnsafeMutableBufferPointer<Element>
    }
}
