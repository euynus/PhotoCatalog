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
        checkProfiles()
        checkBlackAndWhite()
        checkCalibration()
        checkSoftProofing()
        checkColorGrading()
        checkLocalAdjustments()
        checkSpotRemoval()
        checkPeopleMasks()
        checkLensCorrections()
        checkChromaticAberration()
        checkEffects()
        checkAutoAdjustments()
        checkBoostCurve()
        checkHistogram()
        checkGeometryMath()
        checkGeometryRendering()
        checkPersistence()
        checkTransferRules()
        checkPresetBlend()
        checkPerspective()
        checkRangeMasks()
        MainActor.assumeIsolated {
            checkLUTs()
            checkEditsAndUndo()
            checkCopyPasteAndPresets()
            checkPresetFiles()
            checkSoftProofingState()
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

        // a highlight brighter than white passes through where the mixer doesn't reach
        var mixer = ColorMixer()
        mixer.saturation[ColorMixer.Band.red.rawValue] = -100
        let bright = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
            .applyingFilter("CIExposureAdjust", parameters: ["inputEV": 1])
        func firstRed(_ image: CIImage) -> Float {
            var value = [Float](repeating: 0, count: 4)
            DevelopRenderer.context.render(image, toBitmap: &value, rowBytes: 16,
                                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
            return value[0]
        }
        assert(firstRed(bright) > 1.1 && abs(firstRed(DevelopKernels.colorMixer(bright, mixer)) - firstRed(bright)) < 0.001,
               "the mixer leaves values outside 0…1 it doesn't change alone")

        let old = try! JSONDecoder().decode(DevelopSettings.self, from: Data(#"{"mixer":{"hue":[1,2]}}"#.utf8))
        assert(old.mixer.isNeutral, "a malformed mixer loads neutral")
        let carried = DevelopSettings().applying(s, fields: [.colorMixer])
        assert(carried.mixer == s.mixer && carried.fingerprint != DevelopSettings().fingerprint,
               "the mixer travels as one setting and changes the fingerprint")
    }

    /// Profiles change the photo's base look in the right direction, from nothing at 0%.
    private static func checkProfiles() {
        let dark = (0.25, 0.25, 0.25), light = (0.75, 0.75, 0.75), red = (0.75, 0.3, 0.25), green = (0.3, 0.6, 0.25)
        func with(_ profile: DevelopProfile, amount: Double = 100) -> DevelopSettings {
            var settings = DevelopSettings()
            settings.profile = profile.stored
            settings.profileAmount = amount
            return settings
        }
        func chroma(_ c: (r: Double, g: Double, b: Double)) -> Double { max(c.r, c.g, c.b) - min(c.r, c.g, c.b) }
        func spread(_ settings: DevelopSettings) -> Double { luma(mean(light, settings)) - luma(mean(dark, settings)) }
        assert(with(.standard) == .neutral && with(.standard).isNeutral, "Standard stores nothing")
        let plain = mean(red, .neutral)
        for profile in DevelopProfile.allCases {
            let none = mean(red, with(profile, amount: 0))
            assert(abs(none.r - plain.r) < 0.005 && abs(none.g - plain.g) < 0.005 && abs(none.b - plain.b) < 0.005,
                   "\(profile) at 0% is Standard")
        }
        let standard = spread(.neutral), neutral = spread(with(.neutral)), vivid = spread(with(.vivid))
        assert(neutral < standard - 0.02 && vivid > standard + 0.02, "Neutral flattens the tones, Vivid adds contrast")
        assert(chroma(mean(red, with(.vivid))) > chroma(plain) + 0.02 && chroma(mean(red, with(.neutral))) < chroma(plain) - 0.01,
               "Vivid is more colorful, Neutral quieter")
        assert(chroma(mean(green, with(.landscape))) > chroma(mean(green, .neutral)) + 0.02, "Landscape deepens greens")
        let portraitRed = mean(red, with(.portrait))
        assert(chroma(portraitRed) < chroma(plain) && luma(mean((0.8, 0.5, 0.35), with(.portrait))) > luma(mean((0.8, 0.5, 0.35), .neutral)),
               "Portrait calms reds and lightens skin tones")
        for profile in DevelopProfile.allCases {
            let gray = mean((0.5, 0.5, 0.5), with(profile))
            assert(abs(gray.r - gray.g) < 0.01 && abs(gray.g - gray.b) < 0.01, "\(profile) keeps grays gray")
        }
        assert(spread(with(.vivid, amount: 200)) > vivid + 0.01, "200% goes further than 100%")

        // stored by name: an unknown one renders as Standard; only a set profile changes the fingerprint
        let stored = try! JSONDecoder().decode(DevelopSettings.self, from: JSONEncoder().encode(with(.landscape, amount: 140)))
        let unknown = try! JSONDecoder().decode(DevelopSettings.self, from: Data(#"{"profile":"cinematic"}"#.utf8))
        assert(stored.profile == "landscape" && stored.profileAmount == 140 && DevelopProfile(stored: unknown.profile) == .standard
               && stored.fingerprint != DevelopSettings().fingerprint
               && with(.vivid, amount: 50).fingerprint != with(.vivid).fingerprint,
               "a profile and its amount persist and change the fingerprint")
        let carried = DevelopSettings().applying(with(.portrait, amount: 70), fields: [.profile])
        assert(carried.profile == "portrait" && carried.profileAmount == 70 && DevelopField.defaultCopy.contains(.profile),
               "copy and presets carry the profile with its amount")

        // a preset's Amount: a profile the photo didn't have grows from nothing, one it takes away fades
        func blend(_ base: DevelopSettings, _ target: DevelopSettings, _ amount: Double) -> DevelopSettings {
            DevelopSettings.blend(base, target, amount: amount, isRaw: false, whiteBalanceOrigin: (0, 0))
        }
        let grown = blend(.neutral, with(.vivid), 0.5), faded = blend(with(.vivid), .neutral, 0.5)
        let gone = blend(with(.vivid), .neutral, 1.5), swapped = blend(with(.neutral), with(.vivid, amount: 120), 0.5)
        assert(grown.profile == "vivid" && grown.profileAmount == 50 && faded.profile == "vivid" && faded.profileAmount == 50
               && gone.profile == nil && gone.profileAmount == 100 && swapped.profile == "vivid" && swapped.profileAmount == 60,
               "a preset's amount scales its profile from nothing")
    }

    /// Black and white: gray, each color band lighter or darker by the mix, toned by grading.
    private static func checkBlackAndWhite() {
        let red = (0.8, 0.2, 0.15), blue = (0.15, 0.25, 0.85), gray = (0.5, 0.5, 0.5)
        var mono = DevelopSettings()
        mono.profile = DevelopProfile.monochrome.stored
        func isGray(_ c: (r: Double, g: Double, b: Double)) -> Bool { abs(c.r - c.g) < 0.01 && abs(c.g - c.b) < 0.01 }
        let plainRed = mean(red, mono), plainBlue = mean(blue, mono)
        assert(isGray(plainRed) && isGray(plainBlue) && isGray(mean(gray, mono)), "Monochrome renders gray")
        var lighter = mono, darker = mono
        lighter.grayMixer[ColorMixer.Band.red.rawValue] = 100
        darker.grayMixer[ColorMixer.Band.red.rawValue] = -100
        assert(luma(mean(red, lighter)) > luma(plainRed) + 0.08 && luma(mean(red, darker)) < luma(plainRed) - 0.05,
               "the red slider lightens or darkens reds")
        assert(abs(luma(mean(blue, lighter)) - luma(plainBlue)) < 0.01 && abs(luma(mean(gray, lighter)) - luma(mean(gray, mono))) < 0.01,
               "and leaves blues and grays alone")
        var toned = mono
        toned.grading.global = ColorGrading.Grade(hue: 35, saturation: 40, luminance: 0)
        let sepia = mean(gray, toned)
        assert(sepia.r > sepia.b + 0.03, "color grading tones a black-and-white photo")
        var half = mono
        half.profileAmount = 50
        let partly = mean(red, half), full = mean(red, .neutral)
        assert(partly.r - partly.b > 0.1 && partly.r - partly.b < (full.r - full.b) - 0.1,
               "below 100% (a preset's partial amount) keeps some color")
        var color = DevelopSettings()
        color.grayMixer[ColorMixer.Band.red.rawValue] = 100
        assert(abs(mean(red, color).r - full.r) < 0.01, "the mix does nothing in color")

        // the mix persists, travels with copy and presets, and scales with a preset's amount
        let stored = try! JSONDecoder().decode(DevelopSettings.self, from: JSONEncoder().encode(lighter))
        let malformed = try! JSONDecoder().decode(DevelopSettings.self, from: Data(#"{"grayMixer":[1,2]}"#.utf8))
        assert(stored.grayMixer == lighter.grayMixer && malformed.grayMixer == [Double](repeating: 0, count: 8)
               && lighter.fingerprint != mono.fingerprint, "the mix persists and changes the fingerprint")
        assert(DevelopSettings().applying(lighter, fields: [.grayMixer]).grayMixer == lighter.grayMixer
               && DevelopSettings.blend(mono, lighter, amount: 0.5, isRaw: false, whiteBalanceOrigin: (0, 0))
                   .grayMixer[ColorMixer.Band.red.rawValue] == 50, "copy carries the mix and a preset's amount scales it")

        // auto: the photo's colors pulled apart, the lighter one up; a color between two bands moves as one
        func pixels(_ colors: [(UInt8, UInt8, UInt8)]) -> [UInt8] {
            colors.flatMap { c in (0..<200).flatMap { _ in [c.0, c.1, c.2, 255] } }
        }
        let blueGreen = DevelopAuto.grayMix(rgba: pixels([(40, 90, 230), (60, 200, 50)]))   // a darker blue, a lighter green
        let redBlue = DevelopAuto.grayMix(rgba: pixels([(200, 60, 40), (40, 120, 220)]))   // a darker red-orange, a lighter blue
        assert(blueGreen?[ColorMixer.Band.blue.rawValue] == -30 && blueGreen?[ColorMixer.Band.green.rawValue] == 30
               && blueGreen?[ColorMixer.Band.red.rawValue] == 0, "auto spreads the photo's colors by their lightness")
        assert(redBlue?[ColorMixer.Band.red.rawValue] == 0 && redBlue?[ColorMixer.Band.orange.rawValue] == 0
               && redBlue?[ColorMixer.Band.aqua.rawValue] == 30 && redBlue?[ColorMixer.Band.blue.rawValue] == 30,
               "a color between two bands moves as one, and skin's orange is never darkened")
        assert(DevelopAuto.grayMix(rgba: pixels([(40, 120, 220)])) == nil
               && DevelopAuto.grayMix(rgba: [UInt8](repeating: 128, count: 400 * 4)) == nil,
               "and needs two colors to spread")
    }

    /// Calibration moves the primaries and tints the shadows, leaving white and grays alone.
    private static func checkCalibration() {
        let red = (0.85, 0.12, 0.1), blue = (0.12, 0.2, 0.85), gray = (0.5, 0.5, 0.5), white = (0.95, 0.95, 0.95)
        func with(_ edit: (inout DevelopSettings) -> Void) -> DevelopSettings {
            var settings = DevelopSettings()
            edit(&settings)
            return settings
        }
        func chroma(_ c: (r: Double, g: Double, b: Double)) -> Double { max(c.r, c.g, c.b) - min(c.r, c.g, c.b) }
        let plainRed = mean(red, .neutral), plainBlue = mean(blue, .neutral)
        let toward = with { $0.redHue = 100 }, away = with { $0.redHue = -100 }
        assert(mean(red, toward).g > plainRed.g + 0.05 && mean(red, away).b > plainRed.b + 0.05,
               "the red primary's hue leans toward orange or toward magenta")
        assert(chroma(mean(red, with { $0.redSaturation = -100 })) < chroma(plainRed) - 0.05
               && chroma(mean(blue, with { $0.blueSaturation = 100 })) >= chroma(plainBlue) - 0.005
               && mean(blue, with { $0.blueHue = 100 }).r > plainBlue.r + 0.03,
               "saturation scales a primary, and blue's hue leans toward purple")
        let everything = with {
            $0.redHue = 60; $0.redSaturation = -40; $0.greenHue = -50; $0.greenSaturation = 70; $0.blueHue = 30; $0.blueSaturation = -80
        }
        for tone in [gray, white] {
            let c = mean(tone, everything), plain = mean(tone, .neutral)
            assert(abs(c.r - plain.r) < 0.01 && abs(c.g - plain.g) < 0.01 && abs(c.b - plain.b) < 0.01,
                   "the primaries move without tinting grays")
        }
        let rows = DevelopRenderer.calibrationMatrix(everything)
        assert(abs(rows.r.sum() - 1) < 1e-9 && abs(rows.g.sum() - 1) < 1e-9 && abs(rows.b.sum() - 1) < 1e-9,
               "the matrix keeps white")
        let shadow = mean((0.12, 0.12, 0.12), with { $0.shadowTint = 100 })
        let green = mean((0.12, 0.12, 0.12), with { $0.shadowTint = -100 })
        let light = mean(white, with { $0.shadowTint = 100 })
        assert(shadow.r > shadow.g + 0.01 && green.g > green.r + 0.01 && abs(light.r - light.g) < 0.01,
               "the shadows tint turns dark tones magenta or green and leaves light ones")

        let stored = try! JSONDecoder().decode(DevelopSettings.self, from: JSONEncoder().encode(everything))
        assert(stored == everything && everything.fingerprint != DevelopSettings().fingerprint && everything.hasCalibration,
               "calibration persists and changes the fingerprint")
        assert(DevelopSettings().applying(everything, fields: [.calibration]).blueSaturation == -80
               && DevelopField.defaultCopy.contains(.calibration), "calibration copies as one setting")
        let text = DevelopPresetFile.xmp(for: DevelopPreset(id: "c", name: "C", transfer: DevelopTransfer(
            settings: everything, fields: [.calibration], sourceIsRaw: true)))
        let crsOnly = text.replacingOccurrences(of: #"\s*pc:Preset="[^"]*""#, with: "", options: .regularExpression)
        let back = DevelopPresetFile.read(Data(crsOnly.utf8), fileName: "c.xmp")?.preset.transfer
        assert(text.contains(#"crs:RedHue="+60""#) && text.contains(#"crs:BlueSaturation="-80""#)
               && back?.settings.greenSaturation == 70 && back?.settings.redHue == 60 && back?.fields == [.calibration],
               "calibration maps to Camera Raw's own settings")
    }

    /// Soft proofing: a narrower profile clips what it can't hold and lets grays through; the
    /// warning marks exactly what doesn't fit.
    private static func checkSoftProofing() {
        let colors: [(Double, Double, Double)] = [(0, 1, 0), (0.5, 0.5, 0.5), (0.85, 0.65, 0.5)]   // P3 green, gray, skin
        let context = CGContext(data: nil, width: colors.count, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                space: DevelopRenderer.outputColorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for (i, c) in colors.enumerated() {
            context.setFillColor(CGColor(colorSpace: DevelopRenderer.outputColorSpace, components: [c.0, c.1, c.2, 1])!)
            context.fill(CGRect(x: i, y: 0, width: 1, height: 1))
        }
        let image = context.makeImage()!
        let original = SoftProofing.rgba(image)!
        func shown(_ edit: (inout SoftProof) -> Void) -> [UInt8] {
            var proof = SoftProof()
            edit(&proof)
            return SoftProofing.proof(image, proof).flatMap(SoftProofing.rgba) ?? []
        }
        func near(_ a: [UInt8], _ b: [UInt8], _ pixel: Int, _ tolerance: Int = 3) -> Bool {
            (0..<3).allSatisfy { abs(Int(a[pixel * 4 + $0]) - Int(b[pixel * 4 + $0])) <= tolerance }
        }
        let srgb = shown { _ in }
        assert(srgb[0] > 80 && near(srgb, original, 1) && near(srgb, original, 2),
               "proofing in sRGB clips Display P3's green and leaves gray and skin")
        assert(near(shown { $0.profile = "displayP3" }, original, 0) && near(shown { $0.profile = "displayP3" }, original, 1),
               "proofing in the display's own space changes nothing")
        let warned = shown { $0.gamutWarning = true }
        assert(Array(warned[0..<3]) == [255, 0, 0] && near(warned, original, 1) && near(warned, original, 2),
               "the gamut warning marks only the color sRGB can't hold")
        let cmyk = "/System/Library/ColorSync/Profiles/Generic CMYK Profile.icc"
        if FileManager.default.fileExists(atPath: cmyk) {
            let printed = shown { $0.profile = cmyk; $0.gamutWarning = true }
            assert(Array(printed[0..<3]) == [255, 0, 0] && near(printed, original, 1, 4),
                   "a printer profile flags a vivid green and passes gray")
            assert(SoftProofing.isPrinterProfile(cmyk) && !SoftProofing.isPrinterProfile("/System/Library/ColorSync/Profiles/sRGB Profile.icc")
                   && SoftProofing.profiles().contains { $0.id == cmyk }, "printer profiles are found, display profiles aren't")
        }
        assert(SoftProofing.profiles().prefix(3).map(\.id) == ["sRGB", "displayP3", "adobeRGB"]
               && (try? JSONDecoder().decode(SoftProof.self, from: Data("{}".utf8))) == SoftProof(),
               "the output spaces come first, and settings saved before a field existed still load")
    }

    @MainActor
    private static func checkSoftProofingState() {
        let saved = UserDefaults.standard.data(forKey: "pc_softProof")
        defer { UserDefaults.standard.set(saved, forKey: "pc_softProof") }
        let app = AppState.selfCheckFixture()
        app.view = .grid
        app.toggleSoftProofing()
        assert(!app.softProofing, "proofing is a Develop view")
        app.view = .develop
        app.softProof.profile = "/gone/printer.icc"
        app.toggleSoftProofing()
        assert(app.softProofing && app.softProof.profile == "sRGB" && !app.softProofProfiles.isEmpty,
               "turning it on finds the profiles, and one that's gone falls back to sRGB")
        app.toggleSoftProofing()
        assert(!app.softProofing, "and S turns it off again")
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

        // balance favors the highlights (+) or the shadows (-), as in Lightroom
        s = DevelopSettings()
        s.grading.shadows = ColorGrading.Grade(hue: 0, saturation: 100, luminance: 0)
        s.grading.balance = -100
        let favorShadows = mean((0.5, 0.5, 0.5), s)
        s.grading.balance = 100
        let favorHighlights = mean((0.5, 0.5, 0.5), s)
        assert(favorShadows.r - favorShadows.g > favorHighlights.r - favorHighlights.g + 0.03,
               "negative balance widens the shadows' tint, positive narrows it")

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

    /// A drawn face with its landmarks where they are, and a second one when `pair`: people
    /// masks are checked on it without Vision, which only knows real faces.
    private static func drawnPeople(pair: Bool) -> (analysis: PeopleMasks.Analysis, image: CGImage) {
        let width = pair ? 800 : 400, height = 400
        func ellipse(_ c: CGPoint, _ rx: Double, _ ry: Double, _ n: Int, from: Double = 0, to: Double = 2 * .pi) -> [CGPoint] {
            (0..<n).map { k in
                let t = from + (to - from) * Double(k) / Double(n - 1)
                return CGPoint(x: Double(c.x) + rx * cos(t), y: Double(c.y) + ry * sin(t))
            }
        }
        func face(_ dx: Double) -> PeopleMasks.Face {
            // y points down: the jaw runs from the left temple (angle π) down round the chin (π/2)
            PeopleMasks.Face(contour: ellipse(CGPoint(x: 200 + dx, y: 190), 90, 120, 17, from: .pi, to: 0),
                             eyes: [ellipse(CGPoint(x: 165 + dx, y: 180), 18, 7, 8, to: 2 * .pi * 7 / 8),
                                    ellipse(CGPoint(x: 235 + dx, y: 180), 18, 7, 8, to: 2 * .pi * 7 / 8)],
                             brows: [[CGPoint(x: 145 + dx, y: 160), CGPoint(x: 165 + dx, y: 155), CGPoint(x: 185 + dx, y: 160)],
                                     [CGPoint(x: 215 + dx, y: 160), CGPoint(x: 235 + dx, y: 155), CGPoint(x: 255 + dx, y: 160)]],
                             outerLips: ellipse(CGPoint(x: 200 + dx, y: 260), 30, 12, 14, to: 2 * .pi * 13 / 14),
                             innerLips: ellipse(CGPoint(x: 200 + dx, y: 260), 22, 4, 6, to: 2 * .pi * 5 / 6),
                             pupils: [CGPoint(x: 165 + dx, y: 180), CGPoint(x: 235 + dx, y: 180)])
        }
        func inside(_ x: Double, _ y: Double, _ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) -> Bool {
            let u = (x - cx) / rx, v = (y - cy) / ry
            return u * u + v * v <= 1
        }
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var matte = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let px = Double(x) + 0.5, py = Double(y) + 0.5
                let dx = pair && px >= 400 ? 400.0 : 0
                let fx = px - dx
                var c = (0.2, 0.2, 0.2)
                var person = false
                if inside(fx, py, 200, 175, 95, 135) && py < 80 { c = (0.3, 0.2, 0.12); person = true }          // hair
                else if fx > 170 && fx < 230 && py > 290 { c = (0.8, 0.6, 0.5); person = true }                 // neck
                if inside(fx, py, 200, 185, 88, 125) && py >= 80 { c = (0.85, 0.65, 0.55); person = true }      // skin
                if inside(fx, py, 165, 180, 18, 7) || inside(fx, py, 235, 180, 18, 7) {
                    c = inside(fx, py, 165, 180, 7, 7) || inside(fx, py, 235, 180, 7, 7) ? (0.3, 0.2, 0.1) : (0.95, 0.95, 0.95)
                }
                let brow = [(145.0, 160.0, 165.0, 155.0), (165, 155, 185, 160), (215, 160, 235, 155), (235, 155, 255, 160)]
                    .contains { x0, y0, x1, y1 in
                        let t = max(0, min(1, ((fx - x0) * (x1 - x0) + (py - y0) * (y1 - y0)) / ((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0))))
                        return hypot(fx - (x0 + t * (x1 - x0)), py - (y0 + t * (y1 - y0))) < 4
                    }
                if brow { c = (0.25, 0.2, 0.15) }
                if inside(fx, py, 200, 260, 30, 12) { c = inside(fx, py, 200, 260, 22, 4) ? (0.95, 0.93, 0.9) : (0.75, 0.3, 0.35) }
                let i = y * width + x
                pixels[i * 4] = UInt8(c.0 * 255); pixels[i * 4 + 1] = UInt8(c.1 * 255); pixels[i * 4 + 2] = UInt8(c.2 * 255)
                matte[i] = person ? 255 : 0
            }
        }
        let faces = pair ? [face(0), face(400)] : [face(0)]
        let people: [[UInt8]?] = pair
            ? [matte.enumerated().map { $0.offset % width < 400 ? $0.element : 0 }, matte.enumerated().map { $0.offset % width >= 400 ? $0.element : 0 }]
            : [matte]
        let analysis = PeopleMasks.Analysis(width: width, height: height, pixels: pixels, faces: faces, matte: matte, people: people)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: DevelopRenderer.outputColorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        return (analysis, context.makeImage()!)
    }

    private static func checkPeopleMasks() {
        let (one, drawn) = drawnPeople(pair: false)
        func weight(_ part: PersonPart, _ x: Int, _ y: Int, person: Int? = nil, in a: PeopleMasks.Analysis = one) -> Float {
            PeopleMasks.weights(part, person: person, in: a)?[y * a.width + x] ?? -1
        }
        let cheek = (150, 230), eyeWhite = (152, 180), iris = (165, 180), brow = (165, 156), lip = (200, 268)
        let mouth = (200, 260), neck = (200, 340), hair = (200, 60), background = (20, 20)
        assert(weight(.person, 200, 200) > 0.9 && weight(.person, background.0, background.1) < 0.1,
               "the whole person is Vision's matte")
        assert(weight(.faceSkin, cheek.0, cheek.1) > 0.5 && weight(.faceSkin, iris.0, iris.1) < 0.2
               && weight(.faceSkin, brow.0, brow.1) < 0.2 && weight(.faceSkin, lip.0, lip.1) < 0.2
               && weight(.faceSkin, hair.0, hair.1) < 0.2 && weight(.faceSkin, neck.0, neck.1) < 0.2,
               "face skin leaves out the eyes, brows, lips, hair and neck")
        assert(weight(.bodySkin, neck.0, neck.1) > 0.5 && weight(.bodySkin, cheek.0, cheek.1) < 0.2
               && weight(.bodySkin, hair.0, hair.1) < 0.2 && weight(.bodySkin, background.0, background.1) < 0.1,
               "body skin is the rest of the person's skin")
        assert(weight(.eyebrows, brow.0, brow.1) > 0.5 && weight(.eyebrows, cheek.0, cheek.1) < 0.1, "eyebrows follow the brow lines")
        assert(weight(.sclera, eyeWhite.0, eyeWhite.1) > 0.5 && weight(.sclera, iris.0, iris.1) < 0.3
               && weight(.iris, iris.0, iris.1) > 0.5 && weight(.iris, eyeWhite.0, eyeWhite.1) < 0.3,
               "an eye splits into its white and the iris round the pupil")
        assert(weight(.lips, lip.0, lip.1) > 0.5 && weight(.lips, mouth.0, mouth.1) < 0.3
               && weight(.teeth, mouth.0, mouth.1) > 0.5 && weight(.teeth, lip.0, lip.1) < 0.3,
               "lips ring the mouth; teeth are the light inside it")
        assert(one.count == 1 && PeopleMasks.weights(.lips, person: 1, in: one) == nil
               && weight(.lips, lip.0, lip.1, person: 0) == weight(.lips, lip.0, lip.1),
               "one person: the only index is theirs")

        // two people: numbered left to right, each mask narrowed to one
        let (two, _) = drawnPeople(pair: true)
        assert(two.count == 2 && weight(.faceSkin, cheek.0, cheek.1, person: 1, in: two) < 0.1
               && weight(.faceSkin, cheek.0 + 400, cheek.1, person: 1, in: two) > 0.5
               && weight(.person, 200, 200, person: 0, in: two) > 0.9 && weight(.person, 600, 200, person: 0, in: two) < 0.1
               && weight(.faceSkin, cheek.0, cheek.1, in: two) > 0.5 && weight(.faceSkin, cheek.0 + 400, cheek.1, in: two) > 0.5,
               "each person can be picked alone, or everyone together")

        // rendered: a lips mask brightens the lips and nothing else
        let url = pngFile(drawn)
        defer { try? FileManager.default.removeItem(at: url) }
        PeopleMasks.remember(one, for: url)
        var settings = DevelopSettings()
        var lips = LocalAdjustment(kind: .person)
        lips.part = .lips
        lips.exposure = 1.5
        settings.masks = [lips]
        let source = DevelopRenderer.Source(url: url, isRaw: false, maxPixel: nil)!
        let plain = DevelopRenderer.render(source.image(.neutral)!)!, bright = DevelopRenderer.render(source.image(settings)!)!
        assert(Int(pixel(bright, lip.0, lip.1).g) > Int(pixel(plain, lip.0, lip.1).g) + 20
               && abs(Int(pixel(bright, cheek.0, cheek.1).g) - Int(pixel(plain, cheek.0, cheek.1).g)) <= 2,
               "a people mask adjusts only its part")

        // stored with the photo; a different part or person is a different render
        var eyes = lips
        eyes.part = .iris
        var second = lips
        second.person = 1
        let back = (try? JSONEncoder().encode(eyes)).flatMap { try? JSONDecoder().decode(LocalAdjustment.self, from: $0) }
        assert(back == eyes && lips.fingerprintText != eyes.fingerprintText && lips.fingerprintText != second.fingerprintText
               && eyes.title == PersonPart.iris.title,
               "a people mask keeps its part and person")
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
        // refining other masks with the brush: erasing cuts into a gradient, painting extends it
        var ring = LocalAdjustment(kind: .radial)
        ring.radiusX = 0.4; ring.radiusY = 0.4; ring.feather = 10; ring.exposure = 1.5
        var cut = BrushStroke()
        cut.radius = 0.08; cut.feather = 0; cut.erase = true
        cut.append(CGPoint(x: 0.5, y: 0.2)); cut.append(CGPoint(x: 0.5, y: 0.8))
        ring.strokes = [cut]
        s = DevelopSettings(); s.masks = [ring]
        out = develop(gray, s)
        assert(abs(luma(out, 32, 32) - base) < 3 && luma(out, 20, 32) > base + 30,
               "an erase stroke takes a stripe out of a radial gradient")
        var extended = linear
        var patch = BrushStroke()
        patch.radius = 0.1; patch.feather = 0
        patch.append(CGPoint(x: 0.3, y: 0.85))
        extended.strokes = [patch]
        s = DevelopSettings(); s.masks = [extended]
        out = develop(gray, s)
        assert(luma(out, 19, 54) < base - 30 && abs(luma(out, 50, 54) - base) < 2,
               "a paint stroke extends a linear gradient where it was painted")
        var bare = DevelopSettings(); bare.masks = [linear]
        assert(s.fingerprint != bare.fingerprint, "refinement strokes change the fingerprint")

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
        var noSky = LocalAdjustment(kind: .sky)
        let wallExtent = CGRect(x: 0, y: 0, width: 64, height: 64)
        assert(DevelopRenderer.maskWeight(noSky, skyEdit, extent: wallExtent, photo: (wallURL, false)) == nil,
               "a sky mask on a photo without sky covers nothing")
        noSky.inverted = true
        let everything = DevelopRenderer.maskWeight(noSky, skyEdit, extent: wallExtent, photo: (wallURL, false))
            .flatMap { DevelopRenderer.render($0) }
        assert(everything.map { luma($0, 32, 32) > 250 } == true, "and inverted, it covers the whole photo")
        let missingURL = FileManager.default.temporaryDirectory.appendingPathComponent("pc-missing-\(UUID().uuidString).png")
        guard case .unreadable = SemanticMasks.lookup(.sky, url: missingURL, isRaw: false) else {
            preconditionFailure("a missing photo can't be read")
        }
        assert(DevelopRenderer.maskWeight(noSky, skyEdit, extent: wallExtent, photo: (missingURL, false)) == nil,
               "an unreadable photo's inverted mask covers nothing")
        try? FileManager.default.copyItem(at: wallURL, to: missingURL)
        defer { try? FileManager.default.removeItem(at: missingURL) }
        guard case .notFound = SemanticMasks.lookup(.sky, url: missingURL, isRaw: false) else {
            preconditionFailure("a photo that couldn't be read is looked at again once it's there")
        }
        if let subject = SemanticMasks.mask(.subject, url: landscapeURL, isRaw: false) {
            assert(subject.coverage > 0 && subject.coverage <= 1, "a subject mask covers part of the photo")
        }

        let halfStroke = try! JSONDecoder().decode(BrushStroke.self, from: Data(#"{"points":[0.1,0.2,0.3]}"#.utf8))
        assert(halfStroke.pointCount == 1 && halfStroke.radius == 0.05 && !halfStroke.erase,
               "a stroke with a dangling coordinate loads without it")
        var rounded = BrushStroke()
        rounded.append(CGPoint(x: 0.123456789, y: 0.5))
        assert(rounded.points == [0.1235, 0.5], "stroke points are stored rounded")

        let newer = try! JSONDecoder().decode(DevelopSettings.self, from: Data(
            #"{"exposure":0.5,"masks":[{"kind":"depthRange"},{"kind":"linear"}],"spots":[{"mode":"patch","radius":0.02}]}"#.utf8))
        assert(newer.exposure == 0.5 && newer.masks.map(\.kind) == [.linear]
               && newer.spots.first?.mode == .heal && newer.spots.first?.radius == 0.02,
               "a mask or spot from a newer version is left out or read as it can be, not the whole edit")
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

    private static func checkSpotRemoval() {
        // a gradient from dark (left) to light (right) with a dark speck in the middle
        let speckled = image { x, y in
            let v = 0.25 + 0.5 * Double(x) / 63
            let speck = hypot(Double(x) - 32, Double(y) - 32) < 3
            return speck ? (0.02, 0.02, 0.02) : (v, v, v)
        }
        func luma(_ image: CGImage, _ x: Int, _ y: Int) -> Double {
            let p = pixel(image, x, y)
            return 0.3 * Double(p.r) + 0.59 * Double(p.g) + 0.11 * Double(p.b)
        }
        let plain = develop(speckled, .neutral)
        let around = (luma(plain, 32, 26) + luma(plain, 32, 38)) / 2   // above and below: the same brightness
        // the source sits to the left, where the gradient is darker
        var spot = SpotRemoval(target: CGPoint(x: 0.5, y: 0.5), source: CGPoint(x: 0.25, y: 0.5), radius: 5.0 / 64)
        spot.feather = 20
        var s = DevelopSettings(); s.spots = [spot]
        let healed = develop(speckled, s)
        assert(abs(luma(healed, 32, 32) - around) < 8 && luma(healed, 32, 32) > luma(plain, 32, 32) + 60,
               "healing removes the speck and matches the surrounding brightness")
        s.spots[0].mode = .clone
        let cloned = develop(speckled, s)
        assert(luma(cloned, 32, 32) < around - 20, "cloning copies the source as it is, darker here")
        assert(abs(luma(healed, 4, 4) - luma(plain, 4, 4)) < 2 && abs(luma(healed, 60, 60) - luma(plain, 60, 60)) < 2,
               "a spot leaves the rest of the photo alone")
        s.spots[0].mode = .heal
        s.spots[0].opacity = 50
        let half = luma(develop(speckled, s), 32, 32)
        assert(half > luma(plain, 32, 32) + 20 && half < luma(healed, 32, 32) - 20, "half opacity heals halfway")

        // a source just beside the speck: the speck is in the source's surroundings, and must not
        // brighten the fix to make up for it
        let flatSpeck = image { x, y in hypot(Double(x) - 32, Double(y) - 32) < 3 ? (0.02, 0.02, 0.02) : (0.5, 0.5, 0.5) }
        var near = SpotRemoval(target: CGPoint(x: 0.5, y: 0.5), source: CGPoint(x: 0.5, y: 23.0 / 64), radius: 5.0 / 64)
        near.feather = 20
        var nearEdit = DevelopSettings(); nearEdit.spots = [near]
        let nearPlain = develop(flatSpeck, .neutral), nearHealed = develop(flatSpeck, nearEdit)
        assert([30, 32, 34, 36].allSatisfy { abs(luma(nearHealed, 32, $0) - luma(nearPlain, 32, 50)) < 3 },
               "healing from beside the speck matches the surroundings, not the speck")

        // the source search avoids another speck and takes a place that matches
        var luma64 = [Double](repeating: 0, count: 64 * 64)
        for y in 0..<64 { for x in 0..<64 { luma64[y * 64 + x] = 0.25 + 0.5 * Double(x) / 63 } }
        for y in 0..<64 { for x in 0..<64 where hypot(Double(x) - 32, Double(y) - 20) < 3 { luma64[y * 64 + x] = 0.02 } }
        let found = SpotFinder.source(for: CGPoint(x: 0.5, y: 0.5), radius: 3.0 / 64, luma: luma64, width: 64, height: 64)
        let foundPixel = CGPoint(x: found.x * 64, y: found.y * 64)
        assert(abs(foundPixel.x - 32) < 4 && hypot(foundPixel.x - 32, foundPixel.y - 20) > 6,
               "the source is found in the same column of the gradient, away from the other speck")

        let old = try! JSONDecoder().decode(DevelopSettings.self, from: Data(#"{"exposure":0.5}"#.utf8))
        assert(old.spots.isEmpty, "edits saved before spot removal load without spots")
        let partial = try! JSONDecoder().decode(SpotRemoval.self, from: Data(#"{"radius":0.02}"#.utf8))
        assert(partial.radius == 0.02 && partial.mode == .heal && partial.opacity == 100, "a spot missing fields loads")
        assert(DevelopSettings().applying(s, fields: [.spots]).spots == s.spots
               && !DevelopField.defaultCopy.contains(.spots), "spots travel as one setting, off by default")
        assert(s.fingerprint != DevelopSettings().fingerprint, "spots change the fingerprint")
        let dust = DevelopRenderer.render(DevelopRenderer.visualizeSpots(CIImage(cgImage: speckled)))!
        assert(luma(dust, 32, 29) > 100 && luma(dust, 8, 8) < 20, "the dust view shows a speck and not smooth areas")
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

    /// A `width`×`height` image in display P3 from a color per pixel.
    private static func picture(_ width: Int, _ height: Int, _ color: (Int, Int) -> (Double, Double, Double)) -> CGImage {
        var data = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let c = color(x, y), i = (y * width + x) * 4
                data[i] = UInt8(max(0, min(255, (c.0 * 255).rounded())))
                data[i + 1] = UInt8(max(0, min(255, (c.1 * 255).rounded())))
                data[i + 2] = UInt8(max(0, min(255, (c.2 * 255).rounded())))
            }
        }
        let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: DevelopRenderer.outputColorSpace,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        return context.makeImage()!
    }

    private static func checkChromaticAberration() {
        // a scene of gray, black and white rectangles, with a few colored ones, 480 × 360
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func random(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }
        var boxes: [(x: Int, y: Int, w: Int, h: Int, c: (Double, Double, Double))] = []
        let grays = [0.08, 0.3, 0.7, 0.92]
        for _ in 0..<90 {
            let v = grays[random(4)]
            boxes.append((random(470), random(350), 8 + random(50), 8 + random(50), (v, v, v)))
        }
        for i in 0..<8 {
            let color = i.isMultiple(of: 2) ? (0.8, 0.15, 0.1) : (0.12, 0.25, 0.8)
            boxes.append((random(440), random(320), 20 + random(30), 20 + random(30), color))
        }
        let halfDiagonal = (480.0 * 480 + 360 * 360).squareRoot() / 2
        /// The scene with each channel drawn at its own magnification about the middle, with
        /// exact antialiasing: a lens with lateral chromatic aberration.
        func photographed(red: Double, blue: Double) -> CGImage {
            let planes = [red, 1, blue].enumerated().map { channel, scale -> [UInt8] in
                var plane = [UInt8](repeating: 0, count: 480 * 360)
                let context = CGContext(data: &plane, width: 480, height: 360, bitsPerComponent: 8, bytesPerRow: 480,
                                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
                context.setFillColor(gray: 0.45, alpha: 1)
                context.fill(CGRect(x: 0, y: 0, width: 480, height: 360))
                context.translateBy(x: 240, y: 180)
                context.scaleBy(x: scale, y: scale)
                context.translateBy(x: -240, y: -180)
                for box in boxes {
                    context.setFillColor(gray: [box.c.0, box.c.1, box.c.2][channel], alpha: 1)
                    context.fill(CGRect(x: box.x, y: box.y, width: box.w, height: box.h))
                }
                return plane
            }
            return picture(480, 360) { x, y in
                let i = (359 - y) * 480 + x
                return (Double(planes[0][i]) / 255, Double(planes[1][i]) / 255, Double(planes[2][i]) / 255)
            }
        }
        let scene = photographed(red: 1, blue: 1)

        // a lens that magnifies red 0.4% and shrinks blue 0.3% against green: 1.2 and 0.9 pixels
        // at the corners
        let fringed = photographed(red: 1.004, blue: 0.997)
        let found = ChromaticAberration.measure(CIImage(cgImage: fringed))
        func shift(_ scale: ChromaticAberration.Scale, at rho: Double) -> Double {
            (scale.k1 + scale.k2 * rho * rho) * rho * halfDiagonal
        }
        assert(abs(shift(found.red, at: 1) - 1.2) < 0.15 && abs(shift(found.blue, at: 1) + 0.9) < 0.15
               && abs(shift(found.red, at: 0.5) - 0.6) < 0.1 && abs(shift(found.blue, at: 0.5) + 0.45) < 0.1,
               "lateral chromatic aberration is measured from the edges (\(found))")
        assert(ChromaticAberration.measure(CIImage(cgImage: scene)).red.isNone
               || abs(shift(ChromaticAberration.measure(CIImage(cgImage: scene)).red, at: 1)) < 0.1,
               "a sharp photo measures none")

        var settings = DevelopSettings()
        settings.removeChromaticAberration = true
        let corrected = develop(fringed, settings)
        let left = ChromaticAberration.measure(CIImage(cgImage: corrected))
        assert(abs(shift(left.red, at: 1)) < 0.2 && abs(shift(left.blue, at: 1)) < 0.2,
               "removing chromatic aberration lines the channels back up (\(left))")
        assert(settings.hasLensCorrection && settings.fingerprint != DevelopSettings().fingerprint,
               "the correction is an edit of its own")

        // defringe: a purple and a green fringe along a black-to-white edge, and a purple thing
        // away from any edge
        let fringes = image { x, y in
            if x >= 32 && y < 32 { return (1, 1, 1) }
            if x >= 29 && x < 32 && y < 16 { return (0.55, 0.2, 0.75) }   // purple fringe
            if x >= 29 && x < 32 && y < 32 { return (0.3, 0.6, 0.25) }    // green fringe
            if x >= 2 && x < 24 && y >= 40 && y < 62 { return (0.45, 0.25, 0.6) }
            return (0.05, 0.05, 0.05)
        }
        func chroma(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Int { Int(max(p.r, p.g, p.b)) - Int(min(p.r, p.g, p.b)) }
        let plain = develop(fringes, .neutral)
        var purple = DevelopSettings(); purple.defringePurple = 20
        let noPurple = develop(fringes, purple)
        assert(chroma(pixel(noPurple, 30, 8)) * 10 < chroma(pixel(plain, 30, 8)) * 3,
               "purple defringing takes the color out of a purple fringe")
        assert(chroma(pixel(noPurple, 30, 24)) * 10 > chroma(pixel(plain, 30, 24)) * 9
               && chroma(pixel(noPurple, 13, 51)) * 10 > chroma(pixel(plain, 13, 51)) * 9,
               "and leaves green fringes and purple things away from edges alone")
        var green = DevelopSettings(); green.defringeGreen = 20
        assert(chroma(pixel(develop(fringes, green), 30, 24)) * 10 < chroma(pixel(plain, 30, 24)) * 3,
               "green defringing takes the color out of a green fringe")

        // carried by copy, presets, preset files and blends; stored with the photo
        var source = DevelopSettings()
        source.removeChromaticAberration = true; source.defringePurple = 8; source.defringeGreen = 3
        let carried = DevelopSettings().applying(source, fields: [.lensCorrections])
        assert(carried.removeChromaticAberration && carried.defringePurple == 8 && carried.defringeGreen == 3,
               "chromatic aberration settings travel with the lens corrections")
        let preset = DevelopPreset(id: "ca", name: "CA", transfer: DevelopTransfer(settings: source, fields: [.lensCorrections],
                                                                                  sourceIsRaw: true))
        let text = DevelopPresetFile.xmp(for: preset)
        let crsOnly = text.replacingOccurrences(of: #"\s*pc:Preset="[^"]*""#, with: "", options: .regularExpression)
        let lightroom = DevelopPresetFile.read(Data(crsOnly.utf8), fileName: "ca.xmp")
        assert(text.contains("crs:AutoLateralCA=\"1\"") && text.contains("crs:DefringePurpleAmount=\"8\"")
               && lightroom?.preset.transfer.settings.removeChromaticAberration == true
               && lightroom?.preset.transfer.settings.defringePurple == 8 && lightroom?.preset.transfer.settings.defringeGreen == 3
               && lightroom?.skipped.isEmpty == true,
               "Camera Raw's chromatic aberration settings map both ways")
        let half = DevelopSettings.blend(.neutral, source, amount: 0.5, isRaw: true, whiteBalanceOrigin: nil)
        assert(half.removeChromaticAberration && half.defringePurple == 4, "a preset's amount scales defringing")
        let stored = (try? JSONEncoder().encode(source)).flatMap { try? JSONDecoder().decode(DevelopSettings.self, from: $0) }
        assert(stored == source, "chromatic aberration settings are stored")
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

        // auto white balance: a warm cast over gray surfaces, a strong red and a muted blue wall
        // filling half the frame; the grays come out neutral and the colors don't drag the result
        // their way
        let castScene = image { x, y in
            let gray = 0.25 + 0.5 * Double(x + y) / 126
            var c = (gray, gray, gray)
            if x < 24 && y < 20 { c = (0.7, 0.12, 0.1) }        // a red thing
            if x >= 32 { c = (0.35, 0.45, 0.65) }               // a blue wall
            return (min(1, c.0 * 1.12), c.1, c.2 * 0.85)       // under warm light
        }
        let castFile = pngFile(castScene)
        defer { try? FileManager.default.removeItem(at: castFile) }
        let auto = DevelopAuto.autoWhiteBalance(url: castFile, isRaw: false, settings: .neutral)
        var neutralized = DevelopSettings()
        neutralized.temperature = auto?.temperature
        neutralized.tint = auto?.tint
        let balanced = develop(castScene, neutralized)
        let grayPatch = pixel(balanced, 12, 40), redPatch = pixel(balanced, 8, 8), bluePatch = pixel(balanced, 48, 30)
        assert(auto != nil && abs(Int(grayPatch.r) - Int(grayPatch.b)) <= 6 && abs(Int(grayPatch.g) - Int(grayPatch.r)) <= 6
               && Int(redPatch.r) > Int(redPatch.b) + 80 && Int(bluePatch.b) > Int(bluePatch.r) + 40,
               "auto white balance makes the gray surfaces gray and leaves colors colored (\(String(describing: auto)), \(grayPatch))")
        // the answer doesn't depend on where the sliders started
        var cooled = DevelopSettings()
        cooled.temperature = -40
        let again = DevelopAuto.autoWhiteBalance(url: castFile, isRaw: false, settings: cooled)
        assert(again.map { abs($0.temperature - (auto?.temperature ?? 0)) <= 3 && abs($0.tint - (auto?.tint ?? 0)) <= 3 } == true,
               "auto white balance finds the same answer from any start (\(String(describing: again)))")
        // a photo of nothing but a strong color gives no answer rather than a wrong one
        let allBlue = pngFile(image { _, _ in (0.1, 0.2, 0.8) })
        defer { try? FileManager.default.removeItem(at: allBlue) }
        assert(DevelopAuto.autoWhiteBalance(url: allBlue, isRaw: false, settings: .neutral) == nil,
               "auto white balance declines a photo with nothing near gray")

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

    /// Exposure drafts move exposure under the RAW engine's tone curve, measured per photo.
    private static func checkBoostCurve() {
        // a known curve, y = sqrt(x), sampled from gray pixels across ten stops
        var flat: [Float] = [], boosted: [Float] = []
        for i in 0..<4000 {
            let x = pow(2, -10 + Double(i) / 400)   // 2^-10 … 2^0
            let y = x.squareRoot()
            flat += [Float(x), Float(x), Float(x), 1]
            boosted += [Float(y), Float(y), Float(y), 1]
        }
        guard let curve = BoostCurve.measure(boosted: boosted, flat: flat) else {
            assertionFailure("a curve is measured from enough tones")
            return
        }
        assert(abs(curve.apply(0.25) - 0.5) < 0.02 && abs(curve.invert(0.5) - 0.25) < 0.02,
               "the measured curve and its inverse follow the photo's tones")
        let identity = curve.exposureTable(delta: 0).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        assert(identity.count == 1024 * 3 && abs(Double(identity[512 * 3]) - 512.0 / 1023) < 0.01,
               "no exposure change leaves tones where they are")
        let brighter = curve.exposureTable(delta: 1).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        assert(brighter[400 * 3] > identity[400 * 3], "more exposure brightens")
        assert(BoostCurve.measure(boosted: [0.5, 0.5, 0.5, 1], flat: [0.25, 0.25, 0.25, 1]) == nil,
               "too few tones measure nothing")
        // the brightest tones clip in the boosted decode: level at the top, as a real highlight does
        let clipped = boosted.map { min($0, 0.8) }
        if let top = BoostCurve.measure(boosted: clipped, flat: flat) {
            assert(zip(top.outputs, top.outputs.dropFirst()).allSatisfy { $0 < $1 }, "the measured curve always rises")
            let back = top.invert(0.95)
            assert(back.isFinite && back < 100 && abs(top.apply(back) - 0.95) < 1e-6,
                   "tones beyond the samples undo and redo to where they were")
            let darker = top.exposureTable(delta: -1).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            assert(darker[1000 * 3] < 0.95, "less exposure darkens the brightest tones too")
        } else {
            assertionFailure("a curve is measured from a photo with clipped highlights")
        }
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

            // history: steps in order, the newest taken away by an undo, the oldest dropped at the limit
            try store.appendDevelopHistory(["a": (name: "one", settings: edit)])
            var second = edit
            second.contrast = 20
            try store.appendDevelopHistory(["a": (name: "two", settings: second)])
            var steps = try store.loadDevelopHistory("a")
            assert(steps.map(\.name) == ["one", "two"] && steps.last?.settings == second, "history steps round-trip in order")
            try store.removeLastDevelopHistory(["a"])
            steps = try store.loadDevelopHistory("a")
            assert(steps.map(\.name) == ["one"], "an undone edit's step is taken away")
            for n in 0..<(DevelopHistoryStep.limit + 5) {
                try store.appendDevelopHistory(["c": (name: "step \(n)", settings: edit)])
            }
            steps = try store.loadDevelopHistory("c")
            assert(steps.count == DevelopHistoryStep.limit && steps.first?.name == "step 5", "history keeps the newest steps")
            try store.clearDevelopHistory("c")
            let clearedHistory = try store.loadDevelopHistory("c")
            assert(clearedHistory.isEmpty, "history clears")

            var snapshot = DevelopSnapshot(id: "s1", name: "Warm", date: .now, settings: edit)
            try store.saveDevelopSnapshot(snapshot, for: "a")
            snapshot.name = "Warmer"
            try store.saveDevelopSnapshot(snapshot, for: "a")
            try store.saveDevelopSnapshot(DevelopSnapshot(id: "s2", name: "Other", date: .now, settings: .neutral), for: "b")
            let named = try store.loadDevelopSnapshots("a").map(\.name)
            assert(named == ["Warmer"], "snapshots save, rename and stay per photo")
            try store.deleteDevelopSnapshot("s1")
            let remaining = try store.loadDevelopSnapshots("a")
            assert(remaining.isEmpty, "snapshots delete")
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
        let savedImportPreset = app.importDevelopPresetId
        let savedRawDefaults = app.rawDefaultPresetIds
        defer {
            app.developPresets = savedPresets
            app.developTransferFields = savedFields
            app.importDevelopPresetId = savedImportPreset
            app.rawDefaultPresetIds = savedRawDefaults
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

        // resting on a preset shows it without saving; leaving takes it away; a drag in
        // progress is never replaced
        let vivid = DevelopPreset.builtIns.first { $0.id == "builtin.vivid" }!
        app.previewDevelopPreset(vivid, on: c)
        assert(app.developSettings(for: c.id).vibrance == 35 && app.developSettings[c.id]?.vibrance != 35,
               "a preset previews without saving")
        app.endDevelopPresetPreview(vivid.id)
        assert(app.developDraft == nil && app.developSettings(for: c.id).vibrance != 35, "leaving it ends the preview")
        var dragging = app.developSettings(for: c.id)
        dragging.contrast = 12
        app.updateDevelopDraft(dragging, for: c.id)
        app.previewDevelopPreset(vivid, on: c)
        assert(app.developDraft?.settings == dragging, "a preview never replaces a drag")
        app.endDevelopPresetPreview()
        assert(app.developDraft?.settings == dragging, "and ending one leaves the drag alone")
        app.developDraft = nil

        app.setPrimary(c.id)
        app.applyDevelopPreset(DevelopPreset.builtIns.first { $0.name == "黑白" }!)
        assert(app.developSettings[c.id]?.profile == "monochrome" && app.developSettings[c.id]?.exposure == 0.6,
               "a preset changes only its own settings")
        assert(app.developPresetAmount(for: c.id) == nil, "the grid applies presets at full strength, without an amount")

        // in Develop, the preset's amount turns it up or down, until another edit
        app.view = .develop
        app.applyDevelopPreset(vivid)
        assert(app.developPresetAmount(for: c.id)?.amount == 1, "applying a preset in Develop offers its amount")
        app.setDevelopPresetAmount(0.5)
        assert(app.developSettings(for: c.id).vibrance == 18 && app.developSettings[c.id]?.vibrance == 35,
               "dragging the amount previews it")
        app.commitDevelopPresetAmount()
        let halfVivid = app.developSettings[c.id]
        assert(halfVivid.map { $0.vibrance == 18 && $0.saturation == 4 && $0.profile == "monochrome" } == true
               && app.developPresetAmount(for: c.id)?.amount == 0.5 && app.developPresetAmountDraft == nil,
               "releasing saves it")
        var other = app.developSettings(for: c.id)
        other.clarity = 10
        app.commitDevelop([c.id: other], undoName: "清晰度")
        assert(app.developPresetAmount(for: c.id) == nil, "another edit ends the amount")
        app.view = .grid

        app.setPrimary(a.id)
        app.saveDevelopPreset(name: "  测试预设 ", fields: app.developPresetDefaultFields)
        let preset = app.developPresets.last
        assert(preset?.name == "测试预设" && preset?.transfer.fields == [.exposure, .vibrance],
               "a new preset holds what the photo adjusted, framing aside")
        app.saveDevelopPreset(name: "测试预设", fields: [.exposure])
        assert(app.developPresets.filter { $0.name == "测试预设" }.count == 1, "saving a name again replaces it")

        // managing: rename (not onto another's name), update from the photo, groups
        app.saveDevelopPreset(name: "另一个", fields: [.contrast], group: "  人像 ")
        let second = app.developPresets.last!
        assert(second.group == "人像" && app.developPresetGroups == ["人像"], "a preset can be saved into a group")
        assert(!app.renameDevelopPreset(second.id, to: "测试预设") && app.renameDevelopPreset(second.id, to: "对比"),
               "renaming refuses another preset's name")
        var brighter = app.developSettings[a.id] ?? .neutral
        brighter.exposure = 1.1
        app.commitDevelop([a.id: brighter], undoName: "曝光")
        app.updateDevelopPreset(preset!.id)
        let updated = app.developPresets.first { $0.id == preset!.id }
        assert(updated?.transfer.settings.exposure == 1.1 && updated?.transfer.fields == [.exposure],
               "updating takes the photo's values for the settings the preset holds")
        app.moveDevelopPreset(second.id, toGroup: "我的预设")
        assert(app.developPresets.first { $0.id == second.id }?.group == nil && app.developPresetGroups.isEmpty,
               "moving to 我的预设 takes it out of its group")
        app.deleteDevelopPreset(second.id)
        app.deleteDevelopPreset(preset!.id)
        assert(!app.developPresets.contains { $0.name == "测试预设" }, "presets can be deleted")

        app.selectedIds = [a.id, b.id, c.id]
        app.resetDevelopSelection()
        assert(app.developSettings.isEmpty, "reset returns the selection to as shot")

        // import: new photos start from the import preset, recorded in their history
        app.importDevelopPresetId = "builtin.bw"
        _ = app.developHistory(for: b.id)   // shown, so its history is kept in memory without a catalog
        app.applyImportDevelopSettings(to: [a, b])
        assert(app.developSettings[a.id]?.profile == "monochrome" && app.developSettings[b.id]?.profile == "monochrome"
               && app.developSettings[c.id] == nil, "imported photos get the import preset")
        assert(app.developHistory(for: b.id).last?.name == L("导入预设“\(L("黑白"))”"),
               "the import preset is recorded as a history step")
        app.importDevelopPresetId = "gone"
        app.applyImportDevelopSettings(to: [c])
        assert(app.developSettings[c.id] == nil && app.importDevelopPreset == nil, "a deleted import preset does nothing")

        // RAW defaults: a camera's own, or every camera's; applied before the import preset,
        // and where 复位 goes
        // another camera than A's (the demo set has several)
        guard let other = base.first(where: { $0.camera != a.camera && ![a.id, b.id, c.id].contains($0.id) }) else {
            preconditionFailure("the demo set has RAW photos from more than one camera")
        }
        let d = local(other, "D.CR3")
        app.rawDefaultPresetIds = [:]
        app.setRawDefaultPreset("builtin.punch", forCamera: "")
        app.setRawDefaultPreset("builtin.soft", forCamera: d.camera)
        app.importDevelopPresetId = "builtin.bw"
        app.developSettings[a.id] = nil
        app.applyImportDevelopSettings(to: [a, d])
        assert(app.developSettings[d.id]?.contrast == -15 && app.developSettings[d.id]?.profile == "monochrome"
               && app.developSettings[a.id]?.contrast == 35 && app.developSettings[a.id]?.profile == "monochrome",
               "RAW photos start from their camera's default, or every camera's, then the import preset")
        app.setRawDefaultPreset("none", forCamera: d.camera)
        assert(app.defaultDevelopSettings(for: d) == .neutral && app.defaultDevelopSettings(for: a).contrast == 35,
               "a camera can be kept as shot")
        app.setRawDefaultPreset("", forCamera: d.camera)
        assert(app.rawDefaultPresetIds[d.camera] == nil, "clearing a camera's default follows every camera's")
        app.view = .develop
        app.setPrimary(a.id)
        app.resetDevelop(a)
        assert(app.developSettings[a.id] == app.defaultDevelopSettings(for: a) && app.developSettings[a.id]?.contrast == 35,
               "复位 returns a RAW photo to its defaults")
        app.view = .grid
        app.importDevelopPresetId = ""
        app.rawDefaultPresetIds = [:]
    }

    /// LUTs: .cube files parsed (resampled when their size isn't a power of two), applied in
    /// sRGB at their amount, and kept in the library.
    @MainActor
    private static func checkLUTs() {
        func cube(size: Int, title: String = "Test", _ f: (Double, Double, Double) -> (Double, Double, Double)) -> String {
            var lines = ["TITLE \"\(title)\"", "# a comment", "LUT_3D_SIZE \(size)"]
            for b in 0..<size { for g in 0..<size { for r in 0..<size {
                let v = f(Double(r) / Double(size - 1), Double(g) / Double(size - 1), Double(b) / Double(size - 1))
                lines.append(String(format: "%.6f %.6f %.6f", v.0, v.1, v.2))
            } } }
            return lines.joined(separator: "\n")
        }
        let identity = cube(size: 17) { ($0, $1, $2) }
        assert(LUTLibrary.parse(identity)?.size == 32 && LUTLibrary.title(of: identity) == "Test",
               "a 17-point LUT is resampled to 32 points and keeps its title")
        assert(LUTLibrary.parse("LUT_1D_SIZE 2\n0 0 0\n1 1 1") == nil && LUTLibrary.parse("LUT_3D_SIZE 2\n0 0 0") == nil,
               "1D LUTs and files missing values are refused")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pc-luts-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let identityURL = folder.appendingPathComponent("identity.cube"), invertURL = folder.appendingPathComponent("Invert.cube")
        try? identity.write(to: identityURL, atomically: true, encoding: .utf8)
        try? cube(size: 2, title: "") { (1 - $0, 1 - $1, 1 - $2) }.write(to: invertURL, atomically: true, encoding: .utf8)
        try? "not a lut".write(to: folder.appendingPathComponent("bad.cube"), atomically: true, encoding: .utf8)

        let app = AppState.selfCheckFixture()
        let savedLUTs = app.developLUTs
        let result = app.importLUTs(from: ["identity.cube", "Invert.cube", "bad.cube"].map { folder.appendingPathComponent($0) })
        let added = Array(app.developLUTs.dropFirst(savedLUTs.count))
        defer {
            for lut in added { LUTLibrary.remove(id: lut.id) }
            app.developLUTs = savedLUTs
        }
        assert(result.added == 2 && result.failed == 1 && added.map(\.name) == ["Test", "Invert"],
               "LUTs are imported under their title or file name, and bad files counted")

        let color = image { _, _ in (0.7, 0.4, 0.2) }
        let plain = develop(color, .neutral)
        var s = DevelopSettings()
        s.lutId = added[0].id
        let same = pixel(develop(color, s), 32, 32), before = pixel(plain, 32, 32)
        assert(abs(Int(same.r) - Int(before.r)) < 4 && abs(Int(same.b) - Int(before.b)) < 4, "an identity LUT changes nothing")
        s.lutId = added[1].id
        let inverted = pixel(develop(color, s), 32, 32)
        assert(Int(inverted.b) > Int(inverted.r) + 60, "a LUT's look is applied")
        s.lutAmount = 50
        let half = pixel(develop(color, s), 32, 32)
        assert(half.b > before.b + 20 && half.b < inverted.b - 20, "half the amount goes halfway")
        var other = s
        other.lutAmount = 80
        assert(other.fingerprint != s.fingerprint && DevelopSettings().applying(s, fields: [.lut]).lutId == s.lutId,
               "the LUT changes the fingerprint and travels as one setting")
        s.lutId = "gone"
        let missing = pixel(develop(color, s), 32, 32)
        assert(abs(Int(missing.r) - Int(before.r)) < 3, "a LUT no longer in the library leaves the photo as it is")
    }

    /// Color and luminance range masks, alone or narrowing another mask.
    private static func checkRangeMasks() {
        func luma(_ image: CGImage, _ x: Int, _ y: Int) -> Double {
            let p = pixel(image, x, y)
            return 0.2126 * Double(p.r) + 0.7152 * Double(p.g) + 0.0722 * Double(p.b)
        }
        // a gray ramp, dark at the left: a luminance range brightens only the light end
        let ramp = image { x, _ in let v = 0.05 + 0.9 * Double(x) / 63; return (v, v, v) }
        var bright = LocalAdjustment(kind: .luminanceRange)
        bright.range?.low = 70
        bright.range?.high = 100
        bright.range?.smoothness = 10
        bright.exposure = -2
        var s = DevelopSettings(); s.masks = [bright]
        let plain = develop(ramp, .neutral), ranged = develop(ramp, s)
        assert(luma(ranged, 60, 32) < luma(plain, 60, 32) - 40 && abs(luma(ranged, 4, 32) - luma(plain, 4, 32)) < 2,
               "a luminance range reaches only its tones")
        s.masks[0].inverted = true
        let outside = develop(ramp, s)
        assert(luma(outside, 4, 32) < luma(plain, 4, 32) - 3 && abs(luma(outside, 60, 32) - luma(plain, 60, 32)) < 3,
               "inverted, it reaches everything else")

        // red on the left, blue on the right: a color range sampled on red desaturates only red
        let halves = image { x, _ in x < 32 ? (0.8, 0.15, 0.15) : (0.15, 0.25, 0.85) }
        var red = LocalAdjustment(kind: .colorRange)
        red.range?.samples = [CGPoint(x: 0.2, y: 0.5)]
        red.saturation = -100
        var c = DevelopSettings(); c.masks = [red]
        let colored = develop(halves, c)
        let left = pixel(colored, 10, 32), right = pixel(colored, 54, 32)
        assert(abs(Int(left.r) - Int(left.g)) < 30 && Int(right.b) - Int(right.r) > 100,
               "a color range reaches the sampled color and not the others")
        var nothing = red
        nothing.range?.samples = []
        c.masks = [nothing]
        let unsampled = develop(halves, c), before = develop(halves, .neutral)
        assert(abs(Int(pixel(unsampled, 10, 32).r) - Int(pixel(before, 10, 32).r)) < 3,
               "a color range with nothing sampled covers nothing")

        // a radial mask narrowed to the light tones: only where both hold
        var radial = LocalAdjustment(kind: .radial)
        radial.center = CGPoint(x: 0.5, y: 0.5)
        radial.radiusX = 0.6; radial.radiusY = 0.6; radial.feather = 0
        radial.exposure = -2
        radial.range = MaskRange(kind: .luminance)
        radial.range?.low = 70; radial.range?.smoothness = 10
        var r = DevelopSettings(); r.masks = [radial]
        let narrowed = develop(ramp, r)
        assert(luma(narrowed, 60, 32) < luma(plain, 60, 32) - 40 && abs(luma(narrowed, 20, 32) - luma(plain, 20, 32)) < 2,
               "a range narrows another mask to its tones")

        let saved = try! JSONDecoder().decode(DevelopSettings.self, from: JSONEncoder().encode(r))
        assert(saved == r, "ranges round-trip through storage")
        var other = r
        other.masks[0].range?.low = 40
        assert(other.fingerprint != r.fingerprint, "a range changes the fingerprint")
        let old = try! JSONDecoder().decode(LocalAdjustment.self, from: Data(#"{"kind":"radial"}"#.utf8))
        assert(old.range == nil, "masks saved before ranges load without one")
    }

    /// Transform: the perspective correction, the crop kept off its empty corners, points mapped
    /// through it both ways, and Upright setting converging verticals upright.
    private static func checkPerspective() {
        let frame = CGSize(width: 600, height: 400)
        var s = DevelopSettings()
        s.perspectiveVertical = -40
        guard let h = DevelopGeometry.perspective(s, frame: frame) else {
            preconditionFailure("a Transform slider makes a correction")
        }
        let tl = h.apply(CGPoint(x: 0, y: 0))!, tr = h.apply(CGPoint(x: 600, y: 0))!
        let bl = h.apply(CGPoint(x: 0, y: 400))!, br = h.apply(CGPoint(x: 600, y: 400))!
        assert(tr.x - tl.x > br.x - bl.x + 20, "negative Vertical widens the top")
        let back = h.inverse.apply(h.apply(CGPoint(x: 123, y: 45))!)!
        assert(abs(back.x - 123) < 1e-6 && abs(back.y - 45) < 1e-6, "the correction undoes exactly")
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 400).insetBy(dx: -1e-6, dy: -1e-6)
        assert([tl, tr, bl, br].allSatisfy { bounds.contains($0) }, "the corrected photo fits the frame, nothing lost")
        let crop = DevelopGeometry.effectiveCrop(s, frame: frame)
        let larger = DevelopCrop(x: crop.x - 0.01, y: crop.y - 0.01, width: crop.width + 0.02, height: crop.height + 0.02)
        assert(crop.width < 1 && DevelopGeometry.fits(crop, angle: 0, perspective: h, frame: frame)
               && !DevelopGeometry.fits(larger, angle: 0, perspective: h, frame: frame)
               && abs(crop.width * 600 / (crop.height * 400) - 1.5) < 0.001,
               "the automatic crop is the largest of the frame's shape without empty corners")
        s.straighten = 3
        s.perspectiveHorizontal = 25
        s.crop = DevelopGeometry.refit(s, frame: frame)
        let source = CGPoint(x: 0.3, y: 0.7)
        let finished = DevelopGeometry.finishedPoint(fromSource: source, settings: s, sourceSize: frame)
        let returned = DevelopGeometry.sourcePoint(fromFinished: finished, settings: s, sourceSize: frame)
        assert(abs(returned.x - 0.3) < 1e-6 && abs(returned.y - 0.7) < 1e-6, "masks and spots map through the correction both ways")
        let turned = DevelopGeometry.rotated(s, clockwise: true)
        assert(turned.perspectiveVertical == 25 && turned.perspectiveHorizontal == 40, "a quarter turn carries the correction along")
        assert(DevelopGeometry.mirrored(s).perspectiveHorizontal == -25, "mirroring flips the horizontal correction")
        var copied = DevelopSettings().applying(s, fields: [.perspective])
        assert(copied.perspectiveVertical == -40 && copied.crop == nil && !DevelopField.defaultCopy.contains(.perspective),
               "the correction travels as its own setting, off by default")
        copied = s
        copied.perspectiveVertical = 0
        assert(copied.fingerprint != s.fingerprint, "the correction changes the fingerprint")

        // rendered: no empty corners in the result
        let gray = image { _, _ in (0.5, 0.5, 0.5) }
        var render = DevelopSettings()
        render.perspectiveVertical = -60
        let corrected = develop(gray, render)
        let corners = [(0, 0), (corrected.width - 1, 0), (0, corrected.height - 1), (corrected.width - 1, corrected.height - 1)]
        assert(corners.allSatisfy { let p = pixel(corrected, $0.0, $0.1); return p.a == 255 && abs(Int(p.r) - 127) < 12 },
               "the corrected render has no empty corners")

        // Upright: lines of a building shot from below meet above the photo
        let (width, height) = (600, 400)
        let meet = CGPoint(x: 330, y: -900)
        var luma = [Float](repeating: 0.8, count: width * height)
        for bottom in stride(from: 60.0, through: 560.0, by: 70.0) {
            for y in 0..<height {
                let t = (Double(y) - Double(meet.y)) / (Double(height) - Double(meet.y))
                let x = Double(meet.x) + (bottom - Double(meet.x)) * t
                for dx in -1...1 {
                    let xi = Int(x.rounded()) + dx
                    if xi >= 0, xi < width { luma[y * width + xi] = 0.1 }
                }
            }
        }
        guard let upright = Upright.correction(luma: luma, width: width, height: height, mode: .vertical) else {
            preconditionFailure("converging verticals are found")
        }
        var fixed = DevelopSettings()
        fixed.perspectiveVertical = upright.vertical
        fixed.perspectiveHorizontal = upright.horizontal
        fixed.straighten = upright.straighten
        let size = CGSize(width: width, height: height)
        let angles = stride(from: 60.0, through: 560.0, by: 70.0).map { bottom -> Double in
            func finished(_ y: Double) -> CGPoint {
                let t = (y - Double(meet.y)) / (Double(height) - Double(meet.y))
                let x = Double(meet.x) + (bottom - Double(meet.x)) * t
                let p = DevelopGeometry.finishedPoint(fromSource: CGPoint(x: x / Double(width), y: y / Double(height)),
                                                      settings: fixed, sourceSize: size)
                return CGPoint(x: p.x * CGFloat(width), y: p.y * CGFloat(height))
            }
            let a = finished(50), b = finished(350)
            return atan2(Double(b.x - a.x), Double(b.y - a.y)) * 180 / .pi
        }
        assert(upright.vertical < -10 && angles.allSatisfy { abs($0) < 0.8 },
               "Upright sets converging verticals upright (\(upright), \(angles.map { String(format: "%.2f", $0) }))")
        assert(Upright.correction(luma: [Float](repeating: 0.5, count: width * height), width: width, height: height,
                                  mode: .auto) == nil, "a photo without lines has nothing to set upright")

        // Auto: a facade seen from the left — verticals upright, its horizontals meet far right
        let side = CGPoint(x: 3000, y: 180)
        var facade = [Float](repeating: 0.8, count: width * height)
        func plot(_ x: Double, _ y: Double) {
            for d in -1...1 {
                let xi = Int(x.rounded()), yi = Int(y.rounded()) + d
                if xi >= 0, xi < width, yi >= 0, yi < height { facade[yi * width + xi] = 0.1 }
            }
        }
        for left in stride(from: 20.0, through: 380.0, by: 40.0) {
            for x in 0..<width {
                let t = Double(x) / Double(side.x)
                plot(Double(x), left + (Double(side.y) - left) * t)
            }
        }
        for x in stride(from: 50, through: 550, by: 100) {
            for y in 0..<height { facade[y * width + x] = 0.1; facade[y * width + x + 1] = 0.1 }
        }
        guard let auto = Upright.correction(luma: facade, width: width, height: height, mode: .auto) else {
            preconditionFailure("a facade's lines are found")
        }
        var turnedFacade = DevelopSettings()
        turnedFacade.perspectiveVertical = auto.vertical
        turnedFacade.perspectiveHorizontal = auto.horizontal
        turnedFacade.straighten = auto.straighten
        let facadeAngles = stride(from: 20.0, through: 380.0, by: 40.0).map { left -> Double in
            func finished(_ x: Double) -> CGPoint {
                let y = left + (Double(side.y) - left) * x / Double(side.x)
                let p = DevelopGeometry.finishedPoint(fromSource: CGPoint(x: x / Double(width), y: y / Double(height)),
                                                      settings: turnedFacade, sourceSize: size)
                return CGPoint(x: p.x * CGFloat(width), y: p.y * CGFloat(height))
            }
            let a = finished(100), b = finished(500)
            return atan2(Double(b.y - a.y), Double(b.x - a.x)) * 180 / .pi
        }
        // before: from about +3° (top) to -4° (bottom); Auto takes most of that away
        let facadeSpread = (facadeAngles.max() ?? 0) - (facadeAngles.min() ?? 0)
        assert(auto.horizontal > 5 && facadeSpread < 2.5,
               "Auto turns a facade's horizontals most of the way to parallel (\(auto), \(facadeAngles.map { String(format: "%.2f", $0) }))")
    }

    /// A preset's Amount: sliders, white balance, curves and masks scale; the rest is all or nothing.
    private static func checkPresetBlend() {
        var base = DevelopSettings()
        base.exposure = 0.5
        var mask = LocalAdjustment(kind: .radial)
        mask.exposure = 1
        var target = base
        target.exposure = 1.5
        target.contrast = 60
        target.mixer.saturation[ColorMixer.Band.blue.rawValue] = -40
        target.grading.shadows = ColorGrading.Grade(hue: 200, saturation: 40, luminance: 0)
        target.temperature = 20
        target.curve.setPoints(ToneCurve.strongContrast, for: .rgb)
        target.masks = [mask]
        target.crop = DevelopCrop(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        func blend(_ amount: Double) -> DevelopSettings {
            DevelopSettings.blend(base, target, amount: amount, isRaw: false, whiteBalanceOrigin: (0, 0))
        }
        assert(blend(0) == base && blend(1) == target, "no amount is the photo before, full amount the preset")
        let half = blend(0.5)
        assert(abs(half.exposure - 1) < 1e-9 && half.contrast == 30 && half.mixer.saturation[ColorMixer.Band.blue.rawValue] == -20
               && half.grading.shadows.saturation == 20 && half.grading.shadows.hue == 200 && half.temperature == 10,
               "half the amount goes halfway, hues aside")
        let halfCurve = ToneCurve.evaluate(half.curve.editablePoints(for: .rgb), at: 0.25)
        assert(abs(halfCurve - 0.205) < 0.01, "the curve moves halfway too")
        assert(half.masks.first?.exposure == 0.5 && half.masks.first?.id == mask.id && half.crop == target.crop,
               "masks keep their shape and scale their adjustments; the crop comes whole")
        let double = blend(2)
        assert(double.contrast == 100 && abs(double.exposure - 2.5) < 1e-9, "twice the amount goes further and stays in range")
        var rawBase = DevelopSettings(), rawTarget = DevelopSettings()
        rawTarget.temperature = 6500
        rawBase.temperature = nil
        let rawHalf = DevelopSettings.blend(rawBase, rawTarget, amount: 0.5, isRaw: true, whiteBalanceOrigin: (5500, 0))
        assert(rawHalf.temperature == 6000, "a RAW's white balance moves from as shot")
    }

    /// Presets as .xmp files: this app's come back whole; Lightroom's map what both apps have.
    @MainActor
    private static func checkPresetFiles() {
        var settings = DevelopSettings()
        settings.temperature = 6200
        settings.tint = 8
        settings.exposure = 0.35
        settings.curve.setPoints(ToneCurve.mediumContrast, for: .rgb)
        settings.mixer.hue[ColorMixer.Band.blue.rawValue] = -12
        settings.grading.shadows = ColorGrading.Grade(hue: 210, saturation: 15, luminance: -5)
        settings.sharpening = 20
        settings.masks = [LocalAdjustment(kind: .sky)]
        let fields: Set<DevelopField> = [.whiteBalance, .exposure, .toneCurve, .colorMixer, .colorGrading, .sharpening, .masks]
        let preset = DevelopPreset(id: "p", name: "Moody <film>", transfer: DevelopTransfer(settings: settings, fields: fields,
                                                                                          sourceIsRaw: true), group: "Film")
        let text = DevelopPresetFile.xmp(for: preset)
        let back = DevelopPresetFile.read(Data(text.utf8), fileName: "x.xmp")
        assert(back?.preset.name == preset.name && back?.preset.group == "Film" && back?.preset.transfer == preset.transfer
               && back?.skipped.isEmpty == true, "this app's preset file comes back whole, masks included")
        // what Lightroom reads: the same file without the app's own property
        let crsOnly = text.replacingOccurrences(of: #"\s*pc:Preset="[^"]*""#, with: "", options: .regularExpression)
        let asLightroom = DevelopPresetFile.read(Data(crsOnly.utf8), fileName: "x.xmp")?.preset.transfer
        assert(text.contains("crs:Exposure2012=\"+0.35\"") && text.contains("crs:Sharpness=\"60\"")
               && asLightroom?.settings.exposure == 0.35 && asLightroom?.settings.temperature == 6200
               && asLightroom?.settings.sharpening == 20 && asLightroom?.settings.mixer.hue[ColorMixer.Band.blue.rawValue] == -12
               && asLightroom?.settings.grading.shadows == settings.grading.shadows
               && asLightroom.map { abs(ToneCurve.evaluate($0.settings.curve.editablePoints(for: .rgb), at: 0.25) - 0.21) < 0.01 } == true
               && asLightroom?.fields.contains(.masks) == false,
               "the Camera Raw properties carry what Lightroom has")

        let lightroom = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0-c000">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
           crs:PresetType="Normal" crs:Version="15.0" crs:ProcessVersion="11.0" crs:WhiteBalance="As Shot"
           crs:Contrast2012="+15" crs:SaturationAdjustmentOrange="-8" crs:Sharpness="40" crs:ColorNoiseReduction="25"
           crs:SplitToningShadowHue="220" crs:SplitToningShadowSaturation="18" crs:ConvertToGrayscale="False"
           crs:CameraProfile="Adobe Standard" crs:HasSettings="True">
           <crs:Name><rdf:Alt><rdf:li xml:lang="x-default">Matte</rdf:li></rdf:Alt></crs:Name>
           <crs:Group><rdf:Alt><rdf:li xml:lang="x-default">Film Looks</rdf:li></rdf:Alt></crs:Group>
           <crs:ToneCurvePV2012><rdf:Seq><rdf:li>0, 30</rdf:li><rdf:li>255, 240</rdf:li></rdf:Seq></crs:ToneCurvePV2012>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """
        let matte = DevelopPresetFile.read(Data(lightroom.utf8), fileName: "matte.xmp")
        let m = matte?.preset.transfer
        assert(matte?.preset.name == "Matte" && matte?.preset.group == "Film Looks"
               && m?.fields == [.whiteBalance, .contrast, .colorMixer, .sharpening, .noiseReduction, .colorGrading, .toneCurve, .profile]
               && m?.settings.profile == nil
               && m?.settings.temperature == nil && m?.settings.contrast == 15
               && m?.settings.mixer.saturation[ColorMixer.Band.orange.rawValue] == -8
               && m?.settings.sharpening == 0 && m?.settings.colorNoise == 0
               && m?.settings.grading.shadows.hue == 220 && m?.settings.grading.shadows.saturation == 18
               && m.map { abs(ToneCurve.evaluate($0.settings.curve.editablePoints(for: .rgb), at: 0) - 30.0 / 255) < 0.001 } == true
               && matte?.skipped.isEmpty == true,
               "a Lightroom preset maps what both apps have, Adobe Standard as Standard")
        func profiled(_ look: String, amount: String) -> DevelopPresetFile.Reading? {
            DevelopPresetFile.read(Data("""
            <x:xmpmeta xmlns:x="adobe:ns:meta/">
             <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
              <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
               crs:PresetType="Normal" crs:Version="15.0" crs:Contrast2012="+10" crs:CameraProfile="Adobe Standard"
               crs:HasSettings="True">
               <crs:Name><rdf:Alt><rdf:li xml:lang="x-default">Look</rdf:li></rdf:Alt></crs:Name>
               <crs:Look>
                <rdf:Description crs:Name="\(look)" crs:Amount="\(amount)" crs:UUID="EA1DE074F188405965EF399C72C221D9"
                 crs:SupportsAmount="false" crs:SupportsMonochrome="false" crs:SupportsOutputReferred="false">
                 <crs:Group><rdf:Alt><rdf:li xml:lang="x-default">Profiles</rdf:li></rdf:Alt></crs:Group>
                 <crs:Parameters><rdf:Description crs:Version="15.0" crs:ConvertToGrayscale="False"/></crs:Parameters>
                </rdf:Description>
               </crs:Look>
              </rdf:Description>
             </rdf:RDF>
            </x:xmpmeta>
            """.utf8), fileName: "look.xmp")
        }
        let vivid = profiled("Adobe Vivid", amount: "0.6"), creative = profiled("Modern 01", amount: "1")
        let monochrome = profiled("Adobe Monochrome", amount: "1")
        assert(monochrome?.preset.transfer.settings.profile == "monochrome" && monochrome?.skipped.isEmpty == true,
               "Adobe Monochrome is black and white")
        let grayscale = DevelopPresetFile.read(Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
         <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" crs:ConvertToGrayscale="True"
          crs:GrayMixerRed="+20" crs:GrayMixerBlue="-35" crs:HasSettings="True"/>
        </rdf:RDF></x:xmpmeta>
        """.utf8), fileName: "gray.xmp")?.preset.transfer
        assert(grayscale?.settings.profile == "monochrome" && grayscale?.settings.grayMixer[0] == 20
               && grayscale?.settings.grayMixer[ColorMixer.Band.blue.rawValue] == -35 && grayscale?.fields == [.profile, .grayMixer],
               "Camera Raw's black and white and its gray mix map to Monochrome and the mix")
        var bw = DevelopSettings()
        bw.profile = DevelopProfile.monochrome.stored
        bw.grayMixer[ColorMixer.Band.orange.rawValue] = 15
        let bwText = DevelopPresetFile.xmp(for: DevelopPreset(id: "bw", name: "BW", transfer: DevelopTransfer(
            settings: bw, fields: [.profile, .grayMixer], sourceIsRaw: true)))
        assert(bwText.contains(#"crs:ConvertToGrayscale="True""#) && bwText.contains(#"crs:GrayMixerOrange="+15""#),
               "a black-and-white preset tells Lightroom so")
        assert(vivid?.preset.transfer.settings.profile == "vivid" && vivid?.preset.transfer.settings.profileAmount == 60
               && vivid?.preset.transfer.fields == [.contrast, .profile] && vivid?.skipped.isEmpty == true,
               "a Lightroom profile with a near one here becomes it, at its amount")
        assert(creative?.preset.transfer.settings.profile == nil && creative?.preset.transfer.fields == [.contrast]
               && creative?.skipped == [.profile], "a creative profile with none near is left out and said so")
        assert(DevelopPresetFile.read(Data("not xml".utf8), fileName: "a.xmp") == nil
               && DevelopPresetFile.read(Data(#"<x:xmpmeta xmlns:x="adobe:ns:meta/"/>"#.utf8), fileName: "b.xmp") == nil,
               "files that aren't presets are refused")

        // importing and exporting through the app: taken names get a number
        let app = AppState.selfCheckFixture()
        let savedPresets = app.developPresets
        defer { app.developPresets = savedPresets }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pc-presets-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let written = AppState.writeDevelopPresets([preset, preset], to: folder)
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        assert(written == 2 && files == ["Moody -film-.xmp", "Moody -film- 2.xmp"].sorted(),
               "exported presets never overwrite a file")
        try? Data("garbage".utf8).write(to: folder.appendingPathComponent("garbage.xmp"))
        let before = app.developPresets.count
        let result = app.importDevelopPresets(from: (files + ["garbage.xmp"]).map { folder.appendingPathComponent($0) })
        let names = app.developPresets.dropFirst(before).map(\.name)
        assert(result.added == 2 && result.failed == 1 && names == ["Moody <film>", "Moody <film> 2"],
               "importing adds each preset once under a free name and counts what it couldn't read")
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
        _ = app.handleKey("y", hasCommand: false)
        assert(app.developComparing && !app.developShowsOriginal, "Y puts before and after side by side")
        app.developCropping = true
        assert(!app.developComparing, "a tool ends the comparison")
        app.developCropping = false
        app.developComparing = true
        _ = app.handleKey("z", hasCommand: false)
        assert(app.loupeZoom == nil && app.developComparing, "zoom stays off while comparing")
        _ = app.handleKey("escape", hasCommand: false)
        assert(!app.developComparing && app.view == .develop, "Esc ends the comparison and stays in Develop")
        app.developShowsOriginal = true

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
        app.developShowsOriginal = true
        _ = app.handleKey("delete", hasCommand: false)
        assert(app.developSettings["x"]?.masks.count == 1, "with the before view up, Delete removes nothing it doesn't show")
        app.developShowsOriginal = false
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

        // range masks: a color range starts by sampling; clicks add colors, the oldest making way
        let beforeRanges = app.developSettings["x"]
        app.view = .develop
        app.developMasking = true
        undo.beginUndoGrouping()
        var ranged = LocalAdjustment(kind: .radial)
        ranged.exposure = 1
        app.commitDevelop(["x": { var e = DevelopSettings(); e.masks = [ranged]; return e }()], undoName: "radial")
        app.developSelectedMaskId = ranged.id
        app.setMaskRange(.color, maskId: ranged.id, assetId: "x")
        assert(app.developSettings["x"]?.masks.first?.range?.kind == .color && app.developPickingRangeColor,
               "narrowing to a color range starts sampling")
        for i in 0..<6 { app.addRangeSample(CGPoint(x: 0.1 * Double(i), y: 0.5), maskId: ranged.id, assetId: "x") }
        let samples = app.developSettings["x"]?.masks.first?.range?.samples ?? []
        assert(samples.count == MaskRange.maxSamples && samples.first?.x == 0.1, "samples stop at five, the oldest going")
        _ = app.handleKey("escape", hasCommand: false)
        assert(!app.developPickingRangeColor && app.developMasking, "Esc ends sampling first")
        app.setMaskRange(nil, maskId: ranged.id, assetId: "x")
        assert(app.developSettings["x"]?.masks.first?.range == nil, "a range can be taken off again")
        undo.endUndoGrouping()
        app.developSettings["x"] = beforeRanges
        app.view = .grid

        // spot tool: exclusive with the other tools; Delete removes the selected spot, not the photo
        app.view = .develop
        var withSpot = app.developSettings["x"] ?? .neutral
        let spot = SpotRemoval(target: CGPoint(x: 0.3, y: 0.3), source: CGPoint(x: 0.4, y: 0.3), radius: 0.02)
        withSpot.spots = [spot]
        undo.beginUndoGrouping()
        app.commitDevelop(["x": withSpot], undoName: "spot")
        undo.endUndoGrouping()
        app.developMasking = true
        app.developSpotting = true
        assert(!app.developMasking && app.developSpotting, "the spot tool closes the masking tool")
        app.developSelectedSpotId = spot.id
        _ = app.handleKey("]", hasCommand: false)
        assert(app.developSpotBrush.size == 14, "] enlarges the spot brush")
        undo.beginUndoGrouping()
        _ = app.handleKey("delete", hasCommand: false)
        undo.endUndoGrouping()
        assert(app.developSettings["x"]?.spots.isEmpty == true && app.view == .develop, "Delete removes the selected spot")
        undo.undo()
        assert(app.developSettings["x"]?.spots.count == 1, "undo brings the spot back")
        app.developVisualizeSpots = true
        _ = app.handleKey("escape", hasCommand: false)
        assert(!app.developSpotting && !app.developVisualizeSpots && app.view == .develop,
               "Esc closes the spot tool and its dust view")
        app.developSpotting = true
        app.developCropping = true
        assert(!app.developSpotting, "the crop tool closes the spot tool")
        app.view = .grid

        // background work (a spot's source found, auto tone measured) saves its change and keeps
        // a drag in progress, adding the change to it; a commit for another photo leaves it alone
        var dragging = DevelopSettings()
        dragging.exposure = 1
        app.updateDevelopDraft(dragging, for: "d")
        app.commitDevelop(["other": DevelopSettings()], undoName: "other")
        assert(app.developDraft?.assetId == "d", "saving another photo keeps the drag")
        undo.beginUndoGrouping()
        app.commitDevelopChange(["d"], undoName: "spot") { _, settings in
            settings.spots.append(SpotRemoval(target: CGPoint(x: 0.4, y: 0.4), source: CGPoint(x: 0.5, y: 0.4), radius: 0.01))
        }
        undo.endUndoGrouping()
        assert(app.developSettings["d"]?.spots.count == 1 && app.developSettings["d"]?.exposure == 0
               && app.developDraft?.settings.spots.count == 1 && app.developDraft?.settings.exposure == 1,
               "a background change is saved and reaches the drag in progress")
        app.developDraft = nil

        // history: each edit adds a step, undo takes it away, redo puts it back; returning to a
        // step is itself a step
        assert(app.developHistory(for: "h").isEmpty, "a new photo has no history")
        var first = DevelopSettings(); first.exposure = 0.4
        var second = first; second.contrast = 30
        for (value, name) in [(first, "调整曝光度"), (second, "调整对比度")] {
            undo.beginUndoGrouping()
            app.commitDevelop(["h": value], undoName: name)
            undo.endUndoGrouping()
        }
        assert(app.developHistory(for: "h").map(\.name) == ["调整曝光度", "调整对比度"], "each edit adds a history step")
        undo.undo()
        assert(app.developHistory(for: "h").map(\.name) == ["调整曝光度"] && app.developSettings["h"] == first,
               "undo takes the step away")
        undo.redo()
        assert(app.developHistory(for: "h").count == 2 && app.developSettings["h"] == second, "redo puts it back")
        undo.beginUndoGrouping()
        app.applyDevelopHistoryStep(app.developHistory(for: "h")[0], to: "h")
        undo.endUndoGrouping()
        assert(app.developSettings["h"] == first && app.developHistory(for: "h").count == 3,
               "returning to a step restores it as a new step")
        undo.beginUndoGrouping()
        app.applyDevelopHistoryStep(app.developHistory(for: "h")[1], to: "h")
        undo.endUndoGrouping()
        undo.beginUndoGrouping()
        app.applyDevelopHistoryStep(app.developHistory(for: "h")[2], to: "h")
        undo.endUndoGrouping()
        let names = app.developHistory(for: "h").map(\.name)
        assert(names.last == L("历史记录：\("调整曝光度")") && !names.contains { $0.hasPrefix(L("历史记录：") + L("历史记录：")) },
               "returning to a history step doesn't nest its name")

        // snapshots keep a state to come back to
        app.createDevelopSnapshot(for: "h")
        let kept = app.developSnapshots(for: "h")
        assert(kept.count == 1 && kept[0].settings == first, "a snapshot keeps the current settings")
        app.renameDevelopSnapshot(kept[0].id, to: "  Soft  ", for: "h")
        undo.beginUndoGrouping()
        app.commitDevelop(["h": second], undoName: "调整对比度")
        undo.endUndoGrouping()
        undo.beginUndoGrouping()
        app.applyDevelopSnapshot(app.developSnapshots(for: "h")[0], to: "h")
        undo.endUndoGrouping()
        assert(app.developSettings["h"] == first && app.developSnapshots(for: "h")[0].name == "Soft",
               "applying a snapshot restores its settings; names are trimmed")
        undo.beginUndoGrouping()
        app.commitDevelop(["h": second], undoName: "调整对比度")
        undo.endUndoGrouping()
        app.updateDevelopSnapshot(kept[0].id, for: "h")
        let updated = app.developSnapshots(for: "h")
        assert(updated.count == 1 && updated[0].id == kept[0].id && updated[0].name == "Soft" && updated[0].settings == second,
               "updating a snapshot replaces its settings without changing its identity or name")
        app.deleteDevelopSnapshot(kept[0].id, for: "h")
        assert(app.developSnapshots(for: "h").isEmpty, "snapshots delete")
        app.clearDevelopHistory(for: "h")
        assert(app.developHistory(for: "h").isEmpty && app.developSettings["h"] == second,
               "clearing history keeps the current settings")
    }
}
