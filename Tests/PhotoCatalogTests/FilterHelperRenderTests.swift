import XCTest
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoCatalog

/// Non-RAW white balance, CIColorCurves and diagonal weight scaling each had several copies;
/// they now share `DevelopRenderer`'s helpers. Every former site renders the same, byte for byte.
final class FilterHelperRenderTests: XCTestCase {
    private var url: URL?

    override func tearDownWithError() throws {
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    // ---- the former filter chains, as each site had them ----
    private func formerWhiteBalance(_ image: CIImage, temperature warmth: Double, tint: Double) -> CIImage {
        guard warmth != 0 || tint != 0 else { return image }
        return image.applyingFilter("CITemperatureAndTint", parameters: [
            "inputNeutral": CIVector(x: 6500 + warmth * 25, y: tint * 0.5),
            "inputTargetNeutral": CIVector(x: 6500, y: 0),
        ])
    }

    private func formerCurves(_ image: CIImage, _ table: Data) -> CIImage {
        image.applyingFilter("CIColorCurves", parameters: [
            "inputCurvesData": table,
            "inputCurvesDomain": CIVector(x: 0, y: 1),
            "inputColorSpace": DevelopRenderer.outputColorSpace,
        ])
    }

    private func formerScaled(_ weight: CIImage, by k: Double) -> CIImage {
        weight.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
        ])
    }

    /// `DevelopRenderer.applyMasks` as it was, for drawn masks.
    private func formerMasks(_ input: CIImage, _ s: DevelopSettings) -> CIImage {
        let extent = input.extent
        var image = input
        for mask in s.masks where mask.hasEffect {
            guard let weight = DevelopRenderer.maskWeight(mask, s, extent: extent, photo: nil, rangeSource: input) else { continue }
            var adjusted = image
            if mask.exposure != 0 {
                adjusted = adjusted.applyingFilter("CIExposureAdjust", parameters: ["inputEV": mask.exposure])
            }
            if mask.temperature != 0 || mask.tint != 0 {
                adjusted = adjusted.applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: 6500 + mask.temperature * 25, y: mask.tint * 0.5),
                    "inputTargetNeutral": CIVector(x: 6500, y: 0),
                ])
            }
            let tone = mask.toneSettings
            adjusted = DevelopRenderer.applyPresence(DevelopRenderer.applyTone(adjusted, tone), tone)
            image = adjusted.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: image,
                kCIInputMaskImageKey: weight,
            ]).cropped(to: extent)
        }
        return image
    }

    /// `DevelopRenderer.applyProfile` as it was.
    private func formerProfile(_ input: CIImage, _ s: DevelopSettings) -> CIImage {
        let profile = DevelopProfile(stored: s.profile)
        guard profile != .standard, s.profileAmount > 0 else { return input }
        let look = profile.look(amount: s.profileAmount)
        var image = input
        if !look.curve.isEmpty {
            var curve = ToneCurve()
            curve.setPoints(look.curve, for: .rgb)
            image = image.applyingFilter("CIColorCurves", parameters: [
                "inputCurvesData": DevelopRenderer.curveTable(curve),
                "inputCurvesDomain": CIVector(x: 0, y: 1),
                "inputColorSpace": DevelopRenderer.outputColorSpace,
            ])
        }
        guard !look.mixer.isNeutral || look.saturation != 0 else { return image }
        var encoded = DevelopKernels.colorMixer(image.applyingFilter("CILinearToSRGBToneCurve"), look.mixer)
        if look.saturation != 0 {
            encoded = encoded.applyingFilter("CIColorControls", parameters: [
                "inputSaturation": 1 + look.saturation / 100, "inputContrast": 1, "inputBrightness": 0,
            ])
        }
        return encoded.applyingFilter("CISRGBToneCurveToLinear")
    }

    /// `DevelopRenderer.applySpots` as it was, for heal and clone spots.
    private func formerSpots(_ input: CIImage, _ s: DevelopSettings) -> CIImage {
        let extent = input.extent
        let longEdge = max(extent.width, extent.height)
        let clear = CIImage(color: .clear).cropped(to: extent)
        var image = input
        func pixel(_ p: CGPoint) -> CGPoint {
            CGPoint(x: extent.minX + p.x * extent.width, y: extent.maxY - p.y * extent.height)
        }
        for spot in s.spots where spot.opacity > 0 && spot.mode != .remove {
            let radius = max(1, CGFloat(spot.radius) * longEdge)
            let target = pixel(spot.target), source = pixel(spot.source)
            let region = CGRect(x: target.x - radius, y: target.y - radius, width: radius * 2, height: radius * 2)
                .insetBy(dx: -2, dy: -2).intersection(extent)
            guard !region.isNull,
                  let disc = DevelopKernels.disc(center: target, radius: radius, feather: spot.feather / 100, extent: extent)
            else { continue }
            let shifted = image.clampedToExtent()
                .transformed(by: CGAffineTransform(translationX: target.x - source.x, y: target.y - source.y))
            var patch = shifted.cropped(to: extent)
            let ghost = CGPoint(x: 2 * target.x - source.x, y: 2 * target.y - source.y)
            if spot.mode == .heal,
               let ring = DevelopKernels.disc(center: target, radius: radius * 1.05, feather: 0.05, invert: true,
                                              extent: extent),
               let speck = DevelopKernels.disc(center: ghost, radius: radius * 1.05, feather: 0.05, invert: true,
                                               extent: extent) {
                let window = ring.applyingFilter("CIMinimumCompositing", parameters: [kCIInputBackgroundImageKey: speck])
                func surroundings(_ image: CIImage) -> CIImage {
                    image.applyingFilter("CIBlendWithMask", parameters: [
                        kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: window,
                    ]).applyingGaussianBlur(sigma: Double(radius) * 0.6)
                }
                patch = DevelopKernels.heal(patch, sourceRing: surroundings(patch), targetRing: surroundings(image),
                                            extent: extent) ?? patch
            }
            let strength = disc.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: spot.opacity / 100, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: spot.opacity / 100, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: spot.opacity / 100, w: 0),
            ])
            image = patch.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: strength,
            ]).cropped(to: region).composited(over: image)
        }
        return image.cropped(to: extent)
    }

    /// `DevelopRenderer.applyOverlay` as it was.
    private func formerOverlay(_ input: CIImage, _ s: DevelopSettings, maskId: String) -> CIImage? {
        guard let mask = s.masks.first(where: { $0.id == maskId }),
              let weight = DevelopRenderer.maskWeight(mask, s, extent: input.extent, photo: nil, rangeSource: input)
        else { return nil }
        let half = weight.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.55, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0.55, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0.55, w: 0),
        ])
        let red = CIImage(color: CIColor(red: 0.95, green: 0.08, blue: 0.08)).cropped(to: input.extent)
        return red.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: input,
            kCIInputMaskImageKey: half,
        ]).cropped(to: input.extent)
    }

    /// `GenerativeFill.composite` as it was.
    private func formerComposite(_ fill: GenerativeFill.Fill, into image: CIImage, mask: CIImage, opacity: Double,
                                 extent: CGRect) -> CIImage {
        let region = CGRect(x: extent.minX + fill.region.minX * extent.width,
                            y: extent.maxY - fill.region.maxY * extent.height,
                            width: fill.region.width * extent.width, height: fill.region.height * extent.height)
        var patch = CIImage(cgImage: fill.image)
        patch = patch.transformed(by: CGAffineTransform(scaleX: region.width / CGFloat(fill.image.width),
                                                       y: region.height / CGFloat(fill.image.height)))
            .transformed(by: CGAffineTransform(translationX: region.minX, y: region.minY))
        patch = patch.composited(over: image).cropped(to: extent)
        let reach = max(2, Double(region.width) * 0.03)
        let grown = mask.clampedToExtent().applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": reach])
            .cropped(to: extent)
        let ring = grown.applyingFilter("CIMultiplyCompositing", parameters: [
            kCIInputBackgroundImageKey: mask.applyingFilter("CIColorInvert"),
        ]).cropped(to: extent)
        let clear = CIImage(color: .clear).cropped(to: extent)
        func surroundings(_ source: CIImage) -> CIImage {
            source.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: ring,
            ]).applyingGaussianBlur(sigma: reach * 1.5)
        }
        let healed = DevelopKernels.heal(patch, sourceRing: surroundings(patch), targetRing: surroundings(image),
                                         extent: extent) ?? patch
        let strength = grown.applyingGaussianBlur(sigma: reach * 0.5).cropped(to: extent)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: opacity / 100, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: opacity / 100, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: opacity / 100, w: 0),
            ])
        return healed.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: strength,
        ]).cropped(to: extent)
    }

    // ---- comparing ----
    /// `image` over `bounds` as linear half-floats: finer than any 8-bit render, so a changed
    /// parameter can't hide in rounding.
    private func pixels(_ image: CIImage, _ bounds: CGRect) -> [UInt16] {
        let width = Int(bounds.width), height = Int(bounds.height)
        var values = [UInt16](repeating: 0, count: width * height * 4)
        DevelopRenderer.context.render(image, toBitmap: &values, rowBytes: width * 8, bounds: bounds, format: .RGBAh,
                                       colorSpace: DevelopRenderer.linearColorSpace)
        return values
    }

    private func assertSameRender(_ former: CIImage, _ current: CIImage, over bounds: CGRect, _ what: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let before = pixels(former, bounds), after = pixels(current, bounds)
        XCTAssertEqual(before.count, after.count, what, file: file, line: line)
        if let i = before.indices.first(where: { before[$0] != after[$0] }) {
            XCTFail("\(what): differs first at value \(i) (pixel \(i / 4)): \(after[i]) for \(before[i])", file: file, line: line)
        }
        // the edit did something, so the comparison isn't of two untouched photos
        XCTAssertNotEqual(after, pixels(Self.input(), bounds), "\(what) changes the photo", file: file, line: line)
    }

    private static func input() -> CIImage { CIImage(cgImage: photo()) }

    /// The photo as a PNG on disk, as a non-RAW source reads it.
    private func photoFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pc-filters-\(UUID().uuidString).png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, Self.photo(), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        self.url = url
        return url
    }

    // ---- the sites ----
    /// A non-RAW photo's white balance: `spotStage` before any spot is the decoded photo with
    /// exposure and white balance, nothing else.
    func testNonRawWhiteBalance() throws {
        let source = try XCTUnwrap(DevelopRenderer.Source(url: try photoFile(), isRaw: false, maxPixel: nil))
        let plain = try XCTUnwrap(source.spotStage(DevelopSettings(), before: 0))
        for (temperature, tint, exposure) in [(30.0, -12.0, 0.4), (-45, 0, 0), (0, 25, -0.3)] {
            var s = DevelopSettings()
            s.temperature = temperature; s.tint = tint; s.exposure = exposure
            var former = plain
            if exposure != 0 { former = former.applyingFilter("CIExposureAdjust", parameters: ["inputEV": exposure]) }
            former = formerWhiteBalance(former, temperature: temperature, tint: tint)
            assertSameRender(former, try XCTUnwrap(source.spotStage(s, before: 0)), over: plain.extent,
                             "white balance \(temperature)/\(tint) at \(exposure) EV")
        }
    }

    func testMaskWhiteBalance() {
        let input = Self.input()
        var s = DevelopSettings()
        var warm = LocalAdjustment(kind: .radial)
        warm.radiusX = 0.4; warm.radiusY = 0.3; warm.temperature = 40; warm.tint = 10; warm.exposure = 0.3
        var cool = LocalAdjustment(kind: .linear)
        cool.start = CGPoint(x: 0.5, y: 0); cool.end = CGPoint(x: 0.5, y: 0.6); cool.temperature = -35
        s.masks = [warm, cool]
        assertSameRender(formerMasks(input, s), DevelopRenderer.applyMasks(input, s), over: input.extent, "masks' white balance")
    }

    func testToneCurve() {
        let input = Self.input()
        var s = DevelopSettings()
        s.curve.setPoints([CurvePoint(x: 0, y: 0), CurvePoint(x: 0.3, y: 0.22), CurvePoint(x: 0.7, y: 0.8), CurvePoint(x: 1, y: 1)],
                          for: .rgb)
        s.curve.setPoints([CurvePoint(x: 0, y: 0.05), CurvePoint(x: 1, y: 0.95)], for: .blue)
        assertSameRender(formerCurves(input, DevelopRenderer.curveTable(s.curve)), DevelopRenderer.applyCurve(input, s),
                         over: input.extent, "the point curve")
    }

    func testProfileCurve() {
        let input = Self.input()
        for profile in [DevelopProfile.vivid, .portrait, .neutral, .landscape] {
            var s = DevelopSettings()
            s.profile = profile.stored; s.profileAmount = 140
            assertSameRender(formerProfile(input, s), DevelopRenderer.applyProfile(input, s), over: input.extent,
                             "the \(profile.rawValue) profile")
        }
    }

    /// The RAW stage's exposure draft under the engine's tone curve (no RAW fixture reaches the
    /// stage itself, so the table it builds is applied both ways).
    func testExposureBoostCurve() {
        let input = Self.input()
        let inputs = (0..<24).map { 0.001 * pow(1.4, Double($0)) }
        let curve = BoostCurve(inputs: inputs, outputs: inputs.map { $0 / ($0 + 0.18) * 1.18 })
        for delta in [0.7, -1.2] {
            let table = curve.exposureTable(delta: delta)
            assertSameRender(formerCurves(input, table), DevelopRenderer.applyingCurves(input, table), over: input.extent,
                             "an exposure draft of \(delta) EV")
        }
    }

    func testSpotOpacity() {
        let input = Self.input()
        var s = DevelopSettings()
        var heal = SpotRemoval(target: CGPoint(x: 0.3, y: 0.4), source: CGPoint(x: 0.5, y: 0.45), radius: 0.06)
        heal.opacity = 60
        var clone = SpotRemoval(target: CGPoint(x: 0.7, y: 0.6), source: CGPoint(x: 0.6, y: 0.3), radius: 0.05)
        clone.mode = .clone; clone.opacity = 45
        s.spots = [heal, clone]
        assertSameRender(formerSpots(input, s), DevelopRenderer.applySpots(input, s), over: input.extent, "spots at part opacity")
    }

    func testMaskOverlay() throws {
        let input = Self.input()
        var s = DevelopSettings()
        var warm = LocalAdjustment(kind: .radial)
        warm.radiusX = 0.4; warm.radiusY = 0.3; warm.temperature = 40
        s.masks = [warm]
        assertSameRender(try XCTUnwrap(formerOverlay(input, s, maskId: warm.id)),
                         DevelopRenderer.applyOverlay(input, s, maskId: warm.id), over: input.extent, "the mask overlay")
    }

    func testGenerativeFillOpacity() {
        let input = Self.input(), extent = input.extent
        let fill = Self.fill(), mask = Self.mask(extent)
        assertSameRender(formerComposite(fill, into: input, mask: mask, opacity: 70, extent: extent),
                         GenerativeFill.composite(fill, into: input, mask: mask, opacity: 70, extent: extent),
                         over: extent, "a generative fill at 70%")
    }

    /// A 320 × 240 photo of gradients and colored boxes in Display P3.
    private static func photo() -> CGImage {
        let width = 320, height = 240
        var data = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                var c = (Double(x) / Double(width), Double(y) / Double(height), Double((x * 3 + y * 5) % 256) / 255)
                if (x / 40 + y / 40).isMultiple(of: 3) { c = (0.85 - c.0 * 0.5, 0.3 + c.1 * 0.4, 0.15) }
                data[i] = UInt8(c.0 * 255); data[i + 1] = UInt8(c.1 * 255); data[i + 2] = UInt8(c.2 * 255)
            }
        }
        let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: DevelopRenderer.outputColorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        return context.makeImage()!
    }

    /// A generative fill: a gray-green square with a ramp, placed over the middle of the photo.
    private static func fill() -> GenerativeFill.Fill {
        let side = GenerativeFill.side
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                space: DevelopRenderer.outputColorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for row in 0..<16 {
            context.setFillColor(CGColor(colorSpace: DevelopRenderer.outputColorSpace,
                                         components: [0.3 + Double(row) * 0.02, 0.5, 0.35, 1])!)
            context.fill(CGRect(x: 0, y: row * side / 16, width: side, height: side / 16))
        }
        return GenerativeFill.Fill(image: context.makeImage()!, region: CGRect(x: 0.3, y: 0.25, width: 0.4, height: 0.5))
    }

    /// The painted area: a soft-edged rectangle in the middle of `extent`.
    private static func mask(_ extent: CGRect) -> CIImage {
        CIImage(color: .white).cropped(to: CGRect(x: extent.midX - 40, y: extent.midY - 30, width: 80, height: 60))
            .composited(over: CIImage(color: .black).cropped(to: extent))
            .applyingGaussianBlur(sigma: 4).cropped(to: extent)
    }
}
