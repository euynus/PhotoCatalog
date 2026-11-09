import Foundation
import CoreImage

extension DevelopCheck {
    static func checkPresence() {
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

    static func checkEffects() {
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

    static func checkAutoAdjustments() {
        // eyedropper: a warm gray becomes neutral where it was picked
        let warm = image { _, _ in (0.56, 0.5, 0.43) }
        let warmFile = CheckImages.temporaryPNG(warm, prefix: "pc-auto-")
        defer { try? FileManager.default.removeItem(at: warmFile) }
        let balance = DevelopAuto.whiteBalance(url: warmFile, isRaw: false, settings: .neutral, point: CGPoint(x: 0.5, y: 0.5))
        var s = DevelopSettings()
        s.temperature = balance?.temperature
        s.tint = balance?.tint
        let picked = pixel(develop(warm, s), 32, 32)
        assert(balance != nil && abs(Int(picked.r) - Int(picked.b)) <= 6
               && abs(Int(picked.g) - (Int(picked.r) + Int(picked.b)) / 2) <= 6,
               "the eyedropper makes the picked color gray")
        let black = CheckImages.temporaryPNG(image { _, _ in (0, 0, 0) }, prefix: "pc-auto-")
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
        let castFile = CheckImages.temporaryPNG(castScene, prefix: "pc-auto-")
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
        let allBlue = CheckImages.temporaryPNG(image { _, _ in (0.1, 0.2, 0.8) }, prefix: "pc-auto-")
        defer { try? FileManager.default.removeItem(at: allBlue) }
        assert(DevelopAuto.autoWhiteBalance(url: allBlue, isRaw: false, settings: .neutral) == nil,
               "auto white balance declines a photo with nothing near gray")

        // auto tone: dark photos brighten, bright ones darken, a full-range one barely moves
        func gradient(_ from: Double, _ to: Double) -> URL {
            let ramp = image { x, _ in let v = from + (to - from) * Double(x) / 63; return (v, v, v) }
            return CheckImages.temporaryPNG(ramp, prefix: "pc-auto-")
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
    static func checkBoostCurve() {
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

    static func checkHistogram() {
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
}
