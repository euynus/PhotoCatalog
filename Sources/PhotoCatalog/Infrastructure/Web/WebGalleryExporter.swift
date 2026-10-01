// ============================================================
//  Web gallery export — the photos rendered for the web, and the page that shows them
// ============================================================
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One photo of a web gallery: how to render it, its file name and the words shown with it.
struct WebGalleryPhoto: Sendable {
    let item: PrintItem
    let baseName: String
    let caption: String
    let details: String
}

enum WebGalleryExporter {
    /// Writes the gallery into a new folder named `name` inside `parent` (" 2", " 3" … when
    /// taken): `index.html`, and `images/large` and `images/thumbs` of sRGB JPEGs rendered with
    /// each photo's develop settings, without metadata. Returns the page; nil when cancelled
    /// or it couldn't be written, leaving nothing behind.
    static func export(_ photos: [WebGalleryPhoto], settings: WebGallerySettings, name: String, in parent: URL,
                       progress: @escaping @Sendable (Double) -> Void, cancelled: @escaping @Sendable () -> Bool) -> URL? {
        let fm = FileManager.default
        var folder = parent.appendingPathComponent(name, isDirectory: true)
        var suffix = 2
        while fm.fileExists(atPath: folder.path) {
            folder = parent.appendingPathComponent("\(name) \(suffix)", isDirectory: true)
            suffix += 1
        }
        let large = folder.appendingPathComponent("images/large", isDirectory: true)
        let thumbs = folder.appendingPathComponent("images/thumbs", isDirectory: true)
        guard (try? fm.createDirectory(at: large, withIntermediateDirectories: true)) != nil,
              (try? fm.createDirectory(at: thumbs, withIntermediateDirectories: true)) != nil else { return nil }
        func abandon() -> URL? {
            try? fm.removeItem(at: folder)
            return nil
        }
        var pages: [WebGalleryPage.Photo] = []
        for (index, photo) in photos.enumerated() {
            guard !cancelled() else { return abandon() }
            let file = WebGalleryPage.fileName(photo.baseName, index: index)
            guard let image = photo.item.rendered(longEdge: settings.largeSize, colorSpace: sRGB),
                  let thumbnail = scaled(image, shortEdge: settings.thumbnailSize),
                  writeJPEG(image, to: large.appendingPathComponent(file), quality: 0.85),
                  writeJPEG(thumbnail, to: thumbs.appendingPathComponent(file), quality: 0.8) else { continue }
            pages.append(WebGalleryPage.Photo(large: "images/large/" + file, thumbnail: "images/thumbs/" + file,
                                              width: image.width, height: image.height,
                                              thumbnailWidth: thumbnail.width, thumbnailHeight: thumbnail.height,
                                              caption: photo.caption, details: settings.showDetails ? photo.details : ""))
            progress(Double(index + 1) / Double(photos.count))
        }
        guard !pages.isEmpty, !cancelled() else { return abandon() }
        let page = folder.appendingPathComponent("index.html")
        let html = WebGalleryPage.html(title: settings.title.isEmpty ? name : settings.title, subtitle: settings.subtitle,
                                       theme: settings.theme, photos: pages)
        guard (try? html.write(to: page, atomically: true, encoding: .utf8)) != nil else { return abandon() }
        return page
    }

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// `image` with its short side `shortEdge` (or as it is when smaller).
    static func scaled(_ image: CGImage, shortEdge: Int) -> CGImage? {
        let scale = min(1, Double(shortEdge) / Double(min(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded())), height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func writeJPEG(_ image: CGImage, to url: URL, quality: Double) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }
}
