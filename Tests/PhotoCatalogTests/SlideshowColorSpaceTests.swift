import XCTest
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoCatalog

/// A slideshow video converts each slide from Display P3 to Rec. 709, the video's space, once
/// when it caches it, rather than on every frame draw. Core Graphics converts an image before it
/// scales and blends it, so the frames come out as they did, colors past Rec. 709 included: Core
/// Image would clip those where Core Graphics maps them a little inside.
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

    /// A frame drawn as the video draws one (BGRA in Rec. 709, on a black backdrop, smoothly
    /// scaled): `slide` at each of `draws` in turn, as one slide fades in over another. Its bytes.
    private func frame(_ slide: CGImage, _ draws: [(alpha: Double, scale: Double, offset: CGVector)]) throws -> [UInt8] {
        let size = CGSize(width: 960, height: 540)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0, space: video,
            bitmapInfo: SlideshowVideo.frameBitmapInfo))
        context.interpolationQuality = .high
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(origin: .zero, size: size))
        for draw in draws {
            var rect = SlideshowLayout.rect(imageSize: CGSize(width: slide.width, height: slide.height), in: size,
                                            scale: draw.scale, offset: draw.offset)
            rect.origin.y = size.height - rect.maxY
            context.saveGState()
            context.setAlpha(draw.alpha)
            context.draw(slide, in: rect)
            context.restoreGState()
        }
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: bytes, count: context.bytesPerRow * context.height))
    }

    private func largestDifference(_ a: [UInt8], _ b: [UInt8]) -> Int {
        zip(a, b).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
    }

    func testASlideConvertedOnceDrawsTheFramesThatConvertingItOnEachDrawDid() throws {
        var settings = DevelopSettings()
        settings.exposure = 0.3
        settings.saturation = 25
        let item = PrintItem(sourcePath: try photo().path, isRaw: false, develop: settings,
                             originalSize: CGSize(width: 600, height: 400), filename: "slide.png", title: "")
        let developed = try XCTUnwrap(item.developed(forLongEdge: 600))
        let displayP3 = try XCTUnwrap(DevelopRenderer.render(developed))
        let slide = try XCTUnwrap(SlideshowVideo.converted(displayP3, to: video))
        XCTAssertEqual(displayP3.colorSpace?.name, CGColorSpace.displayP3)
        XCTAssertEqual(slide.colorSpace?.name, CGColorSpace.itur_709, "the slide is in the video's space already")
        XCTAssertEqual(slide.width, displayP3.width)
        XCTAssertEqual(slide.height, displayP3.height)

        let zoomed: [(alpha: Double, scale: Double, offset: CGVector)] = [(1, 1.08, CGVector(dx: 0.01, dy: -0.01))]
        // the photo is saturated past Rec. 709: rendered straight into it by Core Image, colors clip
        // far from where drawing the Display P3 render puts them
        let clipped = try XCTUnwrap(DevelopRenderer.context.createCGImage(
            developed, from: developed.extent.integral, format: .RGBA8, colorSpace: video, deferred: false))
        let gamut = largestDifference(try frame(displayP3, zoomed), try frame(clipped, zoomed))
        XCTAssertGreaterThan(gamut, 10, "the photo has colors past Rec. 709")

        let frames: [(name: String, draws: [(alpha: Double, scale: Double, offset: CGVector)])] = [
            ("fitted", [(1, 1, .zero)]),
            ("zoomed", zoomed),
            ("fading in", [(1, 1.12, CGVector(dx: -0.02, dy: 0.015)), (0.4, 1, .zero)]),
        ]
        for (name, draws) in frames {
            let difference = largestDifference(try frame(displayP3, draws), try frame(slide, draws))
            XCTAssertLessThanOrEqual(difference, 1, "\(name): the frame is drawn as before (largest change \(difference))")
        }
    }
}
