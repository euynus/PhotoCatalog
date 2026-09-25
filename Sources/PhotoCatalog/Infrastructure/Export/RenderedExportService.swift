// ============================================================
//  Rendered export — develop settings baked into new files
// ============================================================
import Foundation
import CoreImage
import CoreText
import ImageIO

/// One photo to export, captured on the main actor.
struct RenderedExportItem: Sendable {
    let assetId: String
    let sourcePath: String
    let isRaw: Bool
    let develop: DevelopSettings
    /// Pixel size as recorded (orientation doesn't matter: only the edges' ratio is used).
    let originalSize: CGSize
    let baseName: String
    let date: Date
    let camera: String
    let title: String
    let caption: String
    let keywords: [String]
    let rating: Int
    let author: String
    let copyright: String
}

/// A flag the export queue checks between photos.
final class ExportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
    func reset() { lock.withLock { cancelled = false } }
}

enum RenderedExportService {
    enum Outcome: Sendable {
        case written(URL)
        case skipped
        case failed(String)
    }

    /// Renders one photo at its export size, in the export color space, watermark included.
    static func render(_ item: RenderedExportItem, settings: ExportSettings) -> CGImage? {
        let develop = item.develop
        var cropShare = 1.0
        if develop.hasGeometry {
            let frame = DevelopGeometry.rotatedSize(item.originalSize, develop.rotation)
            let crop = DevelopGeometry.effectiveCrop(develop, frame: frame)
            cropShare = min(crop.width, crop.height)
        }
        let decodeEdge = settings.decodeLongEdge(original: item.originalSize, cropShare: cropShare)
        guard let source = DevelopRenderer.Source(url: URL(fileURLWithPath: item.sourcePath), isRaw: item.isRaw,
                                                  maxPixel: decodeEdge, interactive: false),
              var image = source.image(develop) else { return nil }
        let extent = image.extent.integral
        let target = settings.outputSize(for: extent.size)
        if target != extent.size {
            let scale = target.height / extent.height
            image = image.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scale,
                kCIInputAspectRatioKey: (target.width / extent.width) / scale,
            ])
            image = image.cropped(to: CGRect(origin: image.extent.origin, size: target))
        }
        guard let rendered = bitmap(image, bounds: CGRect(origin: image.extent.origin, size: target),
                                    sixteenBit: settings.format == .tiff && settings.sixteenBit,
                                    colorSpace: settings.colorSpace.cgColorSpace) else { return nil }
        let text = settings.watermark.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.watermarkEnabled, !text.isEmpty else { return rendered }
        return watermarked(rendered, text: text) ?? rendered
    }

    /// One GPU render straight into memory. (A CGImage from `createCGImage` renders lazily, and
    /// the encoder then pulls it through in pieces — several times slower for a full-size photo.)
    /// Pixels are opaque, so the file gets no alpha channel.
    static func bitmap(_ image: CIImage, bounds: CGRect, sixteenBit: Bool, colorSpace: CGColorSpace) -> CGImage? {
        let width = Int(bounds.width), height = Int(bounds.height)
        let bytesPerPixel = sixteenBit ? 8 : 4
        let rowBytes = width * bytesPerPixel
        guard width > 0, height > 0, let buffer = CFDataCreateMutable(nil, rowBytes * height) else { return nil }
        CFDataSetLength(buffer, rowBytes * height)
        DevelopRenderer.context.render(image, toBitmap: CFDataGetMutableBytePtr(buffer), rowBytes: rowBytes,
                                       bounds: bounds, format: sixteenBit ? .RGBA16 : .RGBA8, colorSpace: colorSpace)
        guard let provider = CGDataProvider(data: buffer) else { return nil }
        var info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        if sixteenBit { info.insert(.byteOrder16Little) }
        return CGImage(width: width, height: height, bitsPerComponent: sixteenBit ? 16 : 8,
                       bitsPerPixel: bytesPerPixel * 8, bytesPerRow: rowBytes, space: colorSpace, bitmapInfo: info,
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Renders and writes one photo into `folder`. `reserved` holds lowercased names already
    /// taken by this export, so two photos never land on one file.
    static func export(_ item: RenderedExportItem, sequence: Int, settings: ExportSettings, to folder: URL,
                       reserved: inout Set<String>) -> Outcome {
        let name = settings.fileName(original: item.baseName, sequence: sequence, date: item.date,
                                     camera: item.camera, title: item.title, rating: item.rating)
        guard let destination = destinationURL(in: folder, name: name, ext: settings.format.fileExtension,
                                               collision: settings.collision, reserved: &reserved) else {
            return .skipped
        }
        let rendered = autoreleasepool { render(item, settings: settings) }
        guard let rendered else { return .failed("\(item.baseName)：无法渲染原件") }
        let partial = folder.appendingPathComponent(".\(UUID().uuidString).partial")
        guard let output = CGImageDestinationCreateWithURL(partial as CFURL, settings.format.typeIdentifier as CFString,
                                                           1, nil) else {
            return .failed("\(item.baseName)：无法创建 \(settings.format.title) 文件")
        }
        let sourceProperties = CGImageSourceCreateWithURL(URL(fileURLWithPath: item.sourcePath) as CFURL, nil)
            .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] } ?? [:]
        let properties = metadata(for: item, settings: settings, source: sourceProperties,
                                  size: CGSize(width: rendered.width, height: rendered.height))
        CGImageDestinationAddImage(output, rendered, properties as CFDictionary)
        guard CGImageDestinationFinalize(output) else {
            try? FileManager.default.removeItem(at: partial)
            return .failed("\(item.baseName)：写入失败")
        }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial)
            } else {
                try FileManager.default.moveItem(at: partial, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: partial)
            return .failed("\(item.baseName)：\(error.localizedDescription)")
        }
        return .written(destination)
    }

    static func destinationURL(in folder: URL, name: String, ext: String, collision: ExportSettings.Collision,
                               reserved: inout Set<String>) -> URL? {
        func url(_ suffix: String) -> URL { folder.appendingPathComponent("\(name)\(suffix).\(ext)") }
        func taken(_ candidate: URL) -> Bool {
            reserved.contains(candidate.lastPathComponent.lowercased())
                || (collision != .overwrite && FileManager.default.fileExists(atPath: candidate.path))
        }
        var candidate = url("")
        if collision == .skip, FileManager.default.fileExists(atPath: candidate.path) { return nil }
        var counter = 1
        while taken(candidate) {   // photos of one export never overwrite each other
            candidate = url("-\(counter)")
            counter += 1
        }
        reserved.insert(candidate.lastPathComponent.lowercased())
        return candidate
    }

    /// Properties for the new file: pixels are already upright, so orientation is reset; the
    /// catalog's title, caption, keywords, rating and copyright ride along per `settings`.
    static func metadata(for item: RenderedExportItem, settings: ExportSettings, source: [CFString: Any],
                         size: CGSize) -> [CFString: Any] {
        var properties: [CFString: Any] = [kCGImagePropertyOrientation: 1]
        if settings.format.isLossy { properties[kCGImageDestinationLossyCompressionQuality] = settings.quality }
        guard settings.metadata != .none else { return properties }

        var tiff: [CFString: Any] = [:]
        var iptc: [CFString: Any] = [:]
        if !item.author.isEmpty {
            tiff[kCGImagePropertyTIFFArtist] = item.author
            iptc[kCGImagePropertyIPTCByline] = [item.author]
        }
        if !item.copyright.isEmpty {
            tiff[kCGImagePropertyTIFFCopyright] = item.copyright
            iptc[kCGImagePropertyIPTCCopyrightNotice] = item.copyright
        }
        if settings.metadata == .all {
            if var exif = source[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                exif[kCGImagePropertyExifPixelXDimension] = Int(size.width)
                exif[kCGImagePropertyExifPixelYDimension] = Int(size.height)
                properties[kCGImagePropertyExifDictionary] = exif
            }
            if let aux = source[kCGImagePropertyExifAuxDictionary] { properties[kCGImagePropertyExifAuxDictionary] = aux }
            if !settings.removeLocation, let gps = source[kCGImagePropertyGPSDictionary] {
                properties[kCGImagePropertyGPSDictionary] = gps
            }
            let sourceTIFF = source[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            tiff = sourceTIFF.merging(tiff) { _, catalog in catalog }
            let sourceIPTC = source[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
            iptc = sourceIPTC.merging(iptc) { _, catalog in catalog }
            if settings.removeLocation {
                for key in [kCGImagePropertyIPTCCity, kCGImagePropertyIPTCSubLocation, kCGImagePropertyIPTCProvinceState,
                            kCGImagePropertyIPTCCountryPrimaryLocationName, kCGImagePropertyIPTCCountryPrimaryLocationCode] {
                    iptc[key] = nil
                }
            }
            if !item.title.isEmpty { iptc[kCGImagePropertyIPTCObjectName] = item.title }
            if !item.caption.isEmpty {
                iptc[kCGImagePropertyIPTCCaptionAbstract] = item.caption
                tiff[kCGImagePropertyTIFFImageDescription] = item.caption
            }
            if !item.keywords.isEmpty { iptc[kCGImagePropertyIPTCKeywords] = item.keywords }
            if item.rating > 0 { iptc[kCGImagePropertyIPTCStarRating] = item.rating }
        }
        tiff[kCGImagePropertyTIFFOrientation] = 1
        properties[kCGImagePropertyTIFFDictionary] = tiff
        if !iptc.isEmpty { properties[kCGImagePropertyIPTCDictionary] = iptc }
        return properties
    }

    /// Text in the bottom-right corner, sized to the photo, with a soft shadow for legibility.
    static func watermarked(_ image: CGImage, text: String) -> CGImage? {
        let width = image.width, height = image.height
        var info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        if image.bitsPerComponent == 16 { info.insert(.byteOrder16Little) }
        guard let space = image.colorSpace,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: image.bitsPerComponent, bytesPerRow: 0, space: space,
                                      bitmapInfo: info.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let fontSize = max(12, CGFloat(min(width, height)) * 0.028)
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 0.8),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let margin = fontSize * 1.2
        context.setShadow(offset: CGSize(width: 0, height: -fontSize * 0.06), blur: fontSize * 0.3,
                          color: CGColor(gray: 0, alpha: 0.45))
        context.textPosition = CGPoint(x: CGFloat(width) - margin - bounds.maxX, y: margin - bounds.minY)
        CTLineDraw(line, context)
        return context.makeImage()
    }
}
