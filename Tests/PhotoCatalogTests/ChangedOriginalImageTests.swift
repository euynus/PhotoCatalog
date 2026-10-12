import AppKit
import XCTest
@testable import PhotoCatalog

/// A photo saved over in another app (an external editor) shows its new pixels once a rescan has
/// read it again: its cached thumbnail and preview are made again at the same paths, so what was
/// decoded or rendered from the old ones must not be reused.
final class ChangedOriginalImageTests: CatalogTestCase {
    /// A watched source with one imported photo, `a.jpg`, opened without background maintenance.
    @MainActor
    private func openCatalogWithPhoto() throws -> (AppState, Asset, URL) {
        let source = scratch.appendingPathComponent("Source")
        let package = scratch.appendingPathComponent("Library.photolibrary")
        let photo = source.appendingPathComponent("a.jpg")
        try makeTestJPEG(at: photo, shade: 3)
        let store = try CatalogStore(packageURL: package)
        try store.addSourceRoot(id: "source-1", displayName: "Source", path: source.path, bookmark: nil)
        let asset = try XCTUnwrap(ImportCoordinator(store: store)
            .importFiles([photo], from: source, sourceRootId: "source-1", folderName: "Source").first)
        try store.upsert([asset])
        let app = AppState()
        app.onboarded = true
        app.runsBackgroundMaintenance = false
        XCTAssertTrue(app.openCatalog(at: package))
        return (app, try XCTUnwrap(app.assets.first { $0.id == asset.id }), photo)
    }

    /// Other pixels and a later date, as an editor's save leaves the file.
    private func saveOver(_ photo: URL) throws {
        try makeTestJPEG(at: photo, shade: 12)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(120)],
                                              ofItemAtPath: photo.path)
    }

    /// The image's average red, 0…1.
    private func red(_ image: NSImage) -> Double {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return -1 }
        context.interpolationQuality = .medium
        context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Double(pixel[0]) / 255
    }

    @MainActor
    func testGridShowsAnOriginalSavedOverElsewhere() async throws {
        let (app, asset, photo) = try openCatalogWithPhoto()
        let loader = ThumbLoader()
        let thumb = await app.visibleImageSource(for: asset, requestedSource: asset.thumb, kind: .thumb512)
        loader.load(thumb, maxPixel: 512, cacheGeneration: app.thumbnailCacheGeneration, version: asset.imageVersion)
        try await waitUntil("the thumbnail decoded") { loader.image != nil }
        let old = try XCTUnwrap(loader.image)

        try saveOver(photo)
        try await rescanToCompletion(app)
        let changed = try XCTUnwrap(app.assets.first { $0.id == asset.id })
        XCTAssertNotEqual(changed.imageVersion, asset.imageVersion, "the rescan read the changed file")
        let remade = await app.visibleImageSource(for: changed, requestedSource: changed.thumb, kind: .thumb512)
        XCTAssertEqual(remade, thumb, "the thumbnail was made again where it was")

        // as the grid cell does once the photo it shows has changed
        loader.load(remade, maxPixel: 512, cacheGeneration: app.thumbnailCacheGeneration, version: changed.imageVersion)
        try await waitUntil("the new thumbnail decoded") { loader.image != nil && loader.image !== old }
        let new = try XCTUnwrap(loader.image)
        XCTAssertGreaterThan(red(new), red(old) + 0.2, "the grid shows the saved pixels")
    }

    @MainActor
    func testAdjustedPhotoIsRenderedAgainFromAnOriginalSavedOverElsewhere() async throws {
        let (app, asset, photo) = try openCatalogWithPhoto()
        var settings = DevelopSettings()
        settings.exposure = 0.5
        app.developSettings[asset.id] = settings
        let before = await app.visibleImageSource(for: asset, requestedSource: asset.thumb, kind: .thumb512)
        XCTAssertTrue(before.contains("/Edited/"), "an adjusted photo shows its developed rendering")
        let rendered = try Data(contentsOf: URL(fileURLWithPath: before))

        try saveOver(photo)
        try await rescanToCompletion(app)
        let changed = try XCTUnwrap(app.assets.first { $0.id == asset.id })
        let after = await app.visibleImageSource(for: changed, requestedSource: changed.thumb, kind: .thumb512)
        XCTAssertTrue(after.contains("/Edited/"))
        XCTAssertNotEqual(try Data(contentsOf: URL(fileURLWithPath: after)), rendered,
                          "the adjustments are rendered again from the saved original")
    }
}
