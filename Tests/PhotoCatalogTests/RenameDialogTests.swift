import XCTest
@testable import PhotoCatalog

final class RenameDialogTests: XCTestCase {
    /// Settings → Rename Selected is in a window of its own, so it can be clicked while a sheet
    /// is up over the library: it replaced that sheet (an export or print setup, half done).
    @MainActor
    func testRenameSelectedDoesNotReplaceAnOpenSheet() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-rename-sheet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = dir.appendingPathComponent("original.jpg")
        try Data("image".utf8).write(to: original)

        let app = AppState.selfCheckFixture()
        var asset = try XCTUnwrap(DemoData.assets.first)
        asset.filename = original.lastPathComponent
        asset.localPath = original.path
        asset.isDemo = false
        app.assets = [asset]
        app.select(Selection(type: .lib, id: "all", name: "Rename"))
        XCTAssertEqual(app.selectedIds, [asset.id])

        app.sheet = "print"
        app.showRenameSheet()
        XCTAssertEqual(app.sheet, "print", "the open dialog stays")
        XCTAssertFalse(app.canRenameOriginals, "Settings' Rename Selected is disabled meanwhile")

        app.sheet = nil
        app.showRenameSheet()
        XCTAssertEqual(app.sheet, "rename")
    }

    /// The start number's field took any number, though its stepper stops at 0.
    func testRenameStartNumberIsNeverNegative() {
        XCTAssertEqual(RenameSheet.clampedStart(-5), 0)
        XCTAssertEqual(RenameSheet.clampedStart(0), 0)
        XCTAssertEqual(RenameSheet.clampedStart(42), 42)
        XCTAssertEqual(RenameSheet.clampedStart(5_000_000), 999_999)
    }
}
