import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Web galleries: the page lists every photo, shows its words safely, and its viewer's data
/// points at photos that are there; the photos are sRGB JPEGs no larger than asked (and never
/// enlarged), the thumbnails enough for their tiles; a gallery never overwrites another, and a
/// cancelled one leaves nothing.
enum WebGalleryCheck {
    static func run() {
        checkPage()
        checkExport()
        print("--- web gallery assertions passed ---")
    }

    private static func checkPage() {
        assert(WebGalleryPage.fileName("HR4A 6025 (1)", index: 0) == "001-HR4A-6025-1.jpg"
               && WebGalleryPage.fileName("海边", index: 11) == "012.jpg", "file names are numbered and safe for any server")
        assert(WebGalleryPage.escape("<a href=\"x\">'&'</a>") == "&lt;a href=&quot;x&quot;&gt;&#39;&amp;&#39;&lt;/a&gt;",
               "words are escaped for HTML")
        let photo = WebGalleryPage.Photo(large: "images/large/001.jpg", thumbnail: "images/thumbs/001.jpg", width: 10, height: 10,
                                         thumbnailWidth: 5, thumbnailHeight: 5, caption: "</script><b>", details: "")
        assert(!WebGalleryPage.data([photo]).contains("</script>"), "no caption can end the viewer's script")
        let empty = try? JSONDecoder().decode(WebGallerySettings.self, from: Data("{}".utf8))
        assert(empty == WebGallerySettings(), "settings saved before a field existed take its default")
    }

    private static func image(_ url: URL, width: Int, height: Int) {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: 0.2, green: 0.6, blue: 0.4, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
    }

    /// Width, height and color space name of the image at `url`.
    private static func info(_ url: URL) -> (Int, Int, String)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return (image.width, image.height, (image.colorSpace?.name as String?) ?? "")
    }

    private static func checkExport() {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("pc-web-\(UUID().uuidString)")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let sizes = [(3000, 2000), (600, 900), (1200, 800)]
        let photos = sizes.enumerated().map { index, size -> WebGalleryPhoto in
            let url = folder.appendingPathComponent("photo\(index).jpg")
            image(url, width: size.0, height: size.1)
            return WebGalleryPhoto(item: PrintItem(sourcePath: url.path, isRaw: false, develop: .neutral,
                                                   originalSize: CGSize(width: size.0, height: size.1), filename: url.lastPathComponent, title: ""),
                                   baseName: "photo\(index)", caption: index == 1 ? "Sea & <script>alert(1)</script>" : "Photo \(index)",
                                   details: "Canon · ƒ/2.8")
        }
        var settings = WebGallerySettings()
        settings.title = "Seaside"
        settings.largeSize = 1600
        settings.thumbnailSize = 320
        guard let page = WebGalleryExporter.export(photos, settings: settings, name: "Seaside", in: folder,
                                                   progress: { _ in }, cancelled: { false }),
              let html = try? String(contentsOf: page, encoding: .utf8) else {
            return assertionFailure("a gallery is written")
        }
        let gallery = page.deletingLastPathComponent()
        assert(html.components(separatedBy: "class=\"tile\"").count - 1 == 3 && html.contains("<title>Seaside</title>")
               && html.contains("Sea &amp; &lt;script&gt;alert(1)&lt;/script&gt;") && !html.contains("<script>alert(1)"),
               "the page lists every photo and shows its words safely")
        let start = html.range(of: "const photos = ")!.upperBound
        let end = html.range(of: ";\n", range: start..<html.endIndex)!.lowerBound
        let data = (try? JSONSerialization.jsonObject(with: Data(html[start..<end].utf8))) as? [[String: Any]] ?? []
        assert(data.count == 3 && data.allSatisfy { fm.fileExists(atPath: gallery.appendingPathComponent($0["src"] as? String ?? "-").path) }
               && data[0]["details"] as? String == "Canon · ƒ/2.8", "the viewer's data points at the photos")
        let large = (0..<3).compactMap { info(gallery.appendingPathComponent("images/large/" + WebGalleryPage.fileName("photo\($0)", index: $0))) }
        let thumbs = (0..<3).compactMap { info(gallery.appendingPathComponent("images/thumbs/" + WebGalleryPage.fileName("photo\($0)", index: $0))) }
        assert(large.count == 3 && large[0].0 == 1600 && large[0].1 == 1067 && large[1].0 == 600 && large[1].1 == 900
               && large.allSatisfy { $0.2 == CGColorSpace.sRGB as String },
               "photos are sRGB, no larger than asked and never enlarged")
        assert(thumbs.count == 3 && min(thumbs[0].0, thumbs[0].1) == 320 && min(thumbs[1].0, thumbs[1].1) == 320,
               "thumbnails have the asked short side")
        let again = WebGalleryExporter.export(photos, settings: settings, name: "Seaside", in: folder, progress: { _ in }, cancelled: { false })
        assert(again?.deletingLastPathComponent().lastPathComponent == "Seaside 2", "a second gallery doesn't overwrite the first")
        let cancelled = WebGalleryExporter.export(photos, settings: settings, name: "Stopped", in: folder, progress: { _ in }, cancelled: { true })
        assert(cancelled == nil && !fm.fileExists(atPath: folder.appendingPathComponent("Stopped").path),
               "a cancelled gallery leaves nothing behind")
    }
}
