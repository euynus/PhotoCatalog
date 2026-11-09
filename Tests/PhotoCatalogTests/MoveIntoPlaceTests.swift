import Foundation
import XCTest
@testable import PhotoCatalog

/// A finished temporary file takes its target's place, and never outlives a move that failed.
final class MoveIntoPlaceTests: XCTestCase {
    private var folder: URL!
    private let fm = FileManager.default

    override func setUp() {
        super.setUp()
        folder = fm.temporaryDirectory.appendingPathComponent("pc-move-into-place-\(UUID().uuidString)")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let folder { try? fm.removeItem(at: folder) }
        super.tearDown()
    }

    private func write(_ text: String, _ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func contents(_ url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    /// Hidden files left in the folder: temporary and partial ones.
    private func leftovers() throws -> [String] {
        try fm.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".") }
    }

    func testMovesToANewTarget() throws {
        let temporary = try write("new", ".tmp-1-a.jpg")
        let target = folder.appendingPathComponent("a.jpg")

        try fm.moveIntoPlace(temporary, at: target)

        XCTAssertEqual(try contents(target), "new")
        XCTAssertFalse(fm.fileExists(atPath: temporary.path))
    }

    func testReplacesAnExistingTarget() throws {
        let target = try write("old", "a.jpg")
        let temporary = try write("new", ".tmp-2-a.jpg")

        try fm.moveIntoPlace(temporary, at: target)

        XCTAssertEqual(try contents(target), "new")
        XCTAssertFalse(fm.fileExists(atPath: temporary.path))
        XCTAssertEqual(try leftovers(), [])
    }

    func testAFailedMoveRemovesTheTemporaryFile() throws {
        let temporary = try write("new", ".tmp-3-a.jpg")
        let target = folder.appendingPathComponent("missing folder/a.jpg")

        XCTAssertThrowsError(try fm.moveIntoPlace(temporary, at: target))

        XCTAssertFalse(fm.fileExists(atPath: temporary.path))
        XCTAssertFalse(fm.fileExists(atPath: target.path))
    }

    /// Export's copy: through a partial file that's gone afterwards, whether the copy worked,
    /// replaced a file, or failed (leaving the earlier file as it was).
    func testPlaceCopyLeavesNoPartialFile() throws {
        let source = try write("original", "source.jpg")
        let target = folder.appendingPathComponent("copy.jpg")

        try ExportService.placeCopy(of: source, at: target)
        XCTAssertEqual(try contents(target), "original")

        try Data("changed".utf8).write(to: source)
        try ExportService.placeCopy(of: source, at: target)
        XCTAssertEqual(try contents(target), "changed")

        XCTAssertThrowsError(try ExportService.placeCopy(of: folder.appendingPathComponent("gone.jpg"), at: target))
        XCTAssertEqual(try contents(target), "changed")
        XCTAssertEqual(try leftovers(), [])
    }
}
