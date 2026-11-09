import XCTest
@preconcurrency import ColorSync
@testable import PhotoCatalog

/// Soft proofing and printer-profile conversion split an image's bands among a few threads, each
/// with a ColorSync transform of its own. Split or not, the output must be the same bytes.
final class SoftProofConcurrencyTests: XCTestCase {
    private let size = (width: 2048, height: 1365)
    private let cmykPath = "/System/Library/ColorSync/Profiles/Generic CMYK Profile.icc"

    private func profile(_ name: Unmanaged<CFString>) throws -> ColorSyncProfile {
        try XCTUnwrap(ColorSyncProfileCreateWithName(name.takeUnretainedValue())?.takeRetainedValue())
    }

    private func intent(_ constant: Unmanaged<CFString>?) throws -> String {
        try XCTUnwrap(constant?.takeUnretainedValue() as String?)
    }

    /// `count` bytes of noise (xorshift), the same every run.
    private func noise(_ count: Int) -> [UInt8] {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        var bytes = [UInt8](repeating: 0, count: count)
        bytes.withUnsafeMutableBytes { buffer in
            for offset in stride(from: 0, to: count, by: 8) {
                state ^= state << 13
                state ^= state >> 7
                state ^= state << 17
                withUnsafeBytes(of: state) { word in
                    buffer[offset..<min(count, offset + 8)].copyBytes(from: word.prefix(count - offset))
                }
            }
        }
        return bytes
    }

    /// Where `a` and `b` first differ, or nil when they're the same bytes.
    private func firstDifference(_ a: [UInt8], _ b: [UInt8]) -> Int? {
        guard a.count == b.count else { return min(a.count, b.count) }
        let same = a.withUnsafeBytes { x in b.withUnsafeBytes { y in memcmp(x.baseAddress!, y.baseAddress!, a.count) == 0 } }
        return same ? nil : a.indices.first { a[$0] != b[$0] }
    }

    /// `pixels` converted by up to `workers` threads, or nil when the conversion failed.
    private func converted(_ pixels: [UInt8], from source: (profile: ColorSyncProfile, layout: SoftProofing.Layout),
                           to destination: (profile: ColorSyncProfile, layout: SoftProofing.Layout),
                           intent: String, workers: Int) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: size.width * size.height * destination.layout.bytes)
        let done = pixels.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { result in
                SoftProofing.convert(input.baseAddress!, size, from: source, to: destination, intent: intent,
                                     into: result.baseAddress!, workers: workers)
            }
        }
        return done ? output : nil
    }

    /// One thread's bytes, and those of three and four threads (an uneven split and an even one).
    private func assertSplitMatchesSerial(from source: (profile: ColorSyncProfile, layout: SoftProofing.Layout),
                                          to destination: (profile: ColorSyncProfile, layout: SoftProofing.Layout),
                                          intent: String, _ what: String) throws {
        let input = noise(size.width * size.height * source.layout.bytes)
        let serial = try XCTUnwrap(converted(input, from: source, to: destination, intent: intent, workers: 1), what)
        XCTAssertFalse(serial.allSatisfy { $0 == 0 }, "\(what): something was converted")
        for workers in [3, 4] {
            let split = try XCTUnwrap(converted(input, from: source, to: destination, intent: intent, workers: workers),
                                      "\(what), \(workers) threads")
            XCTAssertEqual(split.count, serial.count)
            if let i = firstDifference(serial, split), i < split.count {
                XCTFail("\(what), \(workers) threads: byte \(i) (row \(i / (split.count / size.height))) is \(split[i]), "
                        + "one thread gives \(serial[i])")
            }
        }
    }

    func testTheImageSpansManyBands() {
        let bands = (size.height - 1) / (SoftProofing.bandPixels / size.width) + 1
        XCTAssertGreaterThan(bands, 4 * 4, "enough bands that four threads each convert several")
        XCTAssertLessThanOrEqual(SoftProofing.maxWorkers, 4)
    }

    func testSRGBProofIsTheSameSplitOrNot() throws {
        let display = try profile(kColorSyncDisplayP3Profile), srgb = try profile(kColorSyncSRGBProfile)
        try assertSplitMatchesSerial(from: (display, .rgbx), to: (srgb, .plain(3)),
                                     intent: try intent(kColorSyncRenderingIntentPerceptual), "Display P3 into sRGB")
        try assertSplitMatchesSerial(from: (srgb, .plain(3)), to: (display, .rgbx),
                                     intent: try intent(kColorSyncRenderingIntentRelative), "sRGB back to Display P3")
    }

    func testCMYKProofIsTheSameSplitOrNot() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: cmykPath), "no Generic CMYK profile on this Mac")
        let display = try profile(kColorSyncDisplayP3Profile)
        let cmyk = try XCTUnwrap(ColorSyncProfileCreateWithURL(URL(fileURLWithPath: cmykPath) as CFURL, nil)?
            .takeRetainedValue())
        try assertSplitMatchesSerial(from: (display, .rgbx), to: (cmyk, .plain(4)),
                                     intent: try intent(kColorSyncRenderingIntentPerceptual), "Display P3 into Generic CMYK")
        try assertSplitMatchesSerial(from: (cmyk, .plain(4)), to: (display, .rgbx),
                                     intent: try intent(kColorSyncRenderingIntentRelative), "Generic CMYK back to Display P3")
    }

    /// A profile ColorSync can't build a transform from fails every thread's run, and the
    /// conversion says so whether it was split or not.
    func testAFailedRunFailsTheConversion() throws {
        let display = try profile(kColorSyncDisplayP3Profile)
        let empty = try XCTUnwrap(ColorSyncProfileCreateMutable()?.takeRetainedValue())
        let input = noise(size.width * size.height * 4)
        let perceptual = try intent(kColorSyncRenderingIntentPerceptual)
        for workers in [1, 4] {
            // (not XCTAssertNil, which would print all the bytes)
            let output = converted(input, from: (display, .rgbx), to: (empty, .plain(3)), intent: perceptual, workers: workers)
            XCTAssertTrue(output == nil, "\(workers) threads: the conversion failed")
        }
    }
}
