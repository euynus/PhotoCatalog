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
        let width = Int(extent.width.rounded()), height = Int(extent.height.rounded())
        guard width > 0, height > 0 else { return nil }
        let key = "\(BrushStroke.hash(mask.strokes))|\(mask.strokes.count)|\(width)x\(height)" as NSString
        let bitmap: CGImage
        if let cached = cache.object(forKey: key) {
            bitmap = cached.image
        } else {
            guard let painted = paint(mask.strokes, width: width, height: height) else { return nil }
            cache.setObject(Box(painted), forKey: key)
            bitmap = painted
        }
        // raw values: the weight must not be color-managed on its way in
        var image = CIImage(cgImage: bitmap, options: [.colorSpace: NSNull()])
        if mask.inverted {
            image = image.applyingFilter("CIColorInvert")
        }
        return image.transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }

    private static func paint(_ strokes: [BrushStroke], width: Int, height: Int) -> CGImage? {
        let gray = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // top-left origin, like the stroke points
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        let longEdge = Double(max(width, height))
        for stroke in strokes where stroke.pointCount > 0 {
            let radius = max(0.5, stroke.radius * longEdge)
            let level = min(1, max(0, stroke.density / 100))
            let hard = min(0.98, max(0, 1 - stroke.feather / 100))
            // a smoothstep-like fall-off from the hard core to the rim
            let profile: [(location: Double, value: Double)] = [
                (0, 1), (hard, 1), (hard + (1 - hard) * 0.25, 0.84), (hard + (1 - hard) * 0.5, 0.5),
                (hard + (1 - hard) * 0.75, 0.16), (1, 0),
            ]
            // painting draws the dab's strength over black; erasing draws its inverse over white
            let components = profile.flatMap { stop -> [CGFloat] in
                let strength = stop.value * level
                return [CGFloat(stroke.erase ? 1 - strength : strength), 1]
            }
            guard let gradient = CGGradient(colorSpace: gray, colorComponents: components,
                                            locations: profile.map { CGFloat($0.location) }, count: profile.count)
            else { continue }
            context.setBlendMode(stroke.erase ? .darken : .lighten)
            let spacing = max(0.75, radius * 0.2)
            func dab(_ x: Double, _ y: Double) {
                let center = CGPoint(x: x, y: y)
                context.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                                           endCenter: center, endRadius: CGFloat(radius), options: [])
            }
            let first = stroke.point(0)
            var px = Double(first.x) * Double(width), py = Double(first.y) * Double(height)
            dab(px, py)
            var carried = 0.0   // distance since the last dab, so spacing holds across points
            for index in 1..<stroke.pointCount {
                let next = stroke.point(index)
                let nx = Double(next.x) * Double(width), ny = Double(next.y) * Double(height)
                let length = hypot(nx - px, ny - py)
                var travelled = spacing - carried
                while travelled <= length {
                    let t = travelled / max(length, 1e-9)
                    dab(px + (nx - px) * t, py + (ny - py) * t)
                    travelled += spacing
                }
                carried = length - (travelled - spacing)
                px = nx; py = ny
            }
        }
        return context.makeImage()
    }
}
