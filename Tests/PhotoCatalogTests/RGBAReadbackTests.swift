import XCTest
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoCatalog

/// SemanticMasks and SoftProofing each had a CGImage → Display P3 RGBA readback; masks now use
/// SoftProofing's. The two must read every image the same, byte for byte.
final class RGBAReadbackTests: XCTestCase {
    private var url: URL?

    override func tearDownWithError() throws {
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    /// SemanticMasks.rgba as it was before it forwarded to SoftProofing's.
    private func formerSemanticRGBA(_ image: CGImage) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let context = CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: DevelopRenderer.outputColorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels
    }

    /// The former readback, SoftProofing's and SemanticMasks' agree on `image`.
    private func assertSameReadback(_ image: CGImage, _ what: String) throws {
        let former = try XCTUnwrap(formerSemanticRGBA(image))
        let proofing = try XCTUnwrap(SoftProofing.rgba(image))
        let masks = try XCTUnwrap(SemanticMasks.rgba(image))
        for (name, pixels) in [("SoftProofing.rgba", proofing), ("SemanticMasks.rgba", masks)] {
            guard pixels.count == former.count else {
                XCTFail("\(what): \(name) gives \(pixels.count) bytes for \(former.count)")
                continue
            }
            if let i = former.indices.first(where: { former[$0] != pixels[$0] }) {
                XCTFail("\(what): \(name) differs first at byte \(i) (pixel \(i / 4)): \(pixels[i]) for \(former[i])")
            }
        }
    }

    /// A JPEG of colored squares in `space`, read back as an Image I/O thumbnail the way masks
    /// find their canonical image.
    private func jpegThumbnail(space: CGColorSpace, maxPixel: Int) throws -> CGImage {
        let width = 900, height = 600
        let gray = space.numberOfComponents == 1
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: gray ? CGImageAlphaInfo.none.rawValue
                                                                             : CGImageAlphaInfo.noneSkipLast.rawValue))
        for y in stride(from: 0, to: height, by: 12) {
            for x in stride(from: 0, to: width, by: 12) {
                let r = CGFloat(x) / CGFloat(width), g = CGFloat(y) / CGFloat(height), b = CGFloat((x * 7 + y * 13) % 256) / 255
                context.setFillColor(gray ? CGColor(gray: (r + g + b) / 3, alpha: 1) : CGColor(red: r, green: g, blue: b, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 12, height: 12))
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pc-rgba-readback-\(UUID().uuidString).jpg")
        self.url = url
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary))
        return try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary))
    }

    /// Noise rendered by DevelopRenderer, in Display P3 like every develop render.
    private func render(opaque: Bool) throws -> CGImage {
        var noise = try XCTUnwrap(CIFilter(name: "CIRandomGenerator")?.outputImage)
            .cropped(to: CGRect(x: 0, y: 0, width: 321, height: 203))
        if opaque { noise = noise.settingAlphaOne(in: noise.extent) }
        return try XCTUnwrap(DevelopRenderer.render(noise))
    }

    func testSRGBJPEGThumbnailReadsTheSame() throws {
        let image = try jpegThumbnail(space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)), maxPixel: 512)
        XCTAssertEqual(image.colorSpace?.name, CGColorSpace.sRGB, "a draw that converts colors")
        try assertSameReadback(image, "sRGB JPEG thumbnail")
    }

    func testGrayJPEGThumbnailReadsTheSame() throws {
        try assertSameReadback(try jpegThumbnail(space: CGColorSpaceCreateDeviceGray(), maxPixel: 512), "gray JPEG thumbnail")
    }

    func testDisplayP3RenderReadsTheSame() throws {
        let image = try render(opaque: true)
        XCTAssertEqual(image.colorSpace?.name, CGColorSpace.displayP3)
        try assertSameReadback(image, "Display P3 render")
    }

    func testTranslucentRenderReadsTheSame() throws {
        try assertSameReadback(try render(opaque: false), "translucent Display P3 render")
    }
}
