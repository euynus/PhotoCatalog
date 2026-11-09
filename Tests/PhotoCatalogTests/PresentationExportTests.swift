import XCTest
@testable import PhotoCatalog

/// What slideshow videos, web galleries and books are made from.
final class PresentationExportTests: CatalogTestCase {
    private func asset(_ id: String, original: URL, preview: URL? = nil, status: AssetStatus = .ready,
                       title: String = "", caption: String = "") -> Asset {
        .smallPhoto(id, filename: original.lastPathComponent, type: "JPG", folderId: "src-presentation",
                    folderName: "Photos", date: Date(timeIntervalSince1970: 1_700_000_000), localPath: original.path,
                    preview: preview?.path ?? "", status: status, title: title, caption: caption, isDemo: false)
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

    /// The book dialog took its photos captioned as the stored setting said when it opened, so
    /// its preview kept those captions whatever the caption picker was set to.
    @MainActor
    func testTheBookPreviewCaptionsPhotosAsThePickerSays() throws {
        let first = scratch.appendingPathComponent("Photos/first.jpg")
        let second = scratch.appendingPathComponent("Photos/second.jpg")
        let app = AppState.selfCheckFixture()
        app.assets = [asset("first", original: first, preview: first, title: "Harbor", caption: "Boats at dawn"),
                      asset("second", original: second, preview: second, title: "Hill", caption: "Fog")]
        app.select(Selection(type: .lib, id: "all", name: "Book"))
        app.selectedIds = ["first", "second"]

        var stored = BookSettings()
        stored.caption = .none
        // as the main window opens it
        let sheet = BookSheet(settings: stored, items: app.bookItems(caption: stored.caption))
        var picked = stored
        for (caption, expected) in [(BookSettings.Caption.filename, ["first.jpg", "second.jpg"]),
                                    (.title, ["Harbor", "Hill"]), (.caption, ["Boats at dawn", "Fog"]),
                                    (.none, ["", ""])] {
            picked.caption = caption
            XCTAssertEqual(Set(sheet.previewItems(for: picked).map(\.caption)), Set(expected),
                           "the preview's captions follow the picker (\(caption))")
        }
    }
}
