import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Rendered export: sizing, naming, file format, metadata, watermark and the job queue.
enum ExportCheck {
    static func run() {
        checkSizing()
        checkNaming()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pc-export-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        checkRenderedFiles(in: directory)
        MainActor.assumeIsolated { checkQueue(in: directory) }
        print("--- rendered export assertions passed ---")
    }

    private static func checkSizing() {
        var s = ExportSettings()
        let photo = CGSize(width: 6000, height: 4000)
        assert(s.outputSize(for: photo) == photo && s.decodeLongEdge(original: photo, cropShare: 1) == nil,
               "no resize keeps full resolution")
        s.resize = .longEdge
        s.edge = 2048
        assert(s.outputSize(for: photo) == CGSize(width: 2048, height: 1365), "long edge scales the longer side")
        assert(s.decodeLongEdge(original: photo, cropShare: 1) == 2050
               && s.decodeLongEdge(original: photo, cropShare: 0.5) == 4098,
               "a crop decodes enough pixels to still fill the output")
        s.resize = .shortEdge
        s.edge = 1080
        assert(s.outputSize(for: photo) == CGSize(width: 1620, height: 1080), "short edge scales the shorter side")
        s.resize = .fitWithin
        s.maxWidth = 1920
        s.maxHeight = 1080
        assert(s.outputSize(for: CGSize(width: 4000, height: 6000)) == CGSize(width: 720, height: 1080),
               "fit within keeps the photo inside the box")
        s.resize = .longEdge
        s.edge = 2048
        assert(s.outputSize(for: CGSize(width: 1000, height: 800)) == CGSize(width: 1000, height: 800),
               "small photos are not enlarged by default")
        s.allowEnlarge = true
        assert(s.outputSize(for: CGSize(width: 1000, height: 800)) == CGSize(width: 2048, height: 1638),
               "enlarging is opt-in")

        let legacy = Data(#"{"format":"heic","edge":1200}"#.utf8)
        let decoded = try? JSONDecoder().decode(ExportSettings.self, from: legacy)
        assert(decoded?.format == .heic && decoded?.edge == 1200 && decoded?.quality == 0.9,
               "export settings saved before a field existed still load")
    }

    private static func checkNaming() {
        var s = ExportSettings()
        s.fileNameTemplate = "{date}-{seq}-{original}"
        s.sequenceStart = 7
        let date = Date(timeIntervalSince1970: 1_704_067_200)   // 2024-01-01 00:00 wall clock
        assert(s.fileName(original: "IMG_1", sequence: 7, date: date, camera: "R5", title: "", rating: 3)
               == "20240101-0007-IMG_1", "tokens fill in the name")
        s.fileNameTemplate = "{title}"
        assert(s.fileName(original: "IMG_1", sequence: 1, date: date, camera: "", title: "a/b:c", rating: 0) == "a-b-c",
               "path characters never reach the file name")
        assert(s.fileName(original: "IMG_1", sequence: 1, date: date, camera: "", title: "", rating: 0) == "IMG_1",
               "an empty name falls back to the original's")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pc-names-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        FileManager.default.createFile(atPath: folder.appendingPathComponent("a.jpg").path, contents: Data())
        var reserved = Set<String>()
        let unique = RenderedExportService.destinationURL(in: folder, name: "a", ext: "jpg", collision: .uniqueName,
                                                          reserved: &reserved)
        let again = RenderedExportService.destinationURL(in: folder, name: "A", ext: "jpg", collision: .uniqueName,
                                                         reserved: &reserved)
        assert(unique?.lastPathComponent == "a-1.jpg" && again?.lastPathComponent == "A-2.jpg",
               "existing files and names used earlier in the export get a number")
        var fresh = Set<String>()
        assert(RenderedExportService.destinationURL(in: folder, name: "a", ext: "jpg", collision: .skip,
                                                    reserved: &fresh) == nil, "skip leaves an existing file alone")
        let first = RenderedExportService.destinationURL(in: folder, name: "a", ext: "jpg", collision: .overwrite,
                                                         reserved: &fresh)
        let second = RenderedExportService.destinationURL(in: folder, name: "a", ext: "jpg", collision: .overwrite,
                                                          reserved: &fresh)
        assert(first?.lastPathComponent == "a.jpg" && second?.lastPathComponent == "a-1.jpg",
               "overwrite replaces old files but never a photo from the same export")
    }

    /// A 400 × 300 JPEG shot in portrait (orientation 6) with GPS, left half dark, right half light.
    private static func writeSource(to url: URL) {
        let context = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(gray: 0.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
        context.setFillColor(gray: 0.8, alpha: 1)
        context.fill(CGRect(x: 200, y: 0, width: 200, height: 300))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 30.5, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 114.3, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifISOSpeedRatings: [400]],
        ] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }

    private static func item(_ path: String, develop: DevelopSettings = .neutral) -> RenderedExportItem {
        RenderedExportItem(assetId: "export-\(path.hashValue)", sourcePath: path, isRaw: false, develop: develop,
                           originalSize: CGSize(width: 400, height: 300), baseName: "IMG_0001",
                           date: Date(timeIntervalSince1970: 1_704_067_200), camera: "Test", title: "标题",
                           caption: "说明", keywords: ["旅行", "海"], rating: 4, author: "作者", copyright: "© 作者")
    }

    private static func properties(_ url: URL) -> [CFString: Any] {
        CGImageSourceCreateWithURL(url as CFURL, nil)
            .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] } ?? [:]
    }

    private static func checkRenderedFiles(in directory: URL) {
        let source = directory.appendingPathComponent("source.jpg")
        writeSource(to: source)
        let out = directory.appendingPathComponent("out", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        var s = ExportSettings()
        s.resize = .longEdge
        s.edge = 200
        s.removeLocation = true
        var reserved = Set<String>()
        guard case .written(let jpeg) = RenderedExportService.export(item(source.path), sequence: 1, settings: s,
                                                                     to: out, reserved: &reserved) else {
            preconditionFailure("JPEG export failed")
        }
        let p = properties(jpeg)
        let iptc = p[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        assert(p[kCGImagePropertyPixelWidth] as? Int == 150 && p[kCGImagePropertyPixelHeight] as? Int == 200,
               "export applies the camera orientation, then the size")
        assert((p[kCGImagePropertyOrientation] as? Int ?? 1) == 1, "exported pixels are upright, orientation reset")
        assert(p[kCGImagePropertyGPSDictionary] == nil, "remove location strips GPS")
        assert((iptc?[kCGImagePropertyIPTCKeywords] as? [String]) == ["旅行", "海"]
               && iptc?[kCGImagePropertyIPTCObjectName] as? String == "标题"
               && (p[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifISOSpeedRatings] != nil,
               "catalog metadata and camera EXIF travel with the file")
        assert((p[kCGImagePropertyProfileName] as? String)?.contains("sRGB") == true, "the sRGB profile is embedded")

        s.metadata = .none
        s.removeLocation = false
        s.fileNameTemplate = "bare"
        guard case .written(let bare) = RenderedExportService.export(item(source.path), sequence: 1, settings: s,
                                                                     to: out, reserved: &reserved) else {
            preconditionFailure("metadata-free export failed")
        }
        let bareProperties = properties(bare)
        assert(bareProperties[kCGImagePropertyGPSDictionary] == nil && bareProperties[kCGImagePropertyIPTCDictionary] == nil,
               "no metadata means no location or catalog fields")

        var tiff = ExportSettings()
        tiff.format = .tiff
        tiff.sixteenBit = true
        tiff.colorSpace = .adobeRGB
        guard case .written(let tif) = RenderedExportService.export(item(source.path), sequence: 1, settings: tiff,
                                                                    to: out, reserved: &reserved) else {
            preconditionFailure("TIFF export failed")
        }
        let tifProperties = properties(tif)
        assert(tif.pathExtension == "tif" && tifProperties[kCGImagePropertyDepth] as? Int == 16
               && (tifProperties[kCGImagePropertyProfileName] as? String)?.contains("Adobe") == true,
               "16-bit Adobe RGB TIFF keeps its depth and profile")

        var heic = ExportSettings()
        heic.format = .heic
        guard case .written(let heif) = RenderedExportService.export(item(source.path), sequence: 1, settings: heic,
                                                                     to: out, reserved: &reserved) else {
            preconditionFailure("HEIC export failed")
        }
        let type = CGImageSourceCreateWithURL(heif as CFURL, nil).flatMap(CGImageSourceGetType) as String?
        assert(type == UTType.heic.identifier, "HEIC export writes HEIC")

        var cropped = DevelopSettings()
        cropped.crop = DevelopCrop(x: 0, y: 0, width: 1, height: 0.5)
        var plain = ExportSettings()
        plain.resize = .longEdge
        plain.edge = 100
        let halfImage = RenderedExportService.render(item(source.path, develop: cropped), settings: plain)!
        assert(halfImage.width == 100 && halfImage.height == 67, "develop crops are baked into the export")

        plain.watermarkEnabled = true
        plain.watermark = "WATERMARK"
        let marked = RenderedExportService.render(item(source.path), settings: plain)!
        plain.watermarkEnabled = false
        let unmarked = RenderedExportService.render(item(source.path), settings: plain)!
        assert(cornerBytes(marked) != cornerBytes(unmarked), "the watermark is drawn in the bottom-right corner")
    }

    private static func cornerBytes(_ image: CGImage) -> [UInt8] {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // bottom-right quarter (rows are top-down in memory)
        return (height / 2..<height).flatMap { row in data[(row * width + width / 2) * 4..<(row * width + width) * 4] }
    }

    @MainActor
    private static func checkQueue(in directory: URL) {
        let base = DemoData.assets.filter { !$0.isRaw }
        func local(_ asset: Asset, _ name: String) -> Asset {
            let url = directory.appendingPathComponent(name)
            writeSource(to: url)
            var copy = asset
            copy.localPath = url.path
            copy.filename = name
            copy.status = .ready
            copy.isDemo = false
            return copy
        }
        let a = local(base[0], "A.jpg"), b = local(base[1], "B.jpg")
        let app = AppState.selfCheckFixture()
        app.assets = [a, b, base[2]]
        app.duplicateGroupsCache = []
        app.select(Selection(type: .lib, id: "all", name: "Export check"))
        let savedSettings = app.renderedExportSettings
        let savedFolder = app.renderedExportFolder
        defer {
            app.renderedExportSettings = savedSettings
            app.renderedExportFolder = savedFolder
        }
        app.selectedIds = [a.id, b.id, base[2].id]
        let items = app.renderedExportItems()
        assert(items.map(\.assetId).sorted() == [a.id, b.id].sorted(), "demo photos without originals are left out")

        var s = ExportSettings()
        s.revealInFinder = false
        s.resize = .longEdge
        s.edge = 64
        s.subfolder = "第一批"
        let folder = directory.appendingPathComponent("queue", isDirectory: true)
        app.startRenderedExport(settings: s, folder: folder)
        s.subfolder = "第二批"
        app.startRenderedExport(settings: s, folder: folder)
        assert(app.renderedExportProgress?.queued == 1, "a second export waits behind the first")
        let deadline = Date().addingTimeInterval(30)
        while app.renderedExportProgress != nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let written = ["第一批", "第二批"].map { name in
            (try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent(name).path))?
                .filter { $0.hasSuffix(".jpg") }.count ?? 0
        }
        assert(app.renderedExportProgress == nil && written == [2, 2], "queued exports run one after another")
        assert(app.renderedExportFolder == folder.path && app.renderedExportSettings.subfolder == "第二批",
               "the dialog remembers the last export")
    }
}
