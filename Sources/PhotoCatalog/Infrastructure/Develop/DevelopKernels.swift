// ============================================================
//  DevelopKernels — Core Image kernels Core Image has no filter for
// ============================================================
import CoreImage

/// Lens distortion and radial gain, compiled from Metal source the first time a render needs
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
