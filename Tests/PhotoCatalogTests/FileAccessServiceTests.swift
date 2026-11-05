import XCTest
@testable import PhotoCatalog

/// Places the user chose, remembered for later launches: the folders originals were relocated
/// or moved to are reached all together when a catalog opens, so no other place pushes them out.
@MainActor
final class FileAccessServiceTests: XCTestCase {
    private static let key = "pc_rememberedLocations"
    private var saved: Any?
    private var root: URL!

    override func setUp() {
        super.setUp()
        saved = UserDefaults.app.object(forKey: Self.key)
        UserDefaults.app.removeObject(forKey: Self.key)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pc-file-access-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let saved { UserDefaults.app.set(saved, forKey: Self.key) } else { UserDefaults.app.removeObject(forKey: Self.key) }
        if let root { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    private func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testOriginalsFolderOutlastsManyPlaces() throws {
        let originals = try folder("Originals")
        FileAccessService.remember(originals, for: .originals)
        XCTAssertEqual(FileAccessService.rememberedPurpose(of: originals), .originals, "no bookmark was made")
        for index in 0..<70 { FileAccessService.remember(try folder("Export \(index)")) }

        XCTAssertEqual(FileAccessService.rememberedPurpose(of: originals), .originals,
                       "export folders pushed out the folder originals were moved to")
        XCTAssertNil(FileAccessService.rememberedPurpose(of: root.appendingPathComponent("Export 0")),
                     "places are still kept to a limit")
    }

    func testOriginalsFolderChosenAgainAsAPlaceStaysOriginals() throws {
        let originals = try folder("Moved")
        FileAccessService.remember(originals, for: .originals)
        FileAccessService.remember(originals)

        XCTAssertEqual(FileAccessService.rememberedPurpose(of: originals), .originals,
                       "choosing the folder for an export made it a plain place, out of reachOriginals()")
    }

    func testForgettingAPlaceKeepsOriginals() throws {
        let originals = try folder("Relocated")
        FileAccessService.remember(originals, for: .originals)
        FileAccessService.forget(originals)

        XCTAssertEqual(FileAccessService.rememberedPurpose(of: originals), .originals)
    }
}
