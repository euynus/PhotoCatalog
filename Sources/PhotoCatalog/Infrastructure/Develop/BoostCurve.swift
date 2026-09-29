// ============================================================
//  BoostCurve — the RAW engine's tone curve, for exposure drafts
// ============================================================
import CoreImage
import Foundation

/// How the RAW engine's tone curve ("boost") maps linear scene light, sampled from one photo.
/// The engine applies exposure before this curve, so moving exposure on an already-decoded
/// image means undoing the curve, scaling, and applying it again — plain scaling of the
/// decoded image came out 10–20% darker than the settled render at +1 to +2 EV.
struct BoostCurve: Sendable {
    /// Ascending samples in linear light: engine input without boost → output with it.
    let inputs: [Double]
    let outputs: [Double]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var byCamera: [String: BoostCurve] = [:]

    /// The last curve measured for a camera model: its shadows and midtones are the same
    /// from photo to photo, so it serves while a photo's own is measured.
    static func remembered(camera: String) -> BoostCurve? {
        guard !camera.isEmpty else { return nil }
        return lock.withLock { byCamera[camera] }
    }

    static func remember(_ curve: BoostCurve, camera: String) {
        guard !camera.isEmpty else { return }
        lock.withLock { byCamera[camera] = curve }
    }

    /// Measures a RAW file's curve from two tiny decodes, with and without boost. Uses its own
    /// decoder, so it can run on any queue.
    static func measure(url: URL) -> BoostCurve? {
        guard let raw = CIRAWFilter(imageURL: url) else { return nil }
        let longEdge = max(raw.nativeSize.width, raw.nativeSize.height)
        raw.scaleFactor = Float(min(1, 256 / max(longEdge, 1)))
        raw.isDraftModeEnabled = true
        func pixels() -> [Float]? {
            guard let image = raw.outputImage else { return nil }
            let rect = image.extent.integral
            let width = Int(rect.width), height = Int(rect.height)
            guard width > 0, height > 0 else { return nil }
            var data = [Float](repeating: 0, count: width * height * 4)
            DevelopRenderer.context.render(image, toBitmap: &data, rowBytes: width * 16, bounds: rect,
                                           format: .RGBAf, colorSpace: DevelopRenderer.linearColorSpace)
            return data
        }
        guard let boosted = pixels() else { return nil }
        raw.boostAmount = 0
        guard let flat = pixels() else { return nil }
        return measure(boosted: boosted, flat: flat)
    }

    /// Measures the curve from the same photo decoded with and without boost (RGBA floats,
    /// linear light, same size). Nil when the photo has too few distinct tones to tell.
    static func measure(boosted: [Float], flat: [Float]) -> BoostCurve? {
        guard boosted.count == flat.count, !flat.isEmpty else { return nil }
        // average both sides in 1/8-EV bins of the unboosted luminance
        let binsPerStop = 8.0, lowest = -14.0, count = Int(18 * binsPerStop)
        var sumIn = [Double](repeating: 0, count: count), sumOut = sumIn, hits = [Int](repeating: 0, count: count)
        for i in stride(from: 0, to: flat.count, by: 4) {
            let input = 0.2126 * Double(flat[i]) + 0.7152 * Double(flat[i + 1]) + 0.0722 * Double(flat[i + 2])
            let output = 0.2126 * Double(boosted[i]) + 0.7152 * Double(boosted[i + 1]) + 0.0722 * Double(boosted[i + 2])
            guard input > 1e-5, output.isFinite, input.isFinite else { continue }
            let bin = Int(((log2(input) - lowest) * binsPerStop).rounded(.down))
            guard (0..<count).contains(bin) else { continue }
            sumIn[bin] += input
            sumOut[bin] += output
            hits[bin] += 1
        }
        var inputs: [Double] = [], outputs: [Double] = []
        for bin in 0..<count where hits[bin] >= 3 {
            let input = sumIn[bin] / Double(hits[bin])
            // the curve never falls: noise between neighboring bins is flattened out
            let output = max(sumOut[bin] / Double(hits[bin]), outputs.last ?? 0)
            guard input > (inputs.last ?? 0) else { continue }
            inputs.append(input)
            outputs.append(output)
        }
        guard inputs.count >= 8 else { return nil }
        return BoostCurve(inputs: inputs, outputs: outputs)
    }

    /// Engine output for unboosted input `x`: proportional below the samples, the last
    /// segment's slope above them.
    func apply(_ x: Double) -> Double { Self.interpolate(x, from: inputs, to: outputs) }

    /// The unboosted input that comes out as `y`.
    func invert(_ y: Double) -> Double { Self.interpolate(y, from: outputs, to: inputs) }

    /// A 1024-entry table for CIColorCurves over display-encoded values: what `delta` EV of
    /// exposure under the curve does to each output value.
    func exposureTable(delta: Double) -> Data {
        let size = 1024, gain = exp2(delta)
        var values = [Float](repeating: 0, count: size * 3)
        for i in 0..<size {
            let linear = Self.decode(Double(i) / Double(size - 1))
            let moved = Self.encode(max(0, apply(invert(linear) * gain)))
            let value = Float(min(1, max(0, moved)))
            values[i * 3] = value
            values[i * 3 + 1] = value
            values[i * 3 + 2] = value
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func interpolate(_ x: Double, from xs: [Double], to ys: [Double]) -> Double {
        guard let first = xs.first, let last = xs.last else { return x }
        if x <= first { return first > 0 ? x * ys[0] / first : ys[0] }
        if x >= last {
            let n = xs.count
            let slope = (ys[n - 1] - ys[n - 2]) / max(xs[n - 1] - xs[n - 2], 1e-12)
            return ys[n - 1] + (x - last) * max(slope, 0)
        }
        // binary search for the segment
        var low = 0, high = xs.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if xs[mid] <= x { low = mid } else { high = mid }
        }
        let t = (x - xs[low]) / max(xs[high] - xs[low], 1e-12)
        return ys[low] + (ys[high] - ys[low]) * t
    }

    /// The sRGB transfer function Display P3 shares.
    private static func decode(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    private static func encode(_ v: Double) -> Double {
        v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }
}
