import XCTest
import CoreGraphics
import CoreImage
@testable import PhotoCatalog

/// `DevelopRenderer.render` materializes its bitmap once. Core Image defers large renders, and a
/// deferred image runs its whole graph again on every read (histogram, layer contents, pixels).
final class RenderMaterializationTests: XCTestCase {
    /// A 6144 × 4096 (25 Mpx) graph of a few filters, past the size Core Image defers.
    private func graph() -> CIImage {
        let extent = CGRect(x: 0, y: 0, width: 6144, height: 4096)
        let gradient = CIImage.empty().applyingFilter("CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: extent.width, y: extent.height),
            "inputColor0": CIColor(red: 0.1, green: 0.3, blue: 0.6), "inputColor1": CIColor(red: 0.9, green: 0.7, blue: 0.2),
        ])
        let noise = CIImage.empty().applyingFilter("CIRandomGenerator")
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.1, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0.1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.1, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            ])
        return noise.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: gradient])
            .applyingFilter("CIExposureAdjust", parameters: ["inputEV": 0.4])
            .applyingFilter("CIColorControls", parameters: ["inputSaturation": 1.2, "inputContrast": 1.1, "inputBrightness": 0])
            .clampedToExtent().applyingGaussianBlur(sigma: 6)
            .applyingFilter("CIUnsharpMask", parameters: ["inputRadius": 4, "inputIntensity": 0.8])
            .cropped(to: extent)
    }

    private func milliseconds(_ work: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        work()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    }

    /// The materialized bitmap is the deferred render's, byte for byte.
    func testMaterializedRenderMatchesTheDeferredOne() throws {
        let image = graph()
        let deferred = try XCTUnwrap(DevelopRenderer.context.createCGImage(
            image, from: image.extent.integral, format: .RGBA8, colorSpace: DevelopRenderer.outputColorSpace, deferred: true))
        let rendered = try XCTUnwrap(DevelopRenderer.render(image))
        XCTAssertEqual(rendered.width, 6144)
        XCTAssertEqual(rendered.height, 4096)
        let expected = try XCTUnwrap(deferred.dataProvider?.data) as Data
        let actual = try XCTUnwrap(rendered.dataProvider?.data) as Data
        XCTAssertEqual(actual.count, expected.count)
        XCTAssertTrue(actual == expected, "the materialized render differs from the deferred one")
    }

    /// Rendering does the work once: reading the image again costs a copy, not another render
    /// of the graph. A ratio, so a loaded machine slows both sides alike.
    func testReadingARenderAgainDoesNotRenderItAgain() throws {
        let image = graph()
        _ = DevelopRenderer.render(image)?.dataProvider?.data   // kernels compiled, caches warm
        var rendered: CGImage?
        let first = milliseconds { rendered = DevelopRenderer.render(image); _ = rendered?.dataProvider?.data }
        let again = try XCTUnwrap(rendered)
        let second = milliseconds { _ = again.dataProvider?.data }
        XCTAssertLessThan(second, first * 0.1, "a second read took \(second) ms after \(first) ms to render and read")
    }
}
