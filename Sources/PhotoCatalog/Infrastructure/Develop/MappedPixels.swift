// ============================================================
//  Mapped pixels — big bitmaps in memory of their own, outside malloc
// ============================================================
import CoreGraphics
import Foundation

/// Photo-sized pixel buffers mapped for one use and unmapped after it, never handed to malloc.
/// A photo-sized block freed back to malloc gets reused for Image I/O's decoded-image cache,
/// whose entries are meant to be purgeable but can't be in reused memory, so they stay
/// resident: a print job enlarging its photos (output bigger than the decode) left one per page,
/// up to about a gigabyte. Unmapped memory goes straight back to the system instead.
enum MappedPixels {
    /// A CGImage over `bytesPerRow * height` zeroed bytes that `fill` writes, unmapped when the
    /// image goes. Nil when the memory can't be had or `fill` fails.
    static func image(width: Int, height: Int, bitsPerComponent: Int, bitsPerPixel: Int, bytesPerRow: Int,
                      space: CGColorSpace, bitmapInfo: CGBitmapInfo,
                      fill: (UnsafeMutableRawPointer) -> Bool) -> CGImage? {
        let length = bytesPerRow * height
        guard width > 0, height > 0, let memory = map(length) else { return nil }
        guard fill(memory), let provider = CGDataProvider(dataInfo: nil, data: memory, size: length,
                                                          releaseData: { _, data, size in
                                                              munmap(UnsafeMutableRawPointer(mutating: data), size)
                                                          })
        else {
            munmap(memory, length)
            return nil
        }
        return CGImage(width: width, height: height, bitsPerComponent: bitsPerComponent, bitsPerPixel: bitsPerPixel,
                       bytesPerRow: bytesPerRow, space: space, bitmapInfo: bitmapInfo, provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// `count` zeroed bytes of scratch memory for `body`, unmapped after it.
    static func scratch<T>(_ count: Int, _ body: (UnsafeMutableRawPointer) -> T?) -> T? {
        guard count > 0, let memory = map(count) else { return nil }
        defer { munmap(memory, count) }
        return body(memory)
    }

    private static func map(_ length: Int) -> UnsafeMutableRawPointer? {
        let memory = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0)
        return memory == MAP_FAILED ? nil : memory
    }
}
