// ============================================================
//  Print renderer — pages for the printer, a PDF and the preview, from one drawing
// ============================================================
import AppKit
import CoreGraphics
import CoreImage
import CoreText
import Foundation

/// A photo to print: its original, how it's developed and what its caption may say.
struct PrintItem: Sendable {
    let sourcePath: String
    let isRaw: Bool
    let develop: DevelopSettings
    /// The original's size as shown (orientation applied).
    let originalSize: CGSize
    let filename: String
    let title: String

    /// Width over height of the developed photo: turned and cropped.
    var aspect: Double {
        let frame = DevelopGeometry.rotatedSize(originalSize, develop.rotation)
        guard develop.hasGeometry else { return frame.height > 0 ? frame.width / frame.height : 1 }
        let crop = DevelopGeometry.effectiveCrop(develop, frame: frame)
        let width = frame.width * crop.width, height = frame.height * crop.height
        return height > 0 ? width / height : 1
    }
}

extension PrintItem {
    /// The photo developed, at most `longEdge` on its long side (never enlarged), in
    /// `colorSpace`: decoded no larger than that needs, allowing for the crop.
    func rendered(longEdge: Int, colorSpace: CGColorSpace) -> CGImage? {
        var cropShare = 1.0
        if develop.hasGeometry {
            let frame = DevelopGeometry.rotatedSize(originalSize, develop.rotation)
            let crop = DevelopGeometry.effectiveCrop(develop, frame: frame)
            cropShare = max(0.05, min(crop.width, crop.height))
        }
        let decode = Double(longEdge) / cropShare
        let maxPixel = decode >= Double(max(originalSize.width, originalSize.height)) ? nil : Int(decode.rounded(.up)) + 2
        guard let source = DevelopRenderer.Source(url: URL(fileURLWithPath: sourcePath), isRaw: isRaw,
                                                  maxPixel: maxPixel, interactive: false),
              var image = source.image(develop) else { return nil }
        let extent = image.extent.integral
        let scale = min(1, Double(longEdge) / Double(max(extent.width, extent.height)))
        if scale < 1 {
            image = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
        }
        let size = CGSize(width: (extent.width * scale).rounded(), height: (extent.height * scale).rounded())
        return RenderedExportService.bitmap(image, bounds: CGRect(origin: image.extent.origin, size: size),
                                            sixteenBit: false, colorSpace: colorSpace)
    }
}

/// Draws print pages: each photo rendered at the pixels its place on the paper needs (never
/// the full original for a small cell), sharpened for the paper and, with a printer profile,
/// converted to it; captions under the photos. The printer, a PDF and the preview all draw
/// through `drawPage`, so what's previewed is what prints. Rendered photos are kept, so the
/// print panel redrawing a page doesn't decode again.
final class PrintRenderer: @unchecked Sendable {
    let items: [PrintItem]
    let settings: PrintSettings
    private let lock = NSLock()
    private var rendered: [String: CGImage] = [:]

    init(items: [PrintItem], settings: PrintSettings) {
        self.items = items
        self.settings = settings
    }

    var pageCount: Int { settings.pageCount(photos: items.count) }
    var pageSize: CGSize { settings.pageSize }

    /// Draws page `index` (from 0) into `context`, whose origin is the page's bottom-left in points.
    func drawPage(_ index: Int, in context: CGContext) {
        let page = pageSize
        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: page))
        let cells = settings.cells(pageSize: page)
        for (cell, itemIndex) in zip(cells, settings.photos(onPage: index, of: items.count)) {
            let item = items[itemIndex]
            let turned = settings.turns(item.aspect, in: cell.photo)
            let aspect = turned ? 1 / item.aspect : item.aspect
            let placement = PrintSettings.placement(of: CGSize(width: aspect, height: 1), in: cell.photo,
                                                    fill: settings.layout == .single && settings.fill)
            // the photo's own pixels: its upright size before any quarter turn
            let pixels = settings.pixelSize(for: turned
                ? CGRect(x: 0, y: 0, width: placement.height, height: placement.width) : placement)
            guard let image = photo(itemIndex, pixels: pixels) else { continue }
            let target = flipped(placement, page: page)
            context.saveGState()
            context.clip(to: flipped(cell.photo, page: page))
            context.interpolationQuality = .high
            if turned {
                // a quarter turn clockwise about the place's center
                context.translateBy(x: target.midX, y: target.midY)
                context.rotate(by: -.pi / 2)
                context.draw(image, in: CGRect(x: -target.height / 2, y: -target.width / 2, width: target.height,
                                               height: target.width))
            } else {
                context.draw(image, in: target)
            }
            context.restoreGState()
            if let caption = cell.caption { drawCaption(captionText(item), in: flipped(caption, page: page), context: context) }
        }
    }

    /// Writes every page into a PDF at `url`. False when the file can't be made.
    @discardableResult
    func writePDF(to url: URL) -> Bool {
        var box = CGRect(origin: .zero, size: pageSize)
        guard pageCount > 0, let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return false }
        for index in 0..<pageCount {
            context.beginPDFPage(nil)
            drawPage(index, in: context)
            context.endPDFPage()
        }
        context.closePDF()
        return true
    }

    /// Page `index` as a bitmap `scale` pixels per point, for the preview.
    func pageImage(_ index: Int, scale: Double) -> CGImage? {
        let size = pageSize
        guard let context = CGContext(data: nil, width: max(1, Int(size.width * scale)), height: max(1, Int(size.height * scale)),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: DevelopRenderer.outputColorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        drawPage(index, in: context)
        return context.makeImage()
    }

    /// Photo `index` developed at `pixels`, sharpened and color-converted for printing.
    func photo(_ index: Int, pixels: CGSize) -> CGImage? {
        let key = "\(index)|\(Int(pixels.width))x\(Int(pixels.height))"
        if let image = lock.withLock({ rendered[key] }) { return image }
        let item = items[index]
        // decode no larger than the print needs, allowing for the crop
        var cropShare = 1.0
        if item.develop.hasGeometry {
            let frame = DevelopGeometry.rotatedSize(item.originalSize, item.develop.rotation)
            let crop = DevelopGeometry.effectiveCrop(item.develop, frame: frame)
            cropShare = max(0.05, min(crop.width, crop.height))
        }
        let longest = Double(max(pixels.width, pixels.height)) / cropShare
        let decode = longest >= Double(max(item.originalSize.width, item.originalSize.height)) ? nil : Int(longest.rounded(.up)) + 2
        guard let source = DevelopRenderer.Source(url: URL(fileURLWithPath: item.sourcePath), isRaw: item.isRaw,
                                                  maxPixel: decode, interactive: false),
              var image = source.image(item.develop) else { return nil }
        let extent = image.extent.integral
        if extent.width > 0, extent.height > 0, extent.size != pixels {
            let scale = pixels.height / extent.height
            image = image.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scale, kCIInputAspectRatioKey: (pixels.width / extent.width) / scale,
            ])
            image = image.cropped(to: CGRect(origin: image.extent.origin, size: pixels))
        }
        image = RenderedExportService.sharpened(image, for: settings.sharpenFor, amount: settings.sharpenAmount)
        guard var bitmap = RenderedExportService.bitmap(image, bounds: CGRect(origin: image.extent.origin, size: pixels),
                                                        sixteenBit: false, colorSpace: DevelopRenderer.outputColorSpace)
        else { return nil }
        if let profile = settings.profile, let converted = SoftProofing.converted(bitmap, toProfile: profile,
                                                                                  intent: settings.intent) {
            bitmap = converted
        }
        lock.withLock { rendered[key] = bitmap }
        return bitmap
    }

    private func captionText(_ item: PrintItem) -> String {
        switch settings.caption {
        case .none: ""
        case .filename: item.filename
        case .title: item.title.isEmpty ? item.filename : item.title
        }
    }

    private func drawCaption(_ text: String, in rect: CGRect, context: CGContext) {
        guard !text.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor(white: 0.25, alpha: 1), .paragraphStyle: paragraph,
        ])
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(string), CFRange(location: 0, length: 0),
                                             CGPath(rect: rect.insetBy(dx: 0, dy: 2), transform: nil), nil)
        context.textMatrix = .identity
        CTFrameDraw(frame, context)
    }

    /// A rect from the page's top-left (the layout's coordinates) to its bottom-left (the context's).
    private func flipped(_ rect: CGRect, page: CGSize) -> CGRect {
        CGRect(x: rect.minX, y: page.height - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// The pages as a view for `NSPrintOperation`: one page per page of the job, drawn by the renderer.
final class PrintPagesView: NSView {
    private let renderer: PrintRenderer

    init(renderer: PrintRenderer) {
        self.renderer = renderer
        let page = renderer.pageSize
        super.init(frame: NSRect(x: 0, y: 0, width: page.width, height: page.height * CGFloat(max(1, renderer.pageCount))))
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: renderer.pageCount)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        let size = renderer.pageSize
        return NSRect(x: 0, y: size.height * CGFloat(page - 1), width: size.width, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        for index in 0..<renderer.pageCount {
            let rect = rectForPage(index + 1)
            guard rect.intersects(dirtyRect) else { continue }
            context.saveGState()
            // back to the page's own bottom-left origin, y up, as the renderer draws
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.scaleBy(x: 1, y: -1)
            renderer.drawPage(index, in: context)
            context.restoreGState()
        }
    }
}
