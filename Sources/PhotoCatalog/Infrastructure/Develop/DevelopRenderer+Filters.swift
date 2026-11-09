import CoreImage
import Foundation

extension DevelopRenderer {
    /// Non-RAW white balance, for the whole photo and for masks alike: a relative shift, where
    /// telling Core Image the scene was lit by a cooler source warms it. Zero leaves the image as it is.
    static func relativeWhiteBalance(_ image: CIImage, temperature: Double, tint: Double) -> CIImage {
        guard temperature != 0 || tint != 0 else { return image }
        return image.applyingFilter("CITemperatureAndTint", parameters: [
            "inputNeutral": CIVector(x: 6500 + temperature * 25, y: tint * 0.5),
            "inputTargetNeutral": CIVector(x: 6500, y: 0),
        ])
    }

    /// A lookup table per channel (see `curveTable`) on display-encoded values: CIColorCurves
    /// converts to Display P3 for the table and back.
    static func applyingCurves(_ image: CIImage, _ table: Data) -> CIImage {
        image.applyingFilter("CIColorCurves", parameters: [
            "inputCurvesData": table,
            "inputCurvesDomain": CIVector(x: 0, y: 1),
            "inputColorSpace": outputColorSpace,
        ])
    }

    /// A weight (a mask, a spot's disc) scaled by `k` in red, green and blue; alpha stays.
    static func scaled(_ weight: CIImage, by k: Double) -> CIImage {
        weight.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
        ])
    }
}
