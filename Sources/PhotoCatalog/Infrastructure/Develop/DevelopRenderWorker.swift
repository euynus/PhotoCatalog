import CoreImage
import ImageIO
import Foundation
import Vision

/// Renders develop previews on its own serial queue (never the Swift cooperative pool: RAW
/// decoding can deadlock it). Requests coalesce — while a slider drags, only the newest
/// pending one renders — and the decoded source is kept until the photo or size changes.
final class DevelopRenderWorker: @unchecked Sendable {
    struct Request: Sendable {
        let url: URL
        let isRaw: Bool
        let maxPixel: Int?
        let settings: DevelopSettings
        let draft: Bool
        var wholeFrame = false
        var overlayMask: String?
        var visualizeSpots = false
        /// Lens blur's depth shown instead of the photo.
        var visualizeDepth = false
        /// Soft proofing: the render shown through this profile (see `SoftProofing`).
        var proof: SoftProof?
        let token: Int
    }

    struct Result: @unchecked Sendable {
        let request: Request
        let image: CGImage?
        let histogram: DevelopHistogram?
        /// The decoded photo's size before rotation and crop.
        let sourceSize: CGSize?
        let asShotTemperature: Double?
        let asShotTint: Double?
    }

    private let queue = DispatchQueue(label: "PhotoCatalog.develop-render", qos: .userInteractive)
    private let lock = NSLock()
    private var pending: (Request, @Sendable (Result) -> Void)?
    private var source: (key: String, source: DevelopRenderer.Source)?

    func submit(_ request: Request, completion: @escaping @Sendable (Result) -> Void) {
        lock.withLock { pending = (request, completion) }
        queue.async { [self] in drain() }
    }

    private func drain() {
        guard let (request, completion) = lock.withLock({ () -> (Request, @Sendable (Result) -> Void)? in
            defer { pending = nil }
            return pending
        }) else { return }
        let key = "\(request.url.path)|\(request.maxPixel ?? 0)"
        if source?.key != key {
            source = DevelopRenderer.Source(url: request.url, isRaw: request.isRaw, maxPixel: request.maxPixel)
                .map { (key, $0) }
        }
        let image = autoreleasepool { () -> CGImage? in
            let rendered = source?.source.image(request.settings, draft: request.draft, wholeFrame: request.wholeFrame,
                                                overlayMask: request.overlayMask, visualizeSpots: request.visualizeSpots,
                                                visualizeDepth: request.visualizeDepth)
                .flatMap(DevelopRenderer.render)
            guard let rendered, let proof = request.proof else { return rendered }
            return SoftProofing.proof(rendered, proof) ?? rendered
        }
        // the crop tool's empty corners and the mask overlay's tint would skew the histogram
        let histogram = request.wholeFrame || request.overlayMask != nil || request.visualizeSpots || request.visualizeDepth
            ? nil : image.flatMap(DevelopRenderer.histogram)
        completion(Result(request: request, image: image, histogram: histogram, sourceSize: source?.source.sourceSize,
                          asShotTemperature: source?.source.asShotTemperature,
                          asShotTint: source?.source.asShotTint))
    }
}
