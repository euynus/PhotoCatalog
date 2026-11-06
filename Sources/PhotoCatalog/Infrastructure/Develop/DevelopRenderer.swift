// ============================================================
//  DevelopRenderer — non-destructive rendering with Core Image
// ============================================================
import CoreImage
import Foundation

enum DevelopRenderer {
    /// One GPU context for the app: contexts are expensive to create and safe to share.
    static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!,
        .cacheIntermediates: false,
    ])

    static let outputColorSpace = CGColorSpace(name: CGColorSpace.displayP3)!

    static let linearColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!

    /// 64-bin R, G, B histogram of a rendered image (fractions of pixels), computed on the GPU
    /// from the encoded display values — what the eye sees, not linear light.
    static func histogram(of image: CGImage) -> DevelopHistogram? {
        var input = CIImage(cgImage: image, options: [.colorSpace: NSNull()])
        let longEdge = max(input.extent.width, input.extent.height)
        if longEdge > 1024 {   // a downsampled render has the same distribution
            let scale = 1024 / longEdge
            input = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let histogram = input.applyingFilter("CIAreaHistogram", parameters: [
            "inputExtent": CIVector(cgRect: input.extent),
            "inputCount": DevelopHistogram.binCount,
            "inputScale": 1,
        ])
        var bins = [Float](repeating: 0, count: DevelopHistogram.binCount * 4)
        context.render(histogram, toBitmap: &bins, rowBytes: DevelopHistogram.binCount * 16,
                       bounds: CGRect(x: 0, y: 0, width: DevelopHistogram.binCount, height: 1),
                       format: .RGBAf, colorSpace: nil)
        let channel = { (offset: Int) in stride(from: offset, to: bins.count, by: 4).map { Double(bins[$0]) } }
        return DevelopHistogram(red: channel(0), green: channel(1), blue: channel(2))
    }

    static func render(_ image: CIImage) -> CGImage? {
        context.createCGImage(image, from: image.extent.integral, format: .RGBA8, colorSpace: outputColorSpace)
    }
}
