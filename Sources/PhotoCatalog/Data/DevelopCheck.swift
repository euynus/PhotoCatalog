import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Develop adjustments render in the right direction, persist, and undo.
enum DevelopCheck {
    static func run() {
        checkRendering()
        checkDetail()
        checkPresence()
        checkToneCurve()
        checkColorMixer()
        checkColorGrading()
        checkLocalAdjustments()
        checkLensCorrections()
        checkEffects()
        checkAutoAdjustments()
        checkHistogram()
        checkGeometryMath()
        checkGeometryRendering()
        checkPersistence()
        checkTransferRules()
        MainActor.assumeIsolated {
            checkEditsAndUndo()
            checkCopyPasteAndPresets()
        }
        print("--- develop assertions passed ---")
    }

    /// A 64×64 solid-color image in display P3.
    private static func solid(_ color: (Double, Double, Double)) -> CGImage {
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                space: DevelopRenderer.outputColorSpace,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: DevelopRenderer.outputColorSpace,
                                     components: [color.0, color.1, color.2, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        return context.makeImage()!
    }

    /// Renders `settings` on `image` through a PNG file, as the app renders a photo.
    private static func develop(_ image: CGImage, _ settings: DevelopSettings, wholeFrame: Bool = false,
                                overlayMask: String? = nil) -> CGImage {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pc-develop-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        let source = DevelopRenderer.Source(url: url, isRaw: false, maxPixel: nil)!
        return DevelopRenderer.render(source.image(settings, wholeFrame: wholeFrame, overlayMask: overlayMask)!)!
    }

    /// 64 × 32: red left half, blue right half.
    private static func split() -> CGImage {
        let context = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                space: DevelopRenderer.outputColorSpace,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: DevelopRenderer.outputColorSpace, components: [1, 0, 0, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        context.setFillColor(CGColor(colorSpace: DevelopRenderer.outputColorSpace, components: [0, 0, 1, 1])!)
        context.fill(CGRect(x: 32, y: 0, width: 32, height: 32))
        return context.makeImage()!
    }

    /// RGBA at (x, y), top-left origin.
    private static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: DevelopRenderer.outputColorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let i = (y * image.width + x) * 4
        return (data[i], data[i + 1], data[i + 2], data[i + 3])
    }

    private static func isRed(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool { p.r > 200 && p.b < 60 }
    private static func isBlue(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool { p.b > 200 && p.r < 60 }

    /// Mean RGB (0…1, display P3) of a rendered adjustment of a solid-color image.
    private static func mean(_ color: (Double, Double, Double), _ settings: DevelopSettings) -> (r: Double, g: Double, b: Double) {
        let rendered = develop(solid(color), settings)
        var pixel = [UInt8](repeating: 0, count: 4)
        let sample = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                               space: DevelopRenderer.outputColorSpace,
                               bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        sample.interpolationQuality = .medium
        sample.draw(rendered, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
    }

    private static func luma(_ c: (r: Double, g: Double, b: Double)) -> Double { 0.3 * c.r + 0.59 * c.g + 0.11 * c.b }

    private static func checkRendering() {
        let gray = (0.5, 0.5, 0.5)
        let neutral = mean(gray, .neutral)
        assert(abs(neutral.r - 0.5) < 0.02 && abs(neutral.b - 0.5) < 0.02, "neutral settings leave the photo unchanged")

        var s = DevelopSettings()
        s.exposure = 1
        assert(luma(mean(gray, s)) > luma(neutral) + 0.1, "positive exposure brightens")

        s = DevelopSettings(); s.temperature = 60
        let warm = mean(gray, s)
        s.temperature = -60
        let cool = mean(gray, s)
        assert(warm.r > warm.b + 0.03 && cool.b > cool.r + 0.03, "temperature warms and cools")

        s = DevelopSettings(); s.shadows = 100
        assert(luma(mean((0.12, 0.12, 0.12), s)) > 0.14, "lifting shadows brightens dark tones")
        s = DevelopSettings(); s.whites = -100
        assert(luma(mean((0.95, 0.95, 0.95), s)) < 0.93, "lowering whites darkens near-white")
        s = DevelopSettings(); s.blacks = 100
        let lifted = luma(mean((0.02, 0.02, 0.02), s))
        assert(lifted > 0.05, "raising blacks lifts the black point")

        s = DevelopSettings(); s.saturation = -100
        let gray2 = mean((0.8, 0.3, 0.2), s)
        assert(abs(gray2.r - gray2.g) < 0.03 && abs(gray2.g - gray2.b) < 0.03, "-100 saturation is monochrome")
        s = DevelopSettings(); s.contrast = 100
        assert(luma(mean((0.8, 0.8, 0.8), s)) > luma(mean((0.8, 0.8, 0.8), .neutral)),
               "contrast pushes light tones lighter")
    }

    /// 64 × 64 image from a per-pixel color function (x, y) → display-P3 RGB.
    private static func image(_ color: (Int, Int) -> (Double, Double, Double)) -> CGImage {
        var data = [UInt8](repeating: 255, count: 64 * 64 * 4)
        for y in 0..<64 {
            for x in 0..<64 {
                let c = color(x, y), i = (y * 64 + x) * 4
                data[i] = UInt8(max(0, min(255, c.0 * 255)))
                data[i + 1] = UInt8(max(0, min(255, c.1 * 255)))
                data[i + 2] = UInt8(max(0, min(255, c.2 * 255)))
            }
        }
        let context = CGContext(data: &data, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 64 * 4,
                                space: DevelopRenderer.outputColorSpace,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        return context.makeImage()!
    }

    /// Standard deviation of luma and of red − blue over the image's interior (0…255 scale).
    private static func spread(_ image: CGImage) -> (luma: Double, chroma: Double) {
        var lumas: [Double] = [], chromas: [Double] = []
        for y in stride(from: 8, to: 56, by: 2) {
            for x in stride(from: 8, to: 56, by: 2) {
                let p = pixel(image, x, y)
                lumas.append(0.3 * Double(p.r) + 0.59 * Double(p.g) + 0.11 * Double(p.b))
                chromas.append(Double(p.r) - Double(p.b))
            }
        }
        func deviation(_ values: [Double]) -> Double {
            let mean = values.reduce(0, +) / Double(values.count)
            return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
        }
        return (deviation(lumas), deviation(chromas))
    }

    private static func checkDetail() {
        // stored before detail existed: loads with the defaults, and keeps its cache name
        let old = try! JSONDecoder().decode(DevelopSettings.self, from: Data(#"{"exposure":0.5}"#.utf8))
        assert(old.sharpenRadius == 1 && !old.hasDetail && old.exposure == 0.5, "old edits load with neutral detail")
        assert(try! JSONDecoder().decode(DevelopSettings.self, from: Data("{}".utf8)).isNeutral, "an empty edit is as shot")
        let legacyText = [Double?](arrayLiteral: nil, nil, 0.5, 0, 0, 0, 0, 0, 0, 0)
            .map { $0.map { String(format: "%.3f", $0) } ?? "-" }.joined(separator: ",")
        var legacyHash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in legacyText.utf8 { legacyHash = (legacyHash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        assert(old.fingerprint == String(legacyHash, radix: 36), "tone-only edits keep their render cache names")
        var sharp = old
        sharp.sharpening = 40
        assert(sharp.fingerprint != old.fingerprint, "detail changes the render fingerprint")

        // a step from dark to light gray: sharpening overshoots on both sides of the edge
        let step = image { x, _ in x < 32 ? (0.3, 0.3, 0.3) : (0.7, 0.7, 0.7) }
        var s = DevelopSettings()
        let plain = develop(step, s)
        s.sharpening = 150
        s.sharpenRadius = 2
        let sharpened = develop(step, s)
        assert(pixel(sharpened, 30, 32).g + 4 < pixel(plain, 30, 32).g
               && pixel(sharpened, 33, 32).g > pixel(plain, 33, 32).g + 4,
               "sharpening darkens the dark side of an edge and lightens the light side")

        // gray with pixel noise
        var seed: UInt64 = 42
        func noise() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 33) / Double(1 << 31) - 0.5
        }
        let grainy = image { _, _ in let n = noise() * 0.16; return (0.5 + n, 0.5 + n, 0.5 + n) }
        let blotchy = image { _, _ in let n = noise() * 0.2; return (0.5 + n, 0.5, 0.5 - n) }
        let grainBase = spread(develop(grainy, .neutral))
        s = DevelopSettings(); s.luminanceNoise = 100
        assert(spread(develop(grainy, s)).luma < grainBase.luma * 0.7, "luminance noise reduction smooths grain")
        s = DevelopSettings(); s.sharpening = 120
        let sharpenedGrain = spread(develop(grainy, s)).luma
        s.sharpenMasking = 90
        assert(sharpenedGrain > grainBase.luma && spread(develop(grainy, s)).luma < sharpenedGrain,
               "masking keeps sharpening off fine noise")
        let colorBase = spread(develop(blotchy, .neutral))
        s = DevelopSettings(); s.colorNoise = 100
        let calmed = develop(blotchy, s)
        assert(spread(calmed).chroma < colorBase.chroma * 0.6, "color noise reduction removes color speckle")
        assert(abs(luma(mean((0.5, 0.5, 0.5), s)) - 0.5) < 0.02, "color noise reduction leaves brightness alone")

        var source = DevelopSettings()
        source.sharpening = 60; source.sharpenRadius = 1.4; source.sharpenMasking = 30; source.colorNoise = 25
        let carried = DevelopSettings().applying(source, fields: [.sharpening])
        assert(carried.sharpening == 60 && carried.sharpenRadius == 1.4 && carried.sharpenMasking == 30
               && carried.colorNoise == 0, "sharpening travels as one setting, noise reduction as another")
        assert(DevelopField.noiseReduction.isAdjusted(in: source) && !DevelopField.noiseReduction.isAdjusted(in: carried),
               "adjusted detail fields are detected")
    }

    private static func checkToneCurve() {
        // the spline: identity stays put, an S curve bends the right way without overshooting
        assert(abs(ToneCurve.evaluate(ToneCurve.identity, at: 0.37) - 0.37) < 1e-9, "a straight curve changes nothing")
        let s = ToneCurve.mediumContrast
        let samples = stride(from: 0.0, through: 1.0, by: 0.01).map { ToneCurve.evaluate(s, at: $0) }
        assert(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 + 1e-9 } && samples.allSatisfy { (0...1).contains($0) },
               "the curve rises monotonically inside the unit square")
        assert(ToneCurve.evaluate(s, at: 0.25) < 0.25 && ToneCurve.evaluate(s, at: 0.75) > 0.75, "an S curve adds contrast")

        var curve = ToneCurve()
        curve.setPoints(ToneCurve.identity, for: .rgb)
        assert(curve.isLinear && curve.rgb.isEmpty, "a straight line is stored as nothing")
        let old = try! JSONDecoder().decode(DevelopSettings.self, from: Data(#"{"exposure":0.5}"#.utf8))
        assert(old.curve.isLinear, "edits saved before curves load with a straight one")

        // rendering: a darkening composite curve, then a red-only lift
        var settings = DevelopSettings()
        settings.curve.setPoints([CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.3), CurvePoint(x: 1, y: 1)], for: .rgb)
        assert(luma(mean((0.5, 0.5, 0.5), settings)) < 0.4, "the composite curve darkens the midtones")
        settings = DevelopSettings()
        settings.curve.setPoints([CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.7), CurvePoint(x: 1, y: 1)], for: .red)
        let lifted = mean((0.5, 0.5, 0.5), settings)
        assert(lifted.r > 0.6 && abs(lifted.g - 0.5) < 0.03 && abs(lifted.b - 0.5) < 0.03, "a channel curve moves only its channel")

        let carried = DevelopSettings().applying(settings, fields: [.toneCurve])
        assert(carried.curve == settings.curve && carried.fingerprint != DevelopSettings().fingerprint,
               "the curve travels as one setting and changes the fingerprint")
    }

    private static func checkColorMixer() {
        let red = (0.8, 0.15, 0.15), blue = (0.15, 0.25, 0.85), gray = (0.5, 0.5, 0.5)
        var s = DevelopSettings()
        s.mixer.saturation[ColorMixer.Band.red.rawValue] = -100
        let grayed = mean(red, s), untouched = mean(blue, s)
        assert(abs(grayed.r - grayed.g) < 0.05 && abs(grayed.g - grayed.b) < 0.05, "-100 red saturation turns red gray")
        assert(untouched.b > untouched.r + 0.4, "and leaves blue alone")
        let neutral = mean(gray, s)
        assert(abs(neutral.r - 0.5) < 0.02 && abs(neutral.b - 0.5) < 0.02, "grays are never touched")

        s = DevelopSettings()
        s.mixer.luminance[ColorMixer.Band.blue.rawValue] = -100
        assert(luma(mean(blue, s)) < luma(mean(blue, .neutral)) - 0.03, "lowering blue luminance darkens blue")
        s = DevelopSettings()
        s.mixer.hue[ColorMixer.Band.blue.rawValue] = 100
        let shifted = mean(blue, s), original = mean(blue, .neutral)
        assert(shifted.r > original.r + 0.05, "a positive blue hue shift turns blue toward purple")

        let old = try! JSONDecoder().decode(DevelopSettings.self, from: Data(#"{"mixer":{"hue":[1,2]}}"#.utf8))
        assert(old.mixer.isNeutral, "a malformed mixer loads neutral")
        let carried = DevelopSettings().applying(s, fields: [.colorMixer])
        assert(carried.mixer == s.mixer && carried.fingerprint != DevelopSettings().fingerprint,
               "the mixer travels as one setting and changes the fingerprint")
    }

    private static func checkColorGrading() {
        let dark = (0.15, 0.15, 0.15), light = (0.85, 0.85, 0.85)
        var s = DevelopSettings()
        s.grading.shadows = ColorGrading.Grade(hue: 30, saturation: 100, luminance: 0)     // orange shadows
        s.grading.highlights = ColorGrading.Grade(hue: 220, saturation: 100, luminance: 0) // blue highlights
        let warmShadows = mean(dark, s), coolHighlights = mean(light, s)
        assert(warmShadows.r > warmShadows.b + 0.05 && coolHighlights.b > coolHighlights.r + 0.05,
               "shadow and highlight tints land in their own tones")
        assert(abs(luma(warmShadows) - luma(mean(dark, .neutral))) < 0.04, "a tint colors without brightening")

        s = DevelopSettings()
        s.grading.midtones = ColorGrading.Grade(hue: 120, saturation: 100, luminance: 0)
        let greenMid = mean((0.5, 0.5, 0.5), s), greenDark = mean((0.03, 0.03, 0.03), s)
        assert(greenMid.g > greenMid.r + 0.05 && greenDark.g - greenDark.r < greenMid.g - greenMid.r,
               "midtones tint the middle more than the ends")

        s = DevelopSettings()
        s.grading.global.luminance = 100
        assert(luma(mean((0.4, 0.4, 0.4), s)) > 0.45, "global luminance brightens everything")
        s = DevelopSettings()
        s.grading.shadows.hue = 200
        s.grading.blending = 80
        assert(s.grading.isNeutral && s.fingerprint == DevelopSettings().fingerprint,
               "a hue without saturation, or blending alone, changes nothing")

        var source = DevelopSettings()
        source.grading.highlights = ColorGrading.Grade(hue: 45, saturation: 20, luminance: 5)
        let carried = DevelopSettings().applying(source, fields: [.colorGrading])
        assert(carried.grading == source.grading, "color grading travels as one setting")
    }

    private static func checkLocalAdjustments() {
        let gray = image { _, _ in (0.4, 0.4, 0.4) }
        func luma(_ image: CGImage, _ x: Int, _ y: Int) -> Double {
            let p = pixel(image, x, y)
            return 0.3 * Double(p.r) + 0.59 * Double(p.g) + 0.11 * Double(p.b)
        }
        let base = luma(develop(gray, .neutral), 32, 32)

        var s = DevelopSettings()
        var radial = LocalAdjustment(kind: .radial)
        radial.center = CGPoint(x: 0.25, y: 0.25)
        radial.radiusX = 0.15; radial.radiusY = 0.15; radial.feather = 20
        radial.exposure = 1.5
        s.masks = [radial]
        var out = develop(gray, s)
        assert(luma(out, 16, 16) > base + 30 && abs(luma(out, 48, 48) - base) < 2,
               "a radial gradient brightens inside and leaves the rest alone")
        s.masks[0].inverted = true
        out = develop(gray, s)
        assert(abs(luma(out, 16, 16) - base) < 2 && luma(out, 48, 48) > base + 30, "an inverted gradient works outside")

        var linear = LocalAdjustment(kind: .linear)
        linear.start = CGPoint(x: 0.5, y: 0); linear.end = CGPoint(x: 0.5, y: 0.5)
        linear.exposure = -1.5
        s.masks = [linear]
        out = develop(gray, s)
        assert(luma(out, 32, 2) < base - 30 && luma(out, 32, 16) < base - 5 && abs(luma(out, 32, 56) - base) < 2,
               "a linear gradient fades from full effect at its start to none past its end")

        s.masks = [linear.withoutAdjustments]
        assert(!s.masks[0].hasEffect && abs(luma(develop(gray, s), 32, 2) - base) < 2, "a mask without adjustments changes nothing")
        var warm = LocalAdjustment(kind: .radial)
        warm.radiusX = 1; warm.radiusY = 1; warm.temperature = 60; warm.saturation = 20
        s.masks = [warm]
        let warmed = pixel(develop(gray, s), 32, 32)
        assert(Int(warmed.r) > Int(warmed.b) + 10, "local temperature warms")

        // masks live on the source photo: after turning, mirroring, straightening and
        // cropping, the effect lands where the overlay maps the mask's center
        let wide = CGContext(data: nil, width: 96, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                             space: DevelopRenderer.outputColorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        wide.setFillColor(CGColor(colorSpace: DevelopRenderer.outputColorSpace, components: [0.3, 0.3, 0.3, 1])!)
        wide.fill(CGRect(x: 0, y: 0, width: 96, height: 64))
        s = DevelopSettings()
        s.rotation = 1; s.flipped = true; s.straighten = 8
        s.crop = DevelopCrop(x: 0.1, y: 0.15, width: 0.8, height: 0.7)
        var spot = LocalAdjustment(kind: .radial)
        spot.center = CGPoint(x: 0.35, y: 0.6)
        spot.radiusX = 0.08; spot.radiusY = 0.08; spot.feather = 10; spot.exposure = 2.5
        s.masks = [spot]
        let placed = develop(wide.makeImage()!, s)
        var data = [UInt8](repeating: 0, count: placed.width * placed.height * 4)
        CGContext(data: &data, width: placed.width, height: placed.height, bitsPerComponent: 8,
                  bytesPerRow: placed.width * 4, space: DevelopRenderer.outputColorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            .draw(placed, in: CGRect(x: 0, y: 0, width: placed.width, height: placed.height))
        var sumX = 0.0, sumY = 0.0, count = 0.0
        for y in 0..<placed.height {
            for x in 0..<placed.width where data[(y * placed.width + x) * 4 + 1] > 125 {   // ~77 around, ~170 inside
                sumX += Double(x) + 0.5; sumY += Double(y) + 0.5; count += 1
            }
        }
        let expected = DevelopGeometry.finishedPoint(fromSource: spot.center, settings: s,
                                                     sourceSize: CGSize(width: 96, height: 64))
        assert(count > 10 && abs(sumX / count - expected.x * Double(placed.width)) < 2
               && abs(sumY / count - expected.y * Double(placed.height)) < 2,
               "a mask follows the photo through rotation, mirroring, straightening and crop")
        for point in [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.7, y: 0.9)] {
            for rotation in 0..<4 {
                var t = s; t.rotation = rotation; t.flipped = rotation % 2 == 0
                let size = CGSize(width: 96, height: 64)
                let back = DevelopGeometry.sourcePoint(
                    fromFinished: DevelopGeometry.finishedPoint(fromSource: point, settings: t, sourceSize: size),
                    settings: t, sourceSize: size)
                assert(abs(back.x - point.x) < 1e-9 && abs(back.y - point.y) < 1e-9, "source and finished points round-trip")
            }
        }

        // brush: a stroke across the middle, part of it erased again
        var brush = LocalAdjustment(kind: .brush)
        brush.exposure = 1.5
        var stroke = BrushStroke()
        stroke.radius = 0.08; stroke.feather = 20
        stroke.append(CGPoint(x: 0.1, y: 0.5)); stroke.append(CGPoint(x: 0.9, y: 0.5))
        brush.strokes = [stroke]
        s = DevelopSettings(); s.masks = [brush]
        out = develop(gray, s)
        assert(luma(out, 32, 32) > base + 30 && luma(out, 12, 32) > base + 30 && abs(luma(out, 32, 8) - base) < 2,
               "a brush stroke adjusts where it was painted and nowhere else")
        var eraser = BrushStroke()
        eraser.radius = 0.1; eraser.feather = 0; eraser.erase = true
        eraser.append(CGPoint(x: 0.5, y: 0.2)); eraser.append(CGPoint(x: 0.5, y: 0.8))
        s.masks[0].strokes.append(eraser)
        out = develop(gray, s)
        assert(abs(luma(out, 32, 32) - base) < 3 && luma(out, 12, 32) > base + 30, "erasing takes the adjustment back")
        s.masks[0].strokes = [stroke]
        s.masks[0].strokes[0].density = 40
        let light = luma(develop(gray, s), 32, 32)
        assert(light > base + 5 && light < luma(out, 12, 32) - 10, "a lower density paints a weaker effect")
        s.masks[0].strokes[0].density = 100
        let tinted = pixel(develop(gray, s, overlayMask: brush.id), 32, 32)
        let untinted = pixel(develop(gray, s, overlayMask: brush.id), 32, 8)
        assert(Int(tinted.r) > Int(tinted.b) + 40 && abs(Int(untinted.r) - Int(untinted.b)) < 4,
               "the overlay tints the selected mask's coverage red")
        // sky: a blue gradient over grass is found, darkened, and the grass left alone; a plain
        // pale wall is not sky
        let landscape = CGContext(data: nil, width: 240, height: 160, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: DevelopRenderer.outputColorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for y in 0..<160 {
            // CGContext rows count from the bottom: grass below 90, sky above
            let t = Double(y) / 160
            let color: [CGFloat] = y < 90 ? [0.22 + 0.1 * CGFloat((y * 7) % 3) / 3, 0.45, 0.18, 1]
                                          : [0.62 - 0.3 * CGFloat(t), 0.75 - 0.15 * CGFloat(t), 0.97, 1]
            landscape.setFillColor(CGColor(colorSpace: DevelopRenderer.outputColorSpace, components: color)!)
            for x in stride(from: 0, to: 240, by: 3) where y >= 90 || (x + y) % 2 == 0 {
                landscape.fill(CGRect(x: x, y: y, width: y < 90 ? 2 : 3, height: 1))
            }
        }
        let landscapeURL = FileManager.default.temporaryDirectory.appendingPathComponent("pc-sky-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: landscapeURL) }
        let landscapeFile = CGImageDestinationCreateWithURL(landscapeURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(landscapeFile, landscape.makeImage()!, nil)
        CGImageDestinationFinalize(landscapeFile)
        let foundSky = SemanticMasks.mask(.sky, url: landscapeURL, isRaw: false)
        assert(foundSky.map { (0.3...0.5).contains($0.coverage) && $0.centroid.y < 0.3 } == true,
               "the sky is found above the grass")
        var skyEdit = DevelopSettings()
        var skyMask = LocalAdjustment(kind: .sky)
        skyMask.exposure = -1.5
        skyEdit.masks = [skyMask]
        let skyRender = DevelopRenderer.render(DevelopRenderer.Source(url: landscapeURL, isRaw: false, maxPixel: nil)!
            .image(skyEdit)!)!
        let plainRender = DevelopRenderer.render(DevelopRenderer.Source(url: landscapeURL, isRaw: false, maxPixel: nil)!
            .image(.neutral)!)!
        assert(luma(skyRender, 120, 20) < luma(plainRender, 120, 20) - 20
               && abs(luma(skyRender, 120, 140) - luma(plainRender, 120, 140)) < 3,
               "a sky mask darkens the sky and leaves the ground alone")
        let wall = image { x, y in (0.86 + 0.02 * Double((x / 8 + y / 8) % 2), 0.85, 0.83) }
        let wallURL = FileManager.default.temporaryDirectory.appendingPathComponent("pc-wall-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: wallURL) }
        let wallFile = CGImageDestinationCreateWithURL(wallURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(wallFile, wall, nil)
        CGImageDestinationFinalize(wallFile)
        assert(SemanticMasks.mask(.sky, url: wallURL, isRaw: false) == nil, "a pale wall is not sky")
        if let subject = SemanticMasks.mask(.subject, url: landscapeURL, isRaw: false) {
            assert(subject.coverage > 0 && subject.coverage <= 1, "a subject mask covers part of the photo")
        }

        let halfStroke = try! JSONDecoder().decode(BrushStroke.self, from: Data(#"{"points":[0.1,0.2,0.3]}"#.utf8))
        assert(halfStroke.pointCount == 1 && halfStroke.radius == 0.05 && !halfStroke.erase,
               "a stroke with a dangling coordinate loads without it")
        var rounded = BrushStroke()
        rounded.append(CGPoint(x: 0.123456789, y: 0.5))
        assert(rounded.points == [0.1235, 0.5], "stroke points are stored rounded")

        let old = try! JSONDecoder().decode(DevelopSettings.self, from: Data(#"{"exposure":0.5}"#.utf8))
        assert(old.masks.isEmpty && old.fingerprint == { var e = DevelopSettings(); e.exposure = 0.5; return e }().fingerprint,
               "edits saved before masks load without any and keep their cache names")
        let partial = try! JSONDecoder().decode(LocalAdjustment.self, from: Data(#"{"kind":"linear","exposure":1}"#.utf8))
        assert(partial.kind == .linear && partial.exposure == 1 && partial.feather == 50, "a mask missing fields loads with defaults")
        let saved = try! JSONDecoder().decode(DevelopSettings.self, from: JSONEncoder().encode(s))
        assert(saved == s, "masks round-trip through storage")
        let carried = DevelopSettings().applying(s, fields: [.masks])
        assert(carried.masks == s.masks && carried.rotation == 0, "masks travel as one setting")
        assert(!DevelopField.defaultCopy.contains(.masks), "copy leaves masks behind unless asked")
    }

    private static func checkPresence() {
        // a fine mid-gray checkerboard: clarity and texture raise or lower its local contrast
        let checker = image { x, y in (x / 2 + y / 2) % 2 == 0 ? (0.4, 0.4, 0.4) : (0.6, 0.6, 0.6) }
        let base = spread(develop(checker, .neutral)).luma
        for keyPath in [\DevelopSettings.clarity, \DevelopSettings.texture] {
            var s = DevelopSettings()
            s[keyPath: keyPath] = 100
            let more = spread(develop(checker, s)).luma
            s[keyPath: keyPath] = -100
            let less = spread(develop(checker, s)).luma
            assert(more > base * 1.1 && less < base * 0.9, "clarity and texture add and remove local contrast")
        }

        // a hazy scene: low contrast lifted toward light gray, with some variation
        let hazy = image { x, y in let v = 0.58 + 0.12 * Double((x * 7 + y * 3) % 10) / 10; return (v, v, v * 0.98) }
        let hazyBase = develop(hazy, .neutral)
        var s = DevelopSettings(); s.dehaze = 80
        let cleared = develop(hazy, s)
        assert(averageLuma(cleared) < averageLuma(hazyBase) - 10 && spread(cleared).luma > spread(hazyBase).luma * 1.3,
               "dehaze lifts the veil: darker and more contrasty")
        s.dehaze = -80
        let fogged = develop(hazy, s)
        assert(spread(fogged).luma < spread(hazyBase).luma * 0.8, "negative dehaze adds haze")

        var source = DevelopSettings()
        source.texture = 20; source.clarity = 35; source.dehaze = 15
        let carried = DevelopSettings().applying(source, fields: [.clarity])
        assert(carried.clarity == 35 && carried.texture == 0 && carried.dehaze == 0, "presence settings travel one by one")
        assert(source.hasPresence && DevelopSettings().fingerprint != carried.fingerprint, "presence changes the fingerprint")
    }

    private static func checkLensCorrections() {
        // a white vertical line right of center on black: straightening barrel distortion
        // stretches the edges outward, so the line lands further right
        // white lines 8 and 24 px right of center on black. Straightening barrel distortion
        // stretches the edges more than the middle, so the outer line moves out proportionally further.
        let lines = image { x, _ in x == 40 || x == 56 ? (1, 1, 1) : (0, 0, 0) }
        func centroid(_ image: CGImage, _ columns: Range<Int>) -> Double {
            let weights = columns.map { Double(pixel(image, $0, 32).g) }
            return zip(columns, weights).map { Double($0) * $1 }.reduce(0, +) / max(weights.reduce(0, +), 1)
        }
        func spreadRatio(_ settings: DevelopSettings) -> Double {
            let rendered = develop(lines, settings)
            return (centroid(rendered, 48..<64) - 31.5) / (centroid(rendered, 34..<48) - 31.5)
        }
        var s = DevelopSettings()
        let neutralRatio = spreadRatio(s)
        s.distortion = 100
        assert(spreadRatio(s) > neutralRatio + 0.05, "positive distortion stretches the edges more than the middle")
        s.distortion = -100
        assert(spreadRatio(s) < neutralRatio - 0.05, "negative distortion compresses them")

        let gray = image { _, _ in (0.4, 0.4, 0.4) }
        s = DevelopSettings(); s.lensVignette = 100
        let lifted = develop(gray, s), plain = develop(gray, .neutral)
        assert(pixel(lifted, 1, 1).g > pixel(plain, 1, 1).g + 20, "lens vignetting correction brightens the corners")
        assert(abs(Int(pixel(lifted, 32, 32).g) - Int(pixel(plain, 32, 32).g)) <= 2, "and leaves the center alone")
        s.lensVignetteMidpoint = 100
        assert(pixel(develop(gray, s), 12, 12).g < pixel(lifted, 12, 12).g, "a higher midpoint confines it to the corners")

        var source = DevelopSettings()
        source.distortion = 30; source.lensVignette = 45; source.lensVignetteMidpoint = 20
        let carried = DevelopSettings().applying(source, fields: [.lensCorrections])
        assert(carried.distortion == 30 && carried.lensVignette == 45 && carried.lensVignetteMidpoint == 20,
               "lens corrections travel together")
        assert(DevelopSettings().fingerprint != carried.fingerprint, "lens corrections change the fingerprint")
    }

    /// Mean luma over every pixel (0…255): a 1-pixel downsample only samples a noisy image.
    private static func averageLuma(_ image: CGImage) -> Double {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: DevelopRenderer.outputColorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let total = stride(from: 0, to: data.count, by: 4).reduce(0.0) {
            $0 + 0.3 * Double(data[$1]) + 0.59 * Double(data[$1 + 1]) + 0.11 * Double(data[$1 + 2])
        }
        return total / Double(image.width * image.height)
    }

    private static func checkEffects() {
        let gray = image { _, _ in (0.5, 0.5, 0.5) }
        let plain = develop(gray, .neutral)
        var s = DevelopSettings(); s.vignette = -100
        let dark = develop(gray, s)
        assert(pixel(dark, 1, 1).g + 40 < pixel(plain, 1, 1).g, "a negative vignette darkens the corners")
        assert(abs(Int(pixel(dark, 32, 32).g) - Int(pixel(plain, 32, 32).g)) <= 2, "and leaves the center alone")
        s.vignette = 100
        assert(pixel(develop(gray, s), 1, 1).g > pixel(plain, 1, 1).g + 20, "a positive vignette lightens them")
        s.vignette = -100; s.vignetteMidpoint = 100
        assert(pixel(develop(gray, s), 10, 10).g > pixel(dark, 10, 10).g, "a higher midpoint keeps it nearer the corners")

        // post-crop: the vignette follows the crop, darkening the corners of what is kept
        s = DevelopSettings(); s.vignette = -100
        s.crop = DevelopCrop(x: 0, y: 0, width: 0.5, height: 0.5)
        let cropped = develop(gray, s)
        assert(cropped.width == 32 && pixel(cropped, 31, 31).g + 40 < pixel(plain, 31, 31).g,
               "the vignette darkens the cropped frame's corners")

        s = DevelopSettings(); s.grain = 60
        let grainy = develop(gray, s)
        assert(spread(grainy).luma > spread(plain).luma + 2, "grain adds texture")
        assert(pixel(develop(gray, s), 20, 20) == pixel(grainy, 20, 20), "the same photo always gets the same grain")
        assert(abs(averageLuma(grainy) - averageLuma(plain)) < 2, "grain doesn't shift brightness")

        var source = DevelopSettings()
        source.vignette = -30; source.vignetteFeather = 80; source.grain = 20; source.grainSize = 60
        let carried = DevelopSettings().applying(source, fields: [.vignette])
        assert(carried.vignette == -30 && carried.vignetteFeather == 80 && carried.grain == 0,
               "the vignette and grain travel separately")
        assert(!DevelopSettings().hasEffects && source.hasEffects, "effects are detected")
    }

    /// Writes `image` to a temporary PNG, as a photo on disk for the automatic adjustments.
    private static func pngFile(_ image: CGImage) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pc-auto-\(UUID().uuidString).png")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return url
    }

    private static func checkAutoAdjustments() {
        // eyedropper: a warm gray becomes neutral where it was picked
        let warm = image { _, _ in (0.56, 0.5, 0.43) }
        let warmFile = pngFile(warm)
        defer { try? FileManager.default.removeItem(at: warmFile) }
        let balance = DevelopAuto.whiteBalance(url: warmFile, isRaw: false, settings: .neutral, point: CGPoint(x: 0.5, y: 0.5))
        var s = DevelopSettings()
        s.temperature = balance?.temperature
        s.tint = balance?.tint
        let picked = pixel(develop(warm, s), 32, 32)
        assert(balance != nil && abs(Int(picked.r) - Int(picked.b)) <= 6
               && abs(Int(picked.g) - (Int(picked.r) + Int(picked.b)) / 2) <= 6,
               "the eyedropper makes the picked color gray")
        let black = pngFile(image { _, _ in (0, 0, 0) })
        defer { try? FileManager.default.removeItem(at: black) }
        assert(DevelopAuto.whiteBalance(url: black, isRaw: false, settings: .neutral, point: CGPoint(x: 0.5, y: 0.5)) == nil,
               "a black point can't be judged")

        // auto tone: dark photos brighten, bright ones darken, a full-range one barely moves
        func gradient(_ from: Double, _ to: Double) -> URL {
            pngFile(image { x, _ in let v = from + (to - from) * Double(x) / 63; return (v, v, v) })
        }
        let dark = gradient(0.03, 0.3), bright = gradient(0.7, 0.97), full = gradient(0.02, 0.98)
        defer { for url in [dark, bright, full] { try? FileManager.default.removeItem(at: url) } }
        var kept = DevelopSettings()
        kept.saturation = -40
        kept.exposure = 1.5
        let lifted = DevelopAuto.tone(url: dark, isRaw: false, settings: kept)
        assert((lifted?.exposure ?? 0) > 0.4 && lifted?.saturation == -40, "auto tone brightens a dark photo and keeps color edits")
        assert((DevelopAuto.tone(url: bright, isRaw: false, settings: .neutral)?.exposure ?? 0) < -0.2,
               "auto tone darkens a bright photo")
        assert(abs(DevelopAuto.tone(url: full, isRaw: false, settings: .neutral)?.exposure ?? 9) < 0.35,
               "auto tone leaves a well-exposed photo nearly alone")
    }

    private static func checkHistogram() {
        let dark = DevelopRenderer.histogram(of: solid((0.1, 0.1, 0.1)))!
        let total = dark.red.reduce(0, +)
        assert(abs(total - 1) < 0.01, "histogram bins are fractions of all pixels")
        // encoded value 0.1 lands in bin 6 of 64 — display values, not linear light (bin 0)
        assert(dark.green.firstIndex(where: { $0 > 0.5 }) == 6, "histogram counts display values")
        assert(dark.shadowClipping < DevelopHistogram.clippingWarning, "mid-dark tones don't clip")

        let white = DevelopRenderer.histogram(of: solid((1, 1, 1)))!
        assert(white.highlightClipping > 0.99, "pure white reports highlight clipping")
        let warm = DevelopRenderer.histogram(of: solid((0.9, 0.5, 0.1)))!
        let peak = { (bins: [Double]) in bins.firstIndex(of: bins.max()!)! }
        assert(peak(warm.red) > peak(warm.green) && peak(warm.green) > peak(warm.blue), "channels are kept apart")
    }

    private static func checkGeometryMath() {
        let frame = CGSize(width: 600, height: 400)
        assert(DevelopGeometry.inscribed(aspect: 1.5, angle: 0, frame: frame) == .full, "level photos keep the whole frame")
        assert(!DevelopGeometry.fits(.full, angle: 8, frame: frame), "a straightened photo has empty corners")
        let auto = DevelopGeometry.inscribed(aspect: 1.5, angle: 8, frame: frame)
        assert(DevelopGeometry.fits(auto, angle: 8, frame: frame) && auto.width < 1
               && abs(auto.width * 600 / (auto.height * 400) - 1.5) < 0.001, "auto crop keeps the shape and fits")
        let grown = DevelopCrop(x: auto.x - 0.001, y: auto.y, width: auto.width + 0.002, height: auto.height)
        assert(!DevelopGeometry.fits(grown, angle: 8, frame: frame), "auto crop is the largest that fits")

        var s = DevelopSettings()
        s.crop = DevelopCrop(x: 0.1, y: 0.2, width: 0.5, height: 0.3)
        s.straighten = 3
        var turned = s
        for _ in 0..<4 { turned = DevelopGeometry.rotated(turned, clockwise: true) }
        assert(turned.rotation == 0 && abs(turned.crop!.x - 0.1) < 1e-9 && abs(turned.crop!.width - 0.5) < 1e-9,
               "four quarter turns come back around")
        let once = DevelopGeometry.rotated(s, clockwise: true)
        assert(once.rotation == 1 && abs(once.crop!.x - 0.5) < 1e-9 && abs(once.crop!.y - 0.1) < 1e-9
               && abs(once.crop!.width - 0.3) < 1e-9, "a quarter turn carries the crop along")
        assert(same(DevelopGeometry.rotated(once, clockwise: false), s), "turning back undoes a turn")
        let mirrored = DevelopGeometry.mirrored(s)
        assert(mirrored.flipped && mirrored.straighten == -3 && abs(mirrored.crop!.x - 0.4) < 1e-9,
               "mirroring flips the crop and the straighten angle")
        assert(same(DevelopGeometry.mirrored(mirrored), s), "mirroring twice is a no-op")
        assert(DevelopGeometry.rotated(mirrored, clockwise: true).rotation == 3,
               "a mirrored photo's clockwise turn runs the other way before the mirror")

        let resized = DevelopGeometry.resize(.full, left: false, right: true, top: false, bottom: true,
                                             dx: -0.4, dy: -0.1, ratio: 1, angle: 0, frame: frame)
        assert(abs(resized.width * 600 - resized.height * 400) < 0.5 && resized.x == 0 && resized.y == 0,
               "a locked corner drag keeps the shape and the opposite corner")
        let edge = DevelopGeometry.resize(.full, left: true, right: false, top: false, bottom: false,
                                          dx: 0.3, dy: 0, ratio: nil, angle: 0, frame: frame)
        assert(abs(edge.x - 0.3) < 1e-9 && edge.height == 1, "a free edge drag moves only that edge")
        let moved = DevelopGeometry.move(auto, dx: 0.5, dy: 0.5, angle: 8, frame: frame)
        assert(DevelopGeometry.fits(moved, angle: 8, frame: frame), "a moved crop stays inside the straightened photo")

        let level = DevelopGeometry.straightenLevelling(from: .zero, to: CGPoint(x: 100, y: 10), current: 0)!
        assert(abs(level + 5.7) < 0.05, "a line falling to the right turns the photo counterclockwise")
        let plumb = DevelopGeometry.straightenLevelling(from: .zero, to: CGPoint(x: -5, y: 100), current: 1)!
        assert(abs(plumb - (1 - 2.9)) < 0.05, "a near-vertical line is made plumb")

        var geometry = DevelopSettings()
        let before = geometry.fingerprint
        geometry.rotation = 1
        assert(geometry.fingerprint != before && DevelopSettings().fingerprint == before,
               "geometry changes the render fingerprint")
        let legacy = Data(#"{"exposure":0.5,"contrast":0,"highlights":0,"shadows":0,"whites":0,"blacks":0,"vibrance":0,"saturation":0}"#.utf8)
        var expected = DevelopSettings()
        expected.exposure = 0.5
        assert((try? JSONDecoder().decode(DevelopSettings.self, from: legacy)) == expected,
               "settings saved before geometry existed still load")
    }

    /// Equal apart from floating-point noise in the crop.
    private static func same(_ a: DevelopSettings, _ b: DevelopSettings) -> Bool {
        var a2 = a, b2 = b
        a2.crop = nil
        b2.crop = nil
        guard a2 == b2, let ca = a.crop, let cb = b.crop else { return a2 == b2 && a.crop == b.crop }
        return [ca.x - cb.x, ca.y - cb.y, ca.width - cb.width, ca.height - cb.height].allSatisfy { abs($0) < 1e-9 }
    }

    private static func checkGeometryRendering() {
        var s = DevelopSettings()
        s.rotation = 1
        let turned = develop(split(), s)
        assert(turned.width == 32 && turned.height == 64, "a quarter turn swaps width and height")
        assert(isRed(pixel(turned, 16, 4)) && isBlue(pixel(turned, 16, 60)), "clockwise brings the left edge to the top")

        s = DevelopSettings(); s.flipped = true
        let mirrored = develop(split(), s)
        assert(isBlue(pixel(mirrored, 4, 16)) && isRed(pixel(mirrored, 60, 16)), "mirroring swaps left and right")

        s = DevelopSettings(); s.crop = DevelopCrop(x: 0.5, y: 0, width: 0.5, height: 1)
        let cropped = develop(split(), s)
        assert(cropped.width == 32 && cropped.height == 32 && isBlue(pixel(cropped, 2, 2))
               && isBlue(pixel(cropped, 29, 29)), "cropping keeps only the chosen part")

        s = DevelopSettings(); s.straighten = 10
        let straight = develop(split(), s)
        assert(straight.width < 64 && straight.height < 32 && abs(Double(straight.width) / Double(straight.height) - 2) < 0.15,
               "straightening crops to the photo's shape")
        let corners = [pixel(straight, 0, 0), pixel(straight, straight.width - 1, straight.height - 1)]
        assert(corners.allSatisfy { $0.a == 255 }, "straightening leaves no empty corners")
        let whole = develop(split(), s, wholeFrame: true)
        assert(whole.width == 64 && whole.height == 32 && pixel(whole, 0, 0).a == 0,
               "the crop tool sees the whole frame with empty corners")

        // sky over sea, the horizon rising 4° to the right: auto straighten turns it clockwise
        let context = CGContext(data: nil, width: 800, height: 500, bitsPerComponent: 8, bytesPerRow: 0,
                                space: DevelopRenderer.outputColorSpace,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: DevelopRenderer.outputColorSpace, components: [0.62, 0.78, 0.95, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 500))
        let rise = tan(4 * Double.pi / 180) * 400
        context.setFillColor(CGColor(colorSpace: DevelopRenderer.outputColorSpace, components: [0.08, 0.2, 0.35, 1])!)
        context.addLines(between: [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 250 - rise),
                                   CGPoint(x: 800, y: 250 + rise), CGPoint(x: 800, y: 0)])
        context.fillPath()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pc-horizon-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        let horizon = DevelopRenderer.horizonAngle(url: url, isRaw: false, settings: DevelopSettings())
        assert(horizon.map { (3...5).contains($0) } == true, "auto straighten levels a horizon rising to the right")
    }

    private static func checkPersistence() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pc-develop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let store = try CatalogStore(packageURL: directory.appendingPathComponent("Develop.photolibrary"))
            var edit = DevelopSettings()
            edit.exposure = 0.7
            edit.temperature = 4800
            try store.saveDevelopSettings(["a": edit, "b": edit])
            let saved = try store.loadDevelopSettings()
            assert(saved == ["a": edit, "b": edit], "adjustments round-trip")
            try store.saveDevelopSettings(["a": .neutral])
            let cleared = try store.loadDevelopSettings()
            assert(cleared == ["b": edit], "neutral settings delete the stored edit")
        } catch {
            preconditionFailure("develop persistence check failed: \(error)")
        }
    }

    private static func checkTransferRules() {
        var source = DevelopSettings()
        source.exposure = 0.8
        source.contrast = 20
        source.temperature = 4200
        source.rotation = 1
        var target = DevelopSettings()
        target.shadows = 30
        target.crop = DevelopCrop(x: 0.1, y: 0.2, width: 0.5, height: 0.3)

        let toned = target.applying(source, fields: [.exposure])
        assert(toned.exposure == 0.8 && toned.contrast == 0 && toned.shadows == 30,
               "only the chosen settings travel; the rest of the photo's edit stays")
        let turned = target.applying(source, fields: [.orientation])
        assert(turned.rotation == 1 && abs(turned.crop!.x - 0.5) < 1e-9 && abs(turned.crop!.y - 0.1) < 1e-9,
               "taking a rotation turns the photo's own crop with it")

        let transfer = DevelopTransfer(settings: source, fields: [.whiteBalance, .exposure], sourceIsRaw: true)
        assert(transfer.applied(to: target, targetIsRaw: true).temperature == 4200,
               "white balance carries between RAW files")
        let onJPEG = transfer.applied(to: target, targetIsRaw: false)
        assert(onJPEG.temperature == nil && onJPEG.exposure == 0.8, "RAW Kelvin never lands on a JPEG")

        assert(DevelopField.exposure.isAdjusted(in: source) && !DevelopField.shadows.isAdjusted(in: source)
               && DevelopField.orientation.isAdjusted(in: source), "adjusted fields are detected")
        for preset in DevelopPreset.builtIns {
            let untouched = Set(DevelopField.allCases).subtracting(preset.transfer.fields)
            assert(untouched.allSatisfy { !$0.isAdjusted(in: preset.transfer.settings) },
                   "built-in preset \(preset.name) only sets the fields it carries")
        }
    }

    @MainActor
    private static func checkCopyPasteAndPresets() {
        let base = DemoData.assets.filter(\.isRaw)
        func local(_ asset: Asset, _ name: String) -> Asset {
            var copy = asset
            copy.localPath = "/tmp/pc-develop-transfer/\(name)"
            copy.status = .ready
            copy.isDemo = false
            return copy
        }
        let a = local(base[0], "A.CR3"), b = local(base[1], "B.CR3"), c = local(base[2], "C.CR3")
        let app = AppState.selfCheckFixture()
        app.assets = [a, b, c]
        app.duplicateGroupsCache = []
        app.select(Selection(type: .lib, id: "all", name: "Transfer check"))
        let savedPresets = app.developPresets
        let savedFields = app.developTransferFields
        defer {
            app.developPresets = savedPresets
            app.developTransferFields = savedFields
        }

        var edit = DevelopSettings()
        edit.exposure = 0.6
        edit.vibrance = 25
        edit.crop = DevelopCrop(x: 0, y: 0, width: 0.5, height: 0.5)
        app.commitDevelop([a.id: edit], undoName: "调整")
        app.setPrimary(a.id)
        app.copyDevelopSettings(fields: DevelopField.defaultCopy)
        app.selectedIds = [b.id, c.id]
        app.primaryId = b.id
        let undo = UndoManager()
        undo.groupsByEvent = false
        app.undoManager = undo
        undo.beginUndoGrouping()
        app.pasteDevelopSettings()
        undo.endUndoGrouping()
        let pasted = app.developSettings[b.id]
        assert(pasted?.exposure == 0.6 && pasted?.vibrance == 25 && pasted?.crop == nil
               && app.developSettings[c.id] == pasted, "paste reaches every selected photo, crop left out")
        undo.undo()
        assert(app.developSettings[b.id] == nil && app.developSettings[c.id] == nil, "one undo takes the paste back")
        app.undoManager = nil

        app.selectedIds = [a.id, b.id, c.id]
        app.primaryId = a.id
        app.syncDevelopSettings(fields: [.exposure])
        assert(app.developSettings[b.id]?.exposure == 0.6 && app.developSettings[b.id]?.vibrance == 0
               && app.developSettings[a.id] == edit, "sync copies the chosen settings from the selected photo")

        app.setPrimary(c.id)
        app.applyDevelopPreset(DevelopPreset.builtIns.first { $0.name == "黑白" }!)
        assert(app.developSettings[c.id]?.saturation == -100 && app.developSettings[c.id]?.exposure == 0.6,
               "a preset changes only its own settings")

        app.setPrimary(a.id)
        app.saveDevelopPreset(name: "  测试预设 ", fields: app.developPresetDefaultFields)
        let preset = app.developPresets.last
        assert(preset?.name == "测试预设" && preset?.transfer.fields == [.exposure, .vibrance],
               "a new preset holds what the photo adjusted, framing aside")
        app.saveDevelopPreset(name: "测试预设", fields: [.exposure])
        assert(app.developPresets.filter { $0.name == "测试预设" }.count == 1, "saving a name again replaces it")
        app.deleteDevelopPreset(preset!.id)
        assert(!app.developPresets.contains { $0.name == "测试预设" }, "presets can be deleted")

        app.selectedIds = [a.id, b.id, c.id]
        app.resetDevelopSelection()
        assert(app.developSettings.isEmpty, "reset returns the selection to as shot")
    }

    @MainActor
    private static func checkEditsAndUndo() {
        let undo = UndoManager()
        undo.groupsByEvent = false
        let app = AppState.selfCheckFixture()
        app.undoManager = undo
        var edit = DevelopSettings()
        edit.exposure = 1.2

        app.updateDevelopDraft(edit, for: "x")
        assert(app.developSettings(for: "x") == edit && app.developSettings["x"] == nil,
               "a drag previews without saving")
        undo.beginUndoGrouping()
        app.commitDevelop(["x": edit], undoName: "调整曝光度")
        undo.endUndoGrouping()
        assert(app.developSettings["x"] == edit && app.developDraft == nil, "release saves the edit")
        undo.undo()
        assert(app.developSettings["x"] == nil, "undo returns the photo to as shot")
        undo.redo()
        assert(app.developSettings["x"] == edit, "redo reapplies the edit")

        app.view = .grid
        _ = app.handleKey("d", hasCommand: false)
        assert(app.view == .develop, "D opens Develop")
        _ = app.handleKey("\\", hasCommand: false)
        assert(app.developShowsOriginal, "\\ shows the photo before adjustments")

        app.view = .grid
        _ = app.handleKey("r", hasCommand: false)
        assert(app.view == .develop && app.developCropping, "R opens the crop tool from anywhere")
        _ = app.handleKey("escape", hasCommand: false)
        assert(app.view == .develop && !app.developCropping, "Esc closes the crop tool but stays in Develop")
        _ = app.handleKey("r", hasCommand: false)
        app.view = .grid
        assert(!app.developCropping, "leaving Develop closes the crop tool")

        // masks: saved and selected when drawn; in the tool, Delete removes the selected mask
        // and never the photo, and Esc disarms a gradient before it closes the tool
        app.view = .develop
        app.primaryId = "x"
        var mask = LocalAdjustment(kind: .radial)
        mask.exposure = 0.5
        undo.beginUndoGrouping()
        app.addMask(mask, to: "x")
        undo.endUndoGrouping()
        assert(app.developSettings["x"]?.masks.map(\.id) == [mask.id] && app.developSelectedMaskId == mask.id,
               "a new mask is saved and selected")
        app.developMasking = true
        app.developMaskCreation = .linear
        _ = app.handleKey("escape", hasCommand: false)
        assert(app.developMasking && app.developMaskCreation == nil, "Esc first disarms a gradient")
        undo.beginUndoGrouping()
        _ = app.handleKey("delete", hasCommand: false)
        undo.endUndoGrouping()
        assert(app.developSettings["x"]?.masks.isEmpty == true && app.view == .develop, "Delete removes the selected mask")
        undo.undo()
        assert(app.developSettings["x"]?.masks.count == 1, "undo brings the mask back")
        _ = app.handleKey("escape", hasCommand: false)
        assert(!app.developMasking && app.view == .develop, "Esc closes the masking tool")
        app.developMasking = true
        app.developCropping = true
        assert(!app.developMasking, "the crop tool closes the masking tool")
        app.developMasking = true
        assert(!app.developCropping, "the masking tool closes the crop tool")
        _ = app.handleKey("]", hasCommand: false)
        assert(app.developBrush.size == 30, "] enlarges the brush in the masking tool")
        for _ in 0..<30 { _ = app.handleKey("[", hasCommand: false) }
        assert(app.developBrush.size == 1, "[ shrinks the brush, down to its smallest")
        _ = app.handleKey("o", hasCommand: false)
        assert(app.developShowsMaskOverlay, "O shows the mask overlay")
        app.view = .grid
        assert(!app.developMasking, "leaving Develop closes the masking tool")
        assert(!app.handleKey("[", hasCommand: false), "[ does nothing outside the masking tool")
    }
}
