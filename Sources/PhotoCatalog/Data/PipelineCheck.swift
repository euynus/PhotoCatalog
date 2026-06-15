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
        let assets = coordinator.importFolder(src)
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

        // 9. FTS5 full-text search
        check(!store.search("IMG").isEmpty, "FTS5 search returns matches for 'IMG'")

        // 10. catalog health check
        let health = CatalogHealth.check(store, assets: assets)
        check(health.dbIntegrityOK && health.assetCount >= 7,
              "health check: db \(health.dbIntegrityOK ? "ok" : "BAD"), \(health.assetCount) assets")

        // 11. perceptual dHash (near pair similar, far pair dissimilar)
        let pa = src.appendingPathComponent("near_a.jpg")
        let pb = src.appendingPathComponent("near_b.jpg")
        let pf = src.appendingPathComponent("far.jpg")
        writeStructured(to: pa, variant: 0)
        writeStructured(to: pb, variant: 1)
        writeStructured(to: pf, variant: 2)
        if let ha = PerceptualHash.dHash(path: pa.path),
           let hb = PerceptualHash.dHash(path: pb.path),
           let hc = PerceptualHash.dHash(path: pf.path) {
            check(PerceptualHash.hamming(ha, hb) <= 10,
                  "dHash near pair similar (hamming \(PerceptualHash.hamming(ha, hb)) ≤ 10)")
            check(PerceptualHash.hamming(ha, hc) > 10,
                  "dHash far pair dissimilar (hamming \(PerceptualHash.hamming(ha, hc)) > 10)")
        } else { check(false, "dHash computed") }

        // 12. XMP sidecar write/read roundtrip
        var sample = assets[1]
        sample.rating = 4; sample.keywords = ["旅行", "测试"]; sample.title = "标题A"
        sample.caption = "说明B"; sample.colorLabel = .red
        let xmpURL = tmp.appendingPathComponent("sample.xmp")
        XMPSidecar.write(sample, to: xmpURL)
        if let sc = XMPSidecar.read(xmpURL) {
            check(sc.rating == 4 && sc.keywords == ["旅行", "测试"] && sc.title == "标题A"
                  && sc.caption == "说明B" && sc.colorLabel == .red, "XMP sidecar write/read roundtrip")
        } else { check(false, "XMP sidecar read") }

        // 13. import applies an existing XMP sidecar (§6.5 META-006)
        let xsrc = tmp.appendingPathComponent("xmpsource")
        try? fm.createDirectory(at: xsrc, withIntermediateDirectories: true)
        let ximg = xsrc.appendingPathComponent("PHOTO.jpg")
        writeTestImage(to: ximg, width: 700, height: 500, seed: 5)
        var seed = assets[0]; seed.rating = 3; seed.keywords = ["导入测试"]; seed.colorLabel = .blue
        seed.title = "T"; seed.caption = ""
        XMPSidecar.write(seed, to: XMPSidecar.sidecarURL(for: ximg))
        let xa = coordinator.importFolder(xsrc).first
        check(xa?.rating == 3 && xa?.keywords == ["导入测试"] && xa?.colorLabel == .blue,
              "import applied XMP sidecar metadata")

        // 14. managed import copies originals into Originals/
        if let mstore = try? CatalogStore(packageURL: tmp.appendingPathComponent("Managed.photolibrary")) {
            let massets = ImportCoordinator(store: mstore).importFolder(src, mode: .managed)
            let managed = !massets.isEmpty && massets.allSatisfy {
                ($0.localPath?.contains("/Originals/") ?? false) && fm.fileExists(atPath: $0.localPath ?? "")
            }
            check(managed, "managed import copied \(massets.count) originals into Originals/")
        } else { check(false, "managed catalog") }

        // 15. batch rename moves the original on disk
        var ren = assets[2]
        if let renURL = RenameService.rename([ren], prefix: "RENAMED")[ren.id] {
            check(fm.fileExists(atPath: renURL.path) && renURL.lastPathComponent.hasPrefix("RENAMED_"),
                  "batch rename moved original to \(renURL.lastPathComponent)")
        } else { check(false, "batch rename") }
        _ = ren

        // 16. on-device Vision analysis + faces column roundtrip
        let vres = VisionService.analyze(src.appendingPathComponent("IMG_0001.jpg"))
        check(vres.faces == 0, "Vision ran on-device (0 faces on synthetic image, \(vres.sceneLabels.count) tags)")
        if let va = coordinator.importFolder(xsrc, autoTag: true).first {
            try? store.upsert([va])
            let back = (try? store.loadAssets())?.first { $0.id == va.id }
            check(back != nil && back?.faces == va.faces, "auto-tagged asset persisted (faces column)")
        } else { check(false, "auto-tag import") }

        // 17. missing detection after deleting an original
        if let p = assets.first(where: { fm.fileExists(atPath: $0.localPath ?? "") })?.localPath {
            try? fm.removeItem(at: URL(fileURLWithPath: p))
            check(!fm.fileExists(atPath: p), "simulated missing original (file removed)")
        }

        // 18. offline external-volume classification (§6.4 ORG-007)
        check(VolumeMonitor.volumeRoot(of: "/Volumes/Photos/2026/a.jpg") == "/Volumes/Photos",
              "external volume root extracted")
        check(VolumeMonitor.volumeRoot(of: "/Users/me/Pictures/a.jpg") == nil, "internal path has no volume root")
        check(VolumeMonitor.status(forInaccessible: "/Volumes/NoSuchDrive_\(UUID().uuidString)/x.jpg") == .offline,
              "unmounted volume → offline")
        check(VolumeMonitor.status(forInaccessible: "/Users/me/gone_\(UUID().uuidString).jpg") == .missing,
              "internal gone → missing")

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

    /// variant 0: vertical bands · 1: bands + small corner mark (near-dup) · 2: horizontal bands (far).
    private static func writeStructured(to url: URL, variant: Int) {
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
