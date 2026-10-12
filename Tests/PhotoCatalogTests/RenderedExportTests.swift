import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoCatalog

/// The Export dialog's files: where they land and what they carry.
final class RenderedExportTests: CatalogTestCase {
    private static let exportKeys = ["pc_renderedExportSettings", "pc_renderedExportFolder"]
    private var savedExportDefaults: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        for key in Self.exportKeys {
            if let value = UserDefaults.standard.object(forKey: key) { savedExportDefaults[key] = value }
        }
    }

    override func tearDown() {
        for key in Self.exportKeys {
            if let value = savedExportDefaults[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        savedExportDefaults = [:]
        super.tearDown()
    }

    /// An 80×60 photo of `type` with `properties` (EXIF, GPS…).
    private func writeImage(at url: URL, type: UTType, shade: Int, properties: [CFString: Any] = [:]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let context = CGContext(data: nil, width: 80, height: 60, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw NSError(domain: "RenderedExportTests", code: 1)
        }
        let level = CGFloat(shade % 16) / 16
        context.setFillColor(CGColor(red: level, green: 1 - level, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw NSError(domain: "RenderedExportTests", code: 2)
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "RenderedExportTests", code: 3) }
    }

    /// A cataloged photo whose original is `url`.
    private func asset(_ id: String, at url: URL, date: Date = Date(timeIntervalSince1970: 1_700_000_000),
                       gps: (Double, Double) = (0, 0)) -> Asset {
        Asset(id: id, pid: 1, ori: "l", thumb: "", preview: "", filename: url.lastPathComponent,
              type: url.pathExtension.uppercased(), isRaw: false, folderId: "src-export",
              folderName: url.deletingLastPathComponent().lastPathComponent, date: date, width: 80, height: 60,
              orientation: 1, camera: "", lens: "", focal: 0, aperture: 0, shutter: "", iso: 0, colorSpace: "sRGB",
              fileMB: 0.01, rating: 0, flag: .none, keywords: [], title: "", caption: "",
              location: Asset.locationLabel(gps.0 == 0 && gps.1 == 0 ? nil : gps), gps: gps, status: .ready,
              importedAt: .now, localPath: url.path, isDemo: false)
    }

    /// Exports `ids` from `app` into `folder` with `settings` and waits for the export to end.
    @MainActor
    private func export(_ ids: Set<String>, from app: AppState, settings: ExportSettings, to folder: URL) async throws {
        app.selectedIds = ids
        app.primaryId = ids.sorted().first
        var settings = settings
        settings.revealInFinder = false
        app.startRenderedExport(settings: settings, folder: folder)
        XCTAssertNotNil(app.renderedExportProgress, "the export started")
        try await waitUntil("export finished", timeout: 30) { app.renderedExportProgress == nil }
    }

    /// Export to the photos' own folder under Overwrite, named `{original}`: a TIFF exported as
    /// JPEG took the name of the JPEG cataloged beside it (as a RAW does its paired JPEG), and a
    /// JPEG its own name, and both originals were replaced by the rendered copies.
    @MainActor
    func testOverwriteNeverReplacesACatalogOriginal() async throws {
        let folder = scratch.appendingPathComponent("Shoot", isDirectory: true)
        let tiff = folder.appendingPathComponent("IMG_1.tif")
        let companion = folder.appendingPathComponent("IMG_1.jpg")
        let jpeg = folder.appendingPathComponent("IMG_2.jpg")
        try writeImage(at: tiff, type: .tiff, shade: 2)
        try writeImage(at: companion, type: .jpeg, shade: 7)
        try writeImage(at: jpeg, type: .jpeg, shade: 11)
        let companionBytes = try Data(contentsOf: companion)
        let jpegBytes = try Data(contentsOf: jpeg)

        let app = AppState.selfCheckFixture()
        app.assets = [asset("tif", at: tiff), asset("companion", at: companion), asset("jpeg", at: jpeg)]
        var settings = ExportSettings()
        settings.format = .jpeg
        settings.fileNameTemplate = "{original}"
        settings.collision = .overwrite
        try await export(["tif", "jpeg"], from: app, settings: settings, to: folder)

        XCTAssertEqual(try Data(contentsOf: companion), companionBytes, "the JPEG cataloged beside the TIFF is untouched")
        XCTAssertEqual(try Data(contentsOf: jpeg), jpegBytes, "the exported photo's own original is untouched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("IMG_1-1.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("IMG_2-1.jpg").path))
        XCTAssertTrue(app.toastCenter.toasts.last?.message.contains("2 张与目录中的原件同名") ?? false,
                      "the export says why: \(app.toastCenter.toasts.last?.message ?? "no toast")")
    }
}
