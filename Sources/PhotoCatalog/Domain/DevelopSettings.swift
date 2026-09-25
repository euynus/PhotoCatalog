// ============================================================
//  Develop settings — non-destructive adjustments (Lightroom Basic)
// ============================================================
import Foundation
import CoreGraphics

/// Adjustments stored per photo in the catalog; the original is never modified.
/// Zero / nil values mean "as shot".
struct DevelopSettings: Codable, Equatable, Hashable, Sendable {
    /// White balance. RAW: absolute Kelvin and tint (nil = as shot, as the camera recorded).
    /// Other formats: relative shifts on a -100…100 scale.
    var temperature: Double?
    var tint: Double?
    var exposure: Double = 0      // EV, -5…5
    var contrast: Double = 0      // -100…100
    var highlights: Double = 0
    var shadows: Double = 0
    var whites: Double = 0
    var blacks: Double = 0
    var vibrance: Double = 0
    var saturation: Double = 0
    /// Geometry, applied in this order after tone: quarter turns clockwise (0…3), a left–right
    /// mirror, a straighten angle in degrees (-45…45, positive turns the photo clockwise), then
    /// the crop. A nil crop keeps the whole photo — or, once straightened, the largest
    /// same-shaped rectangle without empty corners.
    var rotation = 0
    var flipped = false
    var straighten: Double = 0
    var crop: DevelopCrop?

    static let neutral = DevelopSettings()

    var isNeutral: Bool { self == .neutral }

    var hasGeometry: Bool { rotation != 0 || flipped || straighten != 0 || crop != nil }

    /// Tone and color only.
    var withoutGeometry: DevelopSettings {
        var copy = self
        copy.rotation = 0
        copy.flipped = false
        copy.straighten = 0
        copy.crop = nil
        return copy
    }

    /// Tone and color without white balance — what can be pasted between RAW and non-RAW photos,
    /// whose white-balance scales differ.
    var withoutWhiteBalance: DevelopSettings {
        var copy = self
        copy.temperature = nil
        copy.tint = nil
        return copy
    }

    /// Short fingerprint for cache file names, so a new edit never reuses an old render.
    var fingerprint: String {
        let fields: [Double?] = [temperature, tint, exposure, contrast, highlights, shadows,
                                 whites, blacks, vibrance, saturation]
        var text = fields.map { $0.map { String(format: "%.3f", $0) } ?? "-" }.joined(separator: ",")
        if hasGeometry {   // appended only when set, so earlier edits keep their cache names
            let crop = self.crop.map { String(format: "%.4f,%.4f,%.4f,%.4f", $0.x, $0.y, $0.width, $0.height) } ?? "-"
            text += String(format: "|%d,%d,%.2f,", rotation, flipped ? 1 : 0, straighten) + crop
        }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return String(hash, radix: 36)
    }
}

extension DevelopSettings {
    /// Every field is optional in storage, so settings saved before a field existed still load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature)
        tint = try container.decodeIfPresent(Double.self, forKey: .tint)
        exposure = try container.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        contrast = try container.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        highlights = try container.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        shadows = try container.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        whites = try container.decodeIfPresent(Double.self, forKey: .whites) ?? 0
        blacks = try container.decodeIfPresent(Double.self, forKey: .blacks) ?? 0
        vibrance = try container.decodeIfPresent(Double.self, forKey: .vibrance) ?? 0
        saturation = try container.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        rotation = try container.decodeIfPresent(Int.self, forKey: .rotation) ?? 0
        flipped = try container.decodeIfPresent(Bool.self, forKey: .flipped) ?? false
        straighten = try container.decodeIfPresent(Double.self, forKey: .straighten) ?? 0
        crop = try container.decodeIfPresent(DevelopCrop.self, forKey: .crop)
    }
}

/// A crop as fractions of the rotated photo's frame, top-left origin.
struct DevelopCrop: Codable, Equatable, Hashable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let full = DevelopCrop(x: 0, y: 0, width: 1, height: 1)

    var midX: Double { x + width / 2 }
    var midY: Double { y + height / 2 }
}

/// Crop, straighten and rotation math, in the frame of the photo after quarter turns.
/// Frame sizes are in pixels so aspect ratios and angles come out right.
enum DevelopGeometry {
    static let maxStraighten = 45.0
    /// Smallest crop edge, as a fraction of the frame.
    static let minCropFraction = 0.04

    static func rotatedSize(_ size: CGSize, _ rotation: Int) -> CGSize {
        rotation.isMultiple(of: 2) ? size : CGSize(width: size.height, height: size.width)
    }

    /// The crop a render uses: the saved one, or the largest frame-shaped one without empty corners.
    static func effectiveCrop(_ settings: DevelopSettings, frame: CGSize) -> DevelopCrop {
        settings.crop ?? inscribed(aspect: frame.width / max(frame.height, 1), angle: settings.straighten, frame: frame)
    }

    /// Pixel size of the finished render for a photo of `size` (as displayed, before edits).
    static func outputSize(_ settings: DevelopSettings, original size: CGSize) -> CGSize {
        let frame = rotatedSize(size, settings.rotation)
        let crop = effectiveCrop(settings, frame: frame)
        return CGSize(width: max(1, (crop.width * frame.width).rounded()),
                      height: max(1, (crop.height * frame.height).rounded()))
    }

    /// The largest centered crop of pixel aspect `aspect` (width / height) inside the frame
    /// and inside the photo straightened by `angle` degrees.
    static func inscribed(aspect: Double, angle: Double, frame: CGSize) -> DevelopCrop {
        let w0 = Double(frame.width), h0 = Double(frame.height)
        guard w0 > 0, h0 > 0, aspect > 0 else { return .full }
        let radians = abs(angle) * .pi / 180
        let c = cos(radians), s = sin(radians)
        // a w × h crop turned back by the angle must fit the photo: w·c + h·s ≤ W and w·s + h·c ≤ H
        let width = min(w0 / (c + s / aspect), h0 / (s + c / aspect), w0, h0 * aspect)
        let height = width / aspect
        let crop = DevelopCrop(x: 0, y: 0, width: width / w0, height: height / h0)
        return centered(crop, at: (0.5, 0.5))
    }

    /// Whether the crop stays inside the frame and inside the straightened photo.
    static func fits(_ crop: DevelopCrop, angle: Double, frame: CGSize) -> Bool {
        let epsilon = 1e-6
        guard crop.x >= -epsilon, crop.y >= -epsilon,
              crop.x + crop.width <= 1 + epsilon, crop.y + crop.height <= 1 + epsilon,
              crop.width > 0, crop.height > 0 else { return false }
        guard angle != 0 else { return true }
        let w0 = Double(frame.width), h0 = Double(frame.height)
        let radians = angle * .pi / 180
        let c = cos(radians), s = sin(radians)
        let corners = [(crop.x, crop.y), (crop.x + crop.width, crop.y),
                       (crop.x, crop.y + crop.height), (crop.x + crop.width, crop.y + crop.height)]
        return corners.allSatisfy { corner in
            // relative to the frame center, turned back by the straighten angle (y points down)
            let px = (corner.0 - 0.5) * w0, py = (corner.1 - 0.5) * h0
            let qx = c * px + s * py, qy = -s * px + c * py
            return abs(qx) <= w0 / 2 + epsilon * w0 && abs(qy) <= h0 / 2 + epsilon * h0
        }
    }

    /// The crop closest to `candidate` on the way from `valid` that still fits.
    static func constrain(_ candidate: DevelopCrop, from valid: DevelopCrop, angle: Double,
                          frame: CGSize) -> DevelopCrop {
        if fits(candidate, angle: angle, frame: frame) { return candidate }
        let start = fits(valid, angle: angle, frame: frame) ? valid : fit(valid, angle: angle, frame: frame)
        var low = 0.0, high = 1.0
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if fits(lerp(start, candidate, mid), angle: angle, frame: frame) { low = mid } else { high = mid }
        }
        return lerp(start, candidate, low)
    }

    /// Shrinks a crop toward the frame center, keeping its shape, until it fits `angle`.
    static func fit(_ crop: DevelopCrop, angle: Double, frame: CGSize) -> DevelopCrop {
        if fits(crop, angle: angle, frame: frame) { return crop }
        let aspect = crop.width * Double(frame.width) / max(crop.height * Double(frame.height), 1e-9)
        let target = inscribed(aspect: aspect, angle: angle, frame: frame)
        var low = 0.0, high = 1.0
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if fits(lerp(target, crop, mid), angle: angle, frame: frame) { low = mid } else { high = mid }
        }
        return lerp(target, crop, low)
    }

    /// Settings after turning the finished photo a quarter turn, keeping the crop on the same content.
    static func rotated(_ settings: DevelopSettings, clockwise: Bool) -> DevelopSettings {
        var next = settings
        // quarter turns apply before the mirror, so a mirrored photo turns the other way
        let step = (clockwise != settings.flipped) ? 1 : 3
        next.rotation = (settings.rotation + step) % 4
        next.crop = settings.crop.map { crop in
            clockwise
                ? DevelopCrop(x: 1 - crop.y - crop.height, y: crop.x, width: crop.height, height: crop.width)
                : DevelopCrop(x: crop.y, y: 1 - crop.x - crop.width, width: crop.height, height: crop.width)
        }
        return next
    }

    /// Settings after mirroring the finished photo left to right.
    static func mirrored(_ settings: DevelopSettings) -> DevelopSettings {
        var next = settings
        next.flipped.toggle()
        next.straighten = -settings.straighten
        next.crop = settings.crop.map { DevelopCrop(x: 1 - $0.x - $0.width, y: $0.y, width: $0.width, height: $0.height) }
        return next
    }

    /// A crop drag: the named edges move by (dx, dy) frame fractions. `ratio` (pixel width /
    /// height) keeps the shape, growing undragged edges about the center; the result stays
    /// inside the frame and the straightened photo.
    static func resize(_ start: DevelopCrop, left: Bool, right: Bool, top: Bool, bottom: Bool,
                       dx: Double, dy: Double, ratio: Double?, angle: Double, frame: CGSize) -> DevelopCrop {
        var x0 = start.x, x1 = start.x + start.width, y0 = start.y, y1 = start.y + start.height
        if left { x0 = min(max(0, x0 + dx), x1 - minCropFraction) }
        if right { x1 = max(min(1, x1 + dx), x0 + minCropFraction) }
        if top { y0 = min(max(0, y0 + dy), y1 - minCropFraction) }
        if bottom { y1 = max(min(1, y1 + dy), y0 + minCropFraction) }
        var crop = DevelopCrop(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        if let ratio, frame.width > 0, frame.height > 0 {
            let shape = ratio * Double(frame.height) / Double(frame.width)   // width / height in fractions
            let horizontal = left || right, vertical = top || bottom
            var width = crop.width
            if horizontal && vertical {
                width = max(width, crop.height * shape)   // a corner follows the larger pull
            } else if vertical {
                width = crop.height * shape
            }
            let anchorX = left ? start.x + start.width : right ? start.x : start.midX
            let anchorY = top ? start.y + start.height : bottom ? start.y : start.midY
            let roomX = left ? anchorX : right ? 1 - anchorX : 2 * min(anchorX, 1 - anchorX)
            let roomY = top ? anchorY : bottom ? 1 - anchorY : 2 * min(anchorY, 1 - anchorY)
            width = min(width, roomX, roomY * shape)
            let height = width / shape
            crop = DevelopCrop(x: left ? anchorX - width : right ? anchorX : anchorX - width / 2,
                               y: top ? anchorY - height : bottom ? anchorY : anchorY - height / 2,
                               width: width, height: height)
        }
        return constrain(crop, from: start, angle: angle, frame: frame)
    }

    /// A crop moved by (dx, dy) frame fractions, sliding along whichever edge stops it.
    static func move(_ start: DevelopCrop, dx: Double, dy: Double, angle: Double, frame: CGSize) -> DevelopCrop {
        var horizontal = start
        horizontal.x = min(max(0, start.x + dx), 1 - start.width)
        let stepX = constrain(horizontal, from: start, angle: angle, frame: frame)
        var vertical = stepX
        vertical.y = min(max(0, start.y + dy), 1 - start.height)
        return constrain(vertical, from: stepX, angle: angle, frame: frame)
    }

    /// The straighten angle that makes a line drawn on the photo (as displayed at `current`
    /// degrees, y pointing down) level — or plumb, when it is closer to vertical.
    static func straightenLevelling(from start: CGPoint, to end: CGPoint, current: Double) -> Double? {
        let dx = Double(end.x - start.x), dy = Double(end.y - start.y)
        guard hypot(dx, dy) >= 12 else { return nil }
        var tilt = atan2(dy, dx) * 180 / .pi   // positive: the line falls to the right
        while tilt > 45 { tilt -= 90 }
        while tilt < -45 { tilt += 90 }
        let angle = ((current - tilt) * 10).rounded() / 10
        return min(maxStraighten, max(-maxStraighten, angle))
    }

    static func centered(_ crop: DevelopCrop, at center: (Double, Double)) -> DevelopCrop {
        DevelopCrop(x: center.0 - crop.width / 2, y: center.1 - crop.height / 2,
                    width: crop.width, height: crop.height)
    }

    private static func lerp(_ a: DevelopCrop, _ b: DevelopCrop, _ t: Double) -> DevelopCrop {
        DevelopCrop(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t,
                    width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }
}

/// Crop shapes offered in the crop tool. Ratios are long edge : short edge and follow the
/// crop's current orientation.
enum CropAspect: Hashable, CaseIterable, Identifiable {
    case original, free, square, r4x5, r5x7, r2x3, r3x4, r16x9

    var id: Self { self }

    var title: String {
        switch self {
        case .original: L("原始比例")
        case .free: L("自由")
        case .square: "1 : 1"
        case .r4x5: "4 : 5"
        case .r5x7: "5 : 7"
        case .r2x3: "2 : 3"
        case .r3x4: "3 : 4"
        case .r16x9: "16 : 9"
        }
    }

    /// Long : short ratio; nil when the crop is free. `original` uses the photo's frame.
    func ratio(frame: CGSize) -> Double? {
        switch self {
        case .original:
            let long = max(frame.width, frame.height), short = max(min(frame.width, frame.height), 1)
            return Double(long / short)
        case .free: return nil
        case .square: return 1
        case .r4x5: return 5.0 / 4
        case .r5x7: return 7.0 / 5
        case .r2x3: return 3.0 / 2
        case .r3x4: return 4.0 / 3
        case .r16x9: return 16.0 / 9
        }
    }
}

/// One slider in the Basic panel: range, neutral value and display format.
struct DevelopControl: Identifiable {
    let id: WritableKeyPath<DevelopSettings, Double>
    let title: String
    let range: ClosedRange<Double>
    let step: Double
    let format: @Sendable (Double) -> String

    static let exposure = DevelopControl(id: \.exposure, title: L("曝光度"), range: -5...5, step: 0.01) {
        String(format: "%+.2f", $0)
    }
    static let tone: [DevelopControl] = [
        .exposure,
        signed(\.contrast, L("对比度")),
        signed(\.highlights, L("高光")),
        signed(\.shadows, L("阴影")),
        signed(\.whites, L("白色色阶")),
        signed(\.blacks, L("黑色色阶")),
    ]
    static let presence: [DevelopControl] = [
        signed(\.vibrance, L("鲜艳度")),
        signed(\.saturation, L("饱和度")),
    ]

    private static func signed(_ keyPath: WritableKeyPath<DevelopSettings, Double>, _ title: String) -> DevelopControl {
        DevelopControl(id: keyPath, title: title, range: -100...100, step: 1) { value in
            value == 0 ? "0" : String(format: "%+.0f", value)
        }
    }
}

/// Tone distribution of a rendered photo, per channel, as fractions of all pixels.
struct DevelopHistogram: Equatable, Sendable {
    static let binCount = 64
    let red: [Double]
    let green: [Double]
    let blue: [Double]

    /// Share of pixels in the darkest / brightest bin of any channel — clipping warnings.
    var shadowClipping: Double { max(red.first ?? 0, green.first ?? 0, blue.first ?? 0) }
    var highlightClipping: Double { max(red.last ?? 0, green.last ?? 0, blue.last ?? 0) }
    /// Clipping worth flagging: more than a sliver of the photo sits in an end bin.
    static let clippingWarning = 0.005
}
