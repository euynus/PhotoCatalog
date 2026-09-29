// ============================================================
//  DevelopKernels — Core Image kernels Core Image has no filter for
// ============================================================
import CoreImage

/// Lens distortion, radial gain and film grain, compiled from Metal source the first time a render needs
/// them (~0.5 s, once): the package has no Metal build step, and Core Image compiles stitchable
/// kernels at run time. A kernel that fails to compile leaves its adjustment out of the render.
enum DevelopKernels {
    private static let source = """
    #include <CoreImage/CoreImage.h>
    extern "C" { namespace coreimage {
        // Radial distortion about `center`, in units where the corner is at radius 1:
        // k > 0 samples closer to the center toward the edges, which straightens barrel distortion.
        [[stitchable]] float2 lensDistortion(float2 center, float k, float invRadius2, float zoom,
                                             destination dest) {
            float2 p = (dest.coord() - center) / zoom;
            float r2 = dot(p, p) * invRadius2;
            return center + p * (1.0 - k * r2);
        }

        // Multiplies color by 1 + amount·w, where w rises smoothly from 0 at radius `start`
        // to 1 at `start + width` (radius 1 is the corner).
        [[stitchable]] float4 radialGain(sample_t s, float2 center, float invRadius2, float amount,
                                         float start, float width, destination dest) {
            float2 p = dest.coord() - center;
            float r = sqrt(dot(p, p) * invRadius2);
            float w = smoothstep(start, start + max(width, 0.001), r);
            return float4(s.rgb * max(0.0, 1.0 + amount * w), s.a);
        }

        // Adds grain `n` (0.5 = none) to display-encoded color, strongest in the midtones as on film.
        [[stitchable]] float4 filmGrain(sample_t s, sample_t n, float amount) {
            float l = clamp(dot(s.rgb, float3(0.299, 0.587, 0.114)), 0.0, 1.0);
            float weight = 4.0 * l * (1.0 - l) + 0.1;
            return float4(s.rgb + (n.r - 0.5) * amount * weight, s.a);
        }
    }}
    """

    private static let kernels: [String: CIKernel] = {
        guard let compiled = try? CIKernel.kernels(withMetalString: source) else { return [:] }
        return Dictionary(compiled.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }()

    /// `image` warped by distortion `k` (see the kernel), zoomed in just enough that pulling
    /// the edges outward (k < 0) leaves no empty corners.
    static func distort(_ image: CIImage, k: Double) -> CIImage {
        guard k != 0, let warp = kernels["lensDistortion"] as? CIWarpKernel else { return image }
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
        guard amount > 0, let kernel = kernels["filmGrain"] as? CIColorKernel,
              let random = CIFilter(name: "CIRandomGenerator")?.outputImage else { return image }
        let extent = image.extent
        let pixel = max(1, (1 + size / 100 * 3) * scale)
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
        return kernel.apply(extent: extent, arguments: [image, noise, amount / 100 * 0.25]) ?? image
    }

    /// `image` with its brightness scaled toward the corners (see the kernel).
    static func radialGain(_ image: CIImage, amount: Double, start: Double, width: Double) -> CIImage {
        guard amount != 0, let kernel = kernels["radialGain"] as? CIColorKernel else { return image }
        let extent = image.extent
        let halfDiagonal2 = Double(extent.width * extent.width + extent.height * extent.height) / 4
        return kernel.apply(extent: extent, arguments: [
            image, CIVector(x: extent.midX, y: extent.midY), 1 / max(halfDiagonal2, 1), amount, start, width,
        ]) ?? image
    }
}
