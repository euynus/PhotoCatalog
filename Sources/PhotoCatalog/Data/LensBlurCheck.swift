import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Lens blur: every develop kernel compiles; the setting persists and travels as one; a depth
/// map stores, reads and lines up with the photo; the blur falls outside the band in focus; the
/// default focus lands on a face or the subject; the bundled model sees a floor recede.
enum LensBlurCheck {
    static func run() {
        assert(DevelopKernels.failedKernels.isEmpty, "every develop kernel compiles: \(DevelopKernels.failedKernels)")
        checkSettings()
        checkMap()
        checkRendering()
        checkFocus()
        checkModel()
        print("--- lens blur assertions passed ---")
    }

    private static func checkSettings() {
        var settings = DevelopSettings()
        settings.lensBlur.amount = 80
        assert(!settings.hasLensBlur && settings.fingerprint == DevelopSettings().fingerprint,
               "a lens blur that's off changes nothing")
        settings.lensBlur.enabled = true
        settings.lensBlur.focus = 0.35
        settings.lensBlur.range = 40
        var moved = settings
        moved.lensBlur.focus = 0.6
        assert(settings.hasLensBlur && settings.fingerprint != DevelopSettings().fingerprint
               && moved.fingerprint != settings.fingerprint, "lens blur and its focus change the fingerprint")

        let stored = try! JSONDecoder().decode(DevelopSettings.self, from: JSONEncoder().encode(settings))
        var older = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(DevelopSettings())) as! [String: Any]
        older["lensBlur"] = nil
        let fromOlder = try! JSONDecoder().decode(DevelopSettings.self, from: JSONSerialization.data(withJSONObject: older))
        let partial = try! JSONDecoder().decode(LensBlur.self, from: Data(#"{"enabled": true}"#.utf8))
        assert(stored == settings && fromOlder.lensBlur == LensBlur()
               && partial.enabled && partial.amount == 50 && partial.focus == 0.8 && partial.range == 20,
               "lens blur persists, and settings saved before it read as off")

        assert(DevelopSettings().applying(settings, fields: [.lensBlur]).lensBlur == settings.lensBlur
               && DevelopSettings().applying(settings, fields: DevelopField.defaultCopy).lensBlur == LensBlur()
               && DevelopField.lensBlur.isAdjusted(in: settings),
               "lens blur copies as one setting, left behind unless asked: its focus belongs to one photo")

        let half = DevelopSettings.blend(DevelopSettings(), settings, amount: 0.5, isRaw: false, whiteBalanceOrigin: nil)
        let fading = DevelopSettings.blend(settings, DevelopSettings(), amount: 0.5, isRaw: false, whiteBalanceOrigin: nil)
        assert(half.hasLensBlur && half.lensBlur.amount == 40 && half.lensBlur.focus == 0.35
               && fading.hasLensBlur && fading.lensBlur.amount == 40,
               "a preset's lens blur grows from no blur and fades to none")
    }

    private static func checkMap() {
        // top row 0 and 1, bottom row both 0.5
        let map = DepthMap.Map(width: 2, height: 2, values: [0, 1, 0.5, 0.5])
        assert(map.depth(at: CGPoint(x: 0.25, y: 0.25)) == 0 && map.depth(at: CGPoint(x: 0.75, y: 0.25)) == 1
               && abs(map.depth(at: CGPoint(x: 0.5, y: 0.25)) - 0.5) < 1e-6 && abs(map.depth(at: CGPoint(x: 0.25, y: 0.5)) - 0.25) < 1e-6,
               "depth is read between the map's cells, rows from the top")
        assert(map.percentile(0) == 0 && map.percentile(0.5) == 0.5 && map.percentile(0.99) == 1, "percentiles")
        let data = DepthMap.encoded(map)
        assert(DepthMap.decoded(data) == map && DepthMap.decoded(data.dropLast()) == nil && DepthMap.decoded(Data()) == nil,
               "a stored map reads back, and a cut-off one doesn't")

        // one column: near on top, far below
        let image = DepthMap.image(DepthMap.Map(width: 1, height: 2, values: [1, 0]), extent: CGRect(x: 0, y: 0, width: 10, height: 20), guide: nil)
        assert(image.extent == CGRect(x: 0, y: 0, width: 10, height: 20) && value(image, x: 5, y: 18) > 0.9 && value(image, x: 5, y: 1) < 0.1,
               "the map's first row is the photo's top (Core Image's y points up)")
        let mask = DevelopKernels.lensBlurMask(image, focus: 1, inner: 0.06, soft: 0.12)
        assert(value(mask, x: 5, y: 18) < 0.05 && value(mask, x: 5, y: 1) > 0.95, "what's at the focal depth stays sharp")
    }

    /// The red channel of `image` at (`x`, `y`) in Core Image's coordinates.
    private static func value(_ image: CIImage, x: CGFloat, y: CGFloat) -> Float {
        var pixel = [Float](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()]).render(image, toBitmap: &pixel, rowBytes: 16,
            bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return pixel[0]
    }

    /// Writes `image` to a temporary PNG, as a photo on disk.
    private static func pngFile(_ image: CGImage) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pc-lensblur-\(UUID().uuidString).png")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return url
    }

    /// A `width` × `height` RGB image from a color per pixel, rows from the top.
    private static func picture(_ width: Int, _ height: Int, _ color: (Int, Int) -> (Double, Double, Double)) -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let c = color(x, y), i = (y * width + x) * 4
                pixels[i] = UInt8(c.0 * 255); pixels[i + 1] = UInt8(c.1 * 255); pixels[i + 2] = UInt8(c.2 * 255)
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: DevelopRenderer.outputColorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// How much the gray level swings across rows `rows` of `image`: the stripes' contrast.
    private static func contrast(_ image: CGImage, rows: Range<Int>) -> Double {
        let pixels = SemanticMasks.rgba(image)!
        var values: [Double] = []
        for y in rows {
            for x in 8..<(image.width - 8) { values.append(Double(pixels[(y * image.width + x) * 4 + 1]) / 255) }
        }
        let mean = values.reduce(0, +) / Double(values.count)
        return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
    }

    private static func checkRendering() {
        // fine stripes everywhere; the top half far away, the bottom half near
        let stripes = picture(256, 256) { x, _ in x / 2 % 2 == 0 ? (0.2, 0.2, 0.2) : (0.8, 0.8, 0.8) }
        let url = pngFile(stripes)
        defer { try? FileManager.default.removeItem(at: url) }
        DepthMap.remember(DepthMap.Map(width: 4, height: 4, values: (0..<16).map { $0 < 8 ? 0.1 : 0.9 }), for: url)
        let source = DevelopRenderer.Source(url: url, isRaw: false, maxPixel: nil)!
        var settings = DevelopSettings()
        settings.lensBlur.enabled = true
        settings.lensBlur.amount = 100
        settings.lensBlur.focus = 0.9
        let plain = DevelopRenderer.render(source.image(DevelopSettings())!)!
        let blurred = DevelopRenderer.render(source.image(settings)!)!
        let top = 16..<96, bottom = 160..<240
        assert(contrast(blurred, rows: top) < contrast(plain, rows: top) * 0.3
               && contrast(blurred, rows: bottom) > contrast(plain, rows: bottom) * 0.9,
               "the far half blurs and the near half, in focus, stays sharp")
        settings.lensBlur.focus = 0.1
        let refocused = DevelopRenderer.render(source.image(settings)!)!
        assert(contrast(refocused, rows: top) > contrast(plain, rows: top) * 0.9
               && contrast(refocused, rows: bottom) < contrast(plain, rows: bottom) * 0.3, "focusing far blurs the near half instead")

        let depth = SemanticMasks.rgba(DevelopRenderer.render(source.image(DevelopSettings(), visualizeDepth: true)!)!)!
        func color(_ y: Int) -> (r: UInt8, b: UInt8) { (depth[(y * 256 + 128) * 4], depth[(y * 256 + 128) * 4 + 2]) }
        assert(color(40).b > color(40).r && color(220).r > color(220).b, "the depth view shows far cool and near warm")
    }

    private static func checkFocus() {
        // depth by row: 0 at the top to 1 at the bottom
        let map = DepthMap.Map(width: 10, height: 10, values: (0..<100).map { Float($0 / 10) / 9 })
        let small = CGRect(x: 0.7, y: 0.8, width: 0.1, height: 0.1), large = CGRect(x: 0.3, y: 0.2, width: 0.3, height: 0.3)
        // the large face's middle runs from 0.275 to 0.425 down, depth (y × 10 − 0.5) / 9
        assert(abs(DepthMap.focus(map, faces: [small, large], subject: nil) - 3.0 / 9) < 0.02, "the focus goes to the largest face")

        func subject(top: Bool, share: Double) -> CGImage {
            let context = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            context.setFillColor(gray: 1, alpha: 1)
            // a context's y points up
            context.fill(CGRect(x: 0, y: top ? 40 * (1 - share) : 0, width: 40, height: 40 * share))
            return context.makeImage()!
        }
        let upper = DepthMap.focus(map, faces: [], subject: subject(top: true, share: 0.4))
        let lower = DepthMap.focus(map, faces: [], subject: subject(top: false, share: 0.4))
        assert(upper < 0.3 && lower > 0.7, "without a face, the focus is the subject's middle depth")
        assert(DepthMap.focus(map, faces: [], subject: subject(top: true, share: 0.002)) == map.percentile(0.85)
               && DepthMap.focus(map, faces: [], subject: nil) == map.percentile(0.85),
               "without a face or subject, the focus is the nearest major part")
    }

    private static func checkModel() {
        guard AIModels.isAvailable(.depth) else { return assertionFailure("the depth model is bundled") }
        // a pale sky over a checkered floor running to the horizon
        let width = 512, height = 384, horizon = 150.0
        let scene = picture(width, height) { x, y in
            guard Double(y) > horizon + 0.5 else { return (0.7, 0.8, 0.95) }
            let distance = 120 / (Double(y) - horizon), across = (Double(x) - Double(width) / 2) * distance / 120
            let light = (Int(floor(across * 4)) + Int(floor(distance * 4))) % 2 == 0
            return light ? (0.85, 0.82, 0.75) : (0.3, 0.25, 0.2)
        }
        let url = pngFile(scene)
        defer { try? FileManager.default.removeItem(at: url) }
        guard let map = DepthMap.compute(url: url, isRaw: false) else { return assertionFailure("the depth model ran") }
        let near = map.depth(at: CGPoint(x: 0.5, y: 0.95)), far = map.depth(at: CGPoint(x: 0.5, y: 0.45))
        assert(map.values.count == map.width * map.height && near > far + 0.2,
               "the model sees the floor's near edge nearer than its far end")
    }
}
