import Foundation
import CoreImage

extension DevelopCheck {
    static func checkRendering() {
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

    static func checkDetail() {
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
}
