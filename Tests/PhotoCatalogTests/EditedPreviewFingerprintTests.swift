import XCTest
@testable import PhotoCatalog

/// A developed preview is rendered to the file it's looked up by: the photo's remembered settings
/// fingerprint, even when the settings it now has are equal to those it was made from but would
/// format otherwise (0 and -0).
final class EditedPreviewFingerprintTests: CatalogTestCase {
    @MainActor
    func testTheRenderLandsWhereTheRememberedFingerprintNamesIt() async throws {
        let (_, package, imported, _) = try importPhoto("a.jpg", shade: 5)
        let app = openCatalog(package)
        let asset = try XCTUnwrap(app.assets.first { $0.id == imported.id })
        var settings = DevelopSettings()
        settings.contrast = 20
        settings.exposure = 0
        app.developSettings[asset.id] = settings
        let remembered = try XCTUnwrap(app.developFingerprint(for: asset.id))
        settings.exposure = -0.0
        app.developSettings[asset.id] = settings
        XCTAssertEqual(app.developFingerprint(for: asset.id), remembered, "equal settings keep the remembered fingerprint")
        XCTAssertNotEqual(settings.fingerprint, remembered, "the probe: -0 formats otherwise")

        let thumbnails = try XCTUnwrap(app.coordinator).thumbnails
        let expected = thumbnails.editedCachePath(assetId: asset.id, kind: .preview2048, fingerprint: remembered).path
        let shown = await app.visibleImageSource(for: asset, requestedSource: asset.preview, kind: .preview2048)
        XCTAssertEqual(shown, expected, "the render was written under another name than the one looked up")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected))
        XCTAssertEqual(app.verifiedImageSource(for: asset, requestedSource: asset.preview, kind: .preview2048), expected,
                       "the next look finds the render without making it again")
    }
}
