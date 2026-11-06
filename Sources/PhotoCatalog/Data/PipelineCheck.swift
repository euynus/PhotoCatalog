// ============================================================
//  Headless end-to-end check for the real import pipeline.
//  Generates test images, then exercises
//  scan → metadata → thumbnails → hash → persist → reload → export → backup.
// ============================================================
import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

enum PipelineCheck {
    static func run() {
        print("=== PhotoCatalog real-pipeline self-check ===")
        let run = Run()
        run.testImages()
        run.scanner()
        run.importPipeline()
        run.persistReloadRoundtrip()
        run.editPersistence()
        run.exactDuplicates()
        run.exportOriginals()
        run.catalogBackup()
        run.substringSearch()
        run.healthCheck()
        run.perceptualHashes()
        run.xmpRoundtrip()
        run.sidecarImport()
        run.managedImport()
        run.batchRename()
        run.visionAnalysis()
        run.relocation()
        run.availability()
        run.externalVolumes()
        run.catalogDecoder()
        run.cardImport()
        run.cameraImport()
        run.finish()
    }

    /// One run of the check: each numbered step is a method, in an extension by area
    /// (PipelineCheck+<Area>.swift), and `run()` calls them in order. The stored properties
    /// are what more than one step uses.
    final class Run {
        private(set) var failures = 0
        let fm = FileManager.default
        let tmp: URL
        let src: URL
        // step 1 stamps the first test image with these; steps 3 and 4 read them back
        let fixedGPS = (lat: 31.2345, lon: 121.4567, altitude: 88.5)
        let fixedModifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
        // set by step 3, which exits if the catalog can't be created
        var store: CatalogStore!
        var coordinator: ImportCoordinator!
        var assets: [Asset] = []
        var timestampedAsset: Asset?
        var sameHashDifferentSize: Asset!
        // set by step 4
        var album: Album!
        // set by step 13
        var xsrc: URL!

        init() {
            tmp = fm.temporaryDirectory.appendingPathComponent("pc-pipeline-\(UUID().uuidString)")
            src = tmp.appendingPathComponent("source")
            try? fm.createDirectory(at: src, withIntermediateDirectories: true)
        }

        func check(_ cond: Bool, _ label: String) {
            print((cond ? "  ✓ " : "  ✗ FAIL ") + label)
            if !cond { failures += 1 }
        }

        /// The tethering and cache checks, then cleanup and the summary; exits 1 if any check failed.
        func finish() {
            MainActor.assumeIsolated { TetherCheck.run(check) }
            MainActor.assumeIsolated { CacheCheck.run(check) }

            try? fm.removeItem(at: tmp)
            print(failures == 0 ? "--- pipeline OK ---" : "--- \(failures) FAILURE(S) ---")
            exit(failures == 0 ? 0 : 1)
        }
    }
}

// Test images the steps write and read: methods of Run, so the steps call them unqualified.
extension PipelineCheck.Run {
    func writeTestImage(to url: URL, width: Int, height: Int, seed: Int,
                        gps: [CFString: Any]? = nil, exif: [CFString: Any]? = nil) {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        let top = CGColor(red: Double((seed * 47) % 255) / 255, green: 0.45, blue: 0.6, alpha: 1)
        let bottom = CGColor(red: 0.2, green: Double((seed * 83) % 255) / 255, blue: 0.7, alpha: 1)
        ctx.setFillColor(top)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(bottom)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        guard let cg = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        var properties: [CFString: Any] = [:]
        if let gps { properties[kCGImagePropertyGPSDictionary] = gps }
        if let exif { properties[kCGImagePropertyExifDictionary] = exif }
        CGImageDestinationAddImage(dest, cg, properties.isEmpty ? nil : properties as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    func writeBlackImage(to url: URL, width: Int, height: Int, quality: Double? = nil) {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        ctx.setFillColor(CGColor.black)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cg = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        let options = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
        CGImageDestinationAddImage(dest, cg, options)
        CGImageDestinationFinalize(dest)
    }

    func pixelSize(at url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: width, height: height)
    }

    func meanLuminance(at url: URL) -> Double {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 16,
              ] as CFDictionary) else { return 0 }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        context.interpolationQuality = .medium
        context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (0.3 * Double(pixel[0]) + 0.59 * Double(pixel[1]) + 0.11 * Double(pixel[2])) / 255
    }

    func imageIsUniformBlack(at url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 32,
              ] as CFDictionary)
        else { return true }
        let width = cg.width
        let height = cg.height
        let bytesPerPixel = 4
        var data = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        guard let context = CGContext(data: &data,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width * bytesPerPixel,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return true }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        var index = 0
        while index < data.count {
            if data[index] > 2 || data[index + 1] > 2 || data[index + 2] > 2 {
                return false
            }
            index += bytesPerPixel
        }
        return true
    }

    /// variant 0: vertical bands · 1: bands + small corner mark (near-dup) · 2: horizontal bands (far).
    func writeStructured(to url: URL, variant: Int) {
        let w = 120, h = 90
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        let mid = CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        let bright = CGColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1)
        let dark = CGColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1)
        ctx.setFillColor(mid)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        if variant == 2 {
            for y in stride(from: 0, to: h, by: 15) {
                ctx.setFillColor((y / 15) % 2 == 0 ? bright : dark)
                ctx.fill(CGRect(x: 0, y: y, width: w, height: 15))
            }
        } else {
            for x in stride(from: 0, to: w, by: 15) {
                ctx.setFillColor((x / 15) % 2 == 0 ? bright : dark)
                ctx.fill(CGRect(x: x, y: 0, width: 15, height: h))
            }
            if variant == 1 {
                ctx.setFillColor(mid)
                ctx.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
            }
        }
        guard let cg = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
    }
}
