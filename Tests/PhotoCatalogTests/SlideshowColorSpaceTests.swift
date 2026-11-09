import XCTest
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoCatalog

/// A slideshow video renders each slide in Rec. 709, the video's space, rather than in Display
/// P3 converted to Rec. 709 on every frame draw. The frames come out the same but for rounding,
/// and for colors past Rec. 709: Core Image clips those (as it does for an sRGB export) where
/// Core Graphics mapped them a little inside, so a few pixels move further than the mean does.
final class SlideshowColorSpaceTests: XCTestCase {
    private var url: URL?

    override func tearDownWithError() throws {
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    private let video = CGColorSpace(name: CGColorSpace.itur_709)!

    /// A 600 × 400 PNG in Display P3: hue sweeps from gray to colors past Rec. 709's gamut,
    /// across a ramp of brightness.
    private func photo() throws -> URL {
        let width = 600, height = 400
        var data = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let hue = Double(x) / Double(width) * 6, value = 0.15 + 0.85 * Double(y) / Double(height)
                let chroma = min(1, Double(y) / Double(height) * 1.4)
                let k = { (n: Double) in value * (1 - chroma * max(0, min(1, min((n + hue).truncatingRemainder(dividingBy: 6),
                                                                                    4 - (n + hue).truncatingRemainder(dividingBy: 6))))) }
                let i = (y * width + x) * 4
                data[i] = UInt8(k(5) * 255); data[i + 1] = UInt8(k(3) * 255); data[i + 2] = UInt8(k(1) * 255)
            }
        }
        let context = try XCTUnwrap(CGContext(data: &data, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: DevelopRenderer.outputColorSpace,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pc-slide-space-\(UUID().uuidString).png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        self.url = url
        return url
    }

    /// `slide` drawn into a frame as the video draws one (BGRA in Rec. 709, on a black backdrop,
    /// zoomed in a little): the photo's pixels, as R, G, B values 0…255.
    private func framePixels(_ slide: CGImage) throws -> [Double] {
        let size = CGSize(width: 960, height: 540)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0, space: video,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        context.interpolationQuality = .high
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(origin: .zero, size: size))
        var rect = SlideshowLayout.rect(imageSize: CGSize(width: slide.width, height: slide.height), in: size, scale: 1.08,
                                        offset: CGVector(dx: 0.01, dy: -0.01))
        rect.origin.y = size.height - rect.maxY
        context.draw(slide, in: rect)
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let inside = rect.intersection(CGRect(origin: .zero, size: size)).insetBy(dx: 2, dy: 2).integral
        var values: [Double] = []
        values.reserveCapacity(Int(inside.width * inside.height) * 3)
        for y in Int(size.height - inside.maxY)..<Int(size.height - inside.minY) {
            for x in Int(inside.minX)..<Int(inside.maxX) {
                let i = y * context.bytesPerRow + x * 4   // B, G, R, A
                values += [Double(bytes[i + 2]), Double(bytes[i + 1]), Double(bytes[i])]
            }
        }
        return values
    }

    private func mean(_ values: [Double], channel: Int) -> Double {
        stride(from: channel, to: values.count, by: 3).reduce(0) { $0 + values[$1] } / Double(values.count / 3)
    }

    func testASlideRenderedInRec709DrawsAsTheDisplayP3RenderDid() throws {
        var settings = DevelopSettings()
        settings.exposure = 0.3
        settings.saturation = 25
        let item = PrintItem(sourcePath: try photo().path, isRaw: false, develop: settings,
                             originalSize: CGSize(width: 600, height: 400), filename: "slide.png", title: "")
        let developed = try XCTUnwrap(item.developed(forLongEdge: 600))
        let former = try XCTUnwrap(DevelopRenderer.render(developed))
        let current = try XCTUnwrap(DevelopRenderer.render(developed, colorSpace: video))
        XCTAssertEqual(current.colorSpace?.name, CGColorSpace.itur_709, "the slide is in the video's space already")
        XCTAssertEqual(former.colorSpace?.name, CGColorSpace.displayP3)
        XCTAssertEqual(current.width, former.width)
        XCTAssertEqual(current.height, former.height)

        let before = try framePixels(former), after = try framePixels(current)
        XCTAssertEqual(before.count, after.count)
        for (channel, name) in ["red", "green", "blue"].enumerated() {
            let old = mean(before, channel: channel), new = mean(after, channel: channel)
            XCTAssertEqual(new, old, accuracy: 2, "the frame's mean \(name) moves by rounding only (\(old) → \(new))")
        }
        // pixel by pixel too: a conversion gone wrong (P3 values taken for Rec. 709) moves them ~9 levels
        let difference = zip(before, after).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(before.count)
        XCTAssertLessThan(difference, 1, "pixels move by rounding, on average")
    }
}
