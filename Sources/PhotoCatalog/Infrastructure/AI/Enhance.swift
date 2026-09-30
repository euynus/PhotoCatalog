// ============================================================
//  Enhance — Lightroom's Enhance: AI super resolution and denoise
// ============================================================
import CoreGraphics
import CoreImage
import CoreML
import Foundation
import ImageIO

/// Runs bundled models over a whole photo, tile by tile, making a new image: denoise cleans it
/// at its own size, super resolution doubles the width and height. Tiles overlap and only each
/// tile's middle is kept, so the seams fall where every tile saw enough around them.
enum Enhance {
    struct Options: Equatable, Sendable {
        var denoise = true
        /// 0…100: how much of the denoised photo replaces the original.
        var denoiseAmount = 60.0
        var superResolution = false

        var isEmpty: Bool { !denoise && !superResolution }
    }

    /// Runs one photo at a time, off the main thread and the cooperative pool (RAW decoding).
    static let queue = DispatchQueue(label: "PhotoCatalog.enhance", qos: .userInitiated)

    /// An image as three planes of display-encoded values, 0…1.
    struct Planes {
        let width: Int, height: Int
        /// Red, then green, then blue, each `width` × `height`, rows from the top.
        var values: [Float16]

        func value(_ channel: Int, _ x: Int, _ y: Int) -> Float16 { values[(channel * height + y) * width + x] }
    }

    /// The photo's pixels, display-encoded in Display P3, rendered a band of rows at a time so a
    /// large photo never needs a full-size float copy.
    static func planes(of image: CIImage) -> Planes? {
        let rect = image.extent.integral
        let width = Int(rect.width), height = Int(rect.height)
        guard width > 0, height > 0 else { return nil }
        let plane = width * height
        var values = [Float16](repeating: 0, count: plane * 3)
        let bandRows = 256
        var pixels = [Float](repeating: 0, count: width * bandRows * 4)
        for top in stride(from: 0, to: height, by: bandRows) {
            let rows = min(bandRows, height - top)
            // rows count from the top; Core Image's y from the bottom
            let band = CGRect(x: rect.minX, y: rect.maxY - CGFloat(top + rows), width: rect.width, height: CGFloat(rows))
            DevelopRenderer.context.render(image, toBitmap: &pixels, rowBytes: width * 16, bounds: band,
                                           format: .RGBAf, colorSpace: DevelopRenderer.outputColorSpace)
            for y in 0..<rows {
                for x in 0..<width {
                    let source = (y * width + x) * 4, target = (top + y) * width + x
                    values[target] = Float16(min(1, max(0, pixels[source])))
                    values[plane + target] = Float16(min(1, max(0, pixels[source + 1])))
                    values[2 * plane + target] = Float16(min(1, max(0, pixels[source + 2])))
                }
            }
        }
        return Planes(width: width, height: height, values: values)
    }

    /// `input` through `model`, which takes `tile`-pixel squares and returns them `modelScale`
    /// times larger; the result is `outputScale` times the input (`modelScale` divisible by it),
    /// averaged down from the model's output. `progress` hears 0…1; nil when the model fails or
    /// `cancelled` says stop.
    static func run(_ model: MLModel, on input: Planes, tile: Int, margin: Int, modelScale: Int, outputScale: Int,
                    progress: (Double) -> Void = { _ in }, cancelled: () -> Bool = { false }) -> Planes? {
        let reduce = modelScale / outputScale
        let width = input.width * outputScale, height = input.height * outputScale
        var output = [Float16](repeating: 0, count: width * height * 3)
        let step = tile - 2 * margin
        let columns = (input.width + step - 1) / step, rows = (input.height + step - 1) / step
        guard let array = try? MLMultiArray(shape: [1, 3, NSNumber(value: tile), NSNumber(value: tile)], dataType: .float16)
        else { return nil }
        let inputStrides = array.strides.map(\.intValue)
        for row in 0..<rows {
            for column in 0..<columns {
                if cancelled() { return nil }
                // the part this tile is responsible for, and where the tile starts so that part
                // sits in its middle (or against the photo's edge)
                let keepX = column * step, keepY = row * step
                let keepWidth = min(step, input.width - keepX), keepHeight = min(step, input.height - keepY)
                let x0 = max(0, min(keepX - margin, input.width - tile)), y0 = max(0, min(keepY - margin, input.height - tile))
                let pointer = array.dataPointer.assumingMemoryBound(to: Float16.self)
                for channel in 0..<3 {
                    for y in 0..<tile {
                        let sy = min(input.height - 1, max(0, y0 + y))
                        let base = (channel * input.height + sy) * input.width
                        let target = channel * inputStrides[1] + y * inputStrides[2]
                        for x in 0..<tile {
                            pointer[target + x * inputStrides[3]] = input.values[base + min(input.width - 1, max(0, x0 + x))]
                        }
                    }
                }
                guard let features = try? MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(multiArray: array)]),
                      let prediction = try? model.prediction(from: features),
                      let result = prediction.featureValue(for: "output")?.multiArrayValue,
                      result.dataType == .float16 else { return nil }
                let strides = result.strides.map(\.intValue)
                let area = Float(reduce * reduce)
                // the models' outputs are 16-bit floats (read directly: the typed accessors need macOS 15)
                do {
                    let values = result.dataPointer.assumingMemoryBound(to: Float16.self)
                    for channel in 0..<3 {
                        for oy in (keepY * outputScale)..<((keepY + keepHeight) * outputScale) {
                            let my = oy * reduce - y0 * modelScale
                            for ox in (keepX * outputScale)..<((keepX + keepWidth) * outputScale) {
                                let mx = ox * reduce - x0 * modelScale
                                var sum: Float = 0
                                for dy in 0..<reduce {
                                    let rowBase = channel * strides[1] + (my + dy) * strides[2]
                                    for dx in 0..<reduce { sum += Float(values[rowBase + (mx + dx) * strides[3]]) }
                                }
                                output[(channel * height + oy) * width + ox] = Float16(min(1, max(0, sum / area)))
                            }
                        }
                    }
                }
                progress(Double(row * columns + column + 1) / Double(rows * columns))
            }
        }
        return Planes(width: width, height: height, values: output)
    }

    /// The planes as a 16-bit Display P3 image (its pixels handed to the image, not copied).
    static func image(_ planes: Planes) -> CGImage? {
        let plane = planes.width * planes.height
        let pixels = UnsafeMutablePointer<UInt16>.allocate(capacity: plane * 3)
        for i in 0..<plane {
            for channel in 0..<3 {
                pixels[i * 3 + channel] = UInt16((Float(planes.values[channel * plane + i]) * 65535).rounded())
            }
        }
        guard let provider = CGDataProvider(dataInfo: nil, data: pixels, size: plane * 6, releaseData: { _, data, _ in
            data.deallocate()
        }) else {
            pixels.deallocate()
            return nil
        }
        return CGImage(width: planes.width, height: planes.height, bitsPerComponent: 16, bitsPerPixel: 48,
                       bytesPerRow: planes.width * 6, space: DevelopRenderer.outputColorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // ---- denoise ----
    static let denoiseTile = 256
    static let denoiseMargin = 32

    /// `input` through SCUNet, mixed with the original by `amount` (0…100).
    static func denoise(_ input: Planes, amount: Double, progress: (Double) -> Void = { _ in },
                        cancelled: () -> Bool = { false }) -> Planes? {
        guard let model = AIModels.model(.denoise),
              var output = run(model, on: input, tile: denoiseTile, margin: denoiseMargin, modelScale: 1, outputScale: 1,
                               progress: progress, cancelled: cancelled) else { return nil }
        let weight = Float(min(100, max(0, amount)) / 100)
        if weight < 1 {
            for i in output.values.indices {
                let original = Float(input.values[i])
                output.values[i] = Float16(original + (Float(output.values[i]) - original) * weight)
            }
        }
        return output
    }

    /// The whole of it for one photo: its pixels as shot, denoised and/or enlarged. `progress`
    /// hears 0…1 over all the steps.
    static func enhance(_ image: CIImage, options: Options, progress: @escaping (Double) -> Void = { _ in },
                        cancelled: @escaping () -> Bool = { false }) -> Planes? {
        guard !options.isEmpty, var planes = planes(of: image) else { return nil }
        // super resolution works on four times the pixels of the photo at the model's input size,
        // but runs ten times faster per tile than the denoiser: weigh the steps accordingly
        let denoiseShare = options.denoise ? (options.superResolution ? 0.8 : 1.0) : 0
        if options.denoise {
            guard let denoised = denoise(planes, amount: options.denoiseAmount, progress: { progress($0 * denoiseShare) },
                                         cancelled: cancelled) else { return nil }
            planes = denoised
        }
        if options.superResolution {
            guard let enlarged = superResolution(planes, progress: { progress(denoiseShare + $0 * (1 - denoiseShare)) },
                                                 cancelled: cancelled) else { return nil }
            planes = enlarged
        }
        return planes
    }

    /// Writes `image` as an LZW-compressed TIFF carrying `original`'s metadata (camera, lens,
    /// exposure, date, place), upright as it now is.
    static func writeTIFF(_ image: CGImage, to url: URL, metadataFrom original: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 1, nil) else {
            return false
        }
        var properties: [CFString: Any] = [:]
        if let source = CGImageSourceCreateWithURL(original as CFURL, nil),
           let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary,
                        kCGImagePropertyExifAuxDictionary] {
                if let value = metadata[key] { properties[key] = value }
            }
            var tiff = metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            tiff[kCGImagePropertyTIFFOrientation] = 1
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        tiff[kCGImagePropertyTIFFCompression] = 5   // LZW
        properties[kCGImagePropertyTIFFDictionary] = tiff
        properties[kCGImagePropertyOrientation] = 1
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    // ---- super resolution ----
    static let superResolutionTile = 256
    static let superResolutionMargin = 24

    /// `input` at twice the width and height, through Real-ESRGAN's general model.
    static func superResolution(_ input: Planes, progress: (Double) -> Void = { _ in },
                                cancelled: () -> Bool = { false }) -> Planes? {
        guard let model = AIModels.model(.superResolution) else { return nil }
        return run(model, on: input, tile: superResolutionTile, margin: superResolutionMargin, modelScale: 4, outputScale: 2,
                   progress: progress, cancelled: cancelled)
    }
}
