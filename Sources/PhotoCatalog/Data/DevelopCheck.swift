import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Develop adjustments render in the right direction, persist, and undo.
enum DevelopCheck {
    static func run() {
        checkRendering()
        checkDetail()
        checkPresence()
        checkToneCurve()
        checkColorMixer()
        checkProfiles()
        checkBlackAndWhite()
        checkCalibration()
        checkSoftProofing()
        checkColorGrading()
        checkLocalAdjustments()
        checkSpotRemoval()
        checkPeopleMasks()
        checkLensCorrections()
        checkChromaticAberration()
        checkEffects()
        checkAutoAdjustments()
        checkBoostCurve()
        checkHistogram()
        checkGeometryMath()
        checkGeometryRendering()
        checkPersistence()
        checkTransferRules()
        checkPresetBlend()
        checkPerspective()
        checkRangeMasks()
        MainActor.assumeIsolated {
            checkLUTs()
            checkEditsAndUndo()
            checkCopyPasteAndPresets()
            checkPresetFiles()
            checkSoftProofingState()
        }
        print("--- develop assertions passed ---")
    }

    /// A 64×64 solid-color image in display P3.
    static func solid(_ color: (Double, Double, Double)) -> CGImage {
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                space: DevelopRenderer.outputColorSpace,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: DevelopRenderer.outputColorSpace,
                                     components: [color.0, color.1, color.2, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        return context.makeImage()!
    }

    /// Renders `settings` on `image` through a PNG file, as the app renders a photo.
    static func develop(_ image: CGImage, _ settings: DevelopSettings, wholeFrame: Bool = false,
                                overlayMask: String? = nil) -> CGImage {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pc-develop-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        let source = DevelopRenderer.Source(url: url, isRaw: false, maxPixel: nil)!
        return DevelopRenderer.render(source.image(settings, wholeFrame: wholeFrame, overlayMask: overlayMask)!)!
    }

    /// RGBA at (x, y), top-left origin.
    static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: DevelopRenderer.outputColorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let i = (y * image.width + x) * 4
        return (data[i], data[i + 1], data[i + 2], data[i + 3])
    }

    /// Mean RGB (0…1, display P3) of a rendered adjustment of a solid-color image.
    static func mean(_ color: (Double, Double, Double), _ settings: DevelopSettings) -> (r: Double, g: Double, b: Double) {
        let rendered = develop(solid(color), settings)
        var pixel = [UInt8](repeating: 0, count: 4)
        let sample = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                               space: DevelopRenderer.outputColorSpace,
                               bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        sample.interpolationQuality = .medium
        sample.draw(rendered, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
    }

    static func luma(_ c: (r: Double, g: Double, b: Double)) -> Double { 0.3 * c.r + 0.59 * c.g + 0.11 * c.b }

    /// 64 × 64 image from a per-pixel color function (x, y) → display-P3 RGB.
    static func image(_ color: (Int, Int) -> (Double, Double, Double)) -> CGImage {
        var data = [UInt8](repeating: 255, count: 64 * 64 * 4)
        for y in 0..<64 {
            for x in 0..<64 {
                let c = color(x, y), i = (y * 64 + x) * 4
                data[i] = UInt8(max(0, min(255, c.0 * 255)))
                data[i + 1] = UInt8(max(0, min(255, c.1 * 255)))
                data[i + 2] = UInt8(max(0, min(255, c.2 * 255)))
            }
        }
        let context = CGContext(data: &data, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 64 * 4,
                                space: DevelopRenderer.outputColorSpace,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        return context.makeImage()!
    }

    /// Standard deviation of luma and of red − blue over the image's interior (0…255 scale).
    static func spread(_ image: CGImage) -> (luma: Double, chroma: Double) {
        var lumas: [Double] = [], chromas: [Double] = []
        for y in stride(from: 8, to: 56, by: 2) {
            for x in stride(from: 8, to: 56, by: 2) {
                let p = pixel(image, x, y)
                lumas.append(0.3 * Double(p.r) + 0.59 * Double(p.g) + 0.11 * Double(p.b))
                chromas.append(Double(p.r) - Double(p.b))
            }
        }
        func deviation(_ values: [Double]) -> Double {
            let mean = values.reduce(0, +) / Double(values.count)
            return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
        }
        return (deviation(lumas), deviation(chromas))
    }

    /// Writes `image` to a temporary PNG, as a photo on disk for the automatic adjustments.
    static func pngFile(_ image: CGImage) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pc-auto-\(UUID().uuidString).png")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return url
    }
}
