import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Print: page layout, pages written as a PDF, rotate to fit, and printer-profile conversion.
enum PrintCheck {
    static func run() {
        checkLayout()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pc-print-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        checkPDF(in: folder)
        checkRotateAndColor(in: folder)
        print("--- print assertions passed ---")
    }

    private static func checkLayout() {
        var s = PrintSettings()
        let a4 = s.pageSize
        assert(abs(a4.width - 595.28) < 0.1 && abs(a4.height - 841.89) < 0.1, "A4 is 210 × 297 mm")
        s.orientation = .landscape
        assert(s.pageSize == CGSize(width: a4.height, height: a4.width), "landscape turns the paper")
        s.orientation = .portrait

        let single = s.cells(pageSize: a4)
        assert(single == [PrintSettings.Cell(photo: CGRect(x: 36, y: 36, width: a4.width - 72, height: a4.height - 72), caption: nil)],
               "one photo per page fills the area inside the margins")
        s.caption = .filename
        let captioned = s.cells(pageSize: a4)[0]
        assert(captioned.photo.height == a4.height - 72 - PrintSettings.captionHeight
               && captioned.caption?.minY == captioned.photo.maxY, "a caption takes room below its photo")

        s.caption = .none
        s.layout = .contactSheet
        s.rows = 2
        s.columns = 3
        let grid = s.cells(pageSize: a4)
        let width: CGFloat = (a4.width - 72 - 24) / 3, height: CGFloat = (a4.height - 72 - 12) / 2
        let sized = abs(grid[0].photo.width - width) < 1e-9 && abs(grid[0].photo.height - height) < 1e-9
        let spaced = abs(grid[1].photo.minX - (36 + width + 12)) < 1e-9 && abs(grid[3].photo.minY - (36 + height + 12)) < 1e-9
        assert(grid.count == 6 && grid[0].photo.origin == CGPoint(x: 36, y: 36) && sized && spaced,
               "a contact sheet is a grid in reading order, with spacing between cells")
        assert(s.photosPerPage == 6 && s.pageCount(photos: 7) == 2 && s.pageCount(photos: 0) == 0
               && s.photos(onPage: 1, of: 7) == 6..<7, "photos fill pages in order")

        let box = CGRect(x: 0, y: 0, width: 100, height: 100)
        let fit = PrintSettings.placement(of: CGSize(width: 3, height: 2), in: box, fill: false)
        let fill = PrintSettings.placement(of: CGSize(width: 3, height: 2), in: box, fill: true)
        assert(abs(fit.width - 100) < 1e-9 && abs(fit.height - 200.0 / 3) < 1e-9 && abs(fit.midY - 50) < 1e-9
               && abs(fill.width - 150) < 1e-9 && fill.height == 100 && abs(fill.midX - 50) < 1e-9,
               "fit shows the whole photo, fill covers its place")
        let portraitCell = CGRect(x: 0, y: 0, width: 100, height: 200)
        assert(s.turns(1.5, in: portraitCell) && !s.turns(0.66, in: portraitCell), "rotate to fit turns a wide photo in a tall place")
        s.rotateToFit = false
        assert(!s.turns(1.5, in: portraitCell), "and only when asked")
        assert(s.pixelSize(for: CGRect(x: 0, y: 0, width: 72, height: 36)) == CGSize(width: 300, height: 150),
               "a photo renders at the print resolution")
        let old = try? JSONDecoder().decode(PrintSettings.self, from: Data(#"{"paper":"letter"}"#.utf8))
        assert(old?.paper == .letter && old?.layout == .single && old?.resolution == 300 && old?.profile == nil,
               "settings saved before a field existed still load")
    }

    /// A solid-color PNG of `size` at `url`.
    private static func solid(_ color: (Double, Double, Double), size: CGSize, at url: URL) {
        let space = DevelopRenderer.outputColorSpace
        let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: space, components: [color.0, color.1, color.2, 1])!)
        context.fill(CGRect(origin: .zero, size: size))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
    }

    private static func item(_ url: URL, size: CGSize) -> PrintItem {
        PrintItem(sourcePath: url.path, isRaw: false, develop: .neutral, originalSize: size,
                  filename: url.lastPathComponent, title: "")
    }

    /// RGB (0…255) at `point` (points from the top-left) of `page` rendered at 1 pixel per point.
    private static func color(of page: CGPDFPage, at point: CGPoint) -> (Int, Int, Int) {
        let box = page.getBoxRect(.mediaBox)
        let width = Int(box.width), height = Int(box.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: DevelopRenderer.outputColorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.drawPDFPage(page)
        let i = (Int(point.y) * width + Int(point.x)) * 4   // the bitmap's first row is the page's top
        return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
    }

    private static func checkPDF(in folder: URL) {
        let colors: [(Double, Double, Double)] = [(1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 0), (0, 1, 1), (1, 0, 1), (0.5, 0.5, 0.5)]
        let size = CGSize(width: 300, height: 200)
        let items = colors.enumerated().map { index, color -> PrintItem in
            let url = folder.appendingPathComponent("photo-\(index).png")
            solid(color, size: size, at: url)
            return item(url, size: size)
        }
        var settings = PrintSettings()
        settings.layout = .contactSheet
        settings.rows = 2
        settings.columns = 3
        settings.rotateToFit = false
        settings.caption = .filename
        settings.resolution = 72
        let renderer = PrintRenderer(items: items, settings: settings)
        let url = folder.appendingPathComponent("sheet.pdf")
        assert(renderer.writePDF(to: url), "a contact sheet writes as a PDF")
        guard let document = CGPDFDocument(url as CFURL), let first = document.page(at: 1), let second = document.page(at: 2) else {
            assertionFailure("the PDF reads back")
            return
        }
        let box = first.getBoxRect(.mediaBox)
        assert(document.numberOfPages == 2 && abs(box.width - 595.28) < 0.5 && abs(box.height - 841.89) < 0.5,
               "seven photos at six a page make two A4 pages")
        let cells = settings.cells(pageSize: settings.pageSize)
        func center(_ cell: PrintSettings.Cell) -> CGPoint {
            let placed = PrintSettings.placement(of: size, in: cell.photo, fill: false)
            return CGPoint(x: placed.midX, y: placed.midY)
        }
        let red = color(of: first, at: center(cells[0])), blue = color(of: first, at: center(cells[2]))
        let margin = color(of: first, at: CGPoint(x: 10, y: 10)), last = color(of: second, at: center(cells[0]))
        assert(red.0 > 200 && red.1 < 60 && blue.2 > 200 && blue.0 < 60, "the first photo is top left, the third top right (\(red), \(blue))")
        assert(margin == (255, 255, 255) && abs(last.0 - last.2) < 10 && last.0 > 100 && last.0 < 160,
               "the margins stay paper white, and the seventh photo starts page two")
    }

    private static func checkRotateAndColor(in folder: URL) {
        let url = folder.appendingPathComponent("wide.png")
        let size = CGSize(width: 600, height: 300)
        solid((0.1, 0.2, 0.9), size: size, at: url)
        var settings = PrintSettings()
        settings.resolution = 72
        let renderer = PrintRenderer(items: [item(url, size: size)], settings: settings)
        // the photo's painted extent on the upright page: turned, it's taller than wide
        guard let page = renderer.pageImage(0, scale: 0.5), let pixels = SoftProofing.rgba(page) else {
            assertionFailure("the page renders")
            return
        }
        var minX = page.width, maxX = 0, minY = page.height, maxY = 0
        for y in 0..<page.height {
            for x in 0..<page.width where pixels[(y * page.width + x) * 4 + 2] > 150 && pixels[(y * page.width + x) * 4] < 100 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        assert(maxY - minY > (maxX - minX) * 3 / 2, "rotate to fit turns a wide photo to fill a tall page")

        let cmyk = "/System/Library/ColorSync/Profiles/Generic CMYK Profile.icc"
        if FileManager.default.fileExists(atPath: cmyk) {
            settings.profile = cmyk
            let converted = PrintRenderer(items: [item(url, size: size)], settings: settings)
                .photo(0, pixels: CGSize(width: 120, height: 60))
            assert(converted?.colorSpace?.model == .cmyk && converted?.width == 120,
                   "with a printer profile the photo is converted to it before it's drawn")
        }
    }
}
