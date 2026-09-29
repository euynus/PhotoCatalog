// ============================================================
//  LUT library — 3D color lookup tables (.cube) for creative looks
// ============================================================
import CoreImage
import Foundation

/// A LUT the user imported, kept in the app's own folder so every catalog has it.
struct DevelopLUT: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
}

/// Reads `.cube` files (Adobe / Resolve 3D LUTs) and holds them ready for Core Image's color cube.
enum LUTLibrary {
    /// A LUT as Core Image takes it: `size`³ RGBA floats, red changing fastest, over 0…1.
    struct Cube: Sendable {
        let size: Int
        let data: Data
    }

    /// Where imported LUTs are kept: `<id>.cube`.
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PhotoCatalog/LUTs", isDirectory: true)
    }

    static func url(for id: String) -> URL { folder.appendingPathComponent("\(id).cube") }

    private final class Box { let cube: Cube; init(_ cube: Cube) { self.cube = cube } }
    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 8
        return cache
    }()

    /// The LUT `id` from the library, parsed once; nil when it's gone or unreadable.
    static func cube(id: String) -> Cube? {
        if let cached = cache.object(forKey: id as NSString) { return cached.cube }
        guard let text = try? String(contentsOf: url(for: id), encoding: .utf8), let cube = parse(text) else { return nil }
        cache.setObject(Box(cube), forKey: id as NSString)
        return cube
    }

    /// Copies a `.cube` file into the library under `id`; false when it isn't a 3D LUT.
    static func add(_ source: URL, id: String) -> Bool {
        guard let text = try? String(contentsOf: source, encoding: .utf8), parse(text) != nil else { return false }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (try? text.write(to: url(for: id), atomically: true, encoding: .utf8)) != nil
    }

    static func remove(id: String) {
        try? FileManager.default.removeItem(at: url(for: id))
        cache.removeObject(forKey: id as NSString)
    }

    /// The title a `.cube` file gives itself, if any.
    static func title(of text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.uppercased().hasPrefix("TITLE") else { continue }
            let name = trimmed.dropFirst(5).trimmingCharacters(in: CharacterSet.whitespaces.union(["\""]))
            return name.isEmpty ? nil : name
        }
        return nil
    }

    /// A 3D LUT from `.cube` text, resampled to a power-of-two size over 0…1 when it isn't
    /// one already (a 33- or 65-point LUT is common). Nil for 1D LUTs and malformed files.
    static func parse(_ text: String) -> Cube? {
        var size = 0
        var low = SIMD3<Double>(0, 0, 0), high = SIMD3<Double>(1, 1, 1)
        var values: [SIMD3<Double>] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            let keyword = parts.first.map { $0.uppercased() } ?? ""
            switch keyword {
            case "TITLE": continue
            case "LUT_1D_SIZE": return nil   // one curve per channel: not a 3D look
            case "LUT_3D_SIZE":
                guard parts.count == 2, let n = Int(parts[1]), (2...256).contains(n) else { return nil }
                size = n
            case "DOMAIN_MIN", "DOMAIN_MAX":
                let numbers = parts.dropFirst().compactMap { Double($0) }
                guard numbers.count == 3 else { return nil }
                let vector = SIMD3(numbers[0], numbers[1], numbers[2])
                if keyword == "DOMAIN_MIN" { low = vector } else { high = vector }
            default:
                let numbers = parts.compactMap { Double($0) }
                guard numbers.count == 3, numbers.count == parts.count else { continue }   // other keywords
                values.append(SIMD3(numbers[0], numbers[1], numbers[2]))
            }
        }
        guard size >= 2, values.count == size * size * size,
              high.x > low.x, high.y > low.y, high.z > low.z else { return nil }

        // resample onto a power-of-two grid over 0…1 by trilinear interpolation
        let isPowerOfTwo = size & (size - 1) == 0
        let unitDomain = low == SIMD3(0, 0, 0) && high == SIMD3(1, 1, 1)
        let target = isPowerOfTwo && unitDomain ? min(size, 64) : (size <= 33 ? 32 : 64)
        func value(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Double> { values[(b * size + g) * size + r] }
        func lookup(_ input: SIMD3<Double>) -> SIMD3<Double> {
            let position = (input - low) / (high - low) * Double(size - 1)
            let p = SIMD3(min(max(position.x, 0), Double(size - 1)), min(max(position.y, 0), Double(size - 1)),
                          min(max(position.z, 0), Double(size - 1)))
            let i0 = SIMD3(Int(p.x), Int(p.y), Int(p.z))
            let i1 = SIMD3(min(i0.x + 1, size - 1), min(i0.y + 1, size - 1), min(i0.z + 1, size - 1))
            let t = p - SIMD3(Double(i0.x), Double(i0.y), Double(i0.z))
            func lerp(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ t: Double) -> SIMD3<Double> { a + (b - a) * t }
            let c00 = lerp(value(i0.x, i0.y, i0.z), value(i1.x, i0.y, i0.z), t.x)
            let c10 = lerp(value(i0.x, i1.y, i0.z), value(i1.x, i1.y, i0.z), t.x)
            let c01 = lerp(value(i0.x, i0.y, i1.z), value(i1.x, i0.y, i1.z), t.x)
            let c11 = lerp(value(i0.x, i1.y, i1.z), value(i1.x, i1.y, i1.z), t.x)
            return lerp(lerp(c00, c10, t.y), lerp(c01, c11, t.y), t.z)
        }
        var floats = [Float](repeating: 1, count: target * target * target * 4)
        for b in 0..<target {
            for g in 0..<target {
                for r in 0..<target {
                    let input = SIMD3(Double(r), Double(g), Double(b)) / Double(target - 1)
                    let out = target == size && unitDomain ? value(r, g, b) : lookup(input)
                    let i = ((b * target + g) * target + r) * 4
                    floats[i] = Float(out.x); floats[i + 1] = Float(out.y); floats[i + 2] = Float(out.z)
                }
            }
        }
        return Cube(size: target, data: floats.withUnsafeBufferPointer { Data(buffer: $0) })
    }
}
