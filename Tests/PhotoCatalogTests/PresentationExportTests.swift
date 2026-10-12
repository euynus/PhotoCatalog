import XCTest
@testable import PhotoCatalog

/// What slideshow videos, web galleries and books are made from.
final class PresentationExportTests: CatalogTestCase {
    private func asset(_ id: String, original: URL, preview: URL? = nil, status: AssetStatus = .ready,
                       title: String = "", caption: String = "") -> Asset {
        Asset(id: id, pid: 1, ori: "l", thumb: "", preview: preview?.path ?? "", filename: original.lastPathComponent,
              type: "JPG", isRaw: false, folderId: "src-presentation", folderName: "Photos",
              date: Date(timeIntervalSince1970: 1_700_000_000), width: 80, height: 60, orientation: 1, camera: "",
              lens: "", focal: 0, aperture: 0, shutter: "", iso: 0, colorSpace: "sRGB", fileMB: 0.01, rating: 0,
              flag: .none, keywords: [], title: title, caption: caption, location: "", gps: (0, 0), status: status,
              importedAt: .now, localPath: original.path, isDemo: false)
    }

    /// A photo whose original is offline was rendered from its 2048 px preview, though a book,
    /// gallery or video is documented as made from the originals.
    @MainActor
    func testAPhotoWhoseOriginalIsOfflineIsNotRenderedFromItsPreview() throws {
        let online = scratch.appendingPathComponent("Photos/online.jpg")
        let offline = scratch.appendingPathComponent("Card/offline.jpg")
        let preview = scratch.appendingPathComponent("Cache/offline-preview.jpg")
        try makeTestJPEG(at: online, shade: 1)
        try makeTestJPEG(at: preview, shade: 2)
        let app = AppState.selfCheckFixture()
        let present = asset("online", original: online, preview: preview)
        let away = asset("offline", original: offline, preview: preview, status: .offline)
        app.assets = [present, away]

        XCTAssertEqual(app.renderItem(for: present)?.sourcePath, online.path)
        XCTAssertNil(app.renderItem(for: away)?.sourcePath, "an offline photo isn't rendered from its preview")

        app.select(Selection(type: .lib, id: "all", name: "Presentation"))
        app.selectedIds = ["online", "offline"]
        XCTAssertEqual(Set(app.presentationAssets().map(\.id)), ["online", "offline"])
        XCTAssertEqual(app.bookItems(caption: .none).map(\.item.sourcePath), [online.path],
                       "a book leaves the offline photo out")
    }
}
