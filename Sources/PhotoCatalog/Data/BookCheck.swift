import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Photo books: photos grouped onto pages by shape (portraits paired on a wide page, landscapes
/// on a tall one) or a fixed number a page; every photo and caption inside its page, none on
/// another; full-bleed photos filling the page; the PDF with a page for each, the cover first.
enum BookCheck {
    static func run() {
        checkLayout()
        checkPDF()
        print("--- book assertions passed ---")
    }

    private static func checkLayout() {
        let square = BookSettings.Size.square.points, tall = BookSettings.Size.portrait.points
        assert(BookLayout.groups([1.5, 0.67, 0.67, 1.5, 0.67], layout: .auto, page: square) == [[0], [1, 2], [3], [4]]
               && BookLayout.groups([1.5, 1.5, 0.67, 1.5], layout: .auto, page: tall) == [[0, 1], [2], [3]],
               "auto: portraits paired on a wide page, landscapes on a tall one, the rest alone")
        assert(BookLayout.groups(Array(repeating: 1.5, count: 6), layout: .four, page: square) == [[0, 1, 2, 3], [4, 5]]
               && BookLayout.groups(Array(repeating: 1.5, count: 3), layout: .two, page: square) == [[0, 1], [2]],
               "a fixed number a page, the last page with what's left")

        var settings = BookSettings()
        settings.caption = .title
        let aspects = [1.5, 0.67, 0.67, 1.5, 1.33, 0.8]
        for size in BookSettings.Size.allCases {
            for layout in BookSettings.Layout.allCases {
                for margin in BookSettings.Margin.allCases {
                    settings.size = size
                    settings.layout = layout
                    settings.margin = margin
                    let pages = BookLayout.pages(aspects, settings: settings)
                    let bounds = CGRect(origin: .zero, size: size.points).insetBy(dx: -0.01, dy: -0.01)
                    let placed = pages.dropFirst().flatMap { $0.cells.map(\.photo) }
                    assert(pages.first?.isCover == true && placed == Array(aspects.indices)
                           && pages.dropFirst().enumerated().allSatisfy { $0.element.number == $0.offset + 1 },
                           "a cover, then every photo once, in order, on numbered pages")
                    for page in pages {
                        let frames = page.cells.map(\.frame) + page.cells.compactMap(\.caption)
                        assert(frames.allSatisfy { bounds.contains($0) }, "photos and captions stay on the page")
                        for (i, a) in page.cells.enumerated() {
                            for b in page.cells.dropFirst(i + 1) {
                                assert(a.frame.intersection(b.frame).width < 0.01 || a.frame.intersection(b.frame).height < 0.01,
                                       "photos on a page don't overlap")
                            }
                            if let caption = a.caption { assert(caption.minY >= a.frame.maxY - 0.01, "a caption goes under its photo") }
                        }
                    }
                }
            }
        }
        settings = BookSettings()
        settings.margin = .none
        settings.cover = false
        let bleed = BookLayout.pages([1.5, 0.67], settings: settings)
        assert(bleed.count == 2 && bleed[0].cells[0].fill && bleed[0].cells[0].frame == CGRect(origin: .zero, size: settings.size.points)
               && bleed[0].number == 1, "with no margin, a photo alone fills its page")
        let fit = BookLayout.placement(aspect: 2, in: CGRect(x: 0, y: 0, width: 100, height: 100), fill: false)
        let cover = BookLayout.placement(aspect: 2, in: CGRect(x: 0, y: 0, width: 100, height: 100), fill: true)
        assert(fit == CGRect(x: 0, y: 25, width: 100, height: 50) && cover == CGRect(x: -50, y: 0, width: 200, height: 100),
               "a photo is fitted inside its place, or covers it")
        let stored = try! JSONDecoder().decode(BookSettings.self, from: JSONEncoder().encode(settings))
        let empty = try! JSONDecoder().decode(BookSettings.self, from: Data("{}".utf8))
        assert(stored == settings && empty == BookSettings(), "settings persist, missing ones take their defaults")
    }

    private static func checkPDF() {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("pc-book-\(UUID().uuidString)")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let photos: [((Double, Double, Double), Int, Int)] = [((0.9, 0.1, 0.1), 900, 600), ((0.1, 0.2, 0.9), 400, 600), ((0.1, 0.8, 0.2), 400, 600)]
        let items = photos.enumerated().map { index, photo -> BookItem in
            let url = folder.appendingPathComponent("photo\(index).png")
            let context = CGContext(data: nil, width: photo.1, height: photo.2, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.setFillColor(red: photo.0.0, green: photo.0.1, blue: photo.0.2, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: photo.1, height: photo.2))
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            CGImageDestinationFinalize(destination)
            return BookItem(item: PrintItem(sourcePath: url.path, isRaw: false, develop: .neutral,
                                            originalSize: CGSize(width: photo.1, height: photo.2), filename: url.lastPathComponent, title: ""),
                            caption: "Photo \(index + 1)")
        }
        var settings = BookSettings()
        settings.title = "Summer"
        settings.caption = .title
        let renderer = BookRenderer(items: items, settings: settings)
        let url = folder.appendingPathComponent("book.pdf")
        assert(renderer.pages.count == 3 && renderer.writePDF(to: url), "the book is written")
        let document = CGPDFDocument(url as CFURL)
        let box = document?.page(at: 1)?.getBoxRect(.mediaBox) ?? .zero
        assert(document?.numberOfPages == 3 && abs(box.width - settings.size.points.width) < 0.5
               && abs(box.height - settings.size.points.height) < 0.5, "a PDF page for the cover and each page, at the book's size")
        // after the cover and the landscape alone: the two portraits side by side, blue then green
        guard let page = renderer.pageImage(2, scale: 0.5) else { return assertionFailure("a page renders") }
        var pixels = [UInt8](repeating: 0, count: page.width * page.height * 4)
        let context = CGContext(data: &pixels, width: page.width, height: page.height, bitsPerComponent: 8, bytesPerRow: page.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(page, in: CGRect(x: 0, y: 0, width: page.width, height: page.height))
        func color(_ x: Double, _ y: Double) -> (Int, Int, Int) {
            let i = (Int(y * Double(page.height)) * page.width + Int(x * Double(page.width))) * 4
            return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
        }
        let left = color(0.3, 0.45), right = color(0.7, 0.45), corner = color(0.02, 0.02)
        assert(left.2 > 180 && left.0 < 60 && right.1 > 150 && right.0 < 60 && corner == (255, 255, 255),
               "the two portraits share a page, side by side, on white")
        let stopped = folder.appendingPathComponent("stopped.pdf")
        assert(!renderer.writePDF(to: stopped, cancelled: { true }) && !fm.fileExists(atPath: stopped.path),
               "a cancelled book leaves nothing behind")
    }
}
