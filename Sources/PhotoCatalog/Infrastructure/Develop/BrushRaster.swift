// ============================================================
//  BrushRaster — a brush mask's strokes as a grayscale weight
// ============================================================
import CoreImage
import CoreGraphics
import Foundation

/// Paints brush strokes as round soft dabs into an 8-bit gray bitmap the size of the render:
/// painting keeps the brighter of what's there and the dab ("lighten"), erasing the darker,
/// so overlapping dabs never build up past a stroke's density. Rasterized masks are cached,
/// since sliders re-render the photo many times a second.
enum BrushRaster {
    private final class Box { let image: CGImage; init(_ image: CGImage) { self.image = image } }
    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 12
        return cache
    }()

    /// The weight of a brush mask over `extent` (the source photo at the render's size).
    static func weight(_ mask: LocalAdjustment, extent: CGRect) -> CIImage? {
        guard var image = layer(mask.strokes, extent: extent) else { return nil }
        if mask.inverted {
            image = image.applyingFilter("CIColorInvert")
        }
        return image
    }

    /// Another mask's weight with brush strokes added to it and erased from it. Erasing wins
    /// where the two overlap, whatever order they were painted in.
    static func refine(_ base: CIImage, strokes: [BrushStroke], extent: CGRect) -> CIImage {
        var image = base
        let added = strokes.filter { !$0.erase }
        if !added.isEmpty, let painted = layer(added, extent: extent) {
            image = image.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: painted])
        }
        // erased strokes painted as coverage, then taken away
        let removed = strokes.filter(\.erase).map { stroke -> BrushStroke in
            var coverage = stroke
            coverage.erase = false
            return coverage
        }
        if !removed.isEmpty, let erased = layer(removed, extent: extent) {
            image = image.applyingFilter("CIMinimumCompositing", parameters: [
                kCIInputBackgroundImageKey: erased.applyingFilter("CIColorInvert"),
            ])
        }
        return image.cropped(to: extent)
    }

    /// The strokes painted in order over black, positioned on `extent`.
    /// The raster of every stroke but the last, for the mask painted most recently: painting
    /// grows the last stroke frame by frame, so only that stroke needs drawing again.
    private static let prefixLock = NSLock()
    nonisolated(unsafe) private static var prefix: (key: String, image: CGImage)?

    private static func cacheKey(_ strokes: [BrushStroke], width: Int, height: Int) -> String {
        "\(BrushStroke.hash(strokes))|\(strokes.count)|\(width)x\(height)"
    }

    private static func layer(_ strokes: [BrushStroke], extent: CGRect) -> CIImage? {
        let width = Int(extent.width.rounded()), height = Int(extent.height.rounded())
        guard width > 0, height > 0, let last = strokes.last else { return nil }
        let key = cacheKey(strokes, width: width, height: height) as NSString
        let bitmap: CGImage
        if let cached = cache.object(forKey: key) {
            bitmap = cached.image
        } else {
            var painted: CGImage?
            if strokes.count > 1 {
                let head = Array(strokes.dropLast())
                let headKey = cacheKey(head, width: width, height: height)
                var base = prefixLock.withLock { prefix?.key == headKey ? prefix?.image : nil }
                    ?? cache.object(forKey: headKey as NSString)?.image
                if base == nil {
                    base = paint(head, onto: nil, width: width, height: height)
                    if let base { prefixLock.withLock { prefix = (headKey, base) } }
                }
                if let base { painted = paint([last], onto: base, width: width, height: height) }
            } else {
                painted = paint(strokes, onto: nil, width: width, height: height)
            }
            guard let painted else { return nil }
            cache.setObject(Box(painted), forKey: key)
            bitmap = painted
        }
        // raw values: the weight must not be color-managed on its way in
        return CIImage(cgImage: bitmap, options: [.colorSpace: NSNull()])
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }

    /// Draws `strokes` over `base` (or black). Each stroke's dab is rendered once and stamped
    /// along its path: blitting an image is several times cheaper than shading a gradient per dab.
    private static func paint(_ strokes: [BrushStroke], onto base: CGImage?, width: Int, height: Int) -> CGImage? {
        let gray = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        if let base {
            context.draw(base, in: bounds)
        } else {
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(bounds)
        }
        // stroke points have a top-left origin; flip y by hand rather than through the CTM, which
        // would send every stamp through a slower transformed-image path
        let longEdge = Double(max(width, height))
        for stroke in strokes where stroke.pointCount > 0 {
            let radius = max(0.5, stroke.radius * longEdge)
            guard let dab = dabImage(stroke, radius: radius) else { continue }
            context.setBlendMode(stroke.erase ? .darken : .lighten)
            let side = CGFloat(dab.width)
            let spacing = max(0.75, radius * 0.2)
            // whole-pixel positions: a fractional one resamples the dab on every stamp, and half a
            // pixel is invisible in a soft brush
            context.interpolationQuality = .none
            func stamp(_ x: Double, _ y: Double) {
                context.draw(dab, in: CGRect(x: (CGFloat(x) - side / 2).rounded(),
                                             y: (CGFloat(Double(height) - y) - side / 2).rounded(),
                                             width: side, height: side))
            }
            let first = stroke.point(0)
            var px = Double(first.x) * Double(width), py = Double(first.y) * Double(height)
            stamp(px, py)
            var carried = 0.0   // distance since the last dab, so spacing holds across points
            for index in 1..<stroke.pointCount {
                let next = stroke.point(index)
                let nx = Double(next.x) * Double(width), ny = Double(next.y) * Double(height)
                let length = hypot(nx - px, ny - py)
                var travelled = spacing - carried
                while travelled <= length {
                    let t = travelled / max(length, 1e-9)
                    stamp(px + (nx - px) * t, py + (ny - py) * t)
                    travelled += spacing
                }
                carried = length - (travelled - spacing)
                px = nx; py = ny
            }
        }
        return context.makeImage()
    }

    /// One round dab: the stroke's strength over black when painting, its inverse over white
    /// when erasing, falling off smoothly from the hard core to the rim.
    private static func dabImage(_ stroke: BrushStroke, radius: Double) -> CGImage? {
        let side = Int((radius * 2).rounded(.up)) + 2
        let gray = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setFillColor(gray: stroke.erase ? 1 : 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let level = min(1, max(0, stroke.density / 100))
        let hard = min(0.98, max(0, 1 - stroke.feather / 100))
        let profile: [(location: Double, value: Double)] = [
            (0, 1), (hard, 1), (hard + (1 - hard) * 0.25, 0.84), (hard + (1 - hard) * 0.5, 0.5),
            (hard + (1 - hard) * 0.75, 0.16), (1, 0),
        ]
        let components = profile.flatMap { stop -> [CGFloat] in
            let strength = stop.value * level
            return [CGFloat(stroke.erase ? 1 - strength : strength), 1]
        }
        guard let gradient = CGGradient(colorSpace: gray, colorComponents: components,
                                        locations: profile.map { CGFloat($0.location) }, count: profile.count)
        else { return nil }
        let center = CGPoint(x: Double(side) / 2, y: Double(side) / 2)
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center,
                                   endRadius: CGFloat(radius), options: [])
        return context.makeImage()
    }
}
