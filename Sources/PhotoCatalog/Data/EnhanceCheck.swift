import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// Enhance with the bundled models: super resolution enlarges with sharper edges than
/// interpolation and keeps tones; the denoiser takes noise away and keeps edges; the result is
/// written as a 16-bit TIFF carrying the original's metadata.
enum EnhanceCheck {
    static func run() {
        guard AIModels.isAvailable(.superResolution), AIModels.isAvailable(.denoise) else {
            assertionFailure("the AI models are in Resources/Models (script/models/convert.py)")
            return
        }
        checkSuperResolution()
        checkDenoise()
        checkTIFF()
        checkRemove()
        print("--- enhance assertions passed ---")
    }

    /// Planes from a value per pixel (the same in all three channels).
    private static func planes(_ width: Int, _ height: Int, _ value: (Int, Int) -> Float) -> Enhance.Planes {
        var values = [Float16](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let v = Float16(min(1, max(0, value(x, y))))
                for channel in 0..<3 { values[(channel * height + y) * width + x] = v }
            }
        }
        return Enhance.Planes(width: width, height: height, values: values)
    }

    private static func checkSuperResolution() {
        // a disc, a little soft as a lens leaves it, on mid gray; 150 × 110, not a whole number of tiles
        let soft = planes(150, 110) { x, y in
            let d = hypot(Float(x) - 60, Float(y) - 55) - 30
            return 0.5 + 0.35 * (1 - min(1, max(0, (d + 1) / 2)))
        }
        guard let large = Enhance.superResolution(soft) else { return assertionFailure("super resolution ran") }
        assert(large.width == 300 && large.height == 220, "super resolution doubles the width and height")
        // across the disc's edge, the steepest step beats plain interpolation's
        func steepest(_ p: Enhance.Planes, row: Int, scale: Int) -> Float {
            var best: Float = 0
            for x in 1..<p.width { best = max(best, abs(Float(p.value(1, x, row)) - Float(p.value(1, x - 1, row)))) }
            return best * Float(scale)   // per source pixel
        }
        let interpolated = steepest(soft, row: 55, scale: 1) / 2   // a linear enlargement halves the step per pixel
        assert(steepest(large, row: 110, scale: 1) > interpolated * 1.3, "super resolution draws a crisper edge than interpolation")
        let flat = Float(large.value(1, 280, 20)), inside = Float(large.value(1, 120, 110))
        assert(abs(flat - 0.5) < 0.04 && abs(inside - 0.85) < 0.05, "and keeps the tones")
    }

    private static func checkDenoise() {
        // a dark square on gray with noise of σ 0.06, as from a high ISO
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        func gaussian() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let u1 = max(Float(seed >> 40) / Float(1 << 24), 1e-7)
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let u2 = Float(seed >> 40) / Float(1 << 24)
            return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        }
        let clean: (Int, Int) -> Float = { x, y in (x >= 110 && x < 190 && y >= 70 && y < 150) ? 0.2 : 0.55 }
        let noisy = planes(300, 220) { x, y in clean(x, y) + 0.06 * gaussian() }
        func spread(_ p: Enhance.Planes, _ region: (Range<Int>, Range<Int>)) -> (mean: Float, deviation: Float) {
            var values: [Float] = []
            for y in region.1 { for x in region.0 { values.append(Float(p.value(1, x, y))) } }
            let mean = values.reduce(0, +) / Float(values.count)
            return (mean, (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(values.count)).squareRoot())
        }
        let background = (20..<90, 20..<200), square = (120..<180, 80..<140)
        guard let full = Enhance.denoise(noisy, amount: 100), let half = Enhance.denoise(noisy, amount: 50),
              let none = Enhance.denoise(noisy, amount: 0) else { return assertionFailure("the denoiser ran") }
        let before = spread(noisy, background).deviation, after = spread(full, background).deviation
        assert(after < before * 0.35, "denoising takes most of the noise away (σ \(before) → \(after))")
        assert(abs(spread(full, background).mean - spread(full, square).mean - 0.35) < 0.05,
               "and keeps the square as dark against the gray")
        let halfway = spread(half, background).deviation
        assert(halfway > after && halfway < before, "a lower amount keeps some of the original")
        assert(zip(none.values, noisy.values).allSatisfy { abs(Float($0) - Float($1)) < 0.002 }, "amount 0 changes nothing")

        // both steps together: denoised, then enlarged
        let image = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 96, height: 64))
        var options = Enhance.Options()
        options.superResolution = true
        let both = Enhance.enhance(image, options: options)
        assert(both?.width == 192 && both?.height == 128, "Enhance denoises and enlarges in one go")
    }

    private static func checkTIFF() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pc-enhance-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // an "original": a JPEG from a camera, turned by its orientation tag
        let original = folder.appendingPathComponent("IMG_1.jpg")
        let pixels = planes(40, 30) { x, _ in Float(x) / 40 }
        guard let small = Enhance.image(pixels),
              let destination = CGImageDestinationCreateWithURL(original as CFURL, "public.jpeg" as CFString, 1, nil)
        else { return assertionFailure("an original was made") }
        CGImageDestinationAddImage(destination, small, [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "Test Camera", kCGImagePropertyTIFFOrientation: 6],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifISOSpeedRatings: [6400]],
        ] as CFDictionary)
        CGImageDestinationFinalize(destination)
        let output = folder.appendingPathComponent("IMG_1-Enhanced.tif")
        assert(Enhance.writeTIFF(small, to: output, metadataFrom: original), "the result is written")
        let source = CGImageSourceCreateWithURL(output as CFURL, nil)
        let properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [CFString: Any]
        let tiff = properties?[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = properties?[kCGImagePropertyExifDictionary] as? [CFString: Any]
        assert(properties?[kCGImagePropertyDepth] as? Int == 16 && tiff?[kCGImagePropertyTIFFModel] as? String == "Test Camera"
               && (exif?[kCGImagePropertyExifISOSpeedRatings] as? [Int]) == [6400]
               && (properties?[kCGImagePropertyOrientation] as? Int ?? 1) == 1 && tiff?[kCGImagePropertyTIFFCompression] as? Int == 5,
               "a 16-bit compressed TIFF with the original's camera details, upright")
    }

    /// Smart remove: a dark disc on a gradient is filled with the gradient, and the fill follows
    /// an exposure change made afterwards.
    private static func checkRemove() {
        guard AIModels.isAvailable(.inpaint) else { return assertionFailure("the inpainting model is bundled") }
        let width = 480, height = 360
        let scene = planes(width, height) { x, y in
            let background = 0.3 + 0.4 * Float(x) / Float(width)
            return hypot(Float(x) - 240, Float(y) - 180) < 30 ? 0.05 : background
        }
        guard let image = Enhance.image(scene) else { return assertionFailure("a scene was drawn") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pc-remove-\(UUID().uuidString).tif")
        defer { try? FileManager.default.removeItem(at: url) }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)

        var stroke = BrushStroke()
        stroke.radius = 40.0 / 480   // a little wider than the disc
        stroke.feather = 30
        stroke.append(CGPoint(x: 0.5, y: 0.5))
        var spot = SpotRemoval(target: CGPoint(x: 0.5, y: 0.5), source: CGPoint(x: 0.5, y: 0.5), radius: stroke.radius)
        spot.mode = .remove
        spot.strokes = [stroke]
        var settings = DevelopSettings()
        settings.spots = [spot]
        defer { GenerativeFill.forget(index: 0, settings: settings, url: url) }
        guard GenerativeFill.fill(for: 0, settings: settings, url: url, isRaw: false) != nil,
              let source = DevelopRenderer.Source(url: url, isRaw: false, maxPixel: nil) else {
            return assertionFailure("a fill was made")
        }
        func luma(_ settings: DevelopSettings, _ x: Int, _ y: Int) -> Float {
            guard let rendered = source.image(settings), let planes = Enhance.planes(of: rendered) else { return -1 }
            return Float(planes.value(1, x, y))
        }
        let filled = luma(settings, 240, 180), around = luma(settings, 180, 180), beside = luma(settings, 300, 180)
        assert(filled > 0.2 && abs(filled - (around + beside) / 2) < 0.08,
               "removing fills the disc with the gradient around it (\(filled) between \(around) and \(beside))")
        assert(abs(luma(settings, 40, 40) - luma(.neutral, 40, 40)) < 0.01, "and leaves the rest alone")
        // the same fill, after the photo is made brighter: it matches its new surroundings
        var brighter = settings
        brighter.exposure = 1
        let brightFilled = luma(brighter, 240, 180), brightAround = (luma(brighter, 180, 180) + luma(brighter, 300, 180)) / 2
        assert(abs(brightFilled - brightAround) < 0.08, "the fill follows a later exposure change (\(brightFilled) vs \(brightAround))")
        let stored = (try? JSONEncoder().encode(spot)).flatMap { try? JSONDecoder().decode(SpotRemoval.self, from: $0) }
        var moved = spot
        moved.strokes[0].points[0] += 0.01
        assert(stored == spot && moved.fingerprintText != spot.fingerprintText, "a remove spot keeps what was painted")
    }
}
