import CoreImage
import ImageIO
import Foundation
import Vision

extension DevelopRenderer {
    /// Lens corrections on linear light: chromatic aberration first (`lateral`, as measured for
    /// the photo, then fringes, whose reach `scale` fits to the render's size), vignetting (it
    /// belongs to the lens's own frame), then distortion.
    static func applyLens(_ input: CIImage, _ s: DevelopSettings, scale: Double = 1,
                          lateral: ChromaticAberration.Correction? = nil) -> CIImage {
        guard s.hasLensCorrection else { return input }
        var image = input
        if let lateral { image = DevelopKernels.lateralChromaticAberration(image, red: lateral.red, blue: lateral.blue) }
        if s.defringePurple > 0 || s.defringeGreen > 0 {
            // fringes reach further from edges at higher amounts: 1.5 to 6.5 pixels of the full photo
            let reach = (1.5 + max(s.defringePurple, s.defringeGreen) * 0.25) * scale
            image = DevelopKernels.defringe(image, purple: min(1, s.defringePurple / 10), green: min(1, s.defringeGreen / 10),
                                            radius: max(1, reach))
        }
        let start = s.lensVignetteMidpoint / 100 * 0.8
        // +100 lifts the corners 1.3 EV, -100 darkens them as much
        let amount = s.lensVignette >= 0 ? s.lensVignette / 100 * 1.5 : s.lensVignette / 100 * 0.6
        let corrected = DevelopKernels.radialGain(image, amount: amount, start: start, width: 1 - start)
        return DevelopKernels.distort(corrected, k: DevelopGeometry.distortionStrength(s.distortion))
    }

    /// The point curves, as one lookup table per channel applied to display-encoded values
    /// (CIColorCurves converts to Display P3 for the table and back).
    static func applyCurve(_ input: CIImage, _ s: DevelopSettings) -> CIImage {
        guard !s.curve.isLinear else { return input }
        return input.applyingFilter("CIColorCurves", parameters: [
            "inputCurvesData": curveTable(s.curve),
            "inputCurvesDomain": CIVector(x: 0, y: 1),
            "inputColorSpace": outputColorSpace,
        ])
    }

    /// Calibration on linear light: the primaries moved by a matrix that keeps white white, then
    /// the shadows tinted (see `calibrationMatrix` and the kernel).
    static func applyCalibration(_ input: CIImage, _ s: DevelopSettings) -> CIImage {
        guard s.hasCalibration else { return input }
        var image = input
        if [s.redHue, s.redSaturation, s.greenHue, s.greenSaturation, s.blueHue, s.blueSaturation].contains(where: { $0 != 0 }) {
            let rows = calibrationMatrix(s)
            func vector(_ row: SIMD3<Double>) -> CIVector { CIVector(x: row.x, y: row.y, z: row.z, w: 0) }
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": vector(rows.r), "inputGVector": vector(rows.g), "inputBVector": vector(rows.b),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            ])
        }
        return DevelopKernels.shadowTint(image, s.shadowTint)
    }

    /// The rows of the calibration matrix on linear RGB. Each primary's hue leans toward a
    /// neighbor (red: + yellow, − magenta; green: + cyan, − yellow; blue: + purple, − cyan) and its
    /// saturation scales its distance from its own gray; then every row is scaled so white —
    /// and every gray — comes out as it went in.
    static func calibrationMatrix(_ s: DevelopSettings) -> (r: SIMD3<Double>, g: SIMD3<Double>, b: SIMD3<Double>) {
        let luma = SIMD3<Double>(0.2290, 0.6917, 0.0793)   // linear Display P3
        func primary(_ unit: SIMD3<Double>, hue: Double, saturation: Double,
                     plus: SIMD3<Double>, minus: SIMD3<Double>) -> SIMD3<Double> {
            let h = max(-1, min(1, hue / 100)), sat = max(-1, min(1, saturation / 100))
            var color = unit + (h > 0 ? plus : minus) * abs(h) * 0.3
            let gray = SIMD3<Double>(repeating: (color * luma).sum())
            color = gray + (color - gray) * (1 + sat * 0.6)
            return color
        }
        let red = primary(SIMD3(1, 0, 0), hue: s.redHue, saturation: s.redSaturation, plus: SIMD3(0, 1, 0), minus: SIMD3(0, 0, 1))
        let green = primary(SIMD3(0, 1, 0), hue: s.greenHue, saturation: s.greenSaturation, plus: SIMD3(0, 0, 1), minus: SIMD3(1, 0, 0))
        let blue = primary(SIMD3(0, 0, 1), hue: s.blueHue, saturation: s.blueSaturation, plus: SIMD3(1, 0, 0), minus: SIMD3(0, 1, 0))
        // the columns are where each primary goes; the rows are what the filter takes
        let white = red + green + blue
        return (SIMD3(red.x, green.x, blue.x) / white.x, SIMD3(red.y, green.y, blue.y) / white.y,
                SIMD3(red.z, green.z, blue.z) / white.z)
    }

    /// The profile's look (see `DevelopProfile`) at its amount: its curve, then its color
    /// response, on display-encoded values like the curve and mixer it's made of. Standard, or
    /// an amount of 0, leaves the photo as it is.
    static func applyProfile(_ input: CIImage, _ s: DevelopSettings) -> CIImage {
        let profile = DevelopProfile(stored: s.profile)
        guard profile != .standard, s.profileAmount > 0 else { return input }
        let look = profile.look(amount: s.profileAmount)
        var image = input
        if !look.curve.isEmpty {
            var curve = ToneCurve()
            curve.setPoints(look.curve, for: .rgb)
            image = image.applyingFilter("CIColorCurves", parameters: [
                "inputCurvesData": curveTable(curve),
                "inputCurvesDomain": CIVector(x: 0, y: 1),
                "inputColorSpace": outputColorSpace,
            ])
        }
        guard !look.mixer.isNeutral || look.saturation != 0 else { return image }
        var encoded = DevelopKernels.colorMixer(image.applyingFilter("CILinearToSRGBToneCurve"), look.mixer)
        if look.saturation != 0 {
            encoded = encoded.applyingFilter("CIColorControls", parameters: [
                "inputSaturation": 1 + look.saturation / 100, "inputContrast": 1, "inputBrightness": 0,
            ])
        }
        return encoded.applyingFilter("CISRGBToneCurveToLinear")
    }

    /// The HSL mixer — or, with the Monochrome profile, the black-and-white mix in its place —
    /// then color grading (which tones a black-and-white photo), on display-encoded values.
    /// Monochrome below 100% (a preset's partial amount) mixes the gray with the color.
    static func applyMixer(_ input: CIImage, _ s: DevelopSettings) -> CIImage {
        let monochrome = DevelopProfile(stored: s.profile) == .monochrome && s.profileAmount > 0
        guard monochrome || !s.mixer.isNeutral || !s.grading.isNeutral else { return input }
        let encoded = input.applyingFilter("CILinearToSRGBToneCurve")
        var mixed = DevelopKernels.colorMixer(encoded, s.mixer)
        if monochrome {
            let gray = DevelopKernels.grayMixer(encoded, s.grayMixer)
            mixed = s.profileAmount >= 100 ? gray : gray.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: mixed, "inputTime": 1 - s.profileAmount / 100,
            ]).cropped(to: encoded.extent)
        }
        return DevelopKernels.colorGrading(mixed, s.grading).applyingFilter("CISRGBToneCurveToLinear")
    }

    /// The LUT's look, in sRGB as LUTs are made, mixed in at its amount. A LUT no longer in
    /// the library leaves the photo as it is.
    static func applyLUT(_ input: CIImage, _ s: DevelopSettings, originalURL: URL? = nil) -> CIImage {
        guard let id = s.lutId, s.lutAmount > 0, let cube = LUTLibrary.cube(id: id, originalURL: originalURL) else { return input }
        let looked = input.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": cube.size, "inputCubeData": cube.data,
            "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!,
        ])
        guard s.lutAmount < 100 else { return looked.cropped(to: input.extent) }
        return looked.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: input, "inputTime": 1 - s.lutAmount / 100,
        ]).cropped(to: input.extent)
    }

    private static let curveTables = NSCache<NSString, NSData>()

    /// 1024 RGB float triples: each channel's curve after the composite.
    static func curveTable(_ curve: ToneCurve) -> Data {
        let key = curve.fingerprintText as NSString
        if let cached = curveTables.object(forKey: key) { return cached as Data }
        let size = 1024
        var values = [Float](repeating: 0, count: size * 3)
        for i in 0..<size {
            let x = Double(i) / Double(size - 1)
            values[i * 3] = Float(curve.value(x, channel: .red))
            values[i * 3 + 1] = Float(curve.value(x, channel: .green))
            values[i * 3 + 2] = Float(curve.value(x, channel: .blue))
        }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        curveTables.setObject(data as NSData, forKey: key)
        return data
    }

    /// Dehaze, clarity and texture, in display-encoded values. Their radii are fractions of the
    /// photo's long edge, so a preview and the full photo look alike.
    static func applyPresence(_ input: CIImage, _ s: DevelopSettings) -> CIImage {
        guard s.hasPresence else { return input }
        let extent = input.extent
        let longEdge = Double(max(extent.width, extent.height))
        var image = input.applyingFilter("CILinearToSRGBToneCurve")
        image = DevelopKernels.dehaze(image, amount: s.dehaze / 100)
        // negative amounts stop at removing the detail at that scale, never inverting it
        func gain(_ value: Double, up: Double) -> Double { value >= 0 ? value / 100 * up : value / 100 }
        image = DevelopKernels.localContrast(image, sigma: longEdge * 0.008, amount: gain(s.clarity, up: 2), bias: 1)
        image = DevelopKernels.localContrast(image, sigma: max(0.7, longEdge * 0.0012), amount: gain(s.texture, up: 1.5),
                                             bias: 0.5)
        return image.applyingFilter("CISRGBToneCurveToLinear").cropped(to: extent)
    }

    /// Tone and color shared by RAW and other formats, in Lightroom's order. The curve and
    /// contrast work perceptually so slider response matches the eye, not linear light.
    static func applyTone(_ input: CIImage, _ s: DevelopSettings) -> CIImage {
        var image = input
        let highlightAmount = s.highlights < 0 ? 1 + s.highlights / 100 : 1
        if highlightAmount != 1 || s.shadows != 0 {
            image = image.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": highlightAmount,
                "inputShadowAmount": s.shadows / 100,
            ])
        }
        if s.whites != 0 || s.blacks != 0 || s.highlights > 0 {
            // CIToneCurve already works in a perceptual (gamma 2) version of the working space.
            var y: [Double] = [0, 0.25, 0.5, 0.75, 1]
            if s.blacks > 0 { y[0] = s.blacks / 100 * 0.12 } else { y[1] += s.blacks / 100 * 0.08 }
            if s.whites < 0 { y[4] = 1 + s.whites / 100 * 0.12 } else { y[3] += s.whites / 100 * 0.08 }
            if s.highlights > 0 { y[3] += s.highlights / 100 * 0.06 }
            for i in 1..<y.count { y[i] = min(1, max(y[i], y[i - 1] + 0.004)) }
            image = image.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: y[0]),
                "inputPoint1": CIVector(x: 0.25, y: y[1]),
                "inputPoint2": CIVector(x: 0.5, y: y[2]),
                "inputPoint3": CIVector(x: 0.75, y: y[3]),
                "inputPoint4": CIVector(x: 1, y: y[4]),
            ])
        }
        if s.contrast != 0 || s.saturation != 0 {
            // contrast pivots on mid-gray, so apply it in gamma space rather than linear light
            image = image.applyingFilter("CILinearToSRGBToneCurve")
                .applyingFilter("CIColorControls", parameters: [
                    "inputContrast": 1 + s.contrast / 200,
                    "inputSaturation": 1 + s.saturation / 100,
                    "inputBrightness": 0,
                ])
                .applyingFilter("CISRGBToneCurveToLinear")
        }
        if s.vibrance != 0 {
            image = image.applyingFilter("CIVibrance", parameters: ["inputAmount": s.vibrance / 100])
        }
        return image
    }
}
