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
    private static var failures = 0
    private static func check(_ cond: Bool, _ label: String) {
        print((cond ? "  ✓ " : "  ✗ FAIL ") + label)
        if !cond { failures += 1 }
    }

    static func run() {
        print("=== PhotoCatalog real-pipeline self-check ===")
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("pc-pipeline-\(UUID().uuidString)")
        let src = tmp.appendingPathComponent("source")
        let exportDir = tmp.appendingPathComponent("export")
        try? fm.createDirectory(at: src, withIntermediateDirectories: true)

        // 1. generate 6 distinct test JPEGs + 1 exact duplicate
        for i in 0..<6 {
            writeTestImage(to: src.appendingPathComponent(String(format: "IMG_%04d.jpg", i)),
                           width: i % 2 == 0 ? 800 : 600, height: i % 2 == 0 ? 600 : 800, seed: i)
        }
        try? fm.copyItem(at: src.appendingPathComponent("IMG_0000.jpg"),
                         to: src.appendingPathComponent("IMG_0000_copy.jpg"))
        // a non-image file that must be ignored
        try? "not an image".data(using: .utf8)?.write(to: src.appendingPathComponent("notes.txt"))

        // 2. scanner
        let scanned = FileScanner.scan(src)
        check(scanned.count == 7, "scanner found 7 images (ignored notes.txt) — got \(scanned.count)")

        // 3. import pipeline (metadata + thumbnails + hashes)
        guard let store = try? CatalogStore(packageURL: tmp.appendingPathComponent("Lib.photolibrary")) else {
            print("  ✗ FAIL could not create catalog"); exit(1)
        }
        let coordinator = ImportCoordinator(store: store)
        var assets = coordinator.importFolder(src)
        check(assets.count == 7, "imported 7 assets — got \(assets.count)")
        let withDims = assets.allSatisfy { $0.width > 0 && $0.height > 0 }
        check(withDims, "every asset has real pixel dimensions from Image I/O")
        let thumbsExist = assets.allSatisfy {
            fm.fileExists(atPath: $0.thumb) && fm.fileExists(atPath: $0.preview)
        }
        check(thumbsExist, "thumbnails + previews written to disk cache")
        check(assets.allSatisfy { $0.contentHash != nil && $0.quickHash != nil }, "content + quick hashes computed")

        // 4. persist + reload roundtrip
        try? store.upsert(assets)
        let reloaded = (try? store.loadAssets()) ?? []
        check(reloaded.count == 7, "reloaded 7 assets from SQLite — got \(reloaded.count)")

        // 5. edit persistence
        if let id = assets.first?.id {
            try? store.updateAsset({ var a = assets[0]; a.rating = 5; a.keywords = ["测试"]; return a }())
            let again = (try? store.loadAssets()) ?? []
            let edited = again.first { $0.id == id }
            check(edited?.rating == 5 && edited?.keywords == ["测试"], "rating + keyword edit persisted across reload")
        }

        // 6. exact-duplicate detection (the identical pair)
        let dupes = HashService.exactDuplicateGroups(assets)
        check(dupes.contains { $0.items.count == 2 }, "exact-duplicate group found for the identical pair")

        // 7. export originals
        let report = ExportService.copyOriginals(assets, to: exportDir)
        check(report.copied == 7, "exported 7 originals — copied \(report.copied), failed \(report.failed)")

        // 8. backup
        let backup = try? BackupService.backup(store)
        check(backup != nil && fm.fileExists(atPath: backup!.path), "catalog backup written")

        // 9. missing detection after deleting an original
        if let first = assets.first, let p = first.localPath {
            try? fm.removeItem(at: URL(fileURLWithPath: p))
            let stillThere = fm.fileExists(atPath: p)
            check(!stillThere, "simulated missing original (file removed)")
        }

        try? fm.removeItem(at: tmp)
        print(failures == 0 ? "--- pipeline OK ---" : "--- \(failures) FAILURE(S) ---")
        exit(failures == 0 ? 0 : 1)
    }

    private static func writeTestImage(to url: URL, width: Int, height: Int, seed: Int) {
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
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
    }
}
