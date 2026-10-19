import XCTest
@testable import PhotoCatalog

/// Exporting originals and previews over files already there.
final class ExportServiceTests: CatalogTestCase {
    private let fm = FileManager.default

    private func photo(at url: URL, contents: String) throws -> Asset {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        var asset = DemoData.assets[0]
        asset.isDemo = false
        asset.localPath = url.path
        asset.filename = url.lastPathComponent
        return asset
    }

    /// A file that can't be read, until the test ends.
    private func makeUnreadable(_ url: URL) throws {
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
    }

    /// Overwrite: an original that can't be copied leaves the earlier export of it as it was.
    func testOverwriteKeepsThePreviousExportWhenTheCopyFails() throws {
        let source = scratch.appendingPathComponent("Source/IMG_0001.JPG")
        let asset = try photo(at: source, contents: "new")
        let out = scratch.appendingPathComponent("Export")
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        let previous = out.appendingPathComponent("IMG_0001.JPG")
        try Data("previous export".utf8).write(to: previous)
        try makeUnreadable(source)

        let report = ExportService.copyOriginals([asset], to: out, conflict: .overwrite)

        XCTAssertEqual(report.failed, 1)
        XCTAssertEqual(report.copied, 0)
        XCTAssertEqual(try? Data(contentsOf: previous), Data("previous export".utf8), "the earlier export survives")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: out.path), ["IMG_0001.JPG"], "no partial copy is left")
    }

    /// Overwrite: the earlier export is replaced by the original, which keeps its file date.
    func testOverwriteReplacesThePreviousExportKeepingTheOriginalsDate() throws {
        let source = scratch.appendingPathComponent("Source/IMG_0001.JPG")
        let asset = try photo(at: source, contents: "new")
        let taken = Date(timeIntervalSince1970: 1_000_000_000)
        try fm.setAttributes([.modificationDate: taken], ofItemAtPath: source.path)
        let out = scratch.appendingPathComponent("Export")
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        let previous = out.appendingPathComponent("IMG_0001.JPG")
        try Data("previous export".utf8).write(to: previous)

        let report = ExportService.copyOriginals([asset], to: out, conflict: .overwrite)

        XCTAssertEqual(report.copied, 1)
        XCTAssertEqual(try Data(contentsOf: previous), Data("new".utf8))
        XCTAssertEqual(try fm.attributesOfItem(atPath: previous.path)[.modificationDate] as? Date, taken)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: out.path), ["IMG_0001.JPG"])
    }

    /// Overwrite: a preview that can't be copied leaves the earlier exported preview as it was.
    func testPreviewOverwriteKeepsThePreviousExportWhenTheCopyFails() throws {
        let cached = scratch.appendingPathComponent("Cache/preview.jpg")
        try fm.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("new preview".utf8).write(to: cached)
        let asset = Asset(id: "preview-export", pid: 0, ori: "l", thumb: "", preview: cached.path,
                          filename: "IMG_0002.JPG", type: "JPG", isRaw: false, folderId: "f", folderName: "F",
                          date: .now, width: 80, height: 60, orientation: 1, camera: "", lens: "", focal: 0,
                          aperture: 0, shutter: "", iso: 0, colorSpace: "sRGB", fileMB: 0, rating: 0,
                          flag: .none, keywords: [], title: "", caption: "", location: "", gps: (0, 0),
                          status: .ready, importedAt: .now, isDemo: false)
        let out = scratch.appendingPathComponent("Export")
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        let previous = out.appendingPathComponent("IMG_0002-preview.jpg")
        try Data("previous preview".utf8).write(to: previous)
        try makeUnreadable(cached)

        let report = ExportService.exportPreviews([asset], to: out, conflict: .overwrite)

        XCTAssertEqual(report.failed, 1)
        XCTAssertEqual(report.copied, 0)
        XCTAssertEqual(try? Data(contentsOf: previous), Data("previous preview".utf8), "the earlier export survives")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: out.path), ["IMG_0002-preview.jpg"])

        // once it can be read, the new preview replaces the old
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: cached.path)
        XCTAssertEqual(ExportService.exportPreviews([asset], to: out, conflict: .overwrite).copied, 1)
        XCTAssertEqual(try Data(contentsOf: previous), Data("new preview".utf8))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: out.path), ["IMG_0002-preview.jpg"])
    }
}
