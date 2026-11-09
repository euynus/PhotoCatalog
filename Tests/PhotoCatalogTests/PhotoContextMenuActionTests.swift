import XCTest
@testable import PhotoCatalog

/// The photo's right-click menu is built for every visible cell, so it reads no app state and
/// can't disable its items the way the menu bar does: its actions check for themselves, and say
/// why when they can't go ahead.
final class PhotoContextMenuActionTests: CatalogTestCase {
    /// A catalog with one imported photo, `a.jpg`, selected.
    @MainActor
    private func openCatalogWithSelectedPhoto() throws -> AppState {
        let (_, package, asset, _) = try importPhoto("a.jpg", shade: 3)
        let app = openCatalog(package)
        app.prepareContextSelection(asset.id)
        return app
    }

    /// 增强… while photos are still being enhanced opened a dialog whose Enhance did nothing.
    @MainActor
    func testEnhanceWaitsForTheRunInProgress() throws {
        let app = try openCatalogWithSelectedPhoto()
        app.enhanceProgress = (done: 0, total: 3, fraction: 0.5)
        app.showEnhance()
        XCTAssertNil(app.sheet, "no second Enhance dialog while one runs")
        XCTAssertEqual(app.toastCenter.toasts.last?.message, "正在增强照片，请等它完成")

        app.enhanceProgress = nil
        app.showEnhance()
        XCTAssertEqual(app.sheet, AIModels.isAvailable(.denoise) && AIModels.isAvailable(.superResolution)
                       ? "enhance" : nil, "once it's done, the dialog opens")
    }
}
