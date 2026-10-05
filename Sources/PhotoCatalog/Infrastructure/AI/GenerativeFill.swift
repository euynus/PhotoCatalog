// ============================================================
//  Generative fill — smart remove's replacement for what was painted over
// ============================================================
import CoreGraphics
import CoreImage
import CoreML
import CryptoKit
import Darwin
import Foundation
import ImageIO

/// What a remove spot puts in place of the area painted over: LaMa's fill of a square around it,
/// made once from the photo at full size — as it stands before this spot, lens corrections and
/// earlier spots included — and kept in memory and on disk. Renders place it with heal's color
/// matching, so exposure and white balance changed later carry into the fill.
enum GenerativeFill {
    /// The model's square.
    static let side = 512

    struct Fill: @unchecked Sendable {
        /// The filled square, display-encoded Display P3.
        let image: CGImage
        /// Where it goes, as fractions of the source photo (top-left origin).
        let region: CGRect
    }

    private final class Box { let fill: Fill; init(_ fill: Fill) { self.fill = fill } }
    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 48
        return cache
    }()
    private static let lock = NSLock()

    static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoCatalog/Fills", isDirectory: true)
    }

    /// Everything the fill depends on: the file, this spot, the spots before it and the lens
    /// corrections (they move pixels). Not tone or white balance: the fill follows those.
    static func key(index: Int, settings: DevelopSettings, url: URL) -> String {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let text = "\(url.path)|\(modified?.timeIntervalSince1970 ?? 0)|" + pixelDependencies(index: index, settings: settings)
        return SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// What of the settings a fill depends on: the lens corrections, this spot and those before
    /// it. Shared with a full backup's fill names, which must change whenever the fill does.
    static func pixelDependencies(index: Int, settings: DevelopSettings) -> String {
        let lens = String(format: "%.2f,%.2f,%.2f,%d", settings.distortion, settings.lensVignette,
                          settings.lensVignetteMidpoint, settings.removeChromaticAberration ? 1 : 0)
        return lens + "|" + settings.spots.prefix(index + 1).map(\.fingerprintText).joined(separator: ";")
    }

    /// The fill for `settings.spots[index]`: remembered, or — when `make` — made now (a
    /// full-size render and the model: a second or two). Nil when the photo can't be read.
    static func fill(for index: Int, settings: DevelopSettings, url: URL, isRaw: Bool, make: Bool = true) -> Fill? {
        guard settings.spots.indices.contains(index), settings.spots[index].mode == .remove else { return nil }
        let key = key(index: index, settings: settings, url: url)
        let sourceIdentity = fileIdentity(url) ?? url.standardizedFileURL.path
        if let packaged = FullBackupService.packagedFillURL(for: index, settings: settings, originalURL: url) {
            return cachedFill(at: packaged, sourceIdentity: sourceIdentity)
        }
        let memoryKey = "computed|\(sourceIdentity)|\(key)" as NSString
        func storedFill() -> Fill? {
            if let cached = cache.object(forKey: memoryKey) { return cached.fill }
            return cachedFill(at: self.url(key), sourceIdentity: sourceIdentity)
        }
        if let stored = storedFill() { return stored }
        guard make else { return nil }
        return lock.withLock {
            if let stored = storedFill() { return stored }
            guard let made = compute(index: index, settings: settings, url: url, isRaw: isRaw) else { return nil }
            // A read-only/full cache disk must not turn each render into another model run.
            if write(made, key: key), let identity = fileIdentity(self.url(key)) {
                cache.setObject(Box(made), forKey: "\(sourceIdentity)|\(identity)" as NSString)
            } else {
                cache.setObject(Box(made), forKey: memoryKey)
            }
            return made
        }
    }

    /// Removes this photo's generated resource too, so a restored library can regenerate it.
    /// The backup and resources in other restored libraries are never modified.
    @discardableResult
    static func forget(index: Int, settings: DevelopSettings, url: URL) -> Bool {
        let key = key(index: index, settings: settings, url: url)
        let sourceIdentity = fileIdentity(url) ?? url.standardizedFileURL.path
        cache.removeObject(forKey: "computed|\(sourceIdentity)|\(key)" as NSString)
        let files = [FullBackupService.packagedFillURL(for: index, settings: settings, originalURL: url), self.url(key)]
            .compactMap { $0 }
        var removed = true
        for file in files {
            guard let identity = fileIdentity(file) else { continue }
            cache.removeObject(forKey: "\(sourceIdentity)|\(identity)" as NSString)
            do { try FileManager.default.removeItem(at: file) } catch { removed = false }
        }
        return removed
    }

    private static func cachedFill(at url: URL, sourceIdentity: String) -> Fill? {
        guard let identity = fileIdentity(url) else { return nil }
        let key = "\(sourceIdentity)|\(identity)" as NSString
        if let cached = cache.object(forKey: key) { return cached.fill }
        guard let fill = read(url), fileIdentity(url) == identity else { return nil }
        cache.setObject(Box(fill), forKey: key)
        return fill
    }

    private static func fileIdentity(_ url: URL) -> String? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return "\(url.standardizedFileURL.path)|\(info.st_dev):\(info.st_ino):\(info.st_size)|\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)|\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
    }

    // ---- making it ----
    private static func compute(index: Int, settings: DevelopSettings, url: URL, isRaw: Bool) -> Fill? {
        guard let model = AIModels.model(.inpaint),
              let source = DevelopRenderer.Source(url: url, isRaw: isRaw, maxPixel: nil),
              let stage = source.spotStage(settings, before: index) else { return nil }
        let spot = settings.spots[index]
        let extent = stage.extent
        let width = Double(extent.width), height = Double(extent.height), longEdge = max(width, height)
        // the painted dabs in pixels, top-left origin
        let dabs: [(center: CGPoint, radius: Double)] = spot.strokes.flatMap { stroke in
            (0..<stroke.pointCount).map { i in
                let p = stroke.point(i)
                return (CGPoint(x: Double(p.x) * width, y: Double(p.y) * height), stroke.radius * longEdge)
            }
        }
        guard !dabs.isEmpty else { return nil }
        let minX = dabs.map { Double($0.center.x) - $0.radius }.min()!, maxX = dabs.map { Double($0.center.x) + $0.radius }.max()!
        let minY = dabs.map { Double($0.center.y) - $0.radius }.min()!, maxY = dabs.map { Double($0.center.y) + $0.radius }.max()!
        // a square around it with room for context: at least the model's size, the photo's pixels
        // at their own scale when the area is small
        let span = max(maxX - minX, maxY - minY)
        let size = min(min(width, height), max(Double(side), span * 2.2)).rounded()
        let x0 = min(max(0, (minX + maxX) / 2 - size / 2), width - size).rounded()
        let y0 = min(max(0, (minY + maxY) / 2 - size / 2), height - size).rounded()
        let scale = Double(side) / size
        // the square, at the model's size
        let crop = CGRect(x: extent.minX + x0, y: extent.maxY - y0 - size, width: size, height: size)
        let square = stage.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": scale, "inputAspectRatio": 1.0])
            .cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
        guard let planes = Enhance.planes(of: square), planes.width == side, planes.height == side,
              let image = try? MLMultiArray(shape: [1, 3, NSNumber(value: side), NSNumber(value: side)], dataType: .float16),
              let mask = try? MLMultiArray(shape: [1, 1, NSNumber(value: side), NSNumber(value: side)], dataType: .float16)
        else { return nil }
        let pixels = image.dataPointer.assumingMemoryBound(to: Float16.self)
        for i in 0..<(3 * side * side) { pixels[i] = planes.values[i] }
        // the hole: the dabs, a little wider so no edge of what's removed is left to copy
        let hole = holeRaster(dabs.map { (CGPoint(x: (Double($0.center.x) - x0) * scale, y: (Double($0.center.y) - y0) * scale),
                                          $0.radius * scale) })
        let holes = mask.dataPointer.assumingMemoryBound(to: Float16.self)
        for i in 0..<(side * side) { holes[i] = hole[i] > 127 ? 1 : 0 }
        guard let features = try? MLDictionaryFeatureProvider(dictionary: [
            "image": MLFeatureValue(multiArray: image), "mask": MLFeatureValue(multiArray: mask),
        ]), let prediction = try? model.prediction(from: features),
              let output = prediction.featureValue(for: "output")?.multiArrayValue, output.dataType == .float16
        else { return nil }
        let strides = output.strides.map(\.intValue)
        let values = output.dataPointer.assumingMemoryBound(to: Float16.self)
        var filled = [Float16](repeating: 0, count: 3 * side * side)
        for channel in 0..<3 {
            for y in 0..<side {
                for x in 0..<side {
                    let value = Float(values[channel * strides[1] + y * strides[2] + x * strides[3]])
                    filled[(channel * side + y) * side + x] = Float16(min(1, max(0, value)))
                }
            }
        }
        guard let result = Enhance.image(Enhance.Planes(width: side, height: side, values: filled)) else { return nil }
        return Fill(image: result, region: CGRect(x: x0 / width, y: y0 / height, width: size / width, height: size / height))
    }

    /// The hole's dabs drawn at the model's size, widened by a sixth of their radius and 3 px.
    private static func holeRaster(_ dabs: [(center: CGPoint, radius: Double)]) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: side * side)
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.translateBy(x: 0, y: CGFloat(side))
            context.scaleBy(x: 1, y: -1)
            context.setFillColor(gray: 1, alpha: 1)
            for dab in dabs {
                let r = CGFloat(dab.radius * 1.17 + 3)
                context.fillEllipse(in: CGRect(x: dab.center.x - r, y: dab.center.y - r, width: 2 * r, height: 2 * r))
            }
            // strokes painted fast leave gaps between dabs: join them
            if dabs.count > 1 {
                context.setStrokeColor(gray: 1, alpha: 1)
                context.setLineCap(.round)
                for (a, b) in zip(dabs, dabs.dropFirst()) {
                    context.setLineWidth(CGFloat(min(a.radius, b.radius) * 2.34 + 6))
                    context.move(to: a.center)
                    context.addLine(to: b.center)
                    context.strokePath()
                }
            }
        }
        return bytes
    }

    // ---- putting it in ----
    /// `fill` placed over `image` where `mask` (the painted area, over `extent`) says, its color
    /// and brightness matched to what surrounds it now, at `opacity` (0…100).
    static func composite(_ fill: Fill, into image: CIImage, mask: CIImage, opacity: Double, extent: CGRect) -> CIImage {
        let region = CGRect(x: extent.minX + fill.region.minX * extent.width,
                            y: extent.maxY - fill.region.maxY * extent.height,
                            width: fill.region.width * extent.width, height: fill.region.height * extent.height)
        var patch = CIImage(cgImage: fill.image)
        patch = patch.transformed(by: CGAffineTransform(scaleX: region.width / CGFloat(fill.image.width),
                                                       y: region.height / CGFloat(fill.image.height)))
            .transformed(by: CGAffineTransform(translationX: region.minX, y: region.minY))
        // outside the square the photo is its own fill
        patch = patch.composited(over: image).cropped(to: extent)
        // a band around the painted area, where fill and photo should agree
        let reach = max(2, Double(region.width) * 0.03)
        let grown = mask.clampedToExtent().applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": reach])
            .cropped(to: extent)
        let ring = grown.applyingFilter("CIMultiplyCompositing", parameters: [
            kCIInputBackgroundImageKey: mask.applyingFilter("CIColorInvert"),
        ]).cropped(to: extent)
        let clear = CIImage(color: .clear).cropped(to: extent)
        func surroundings(_ source: CIImage) -> CIImage {
            source.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: ring,
            ]).applyingGaussianBlur(sigma: reach * 1.5)
        }
        let healed = DevelopKernels.heal(patch, sourceRing: surroundings(patch), targetRing: surroundings(image),
                                         extent: extent) ?? patch
        let strength = grown.applyingGaussianBlur(sigma: reach * 0.5).cropped(to: extent)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: opacity / 100, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: opacity / 100, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: opacity / 100, w: 0),
            ])
        return healed.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: strength,
        ]).cropped(to: extent)
    }

    // ---- on disk ----
    private static func url(_ key: String) -> URL { folder.appendingPathComponent("\(key).png") }

    private static func write(_ fill: Fill, key: String) -> Bool {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url(key) as CFURL, "public.png" as CFString, 1, nil) else { return false }
        let region = [fill.region.minX, fill.region.minY, fill.region.width, fill.region.height]
            .map { String(format: "%.8f", Double($0)) }.joined(separator: ",")
        CGImageDestinationAddImage(destination, fill.image, [
            kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription: region],
        ] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    private static func read(_ url: URL) -> Fill? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == side, image.height == side,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let text = (properties[kCGImagePropertyPNGDictionary] as? [CFString: Any])?[kCGImagePropertyPNGDescription] as? String
        else { return nil }
        let numbers = text.split(separator: ",").compactMap { Double($0) }
        guard numbers.count == 4, numbers.allSatisfy(\.isFinite),
              numbers[0] >= 0, numbers[1] >= 0, numbers[2] > 0, numbers[3] > 0,
              numbers[0] + numbers[2] <= 1.000001, numbers[1] + numbers[3] <= 1.000001 else { return nil }
        return Fill(image: image, region: CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]))
    }
}
