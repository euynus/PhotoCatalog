import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Photo Merge: HDR from bracketed exposures.
enum MergeCheck {
    static func run() {
        checkHDR()
        print("--- photo merge assertions passed ---")
    }

    /// A scene in linear light (0…4), with structure at every scale as a photo has: soft
    /// shading, discs of all sizes, fine texture; a bright window full of detail and a dark
    /// corner with some too.
    private static func scene(_ x: Int, _ y: Int) -> Double {
        // SplitMix64: a lattice-free hash (a simpler one repeats, and registration locks onto it)
        func hash(_ a: Int, _ b: Int) -> Double {
            var z = UInt64(bitPattern: Int64(a)) &* 0x9E37_79B9_7F4A_7C15 ^ UInt64(bitPattern: Int64(b)) &* 0xC2B2_AE3D_27D4_EB4F
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Double(z % 10_000) / 10_000
        }
        let detail = 0.8 + 0.4 * hash(x / 2, y / 2)
        if x > 300, y < 200 { return 3.0 * detail }         // the window: blown out at 0 EV
        if x < 180, y > 340 { return 0.012 * detail }       // the dark corner: black at 0 EV
        var value = 0.18 * (0.7 + 0.6 * Double(x + 2 * y) / 1536) * detail
        for disc in 0..<24 {
            let cx = hash(disc, 1) * 512, cy = hash(disc, 2) * 512, r = 8 + hash(disc, 3) * 44
            if hypot(Double(x) - cx, Double(y) - cy) < r { value *= 0.3 + 1.7 * hash(disc, 4) }
        }
        return value
    }

    /// The scene as a camera at `ev` records it, display-encoded and clipped, `shift` pixels
    /// to the right and down; `blocker` puts something dark where it was.
    private static func bracket(_ ev: Double, shift: (Int, Int) = (0, 0), blocker: CGRect? = nil) -> URL {
        let size = 512
        var data = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                var v = scene(x - shift.0, y - shift.1) * pow(2, ev)
                // something with its own detail, darker than what it covers
                if let blocker, blocker.contains(CGPoint(x: x, y: y)) { v = scene(x + 37, y + 11) * 0.25 * pow(2, ev) }
                let encoded = v <= 0.0031308 ? v * 12.92 : 1.055 * pow(min(v, 1), 1 / 2.4) - 0.055
                let byte = UInt8(max(0, min(255, encoded * 255)))
                let i = (y * size + x) * 4
                data[i] = byte; data[i + 1] = byte; data[i + 2] = byte
            }
        }
        let context = CGContext(data: &data, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pc-bracket-\(UUID().uuidString).png")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return url
    }

    /// How alike two images' detail is over `rect`: the correlation of their gray levels.
    private static func correlation(_ a: CGImage, _ b: CGImage, _ rect: CGRect, offset: Int = 0) -> Double {
        guard let pa = SemanticMasks.rgba(a), let pb = SemanticMasks.rgba(b) else { return 0 }
        var xs: [Double] = [], ys: [Double] = []
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                xs.append(Double(pa[(y * a.width + x) * 4 + 1]))
                ys.append(Double(pb[((y + offset) * b.width + x + offset) * 4 + 1]))
            }
        }
        let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for (x, y) in zip(xs, ys) { sxy += (x - mx) * (y - my); sxx += (x - mx) * (x - mx); syy += (y - my) * (y - my) }
        return sxy / max((sxx * syy).squareRoot(), 1e-9)
    }

    /// Gray levels (0…255) of `image` over `rect` (top-left pixels): mean and spread.
    private static func stats(_ image: CGImage, _ rect: CGRect) -> (mean: Double, spread: Double) {
        guard let pixels = SemanticMasks.rgba(image) else { return (0, 0) }
        var values: [Double] = []
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) where x < image.width && y < image.height {
                values.append(Double(pixels[(y * image.width + x) * 4 + 1]))
            }
        }
        let mean = values.reduce(0, +) / Double(max(values.count, 1))
        let spread = (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(max(values.count, 1))).squareRoot()
        return (mean, spread)
    }

    private static func checkHDR() {
        let urls = [bracket(-2), bracket(0), bracket(2, shift: (5, 3))]
        defer { for url in urls { try? FileManager.default.removeItem(at: url) } }
        let frames = zip(urls, [0.25, 1, 4]).map { PhotoMerge.Frame(url: $0, isRaw: false, brightness: $1) }
        guard let merged = PhotoMerge.hdr(frames, options: .init(), maxPixel: nil),
              let result = DevelopRenderer.render(merged.image) else {
            preconditionFailure("brackets merge")
        }
        assert(merged.reference == 1, "the middle exposure is the reference")
        let middle = DevelopRenderer.render(PhotoMerge.decode(frames[1], maxPixel: nil)!)!
        // the window keeps its detail, the dark corner shows its detail, the rest stays put
        let window = CGRect(x: 360, y: 40, width: 100, height: 100), corner = CGRect(x: 40, y: 380, width: 100, height: 80)
        let middleWindow = stats(middle, window), mergedWindow = stats(result, window)
        let middleCorner = stats(middle, corner), mergedCorner = stats(result, corner)
        assert(middleWindow.spread < 2 && mergedWindow.spread > 10 && mergedWindow.mean < 250,
               "the bright window's detail comes back (\(middleWindow) → \(mergedWindow))")
        assert(mergedCorner.mean > middleCorner.mean + 10 && mergedCorner.spread > middleCorner.spread * 1.5,
               "the dark corner opens up (\(middleCorner) → \(mergedCorner))")
        assert(result.width >= 496 && result.width <= 508 && result.height >= 496 && result.height <= 509,
               "the result is cut to what every frame covers once lined up (\(result.width)×\(result.height))")
        // lined up by median threshold bitmaps, whatever the exposure: the +2 EV frame was
        // taken 5 px to the right and 3 px down
        let grays = [0, 1, 2].map { PhotoMerge.grayscale(DevelopRenderer.render(PhotoMerge.decode(frames[$0], maxPixel: 1024)!)!)! }
        let shift = PhotoMerge.medianThresholdShift(of: grays[2].pixels, onto: grays[1].pixels, width: grays[1].width,
                                                    height: grays[1].height)
        let still = PhotoMerge.medianThresholdShift(of: grays[0].pixels, onto: grays[1].pixels, width: grays[1].width,
                                                    height: grays[1].height)
        assert(shift == CGPoint(x: -5, y: -3) && still == .zero, "frames are lined up whatever their exposure (\(shift), \(still))")

        // something dark passed through the +2 EV frame: deghosting keeps the middle exposure there
        let blocker = CGRect(x: 220, y: 260, width: 60, height: 60)
        let ghosted = [bracket(-2), bracket(0), bracket(2, blocker: blocker)]
        defer { for url in ghosted { try? FileManager.default.removeItem(at: url) } }
        let ghostFrames = zip(ghosted, [0.25, 1, 4]).map { PhotoMerge.Frame(url: $0, isRaw: false, brightness: $1) }
        // a ghost shows as the other thing's detail mixed in: compare the patch with the middle exposure's
        let patch = CGRect(x: 230, y: 270, width: 40, height: 40)
        let middleFrame = DevelopRenderer.render(PhotoMerge.decode(ghostFrames[1], maxPixel: nil)!)!
        func likeness(deghost: Bool) -> Double {
            guard let merged = PhotoMerge.hdr(ghostFrames, options: .init(align: false, deghost: deghost), maxPixel: nil),
                  let image = DevelopRenderer.render(merged.image) else { return 0 }
            return correlation(image, middleFrame, patch, offset: 1)   // the merge leaves out a pixel all round
        }
        let kept = likeness(deghost: true), smeared = likeness(deghost: false)
        assert(kept > 0.9 && kept > smeared + 0.1, "deghosting keeps what moved out of the merge (\(kept) vs \(smeared))")
    }
}
