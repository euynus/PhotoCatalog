import XCTest
@testable import PhotoCatalog

/// A rescan aliases each known path once and trusts the result: every alias of an alias of a
/// path is already among the path's aliases, so aliasing the aliases again adds nothing.
final class PathIdentityClosureTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        // left as the temporary directory gives it (/var/folders, a link to /private/var/folders)
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-alias-closure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Real"),
                                                withIntermediateDirectories: true)
        try Data("photo".utf8).write(to: folder.appendingPathComponent("Real/photo.jpg"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("Link"),
                                                   withDestinationURL: folder.appendingPathComponent("Real"))
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func assertClosed(_ path: String, file: StaticString = #filePath, line: UInt = #line) {
        let aliases = PathIdentity.aliases(forPath: path)
        XCTAssertTrue(aliases.contains(path), "a path is its own alias", file: file, line: line)
        for alias in aliases {
            let again = PathIdentity.aliases(forPath: alias)
            XCTAssertTrue(again.isSubset(of: aliases),
                          "\(alias) adds \(again.subtracting(aliases)) to \(path)'s aliases", file: file, line: line)
        }
    }

    private var canonicalFolder: String {
        get throws {
            try XCTUnwrap(try folder.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath)
        }
    }

    func testSymlinkedFolder() throws {
        assertClosed(folder.appendingPathComponent("Link/photo.jpg").path)
        assertClosed(try canonicalFolder + "/Link/photo.jpg")
        let aliases = PathIdentity.aliases(forPath: folder.appendingPathComponent("Link/photo.jpg").path)
        XCTAssertTrue(aliases.contains(folder.appendingPathComponent("Real/photo.jpg").resolvingSymlinksInPath().path),
                      "the link's file is known by the folder it points to")
    }

    /// /var/folders and /private/var/folders, as /tmp and /private/tmp: one folder, two names.
    func testPrivateFirmlinkedPrefix() throws {
        let canonical = try canonicalFolder
        try XCTSkipIf(canonical == folder.path, "the temporary directory has no second name here")
        let plain = folder.appendingPathComponent("Real/photo.jpg").path
        let privatePath = canonical + "/Real/photo.jpg"
        assertClosed(plain)
        assertClosed(privatePath)
        XCTAssertEqual(PathIdentity.aliases(forPath: plain), PathIdentity.aliases(forPath: privatePath))
        for path in ["/tmp", "/private/tmp"] { assertClosed(path) }
    }

    func testDotDotComponent() throws {
        let path = folder.appendingPathComponent("Real").path + "/../Real/photo.jpg"
        assertClosed(path)
        XCTAssertTrue(PathIdentity.aliases(forPath: path).contains(folder.appendingPathComponent("Real/photo.jpg").path))
    }

    func testCaseMismatchOnCaseInsensitiveVolume() throws {
        let caseSensitive = try folder.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames ?? true
        try XCTSkipIf(caseSensitive, "the temporary directory's volume is case-sensitive")
        assertClosed(folder.appendingPathComponent("Real/PHOTO.JPG").path)
        assertClosed(try canonicalFolder + "/real/Photo.jpg")
        assertClosed(folder.appendingPathComponent("LINK/photo.jpg").path)
        XCTAssertTrue(PathIdentity.aliases(forPath: folder.appendingPathComponent("Real/PHOTO.JPG").path)
            .contains(try canonicalFolder + "/Real/photo.jpg"), "the name as it is on disk")
    }

    /// A removed photo's file that's gone has fewer names, still closed.
    func testMissingFile() throws {
        assertClosed(folder.appendingPathComponent("Real/gone.jpg").path)
        assertClosed(try canonicalFolder + "/Link/gone.jpg")
    }

    /// What the rescan relies on: aliasing a set of paths' aliases once more gives the same set.
    func testAliasingAliasesAgainAddsNothing() throws {
        let canonical = try canonicalFolder
        let paths = [folder.appendingPathComponent("Link/photo.jpg").path,
                     canonical + "/Real/photo.jpg",
                     folder.appendingPathComponent("Real").path + "/../Real/photo.jpg",
                     folder.appendingPathComponent("Real/gone.jpg").path]
        let once = paths.reduce(into: Set<String>()) { $0.formUnion(PathIdentity.aliases(forPath: $1)) }
        let twice = once.reduce(into: once) { $0.formUnion(PathIdentity.aliases(forPath: $1)) }
        XCTAssertEqual(twice, once)
    }
}
