import XCTest
@testable import PhotoCatalog

/// Grid and filmstrip cells skip their body when equal, so equal must mean the cell would show
/// the same thing: a photo saved over elsewhere and read again keeps its thumbnail path, and only
/// its file's date and hash (`Asset.imageVersion`) tell its tile to decode the new pixels.
final class PhotoCellEquatableTests: XCTestCase {
    private func gridCell(_ asset: Asset) -> GridCell {
        GridCell(asset: asset, size: 160, selected: false, isPrimary: false, showInfo: true,
                 stackCount: nil, stackCollapsed: false, pairLabel: nil, isEdited: false,
                 inQuickCollection: false, onToggleStack: {})
    }

    /// The photo after a rescan read its file saved over in another app.
    private func savedOver(_ asset: Asset) -> Asset {
        var changed = asset
        changed.fileModifiedAt = (asset.fileModifiedAt ?? Date(timeIntervalSince1970: 0)).addingTimeInterval(120)
        changed.quickHash = "changed-\(asset.quickHash ?? "")"
        return changed
    }

    @MainActor
    func testGridCellOfAPhotoSavedOverElsewhereIsAnother() {
        let asset = DemoData.assets[0]
        let changed = savedOver(asset)
        XCTAssertEqual(changed.thumb, asset.thumb, "the thumbnail is made again at the same path")
        XCTAssertNotEqual(changed.imageVersion, asset.imageVersion)
        XCTAssertTrue(gridCell(asset) == gridCell(asset))
        XCTAssertFalse(gridCell(asset) == gridCell(changed), "the tile loads the new thumbnail")
    }

    @MainActor
    func testFilmstripCellOfAPhotoSavedOverElsewhereIsAnother() {
        let asset = DemoData.assets[0]
        let changed = savedOver(asset)
        XCTAssertTrue(FilmstripCell(asset: asset, isPrimary: false, select: {})
                      == FilmstripCell(asset: asset, isPrimary: false, select: {}))
        XCTAssertFalse(FilmstripCell(asset: asset, isPrimary: false, select: {})
                       == FilmstripCell(asset: changed, isPrimary: false, select: {}),
                       "the filmstrip loads the new thumbnail")
    }
}
