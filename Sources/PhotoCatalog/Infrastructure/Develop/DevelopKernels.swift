// ============================================================
//  DevelopKernels — Core Image kernels Core Image has no filter for
// ============================================================
import CoreImage

/// Lens distortion, radial gain, film grain, local contrast, haze removal, the color mixer,
/// color grading, mask shapes, healing and a high-pass view, each compiled from Metal source the first time a render needs it: the package
/// has no Metal build step, and Core Image compiles stitchable kernels at run time. A kernel
/// that fails to compile leaves its adjustment out of the render.
enum DevelopKernels {
    /// Converts between RGB and HSL (hue in degrees), for the mixer and color grading.
    private static let hsl = """
    float3 toHSL(float3 c) {
        float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b));
        float l = (mx + mn) * 0.5, d = mx - mn, h = 0.0, s = 0.0;
        if (d > 1e-5) {
            s = d / max(1.0 - abs(2.0 * l - 1.0), 1e-5);
            if (mx == c.r) { h = fmod((c.g - c.b) / d + 6.0, 6.0); }
            else if (mx == c.g) { h = (c.b - c.r) / d + 2.0; }
            else { h = (c.r - c.g) / d + 4.0; }
            h *= 60.0;
        }
        return float3(h, s, l);
    }
    float3 fromHSL(float3 hsl) {
        float h = fmod(hsl.x + 360.0, 360.0) / 60.0, s = hsl.y, l = hsl.z;
        float c = (1.0 - abs(2.0 * l - 1.0)) * s;
        float x = c * (1.0 - abs(fmod(h, 2.0) - 1.0));
        float3 rgb = h < 1.0 ? float3(c, x, 0) : h < 2.0 ? float3(x, c, 0) : h < 3.0 ? float3(0, c, x)
                   : h < 4.0 ? float3(0, x, c) : h < 5.0 ? float3(x, 0, c) : float3(c, 0, x);
        return rgb + (l - c * 0.5);
    }
    """

    /// One source per kernel: kernels compiled from a single source share Core Image's
    /// compiled-program cache, and a later graph could run the code of a kernel rendered before it.
    private static let bodies: [String: String] = [
        "lensDistortion": """
        // Radial distortion about `center`, in units where the corner is at radius 1:
        // k > 0 samples closer to the center toward the edges, which straightens barrel distortion.
        [[stitchable]] float2 lensDistortion(float2 center, float k, float invRadius2, float zoom,
                                             destination dest) {
            float2 p = (dest.coord() - center) / zoom;
            float r2 = dot(p, p) * invRadius2;
            return center + p * (1.0 - k * r2);
        }
        """,
        "radialGain": """
        // Multiplies color by 1 + amount·w, where w rises smoothly from 0 at radius `start`
        // to 1 at `start + width` (radius 1 is the corner).
        [[stitchable]] float4 radialGain(sample_t s, float2 center, float invRadius2, float amount,
                                         float start, float width, destination dest) {
            float2 p = dest.coord() - center;
            float r = sqrt(dot(p, p) * invRadius2);
            float w = smoothstep(start, start + max(width, 0.001), r);
            return float4(s.rgb * max(0.0, 1.0 + amount * w), s.a);
        }
        """,
        "localContrast": """
        // Adds the luminance difference between `s` and its blur `b` back `amount` times, weighted
        // toward the midtones by `bias` (1 = midtones only, 0 = evenly) so edges don't halo in
        // the highlights and shadows. Negative amounts soften.
        [[stitchable]] float4 localContrast(sample_t s, sample_t b, float amount, float bias) {
            float3 luma = float3(0.299, 0.587, 0.114);
            float l = clamp(dot(s.rgb, luma), 0.0, 1.0);
            float w = mix(1.0, 4.0 * l * (1.0 - l), bias);
            return float4(s.rgb + (l - dot(b.rgb, luma)) * amount * w, s.a);
        }
        """,
        "dehaze": """
        // Haze on display-encoded color, from `d`, the blurred dark channel (how thick the veil
        // is): positive amounts invert the veil toward `air`, negative ones add it.
        [[stitchable]] float4 dehaze(sample_t s, sample_t d, float amount, float air) {
            float3 c = s.rgb;
            if (amount >= 0.0) {
                float t = max(1.0 - 0.95 * amount * d.r / air, 0.25);
                c = (c - air) / t + air;
            } else {
                c = mix(c, float3(air), -amount * 0.6 * (0.4 + 0.6 * d.r));
            }
            return float4(c, s.a);
        }
        """,
        "colorMixer": """
        \(hsl)
        // HSL mixer on display-encoded color. b0…b7 hold each band's (hue, saturation, luminance)
        // shift, -1…1; band centers match ColorMixer.Band.hue. Neighboring bands cross-fade, so
        // the weights always sum to one, and everything scales with how colorful the pixel is.
        [[stitchable]] float4 colorMixer(sample_t s, float4 b0, float4 b1, float4 b2, float4 b3,
                                         float4 b4, float4 b5, float4 b6, float4 b7) {
            float4 bands[8] = { b0, b1, b2, b3, b4, b5, b6, b7 };
            const float centers[8] = { 0.0, 30.0, 60.0, 120.0, 180.0, 240.0, 270.0, 300.0 };
            float3 c = clamp(s.rgb, 0.0, 1.0);
            float3 hsl = toHSL(c);
            float weights[8] = { 0, 0, 0, 0, 0, 0, 0, 0 };
            for (int i = 0; i < 8; i++) {
                float a = centers[i], b = i == 7 ? centers[0] + 360.0 : centers[i + 1];
                float h = hsl.x < a ? hsl.x + 360.0 : hsl.x;
                if (h >= a && h < b) {
                    float t = smoothstep(0.0, 1.0, (h - a) / (b - a));
                    weights[i] += 1.0 - t;
                    weights[(i + 1) % 8] += t;
                }
            }
            float3 shift = float3(0.0);
            for (int i = 0; i < 8; i++) { shift += weights[i] * bands[i].xyz; }
            // weight by chroma, not HSL saturation: near white and near black a sliver of color
            // has high saturation, and a white shirt's bluish shadows would count as blue
            float colorful = smoothstep(0.02, 0.2, max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b)));
            hsl.x += shift.x * 30.0 * colorful;
            hsl.y = clamp(hsl.y * (1.0 + shift.y * colorful), 0.0, 1.0);
            hsl.z = clamp(hsl.z * exp2(shift.z * colorful), 0.0, 1.0);
            // only the change is added: colors outside 0…1 (highlights a mask may still bring
            // back, wide-gamut color) pass through where the mixer doesn't reach
            return float4(s.rgb + fromHSL(hsl) - fromHSL(toHSL(c)), s.a);
        }
        """,
        "colorGrading": """
        \(hsl)
        // Color grading on display-encoded color. Each grade is (hue°, saturation 0…1, luminance
        // -1…1) for shadows, midtones, highlights and the whole photo; shape is (blending 0…1,
        // balance -1…1, positive favoring the highlights). Region weights split luma around a
        // balance-shifted middle and always sum to one; tints are pure chroma, so they color
        // without brightening.
        [[stitchable]] float4 colorGrading(sample_t s, float4 shadows, float4 midtones, float4 highlights,
                                           float4 global, float2 shape) {
            float3 luma = float3(0.299, 0.587, 0.114);
            float3 c = s.rgb;
            float l = clamp(dot(c, luma), 0.0, 1.0);
            float middle = 0.5 - shape.y * 0.3;
            float width = 0.12 + shape.x * 0.36;
            float ws = 1.0 - smoothstep(middle - width, middle, l);
            float wh = smoothstep(middle, middle + width, l);
            float4 grades[4] = { shadows, midtones, highlights, global };
            float weights[4] = { ws, max(0.0, 1.0 - ws - wh), wh, 1.0 };
            for (int i = 0; i < 4; i++) {
                float4 g = grades[i];
                float3 tint = fromHSL(float3(g.x, 1.0, 0.5));
                tint -= dot(tint, luma);
                c += weights[i] * (tint * g.y * 0.3 + g.z * 0.2);
            }
            return float4(c, s.a);
        }
        """,
        "linearMask": """
        // Mask weight of a linear gradient: 1 at `start`, 0 at `end`, a smooth fall-off between
        // (flipped by `invert` = 1). Weight in every channel, opaque.
        [[stitchable]] float4 linearMask(float2 start, float2 end, float invert, destination dest) {
            float2 d = end - start;
            float t = clamp(dot(dest.coord() - start, d) / max(dot(d, d), 1e-6), 0.0, 1.0);
            float w = mix(1.0 - smoothstep(0.0, 1.0, t), smoothstep(0.0, 1.0, t), invert);
            return float4(w, w, w, 1.0);
        }
        """,
        "ellipseMask": """
        // Mask weight of an ellipse around `center`: `u` and `v` are its axes divided by their
        // radii, so the edge sits at distance 1. The weight falls from 1 to 0 over the outer
        // `feather` of the radius (flipped by `invert` = 1).
        [[stitchable]] float4 ellipseMask(float2 center, float2 u, float2 v, float feather, float invert,
                                          destination dest) {
            float2 p = dest.coord() - center;
            float d = length(float2(dot(p, u), dot(p, v)));
            float w = 1.0 - smoothstep(1.0 - max(feather, 0.01), 1.0, d);
            w = mix(w, 1.0 - w, invert);
            return float4(w, w, w, 1.0);
        }
        """,
        "heal": """
        // Healing: the source patch `s` moved onto the target, offset by the difference between
        // the target's surroundings `lt` and the source's `ls`. Both were blurred with the spot
        // itself left out, so each is premultiplied by how much of the ring it saw.
        [[stitchable]] float4 heal(sample_t s, sample_t ls, sample_t lt) {
            float3 target = lt.rgb / max(lt.a, 1e-4);
            float3 source = ls.rgb / max(ls.a, 1e-4);
            return float4(max(s.rgb + target - source, 0.0), s.a);
        }
        """,
        "highPass": """
        // Fine detail as white on black: how far each pixel's gray `s` is from its blur `b`.
        [[stitchable]] float4 highPass(sample_t s, sample_t b, float gain) {
            float v = clamp(abs(s.r - b.r) * gain, 0.0, 1.0);
            return float4(v, v, v, 1.0);
        }
        """,
        "filmGrain": """
        // Adds grain `n` (0.5 = none) to display-encoded color, strongest in the midtones as on film.
        [[stitchable]] float4 filmGrain(sample_t s, sample_t n, float amount) {
            float l = clamp(dot(s.rgb, float3(0.299, 0.587, 0.114)), 0.0, 1.0);
            float weight = 4.0 * l * (1.0 - l) + 0.1;
            return float4(s.rgb + (n.r - 0.5) * amount * weight, s.a);
        }
        """,
    ]

    private static let lock = NSLock()
    /// Each kernel once compiled, or nil once it failed to: a failure isn't retried every render.
    nonisolated(unsafe) private static var compiled: [String: CIKernel?] = [:]

    /// The named kernel, compiled on first use (a fraction of a second, once per kernel).
    private static func kernel(_ name: String) -> CIKernel? {
        lock.withLock {
            if let kernel = compiled[name] { return kernel }
            guard let body = bodies[name] else { return nil }
            let source = "#include <CoreImage/CoreImage.h>\nextern \"C\" { namespace coreimage {\n\(body)\n}}\n"
            let kernel = (try? CIKernel.kernels(withMetalString: source))?.first { $0.name == name }
            compiled[name] = .some(kernel)
            return kernel
        }
    }

    /// `image` warped by distortion `k` (see the kernel), zoomed in just enough that pulling
    /// the edges outward (k < 0) leaves no empty corners.
    static func distort(_ image: CIImage, k: Double) -> CIImage {
        guard k != 0, let warp = kernel("lensDistortion") as? CIWarpKernel else { return image }
        let extent = image.extent
        let halfDiagonal2 = Double(extent.width * extent.width + extent.height * extent.height) / 4
        let zoom = k < 0 ? 1 - k : 1
        let margin = max(extent.width, extent.height) * CGFloat(abs(k))
        let center = CIVector(x: extent.midX, y: extent.midY)
        return warp.apply(extent: extent, roiCallback: { _, rect in rect.insetBy(dx: -margin, dy: -margin) },
                          image: image.clampedToExtent(),
                          arguments: [center, k, 1 / max(halfDiagonal2, 1), zoom])?.cropped(to: extent) ?? image
    }

    /// Film grain on display-encoded `image`: amount, size and roughness 0…100; `scale` is the
    /// render's size relative to the full photo, so grain keeps its size in the full-resolution photo.
    /// Core Image's random field is fixed, so the same photo always gets the same grain.
    static func grain(_ image: CIImage, amount: Double, size: Double, roughness: Double, scale: Double) -> CIImage {
        guard amount > 0, let kernel = kernel("filmGrain") as? CIColorKernel,
              let random = CIFilter(name: "CIRandomGenerator")?.outputImage else { return image }
        let extent = image.extent
        // grain smaller than a pixel of a reduced render averages out, as it does when the
        // full-size photo is viewed at that size: fainter, not coarser
        let grainPixel = (1 + size / 100 * 3) * scale
        let pixel = max(1, grainPixel)
        // The random field's alpha is random too, and filters that unpremultiply (the color
        // matrix) would skew it bright; make it opaque over the area the grain samples first.
        let region = extent.insetBy(dx: -64, dy: -64)
        let field = random.cropped(to: region).settingAlphaOne(in: region)
        let coarse = field.transformed(by: CGAffineTransform(scaleX: pixel, y: pixel))
            .applyingGaussianBlur(sigma: pixel * 0.35)
            // blurring flattens the noise; stretch it back toward full contrast
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 2.2, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: -0.6, y: 0, z: 0, w: 0),
            ])
        // roughness mixes in finer noise, from the field's independent green channel
        let fine = field.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 0, y: 1, z: 0, w: 0)])
            .transformed(by: CGAffineTransform(scaleX: max(1, pixel / 2), y: max(1, pixel / 2)))
        let noise = coarse.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: fine, "inputTime": roughness / 100 * 0.6,
        ]).cropped(to: extent)
        return kernel.apply(extent: extent, arguments: [image, noise, amount / 100 * 0.25 * min(1, grainPixel)]) ?? image
    }

    /// Local contrast of display-encoded `image` at `sigma` pixels (see the kernel).
    static func localContrast(_ image: CIImage, sigma: Double, amount: Double, bias: Double) -> CIImage {
        guard amount != 0, let kernel = kernel("localContrast") as? CIColorKernel else { return image }
        let extent = image.extent
        let blurred = image.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
        return kernel.apply(extent: extent, arguments: [image, blurred, amount, bias]) ?? image
    }

    /// Haze removal (amount > 0) or added haze (< 0) on display-encoded `image`, -1…1, using the
    /// dark-channel prior: haze lifts the darkest channel of every patch, so its blurred minimum
    /// maps the veil.
    static func dehaze(_ image: CIImage, amount: Double) -> CIImage {
        guard amount != 0, let kernel = kernel("dehaze") as? CIColorKernel else { return image }
        let extent = image.extent
        let longEdge = Double(max(extent.width, extent.height))
        let veil = image.applyingFilter("CIMinimumComponent")
            .clampedToExtent()
            .applyingFilter("CIMorphologyMinimum", parameters: ["inputRadius": max(1, longEdge * 0.004)])
            .applyingGaussianBlur(sigma: longEdge * 0.01)
            .cropped(to: extent)
        return kernel.apply(extent: extent, arguments: [image, veil, amount, 0.92]) ?? image
    }

    /// The HSL mixer on display-encoded `image` (see the kernel).
    static func colorMixer(_ image: CIImage, _ mixer: ColorMixer) -> CIImage {
        guard !mixer.isNeutral, let kernel = kernel("colorMixer") as? CIColorKernel else { return image }
        let bands = (0..<8).map { i in
            CIVector(x: mixer.hue[i] / 100, y: mixer.saturation[i] / 100, z: mixer.luminance[i] / 100, w: 0)
        }
        return kernel.apply(extent: image.extent, arguments: [image] + bands) ?? image
    }

    /// Color grading on display-encoded `image` (see the kernel).
    static func colorGrading(_ image: CIImage, _ grading: ColorGrading) -> CIImage {
        guard !grading.isNeutral, let kernel = kernel("colorGrading") as? CIColorKernel else { return image }
        let grades = [grading.shadows, grading.midtones, grading.highlights, grading.global].map {
            CIVector(x: $0.hue, y: $0.saturation / 100, z: $0.luminance / 100, w: 0)
        }
        let shape = CIVector(x: grading.blending / 100, y: grading.balance / 100)
        return kernel.apply(extent: image.extent, arguments: [image] + grades + [shape]) ?? image
    }

    /// The weight of `mask` over `extent`, the source photo at the render's size: 1 where the
    /// mask applies fully, 0 where it doesn't.
    static func maskWeight(_ mask: LocalAdjustment, extent: CGRect) -> CIImage? {
        // mask positions are top-left fractions of the source photo; kernels see Core Image's
        // bottom-left pixel coordinates
        func pixel(_ p: CGPoint) -> CIVector {
            CIVector(x: extent.minX + p.x * extent.width, y: extent.maxY - p.y * extent.height)
        }
        let invert: Double = mask.inverted ? 1 : 0
        switch mask.kind {
        case .linear:
            guard let kernel = kernel("linearMask") as? CIColorKernel else { return nil }
            return kernel.apply(extent: extent, arguments: [pixel(mask.start), pixel(mask.end), invert])
        case .radial:
            guard let kernel = kernel("ellipseMask") as? CIColorKernel else { return nil }
            let longEdge = Double(max(extent.width, extent.height))
            let rx = max(mask.radiusX * longEdge, 0.5), ry = max(mask.radiusY * longEdge, 0.5)
            // the angle turns clockwise on screen, where y points down; Core Image's y points up
            let a = mask.angle * .pi / 180
            let u = CIVector(x: cos(a) / rx, y: -sin(a) / rx)
            let v = CIVector(x: -sin(a) / ry, y: -cos(a) / ry)
            return kernel.apply(extent: extent, arguments: [pixel(mask.center), u, v, mask.feather / 100, invert])
        case .brush:
            return BrushRaster.weight(mask, extent: extent)
        case .subject, .sky:
            return nil   // found in the photo: see SemanticMasks
        }
    }

    /// A soft disc: weight 1 inside `radius` pixels of `center`, falling to 0 over the outer
    /// `feather` (0…1) of the radius; `invert` flips it.
    static func disc(center: CGPoint, radius: CGFloat, feather: Double, invert: Bool = false,
                     extent: CGRect) -> CIImage? {
        guard let kernel = kernel("ellipseMask") as? CIColorKernel else { return nil }
        let r = max(Double(radius), 0.5)
        return kernel.apply(extent: extent, arguments: [
            CIVector(x: center.x, y: center.y), CIVector(x: 1 / r, y: 0), CIVector(x: 0, y: 1 / r),
            feather, invert ? 1.0 : 0.0,
        ])
    }

    /// The healed patch (see the kernel), over `extent`.
    static func heal(_ shifted: CIImage, sourceRing: CIImage, targetRing: CIImage, extent: CGRect) -> CIImage? {
        (kernel("heal") as? CIColorKernel)?.apply(extent: extent, arguments: [shifted, sourceRing, targetRing])
    }

    /// Fine detail of display-encoded gray `image` against its `blurred` copy, white on black.
    static func highPass(_ image: CIImage, blurred: CIImage, gain: Double) -> CIImage {
        (kernel("highPass") as? CIColorKernel)?.apply(extent: image.extent, arguments: [image, blurred, gain]) ?? image
    }

    /// `image` with its brightness scaled toward the corners (see the kernel).
    static func radialGain(_ image: CIImage, amount: Double, start: Double, width: Double) -> CIImage {
        guard amount != 0, let kernel = kernel("radialGain") as? CIColorKernel else { return image }
        let extent = image.extent
        let halfDiagonal2 = Double(extent.width * extent.width + extent.height * extent.height) / 4
        return kernel.apply(extent: extent, arguments: [
            image, CIVector(x: extent.midX, y: extent.midY), 1 / max(halfDiagonal2, 1), amount, start, width,
        ]) ?? image
    }
}
