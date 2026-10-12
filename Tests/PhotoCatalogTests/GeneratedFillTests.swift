import XCTest
import ImageIO
@testable import PhotoCatalog

/// Generative fills (smart remove) follow their photo's file when the app moves, renames or
/// relinks it, so they aren't made again and a full backup finds them.
final class GeneratedFillTests: CatalogTestCase {
    private var fills: URL { scratch.appendingPathComponent("Fills") }

    /// A develop setting with one remove spot, made distinct by `x`.
    private func removal(at x: CGFloat) -> DevelopSettings {
        var settings = DevelopSettings()
        var stroke = BrushStroke()
        stroke.append(CGPoint(x: x, y: 0.5))
        var spot = SpotRemoval(target: CGPoint(x: x, y: 0.5), source: CGPoint(x: x, y: 0.5), radius: 0.05)
        spot.mode = .remove
        spot.strokes = [stroke]
        settings.spots = [spot]
        return settings
    }

    /// A stored fill, as GenerativeFill writes one: a square PNG naming where it goes.
    private func writeFill(for settings: DevelopSettings, of photo: URL) throws {
        try FileManager.default.createDirectory(at: fills, withIntermediateDirectories: true)
        let url = fills.appendingPathComponent(GenerativeFill.key(index: 0, settings: settings, url: photo) + ".png")
        let side = GenerativeFill.side
        let context = try XCTUnwrap(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), [
            kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription: "0.25,0.25,0.5,0.5"],
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func fillExists(for settings: DevelopSettings, of photo: URL) -> Bool {
        FileManager.default.fileExists(atPath: fills.appendingPathComponent(
            GenerativeFill.key(index: 0, settings: settings, url: photo) + ".png").path)
    }

    /// A photo with smart-remove fills in its current edit, its history and a snapshot is
    /// renamed by the app: its fills go with it, and a full backup of the catalog succeeds.
    @MainActor
    func testFullBackupAfterARenamedPhotoKeepsItsFills() async throws {
        let source = scratch.appendingPathComponent("Source")
        let photo = source.appendingPathComponent("IMG_0001.JPG")
        try makeTestJPEG(at: photo, shade: 1)
        let package = scratch.appendingPathComponent("Library.photolibrary")
        let store = try CatalogStore(packageURL: package)
        try store.addSourceRoot(id: "source-1", displayName: "Source", path: source.path, bookmark: nil)
        let asset = try XCTUnwrap(ImportCoordinator(store: store)
            .importFiles([photo], from: source, sourceRootId: "source-1", folderName: "Source").first)
        try store.upsert([asset])
        let current = removal(at: 0.5), earlier = removal(at: 0.6), saved = removal(at: 0.7)
        try store.saveDevelopSettings([asset.id: current])
        try store.appendDevelopHistory([asset.id: ("Remove", earlier)])
        try store.saveDevelopSnapshot(DevelopSnapshot(id: "snap", name: "Saved", date: Date(), settings: saved),
                                      for: asset.id)
        for settings in [current, earlier, saved] { try writeFill(for: settings, of: photo) }

        let app = AppState()
        app.onboarded = true
        app.generatedFillFolder = fills
        XCTAssertTrue(app.openCatalog(at: package))
        try await waitUntil("originals checked") { !app.isCheckingOriginals }
        let renamed = source.appendingPathComponent("Holiday 001.JPG")
        try FileManager.default.moveItem(at: photo, to: renamed)
        XCTAssertTrue(app.applyMovedOriginalLocations([asset.id: renamed]))
        // carried off the main thread
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, ![current, earlier, saved].allSatisfy({ fillExists(for: $0, of: renamed) }) {
            try await Task.sleep(for: .milliseconds(20))
        }

        let luts = scratch.appendingPathComponent("LUTs")
        try FileManager.default.createDirectory(at: luts, withIntermediateDirectories: true)
        let report = try FullBackupService.backup(store, to: scratch.appendingPathComponent("Backup.photobackup"),
                                                  externalLUTDirectory: luts, externalFillDirectory: fills)
        XCTAssertEqual(report.fillCount, 3)
    }

    /// Carrying fills moves each one stored for the old path to the new one, and leaves fills of
    /// other photos alone.
    func testCarryMovesTheFillsMadeForTheOldPath() throws {
        let photo = scratch.appendingPathComponent("Source/IMG_0001.JPG")
        let other = scratch.appendingPathComponent("Source/IMG_0002.JPG")
        try makeTestJPEG(at: photo, shade: 1)
        try makeTestJPEG(at: other, shade: 2)
        let settings = removal(at: 0.5)
        try writeFill(for: settings, of: photo)
        try writeFill(for: settings, of: other)
        let modified = try photo.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let moved = scratch.appendingPathComponent("Elsewhere/Renamed.JPG")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: photo, to: moved)

        XCTAssertEqual(GenerativeFill.carry([settings], from: photo.path, modified: [modified], to: moved, in: fills), 1)
        XCTAssertTrue(fillExists(for: settings, of: moved))
        XCTAssertTrue(fillExists(for: settings, of: other))
    }
}
