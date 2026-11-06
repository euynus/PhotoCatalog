import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

extension DevelopCheck {
    static func checkToneCurve() {
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

    static func checkColorMixer() {
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
    static func checkProfiles() {
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
    static func checkBlackAndWhite() {
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
    static func checkCalibration() {
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
    static func checkSoftProofing() {
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
    static func checkSoftProofingState() {
        let saved = UserDefaults.app.data(forKey: "pc_softProof")
        defer { UserDefaults.app.set(saved, forKey: "pc_softProof") }
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

    static func checkColorGrading() {
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
}
