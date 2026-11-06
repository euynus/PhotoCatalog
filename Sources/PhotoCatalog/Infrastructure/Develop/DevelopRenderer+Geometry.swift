import CoreImage
import ImageIO
import Foundation
import Vision

extension DevelopRenderer {
    /// Rotation, mirror, straighten and crop (see `DevelopSettings`). The result's origin is zero.
    static func applyGeometry(_ input: CIImage, _ s: DevelopSettings, wholeFrame: Bool = false) -> CIImage {
        guard s.hasGeometry else { return input }
        let orientations: [CGImagePropertyOrientation] = [.up, .right, .down, .left]   // clockwise turns
        var image = input.oriented(orientations[((s.rotation % 4) + 4) % 4])
        if s.flipped { image = image.oriented(.upMirrored) }
        image = atOrigin(image)
        let frame = CGRect(origin: .zero, size: image.extent.integral.size)
        if let perspective = DevelopGeometry.perspective(s, frame: frame.size) {
            // the frame's corners where the correction puts them (Core Image's y points up);
            // outside the corrected photo stays empty, and the crop leaves it out
            func corner(_ x: CGFloat, _ y: CGFloat) -> CIVector {
                let p = perspective.apply(CGPoint(x: x, y: y)) ?? CGPoint(x: x, y: y)
                return CIVector(x: p.x, y: frame.height - p.y)
            }
            image = image.applyingFilter("CIPerspectiveTransform", parameters: [
                "inputTopLeft": corner(0, 0), "inputTopRight": corner(frame.width, 0),
                "inputBottomRight": corner(frame.width, frame.height), "inputBottomLeft": corner(0, frame.height),
            ]).cropped(to: frame)
        }
        if s.straighten != 0 {
            // Core Image's y axis points up, so a clockwise turn is a negative angle
            let turn = CGAffineTransform(translationX: frame.midX, y: frame.midY)
                .rotated(by: -s.straighten * .pi / 180)
                .translatedBy(x: -frame.midX, y: -frame.midY)
            image = image.clampedToExtent().transformed(by: turn).cropped(to: frame)
            if wholeFrame {
                // outside the turned photo stays empty so the crop tool shows where the photo ends
                let mask = CIImage(color: .white).cropped(to: frame).transformed(by: turn)
                image = image.applyingFilter("CIBlendWithAlphaMask", parameters: [
                    kCIInputBackgroundImageKey: CIImage.empty(),
                    kCIInputMaskImageKey: mask,
                ]).cropped(to: frame)
            }
        }
        guard !wholeFrame else { return image }
        let crop = DevelopGeometry.effectiveCrop(s, frame: frame.size)
        let x = (crop.x * frame.width).rounded(), width = max(1, (crop.width * frame.width).rounded())
        let height = max(1, (crop.height * frame.height).rounded())
        let y = ((1 - crop.y) * frame.height).rounded() - height   // top-left fractions → bottom-left pixels
        return atOrigin(image.cropped(to: CGRect(x: x, y: max(0, y), width: width, height: height)))
    }

    /// The straighten angle (degrees, positive = clockwise) that levels the horizon Vision
    /// finds in the photo as rotated and mirrored by `settings`; nil when it finds none.
    static func horizonAngle(url: URL, isRaw: Bool, settings: DevelopSettings) -> Double? {
        var oriented = DevelopSettings()
        oriented.rotation = settings.rotation
        oriented.flipped = settings.flipped
        guard let image = Source(url: url, isRaw: isRaw, maxPixel: 1024)?.image(oriented).flatMap(render) else {
            return nil
        }
        let request = VNDetectHorizonRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        // Vision reports a horizon rising to the right as a negative angle, which a clockwise
        // (positive) straighten of the same size levels
        return request.results?.first.map { -Double($0.angle) * 180 / .pi }
    }

    /// The Transform and straighten settings that set the photo's verticals upright (see
    /// `Upright`), found in the photo as rotated, mirrored and lens-corrected by `settings`.
    static func uprightCorrection(url: URL, isRaw: Bool, settings: DevelopSettings,
                                  mode: Upright.Mode) -> Upright.Correction? {
        var oriented = DevelopSettings()
        oriented.rotation = settings.rotation
        oriented.flipped = settings.flipped
        oriented.distortion = settings.distortion   // lens distortion bends the lines it looks for
        guard let image = Source(url: url, isRaw: isRaw, maxPixel: 900)?.image(oriented).flatMap(render),
              let pixels = SemanticMasks.rgba(image) else { return nil }
        let count = image.width * image.height
        var luma = [Float](repeating: 0, count: count)
        for i in 0..<count {
            luma[i] = (0.2126 * Float(pixels[i * 4]) + 0.7152 * Float(pixels[i * 4 + 1])
                       + 0.0722 * Float(pixels[i * 4 + 2])) / 255
        }
        return Upright.correction(luma: luma, width: image.width, height: image.height, mode: mode)
    }

    private static func atOrigin(_ image: CIImage) -> CIImage {
        let origin = image.extent.origin
        return origin == .zero ? image : image.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
    }
}
