import XCTest
@testable import PhotoCatalog

/// A card's file list and an import call the same files RAW: `FileScanner.isRaw` decides both.
final class RawExtensionAgreementTests: CatalogTestCase {
    /// Extensions outside FileScanner's own lists: RAWs only the system knows, and non-photos.
    private let otherExtensions = ["nrw", "3fr", "crw", "erf", "mos", "abc", "txt"]

    private var extensions: [String] {
        FileScanner.knownExtensions.sorted() + otherExtensions
    }

    func testCardListAgreesWithFileScanner() throws {
        let card = scratch.appendingPathComponent("Card/DCIM/100CANON")
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        for (index, ext) in extensions.enumerated() {
            // upper case on some, as cameras write them
            let name = String(format: "IMG_%04d.", index) + (index.isMultiple(of: 2) ? ext.uppercased() : ext)
            try Data().write(to: card.appendingPathComponent(name))
        }

        let listed = CardImportService.scan(card, catalog: CardImportService.CatalogIndex([]))

        let listedExtensions = Set(listed.map { $0.url.pathExtension.lowercased() })
        XCTAssertTrue(FileScanner.knownExtensions.isSubset(of: listedExtensions), "every known type is listed")
        XCTAssertFalse(listedExtensions.contains("txt"))
        for file in listed {
            let ext = file.url.pathExtension.lowercased()
            XCTAssertEqual(file.isRaw, FileScanner.isRaw(extension: ext), file.name)
        }
        XCTAssertTrue(listed.contains { $0.isRaw } && listed.contains { !$0.isRaw })
    }

    func testImportAgreesWithFileScanner() throws {
        let source = scratch.appendingPathComponent("Source")
        let sample = scratch.appendingPathComponent("sample.jpg")
        try makeTestJPEG(at: sample, shade: 4)
        let bytes = try Data(contentsOf: sample)
        // a still's bytes under each photo type's extension: Image I/O reads them by their contents
        let stills = extensions.filter { !Asset.videoTypes.contains($0.uppercased()) }
        var files: [URL] = []
        for (index, ext) in stills.enumerated() {
            let url = source.appendingPathComponent(String(format: "IMG_%04d.%@", index, ext))
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            var unique = bytes
            unique.append(contentsOf: [UInt8(index)])   // not exact duplicates of each other
            try unique.write(to: url)
            files.append(url)
        }
        let store = try CatalogStore(packageURL: scratch.appendingPathComponent("Library.photolibrary"))

        let imported = ImportCoordinator(store: store).importFiles(files, from: source)

        for asset in imported {
            let ext = (asset.filename as NSString).pathExtension.lowercased()
            XCTAssertEqual(asset.isRaw, FileScanner.isRaw(extension: ext), asset.filename)
        }
        let importedExtensions = Set(imported.map { ($0.filename as NSString).pathExtension.lowercased() })
        XCTAssertTrue(importedExtensions.isSuperset(of: ["jpg", "png", "cr2", "dng", "nef"]),
                      "imported \(importedExtensions.sorted())")
    }
}
