// ============================================================
//  DevelopAuto — white balance from a neutral point, automatic tone
// ============================================================
import CoreImage
import Foundation

/// Solves for settings by rendering the photo small and measuring the result, so every stage
/// of the pipeline (RAW decode, tone, geometry) is accounted for without inverting any of it.
/// Synchronous and slow-ish (a few dozen small renders): run off the main thread and off the
/// cooperative pool, which RAW decoding can deadlock.
enum DevelopAuto {
    private static let workingPixel = 512

    /// Linear display-P3 color averaged over a small square at `point` (fractions of the image,
    /// top-left origin).
    static func sample(_ image: CIImage, at point: CGPoint) -> SIMD3<Double>? {
        let extent = image.extent
        let side = max(3, (max(extent.width, extent.height) * 0.01).rounded())
        let center = CGPoint(x: extent.minX + point.x * extent.width, y: extent.maxY - point.y * extent.height)
        let rect = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
            .integral.intersection(extent)
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return nil }
        let width = Int(rect.width), height = Int(rect.height)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        DevelopRenderer.context.render(image, toBitmap: &pixels, rowBytes: width * 16, bounds: rect,
                                       format: .RGBAf, colorSpace: DevelopRenderer.linearColorSpace)
        var sum = SIMD3<Double>(repeating: 0)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            sum += SIMD3(Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2]))
        }
        return sum / Double(width * height)
    }

    /// Temperature and tint that render the photo gray at `point` (fractions of the finished,
    /// cropped photo); nil when the point is too dark or too bright to judge its color.
    static func whiteBalance(url: URL, isRaw: Bool, settings: DevelopSettings,
                             point: CGPoint) -> (temperature: Double, tint: Double)? {
        guard let source = DevelopRenderer.Source(url: url, isRaw: isRaw, maxPixel: workingPixel) else { return nil }
        // RAW Kelvin is searched in mireds, where equal steps look equally warmer; other formats
        // use their relative scale directly
        let temperatureRange: ClosedRange<Double> = isRaw ? 2000...12000 : -100...100
        let tintRange: ClosedRange<Double> = isRaw ? -150...150 : -100...100
        func toParameter(_ temperature: Double) -> Double { isRaw ? 1_000_000 / temperature : temperature }
        func fromParameter(_ value: Double) -> Double { isRaw ? 1_000_000 / value : value }
        let asShotTemperature = source.asShotTemperature ?? 5500
        // the search stays inside the sliders' ranges (mireds run opposite to Kelvin)
        let lower = SIMD2(isRaw ? toParameter(temperatureRange.upperBound) : temperatureRange.lowerBound, tintRange.lowerBound)
        let upper = SIMD2(isRaw ? toParameter(temperatureRange.lowerBound) : temperatureRange.upperBound, tintRange.upperBound)
        var x = SIMD2(toParameter(settings.temperature ?? (isRaw ? asShotTemperature : 0)),
                      settings.tint ?? (isRaw ? source.asShotTint ?? 0 : 0)).clamped(lowerBound: lower, upperBound: upper)
        let step = SIMD2(isRaw ? 4.0 : 2.0, 2.0)

        func trial(at x: SIMD2<Double>) -> DevelopSettings {
            var next = settings
            next.temperature = fromParameter(x.x)
            next.tint = x.y
            return next
        }
        /// How far from gray the point renders: log red/green and log blue/green.
        func residual(_ x: SIMD2<Double>, draft: Bool) -> SIMD2<Double>? {
            guard let image = source.image(trial(at: x), draft: draft), let c = sample(image, at: point),
                  c.min() > 0.002, c.max() < 0.97 else { return nil }
            return SIMD2(log(c.x / c.y), log(c.z / c.y))
        }

        // Newton steps on the fast path (white balance as a shift of the decoded stage), then
        // two corrections on accurate renders, reusing the last slopes. A cast beyond the
        // sliders' reach ends at the nearest setting they allow.
        var jacobian: (SIMD2<Double>, SIMD2<Double>)?
        for iteration in 0..<9 {
            let draft = iteration < 7
            guard let r = residual(x, draft: draft) else { return nil }
            if abs(r.x) < 0.003 && abs(r.y) < 0.003 { if draft { continue } else { break } }
            if draft {
                // at a range limit, measure the slope on the inward side
                let hx = x.x + step.x > upper.x ? -step.x : step.x
                let hy = x.y + step.y > upper.y ? -step.y : step.y
                guard let rx = residual(x + SIMD2(hx, 0), draft: true),
                      let ry = residual(x + SIMD2(0, hy), draft: true) else { return nil }
                jacobian = ((rx - r) / hx, (ry - r) / hy)
            }
            guard let (dx, dy) = jacobian else { break }
            let determinant = dx.x * dy.y - dy.x * dx.y
            guard abs(determinant) > 1e-9 else { break }
            var delta = SIMD2(-(dy.y * r.x - dy.x * r.y) / determinant, -(-dx.y * r.x + dx.x * r.y) / determinant)
            let limit = SIMD2(isRaw ? 40.0 : 25.0, 25.0)
            delta = delta.clamped(lowerBound: -limit, upperBound: limit)
            let next = (x + delta).clamped(lowerBound: lower, upperBound: upper)
            if next == x { break }   // pinned at a limit
            x = next
        }
        return (fromParameter(x.x).rounded(), x.y.rounded())
    }

    /// Exposure, highlights, shadows, whites and blacks chosen from the photo's tones; every
    /// other setting is kept. Nil when the photo can't be rendered.
    static func tone(url: URL, isRaw: Bool, settings: DevelopSettings) -> DevelopSettings? {
        guard let source = DevelopRenderer.Source(url: url, isRaw: isRaw, maxPixel: workingPixel) else { return nil }
        var s = settings
        s.exposure = 0; s.contrast = 0; s.highlights = 0; s.shadows = 0; s.whites = 0; s.blacks = 0

        /// Sorted display-encoded lumas of a small render. Drafts apply exposure as a gain on
        /// the cached RAW stage, after the RAW engine's tone curve, so they only match the photo
        /// near the stage's own exposure; an accurate render moves the stage to `s.exposure`.
        func lumas(_ s: DevelopSettings, accurate: Bool = false) -> [Double]? {
            guard var image = source.image(s, draft: !accurate) else { return nil }
            let longEdge = max(image.extent.width, image.extent.height)
            if longEdge > 200 { image = image.transformed(by: CGAffineTransform(scaleX: 200 / longEdge, y: 200 / longEdge)) }
            let rect = image.extent.integral
            let width = Int(rect.width), height = Int(rect.height)
            guard width > 0, height > 0 else { return nil }
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            DevelopRenderer.context.render(image, toBitmap: &pixels, rowBytes: width * 4, bounds: rect,
                                           format: .RGBA8, colorSpace: DevelopRenderer.outputColorSpace)
            return stride(from: 0, to: pixels.count, by: 4).map {
                (0.2126 * Double(pixels[$0]) + 0.7152 * Double(pixels[$0 + 1]) + 0.0722 * Double(pixels[$0 + 2])) / 255
            }.sorted()
        }
        func percentile(_ values: [Double], _ q: Double) -> Double {
            values[min(values.count - 1, max(0, Int(Double(values.count) * q)))]
        }
        /// The value in `range` where `measure` (increasing) reaches `target`, by bisection.
        func solve(_ range: ClosedRange<Double>, target: Double, measure: (Double) -> Double?) -> Double? {
            var low = range.lowerBound, high = range.upperBound
            guard let atLow = measure(low), let atHigh = measure(high) else { return nil }
            if atLow >= target { return low }
            if atHigh <= target { return high }
            for _ in 0..<8 {
                let mid = (low + high) / 2
                guard let value = measure(mid) else { return nil }
                if value < target { low = mid } else { high = mid }
            }
            return (low + high) / 2
        }

        // 1. exposure: 70% of the way from the photo's median to mid-gray (18% gray encodes to
        //    ~0.46), so a dusk scene stays a dusk scene. Brightening stops before more than about
        //    1% of the photo nears clipping — a bright subject in a dim frame would blow out —
        //    but that limit never darkens a photo below as shot (night lights are meant to clip).
        //    Exposure is solved on accurate renders: the RAW engine applies it before its own
        //    highlight shoulder, which a draft's gain on the cached stage can't reproduce.
        var rendered: [Double: [Double]] = [:]
        func tones(atExposure ev: Double) -> [Double]? {
            if let cached = rendered[ev] { return cached }
            var trial = s; trial.exposure = ev
            let values = lumas(trial, accurate: true)
            rendered[ev] = values
            return values
        }
        /// The exposure in `range` where the `q` percentile reaches `target`, within `tolerance`:
        /// regula falsi with the Illinois fix, since tones rise smoothly with exposure (a few
        /// renders, not eight). Near the highlight shoulder tones barely move, hence the tighter
        /// tolerance there.
        func exposure(target: Double, percentile q: Double, in range: ClosedRange<Double>,
                      tolerance: Double) -> Double? {
            func measure(_ ev: Double) -> Double? { tones(atExposure: ev).map { percentile($0, q) - target } }
            var a = range.lowerBound, b = range.upperBound
            guard var fa = measure(a), var fb = measure(b) else { return nil }
            if fa >= 0 { return a }
            if fb <= 0 { return b }
            var side = 0
            for _ in 0..<6 where b - a > 0.04 {
                let c = b - fb * (b - a) / (fb - fa)
                guard let fc = measure(c) else { return nil }
                if abs(fc) < tolerance { return c }
                if fc < 0 {
                    a = c; fa = fc
                    if side == -1 { fb /= 2 }
                    side = -1
                } else {
                    b = c; fb = fc
                    if side == 1 { fa /= 2 }
                    side = 1
                }
            }
            return (a + b) / 2
        }
        guard let asShot = tones(atExposure: 0),
              let middle = exposure(target: 0.46, percentile: 0.5, in: percentile(asShot, 0.5) < 0.46 ? 0...2 : -2...0,
                                    tolerance: 0.006) else { return nil }
        var ev = middle * 0.7
        if ev > 0, let candidate = tones(atExposure: ev), percentile(candidate, 0.99) > 0.97 {
            ev = exposure(target: 0.97, percentile: 0.99, in: 0...ev, tolerance: 0.002) ?? 0
        }
        s.exposure = (ev * 100).rounded() / 100
        // from here on the stage sits at the chosen exposure, so every draft below is exact
        guard let exposed = lumas(s, accurate: true) else { return nil }

        // 2. recover clipped highlights and open up large dark areas
        let clipped = Double(exposed.filter { $0 > 0.96 }.count) / Double(exposed.count)
        if clipped > 0.02 { s.highlights = -min(70, ((clipped - 0.02) * 1000).rounded()) }
        let dark = Double(exposed.filter { $0 < 0.06 }.count) / Double(exposed.count)
        if dark > 0.08 { s.shadows = min(50, ((dark - 0.08) * 300).rounded()) }

        // 3. white and black points: only a dull or clipping top end moves the whites, and only
        //    washed-out shadows move the blacks (crushed ones are left alone)
        guard let current = lumas(s) else { return nil }
        // Whites lift the upper midtones too, not just the white point: pull them down when the
        // top clips, and nudge them up only for a clearly dull top end
        let top = percentile(current, 0.997)
        if top > 0.985 || top < 0.85 {
            s.whites = (solve(-40...15, target: 0.96) { value in
                var trial = s; trial.whites = value
                return lumas(trial).map { percentile($0, 0.997) }
            } ?? 0).rounded()
        }
        if percentile(current, 0.003) > 0.05 {
            s.blacks = (solve(-40...40, target: 0.02) { value in
                var trial = s; trial.blacks = value
                return lumas(trial).map { percentile($0, 0.003) }
            } ?? 0).rounded()
        }
        return s
    }
}
