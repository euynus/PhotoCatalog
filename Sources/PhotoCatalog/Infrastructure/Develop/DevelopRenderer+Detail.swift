import CoreImage
import Foundation

extension DevelopRenderer {
    /// Post-crop vignette (on linear light, so darkening behaves like exposure), then grain.
    static func applyEffects(_ input: CIImage, _ s: DevelopSettings, scale: CGFloat) -> CIImage {
        guard s.hasEffects else { return input }
        var image = input
        if s.vignette != 0 {
            // the transition is centered on the midpoint and as wide as the feather asks
            let middle = 0.3 + s.vignetteMidpoint / 100 * 0.7
            let width = 0.1 + s.vignetteFeather / 100 * 0.8
            let amount = s.vignette >= 0 ? s.vignette / 100 * 1.5 : s.vignette / 100 * 0.85
            image = DevelopKernels.radialGain(image, amount: amount, start: max(0, middle - width / 2), width: width)
        }
        if s.grain > 0 {
            let encoded = image.applyingFilter("CILinearToSRGBToneCurve")
            image = DevelopKernels.grain(encoded, amount: s.grain, size: s.grainSize, roughness: s.grainRoughness,
                                         scale: Double(scale))
                .applyingFilter("CISRGBToneCurveToLinear")
        }
        return image
    }

    /// Noise reduction, then sharpening, in display-encoded values where noise and halos are
    /// judged. `scale` is the render's size relative to the full-resolution photo (≤ 1).
    static func applyDetail(_ input: CIImage, _ s: DevelopSettings, scale: CGFloat) -> CIImage {
        guard s.hasDetail else { return input }
        let extent = input.extent
        var image = input.applyingFilter("CILinearToSRGBToneCurve")
        if s.luminanceNoise > 0 {
            // a 3×3 median first: CINoiseReduction alone leaves isolated specks at high ISO
            let smoothed = image.applyingFilter("CIMedianFilter")
                .applyingFilter("CINoiseReduction", parameters: [
                    "inputNoiseLevel": s.luminanceNoise / 100 * 0.06, "inputSharpness": 0,
                ])
            // luminance only (color noise has its own slider); the fixed-size median eases in
            // over the first third, and less in a reduced preview where noise is averaged away
            let luminance = smoothed.applyingFilter("CILuminosityBlendMode", parameters: [kCIInputBackgroundImageKey: image])
            let strength = min(1, s.luminanceNoise / 30) * min(1, Double(scale) * 1.5)
            image = image.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: luminance, "inputTime": strength,
            ])
        }
        if s.colorNoise > 0 {
            // blur the color and keep the original's luminance
            let sigma = s.colorNoise / 100 * 8 * Double(scale)
            let blurred = image.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
            image = blurred.applyingFilter("CIColorBlendMode", parameters: [kCIInputBackgroundImageKey: image])
        }
        if s.sharpening > 0 {
            let sharpened = image.applyingFilter("CISharpenLuminance", parameters: [
                "inputSharpness": s.sharpening / 100,
                "inputRadius": max(0.5, s.sharpenRadius * Double(scale)),
            ])
            image = s.sharpenMasking > 0
                ? sharpened.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: image,
                    kCIInputMaskImageKey: edgeMask(image, masking: s.sharpenMasking, scale: scale),
                ])
                : sharpened
        }
        return image.applyingFilter("CISRGBToneCurveToLinear").cropped(to: extent)
    }

    /// White on edges, black on smooth areas; higher masking keeps only stronger edges.
    static func edgeMask(_ gamma: CIImage, masking: Double, scale: CGFloat) -> CIImage {
        let extent = gamma.extent
        let edges = gamma.applyingFilter("CIColorControls", parameters: ["inputSaturation": 0])
            .clampedToExtent().applyingGaussianBlur(sigma: max(0.6, 1.2 * Double(scale)))
            .applyingFilter("CIEdges", parameters: ["inputIntensity": 6]).cropped(to: extent)
            // edge strength is heavy-tailed; a square root spreads it so the slider moves evenly
            .applyingFilter("CIGammaAdjust", parameters: ["inputPower": 0.5])
        let threshold = pow(masking / 100, 2) * 0.3, width = 0.02 + threshold * 0.5
        let gain = 1 / width, bias = -threshold / width
        return edges.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0),
        ]).applyingFilter("CIColorClamp")
    }
}
