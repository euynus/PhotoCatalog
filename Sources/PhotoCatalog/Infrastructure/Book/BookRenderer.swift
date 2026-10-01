// ============================================================
//  Book renderer — a photo book's pages, as a PDF or as previews
// ============================================================
import CoreGraphics
import CoreText
import Foundation

/// One photo of a book: how to render it, and its caption.
struct BookItem: Sendable {
    let item: PrintItem
    let caption: String
}

/// Draws a book's pages (see `BookLayout`): each photo rendered at 300 ppi for the size it's
/// drawn at, kept for redraws; captions under photos, the title on the cover, page numbers in
/// the bottom margin. The PDF and the preview draw through `drawPage` alike.
final class BookRenderer: @unchecked Sendable {
    let items: [BookItem]
    let settings: BookSettings
    let pages: [BookPage]
    /// Pixels per inch the photos are rendered at.
    var resolution = 300.0
    private let lock = NSLock()
    private var rendered: [String: CGImage] = [:]
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!

    init(items: [BookItem], settings: BookSettings) {
        self.items = items
        self.settings = settings
        pages = BookLayout.pages(items.map(\.item.aspect), settings: settings)
    }

    var pageSize: CGSize { settings.size.points }

    private var textGray: Double { settings.background == .black ? 0.85 : 0.2 }

    /// Draws page `index` into `context`, whose origin is the page's bottom-left in points.
    func drawPage(_ index: Int, in context: CGContext) {
        let page = pageSize
        let layout = pages[index]
        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(CGColor(gray: settings.background == .black ? 0 : 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: page))
        for cell in layout.cells {
            let item = items[cell.photo].item
            let place = BookLayout.placement(aspect: item.aspect, in: cell.frame, fill: cell.fill)
            let pixels = Int((max(place.width, place.height) / 72 * resolution).rounded(.up))
            guard let image = photo(cell.photo, longEdge: pixels) else { continue }
            context.saveGState()
            context.clip(to: flipped(cell.frame))
            context.interpolationQuality = .high
            context.draw(image, in: flipped(place))
            context.restoreGState()
            if let caption = cell.caption, !items[cell.photo].caption.isEmpty {
                // right under the photo as placed, not at the foot of its place (still inside it)
                let under = CGRect(x: place.minX, y: min(place.maxY, caption.minY), width: place.width, height: caption.height)
                draw(items[cell.photo].caption, in: under, size: caption.height * 0.42, gray: textGray, context: context)
            }
        }
        if let title = layout.title {
            let short = min(page.width, page.height)
            let name = settings.title.isEmpty ? "" : settings.title
            let hasSubtitle = !settings.subtitle.isEmpty
            draw(name, in: CGRect(x: title.minX, y: title.minY, width: title.width, height: title.height * (hasSubtitle ? 0.6 : 1)),
                 size: short * 0.055, gray: textGray, context: context, bold: true)
            if hasSubtitle {
                draw(settings.subtitle, in: CGRect(x: title.minX, y: title.minY + title.height * 0.55, width: title.width,
                                                   height: title.height * 0.3),
                     size: short * 0.03, gray: textGray * 0.8 + 0.1, context: context)
            }
        }
        if let number = layout.number, let frame = layout.numberFrame {
            draw("\(number)", in: frame, size: min(page.width, page.height) * 0.022, gray: 0.55, context: context)
        }
    }

    /// Writes every page into a PDF at `url`, telling `progress` each page done.
    @discardableResult
    func writePDF(to url: URL, progress: (Double) -> Void = { _ in }, cancelled: () -> Bool = { false }) -> Bool {
        var box = CGRect(origin: .zero, size: pageSize)
        guard !pages.isEmpty, let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return false }
        for index in pages.indices {
            guard !cancelled() else {
                context.closePDF()
                try? FileManager.default.removeItem(at: url)
                return false
            }
            context.beginPDFPage(nil)
            drawPage(index, in: context)
            context.endPDFPage()
            progress(Double(index + 1) / Double(pages.count))
        }
        context.closePDF()
        return true
    }

    /// Page `index` as a bitmap `scale` pixels per point, for the preview.
    func pageImage(_ index: Int, scale: Double) -> CGImage? {
        guard pages.indices.contains(index) else { return nil }
        let size = pageSize
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        drawPage(index, in: context)
        return context.makeImage()
    }

    /// Photo `index` developed with its long side `longEdge` pixels (rounded up, so photos
    /// drawn at about the same size share one rendering).
    private func photo(_ index: Int, longEdge: Int) -> CGImage? {
        let bucket = max(64, Int((Double(longEdge) / 64).rounded(.up)) * 64)
        let key = "\(index)|\(bucket)"
        if let image = lock.withLock({ rendered[key] }) { return image }
        guard let image = items[index].item.rendered(longEdge: bucket, colorSpace: space) else { return nil }
        lock.withLock { rendered[key] = image }
        return image
    }

    /// `rect` (top-left origin) in the context's bottom-left coordinates.
    private func flipped(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: pageSize.height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// `text` on one line, centered in `rect`, shortened with "…" when too long.
    private func draw(_ text: String, in rect: CGRect, size: Double, gray: Double, context: CGContext, bold: Bool = false) {
        guard !text.isEmpty else { return }
        let font = CTFontCreateWithName((bold ? "HelveticaNeue-Medium" : "HelveticaNeue") as CFString, size, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: gray, alpha: 1),
        ])
        var line = CTLineCreateWithAttributedString(attributed)
        if CTLineGetTypographicBounds(line, nil, nil, nil) > rect.width {
            let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: gray, alpha: 1),
            ]))
            line = CTLineCreateTruncatedLine(line, rect.width, .end, ellipsis) ?? line
        }
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        let box = flipped(rect)
        context.saveGState()
        context.textPosition = CGPoint(x: box.midX - width / 2, y: box.midY - (ascent - descent) / 2)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
