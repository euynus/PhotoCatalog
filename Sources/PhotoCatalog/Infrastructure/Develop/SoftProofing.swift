// ============================================================
//  Soft proofing — the photo as another color space or a printer will show it
// ============================================================
import ColorSync
import CoreGraphics
import Foundation

/// How Develop proofs the photo (Lightroom's Soft Proofing): the profile it's shown through,
/// the rendering intent, whether paper white and ink black are simulated, and whether colors
/// the profile can't hold are marked.
struct SoftProof: Codable, Equatable, Sendable {
    enum Intent: String, Codable, CaseIterable, Identifiable, Sendable {
        case perceptual, relative

        var id: Self { self }
        var title: String {
            switch self {
            case .perceptual: L("可感知")
            case .relative: L("相对比色")
            }
        }
    }

    /// A built-in space ("sRGB", "displayP3", "adobeRGB") or the path of an ICC profile.
    var profile = "sRGB"
    var intent = Intent.perceptual
    var simulatePaper = false
    var gamutWarning = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profile = try c.decodeIfPresent(String.self, forKey: .profile) ?? "sRGB"
        intent = try c.decodeIfPresent(Intent.self, forKey: .intent) ?? .perceptual
        simulatePaper = try c.decodeIfPresent(Bool.self, forKey: .simulatePaper) ?? false
        gamutWarning = try c.decodeIfPresent(Bool.self, forKey: .gamutWarning) ?? false
    }
}

enum SoftProofing {
    /// A profile to proof with.
    struct Profile: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
    }

    static let builtIns = [Profile(id: "sRGB", name: "sRGB"), Profile(id: "displayP3", name: "Display P3"),
                           Profile(id: "adobeRGB", name: "Adobe RGB (1998)")]

    /// The output spaces first, then every printer profile installed on this Mac (by name).
    static func profiles() -> [Profile] {
        let folders = ["/Library/ColorSync/Profiles", NSHomeDirectory() + "/Library/ColorSync/Profiles",
                       "/System/Library/ColorSync/Profiles", "/Library/Printers"]
        var found: [Profile] = []
        var seen = Set<String>()
        for folder in folders {
            guard let walker = FileManager.default.enumerator(atPath: folder) else { continue }
            for case let relative as String in walker {
                let path = (folder as NSString).appendingPathComponent(relative)
                guard ["icc", "icm"].contains((path as NSString).pathExtension.lowercased()), isPrinterProfile(path),
                      let name = profileName(path), seen.insert(name).inserted else { continue }
                found.append(Profile(id: path, name: name))
            }
        }
        return builtIns + found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Whether the ICC file at `path` describes an output device (its header's class is 'prtr').
    static func isPrinterProfile(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let header = (try? handle.read(upToCount: 20)) ?? Data()
        return header.count == 20 && header.subdata(in: 12..<16) == Data("prtr".utf8)
    }

    private static func profileName(_ path: String) -> String? {
        guard let profile = ColorSyncProfileCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)?.takeRetainedValue()
        else { return nil }
        return (ColorSyncProfileCopyDescriptionString(profile)?.takeRetainedValue() as String?)
            ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    static func name(of id: String) -> String {
        builtIns.first { $0.id == id }?.name ?? profileName(id) ?? ((id as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    static func colorSpace(_ id: String) -> CGColorSpace? {
        switch id {
        case "sRGB": return CGColorSpace(name: CGColorSpace.sRGB)
        case "displayP3": return CGColorSpace(name: CGColorSpace.displayP3)
        case "adobeRGB": return CGColorSpace(name: CGColorSpace.adobeRGB1998)
        default: return (try? Data(contentsOf: URL(fileURLWithPath: id))).flatMap { CGColorSpace(iccData: $0 as CFData) }
        }
    }

    /// `image` (in Display P3) as `proof` shows it, back in Display P3: converted into the
    /// profile with its intent and out again, so colors it can't hold are clipped or compressed
    /// as they will be. Simulating paper converts absolutely both ways, so paper white and ink
    /// black show as they are. With the gamut warning on, colors that don't survive a relative
    /// round trip are painted red. Nil when the profile can't be used.
    static func proof(_ image: CGImage, _ proof: SoftProof) -> CGImage? {
        guard let device = colorSyncProfile(proof.profile), let display = displayProfile,
              let channels = colorSpace(proof.profile)?.numberOfComponents,
              let space = CGColorSpace(name: CGColorSpace.displayP3), let original = rgba(image) else { return nil }
        let absolute = intent(kColorSyncRenderingIntentAbsolute), relative = intent(kColorSyncRenderingIntentRelative)
        let into = proof.simulatePaper ? absolute
            : proof.intent == .perceptual ? intent(kColorSyncRenderingIntentPerceptual) : relative
        let back = proof.simulatePaper ? absolute : relative
        let size = (width: image.width, height: image.height)
        func roundTrip(_ into: String, _ back: String) -> [UInt8]? {
            convert(original, size, from: (display, .rgbx), to: (device, .plain(channels)), intent: into)
                .flatMap { convert($0, size, from: (device, .plain(channels)), to: (display, .rgbx), intent: back) }
        }
        guard var shown = roundTrip(into, back) else { return nil }
        if proof.gamutWarning {
            if let tripped = into == relative && back == relative ? shown : roundTrip(relative, relative) {
                for i in stride(from: 0, to: min(shown.count, original.count, tripped.count), by: 4)
                where outOfGamut(original, tripped, i) {
                    shown[i] = 255
                    shown[i + 1] = 0
                    shown[i + 2] = 0
                }
            }
        }
        return bitmap(shown, width: size.width, height: size.height, space: space)
    }

    /// `image` (in Display P3) converted into the profile `id` with `intent`, tagged with that
    /// profile's color space so drawing it hands the profile's own values on — what printing
    /// with a printer profile needs. Nil when the profile can't be used.
    static func converted(_ image: CGImage, toProfile id: String, intent: SoftProof.Intent) -> CGImage? {
        guard let device = colorSyncProfile(id), let display = displayProfile, let space = colorSpace(id),
              let original = rgba(image) else { return nil }
        let channels = space.numberOfComponents
        let size = (width: image.width, height: image.height)
        let chosen = intent == .perceptual ? Self.intent(kColorSyncRenderingIntentPerceptual)
            : Self.intent(kColorSyncRenderingIntentRelative)
        guard let pixels = convert(original, size, from: (display, .rgbx), to: (device, .plain(channels)), intent: chosen),
              let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: size.width, height: size.height, bitsPerComponent: 8, bitsPerPixel: 8 * channels,
                       bytesPerRow: size.width * channels, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// A color that comes back from the profile with its hue or saturation more than a few
    /// levels off, or its lightness above the deepest shadows, didn't fit in it. (Black that
    /// only prints as the ink's black isn't a color out of gamut.)
    static func outOfGamut(_ original: [UInt8], _ tripped: [UInt8], _ i: Int) -> Bool {
        func parts(_ p: [UInt8]) -> (y: Int, a: Int, b: Int) {
            let r = Int(p[i]), g = Int(p[i + 1]), b = Int(p[i + 2])
            return ((2126 * r + 7152 * g + 722 * b) / 10000, r - g, (r + g) / 2 - b)
        }
        let o = parts(original), t = parts(tripped)
        return max(abs(o.a - t.a), abs(o.b - t.b)) > 12 || (o.y > 48 && abs(o.y - t.y) > 12)
    }

    private static func intent(_ constant: Unmanaged<CFString>?) -> String {
        (constant?.takeUnretainedValue() as String?) ?? ""
    }

    private static let displayProfile = ColorSyncProfileCreateWithName(kColorSyncDisplayP3Profile.takeUnretainedValue())?
        .takeRetainedValue()

    private static func colorSyncProfile(_ id: String) -> ColorSyncProfile? {
        let name: Unmanaged<CFString>? = switch id {
        case "sRGB": kColorSyncSRGBProfile
        case "displayP3": kColorSyncDisplayP3Profile
        case "adobeRGB": kColorSyncAdobeRGB1998Profile
        default: nil
        }
        if let name { return ColorSyncProfileCreateWithName(name.takeUnretainedValue())?.takeRetainedValue() }
        return ColorSyncProfileCreateWithURL(URL(fileURLWithPath: id) as CFURL, nil)?.takeRetainedValue()
    }

    /// How 8-bit pixels lie in memory: RGB with a fourth byte skipped, or `n` packed components
    /// (RGB, CMYK or gray).
    private enum Layout {
        case rgbx
        case plain(Int)

        var bytes: Int {
            switch self {
            case .rgbx: 4
            case .plain(let n): n
            }
        }
        var colorSync: ColorSyncDataLayout {
            switch self {
            case .rgbx: ColorSyncDataLayout(kColorSyncByteOrderDefault) | ColorSyncDataLayout(kColorSyncAlphaNoneSkipLast.rawValue)
            case .plain: ColorSyncDataLayout(kColorSyncByteOrderDefault) | ColorSyncDataLayout(kColorSyncAlphaNone.rawValue)
            }
        }
    }

    /// 8-bit pixels from one profile to another with `intent`, through ColorSync so the intent
    /// is the one asked for.
    private static func convert(_ pixels: [UInt8], _ size: (width: Int, height: Int),
                                from source: (profile: ColorSyncProfile, layout: Layout),
                                to destination: (profile: ColorSyncProfile, layout: Layout),
                                intent: String) -> [UInt8]? {
        let key = { (k: Unmanaged<CFString>) in k.takeUnretainedValue() as String }
        let steps: [[String: Any]] = [
            [key(kColorSyncProfile): source.profile, key(kColorSyncRenderingIntent): intent,
             key(kColorSyncTransformTag): kColorSyncTransformDeviceToPCS.takeUnretainedValue()],
            [key(kColorSyncProfile): destination.profile, key(kColorSyncRenderingIntent): intent,
             key(kColorSyncTransformTag): kColorSyncTransformPCSToDevice.takeUnretainedValue()],
        ]
        guard let transform = ColorSyncTransformCreate(steps as CFArray, nil)?.takeRetainedValue() else { return nil }
        var output = [UInt8](repeating: 0, count: size.width * size.height * destination.layout.bytes)
        let done = pixels.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { result in
                ColorSyncTransformConvert(transform, size.width, size.height, result.baseAddress!, kColorSync8BitInteger,
                                          destination.layout.colorSync, size.width * destination.layout.bytes,
                                          input.baseAddress!, kColorSync8BitInteger, source.layout.colorSync,
                                          size.width * source.layout.bytes, nil)
            }
        }
        return done ? output : nil
    }

    /// Display P3 RGBA bytes of `image`.
    static func rgba(_ image: CGImage) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.displayP3),
              let context = CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels
    }

    private static func bitmap(_ pixels: [UInt8], width: Int, height: Int, space: CGColorSpace) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
