import XCTest
@testable import PhotoCatalog

/// Source folders as the catalog keeps them: their place in the sidebar and whether they are
/// watched (referenced) or only where photos were copied from (managed).
final class SourceRootTests: CatalogTestCase {
    /// A folder imported again keeps its place in the sidebar, and stays referenced — watched —
    /// when the second import copies its photos instead.
    func testImportingAFolderAgainKeepsItsPlaceAndMode() throws {
        let store = try CatalogStore(packageURL: scratch.appendingPathComponent("Library.photolibrary"))
        try store.addSourceRoot(id: "first", displayName: "First", path: "/Photos/First", bookmark: nil)
        try store.addSourceRoot(id: "second", displayName: "Second", path: "/Photos/Second", bookmark: nil)
        // imported months apart
        try store.db.run("UPDATE source_roots SET created_at='2025-01-01T00:00:00Z' WHERE id='first';")
        try store.db.run("UPDATE source_roots SET created_at='2025-06-01T00:00:00Z' WHERE id='second';")

        try store.addSourceRoot(id: "first", displayName: "First", path: "/Photos/First",
                                bookmark: Data("new access".utf8), mode: .managed)

        let roots = try store.loadSourceRoots()
        XCTAssertEqual(roots.map(\.id), ["first", "second"], "the folder keeps its place")
        let first = try XCTUnwrap(roots.first { $0.id == "first" })
        XCTAssertEqual(first.managementMode, ImportMode.referenced.rawValue, "and is still watched")
        XCTAssertEqual(first.bookmarkData, Data("new access".utf8), "with the access the import brought")
    }

    /// A folder whose photos were copied, imported again in place: it now holds photos in place,
    /// which need it watched and opened through its bookmark.
    func testFolderImportedInPlaceAfterACopyImportBecomesReferenced() throws {
        let store = try CatalogStore(packageURL: scratch.appendingPathComponent("Library.photolibrary"))
        try store.addSourceRoot(id: "card", displayName: "Card", path: "/Volumes/Card", bookmark: nil, mode: .managed)

        try store.addSourceRoot(id: "card", displayName: "Card", path: "/Volumes/Card", bookmark: nil)

        XCTAssertEqual(try store.loadSourceRoots().map(\.managementMode), [ImportMode.referenced.rawValue])
    }

    /// Import Photo Folder… in managed mode on a folder already imported in place: its photos
    /// still show as added in place, and it is still watched after a relaunch.
    @MainActor
    func testManagedImportOfAReferencedFolderLeavesItReferenced() async throws {
        let folder = scratch.appendingPathComponent("Folder")
        try makeTestJPEG(at: folder.appendingPathComponent("a.jpg"), shade: 1)
        let package = scratch.appendingPathComponent("Library.photolibrary")
        let store = try CatalogStore(packageURL: package)
        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))
        app.importMode = .referenced
        app.importFolder(folder)
        try await waitUntil("referenced import finished") { !app.importing }
        let inPlace = try XCTUnwrap(app.assets.first { !$0.isDemo && $0.filename == "a.jpg" })

        try makeTestJPEG(at: folder.appendingPathComponent("b.jpg"), shade: 2)
        app.importMode = .managed
        app.importFolder(folder)
        try await waitUntil("managed import finished") { !app.importing }

        XCTAssertEqual(app.managementDisplayText(for: inPlace), "原位添加", "the photo in place isn't shown as copied")
        XCTAssertEqual(try store.loadSourceRoots().map(\.managementMode), [ImportMode.referenced.rawValue],
                       "the folder is watched after a relaunch")
    }
}
