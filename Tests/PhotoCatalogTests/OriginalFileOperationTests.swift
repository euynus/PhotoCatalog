import XCTest
@testable import PhotoCatalog

/// Photo → Move Originals / Copy Originals: files that share a name (a RAW and its JPEG) go
/// together under one name with their sidecar, and never beside another photo's.
final class OriginalFileOperationTests: CatalogTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(true, forKey: "pc_pairRawJpeg")
    }

    private var demo = DemoData.assets.makeIterator()

    /// A file at `folder/name` holding `text`, and a photo of it.
    private func photo(_ folder: URL, _ name: String, text: String? = nil) throws -> Asset {
        let url = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data((text ?? name).utf8).write(to: url)
        var asset = try XCTUnwrap(demo.next())
        asset.isDemo = false
        asset.localPath = url.path
        asset.filename = name
        return asset
    }

    private func file(_ folder: URL, _ name: String, _ text: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: folder.appendingPathComponent(name))
    }

    private func text(_ folder: URL, _ name: String) -> String? {
        (try? Data(contentsOf: folder.appendingPathComponent(name))).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// The destination already has another photo of the pair's name, with its sidecar: the
    /// pair moves under one new name with its own sidecar, whichever of the two comes first.
    func testMovingAPairOntoATakenNameKeepsThePairAndItsSidecar() throws {
        for jpegFirst in [false, true] {
            let source = scratch.appendingPathComponent("Source-\(jpegFirst)")
            let destination = scratch.appendingPathComponent("Destination-\(jpegFirst)")
            try file(destination, "IMG_0001.CR3", "their raw")
            try file(destination, "IMG_0001.xmp", "their sidecar")
            let raw = try photo(source, "IMG_0001.CR3")
            let jpeg = try photo(source, "IMG_0001.JPG")
            try file(source, "IMG_0001.xmp", "our sidecar")

            let report = OriginalFileOperationService.perform(.move, assets: jpegFirst ? [jpeg, raw] : [raw, jpeg],
                                                              destination: destination)
            XCTAssertEqual(report.moved, 2)
            XCTAssertEqual(report.updatedLocations[raw.id]?.lastPathComponent, "IMG_0001 (1).CR3")
            XCTAssertEqual(report.updatedLocations[jpeg.id]?.lastPathComponent, "IMG_0001 (1).JPG",
                           "the JPEG takes the RAW's new name (JPEG first: \(jpegFirst))")
            XCTAssertEqual(text(destination, "IMG_0001 (1).xmp"), "our sidecar")
            XCTAssertEqual(text(destination, "IMG_0001.CR3"), "their raw")
            XCTAssertEqual(text(destination, "IMG_0001.xmp"), "their sidecar")
            XCTAssertNil(text(destination, "IMG_0001.JPG"), "no JPEG beside their RAW")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: source.path), [], "nothing stays behind")
        }
    }

    /// Only a sidecar of that name is there (its photo elsewhere): the photo is numbered rather
    /// than moved beside it, and takes its own sidecar along.
    func testMovingOntoAStrangersSidecarNumbersThePhoto() throws {
        let source = scratch.appendingPathComponent("Source")
        let destination = scratch.appendingPathComponent("Destination")
        try file(destination, "IMG_0002.xmp", "their sidecar")
        let single = try photo(source, "IMG_0002.JPG")
        try file(source, "IMG_0002.xmp", "our sidecar")

        let report = OriginalFileOperationService.perform(.move, assets: [single], destination: destination)
        XCTAssertEqual(report.updatedLocations[single.id]?.lastPathComponent, "IMG_0002 (1).JPG")
        XCTAssertEqual(text(destination, "IMG_0002 (1).xmp"), "our sidecar")
        XCTAssertEqual(text(destination, "IMG_0002.xmp"), "their sidecar")
        XCTAssertNil(text(source, "IMG_0002.xmp"), "the sidecar went along")
    }

    /// Copying keeps the pair together the same way, and leaves the originals where they are.
    func testCopyingAPairOntoATakenNameKeepsThePair() throws {
        let source = scratch.appendingPathComponent("Source")
        let destination = scratch.appendingPathComponent("Destination")
        try file(destination, "IMG_0003.JPG", "their jpeg")
        let raw = try photo(source, "IMG_0003.CR3")
        let jpeg = try photo(source, "IMG_0003.JPG")
        try file(source, "IMG_0003.xmp", "our sidecar")

        let report = OriginalFileOperationService.perform(.copy, assets: [raw, jpeg], destination: destination)
        XCTAssertEqual(report.copied, 2)
        XCTAssertEqual(text(destination, "IMG_0003 (1).CR3"), "IMG_0003.CR3")
        XCTAssertEqual(text(destination, "IMG_0003 (1).JPG"), "IMG_0003.JPG")
        XCTAssertEqual(text(destination, "IMG_0003 (1).xmp"), "our sidecar")
        XCTAssertEqual(text(destination, "IMG_0003.JPG"), "their jpeg")
        XCTAssertNil(text(destination, "IMG_0003.CR3"))
        XCTAssertEqual(text(source, "IMG_0003.xmp"), "our sidecar")
    }

    /// A sidecar that can't be moved keeps its pair where it is: the move is taken back rather
    /// than leaving the photos without their metadata.
    func testPairWhoseSidecarCantMoveStaysPut() throws {
        let source = scratch.appendingPathComponent("Source")
        let destination = scratch.appendingPathComponent("Destination")
        let raw = try photo(source, "IMG_0005.CR3")
        let jpeg = try photo(source, "IMG_0005.JPG")
        try file(source, "IMG_0005.xmp", "our sidecar")
        let sidecar = source.appendingPathComponent("IMG_0005.xmp")
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: sidecar.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: sidecar.path) }

        let report = OriginalFileOperationService.perform(.move, assets: [raw, jpeg], destination: destination)
        XCTAssertEqual(report.moved, 0)
        XCTAssertEqual(report.failed, 2)
        XCTAssertEqual(report.updatedLocations, [:])
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: source.path)),
                       ["IMG_0005.CR3", "IMG_0005.JPG", "IMG_0005.xmp"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
    }

    /// A JPEG and a TIFF of one name, each with its sidecar, move together, and back again when
    /// the move is rolled back, each sidecar with its own photo.
    func testNamesakesMoveAndRollBackWithTheirOwnSidecars() throws {
        let source = scratch.appendingPathComponent("Source")
        let destination = scratch.appendingPathComponent("Destination")
        let jpeg = try photo(source, "IMG_0004.JPG")
        let tiff = try photo(source, "IMG_0004.TIF")
        try file(source, "IMG_0004.xmp", "jpeg sidecar")
        try file(source, "IMG_0004.TIF.xmp", "tiff sidecar")

        let report = OriginalFileOperationService.perform(.move, assets: [jpeg, tiff], destination: destination)
        XCTAssertEqual(report.moved, 2)
        XCTAssertEqual(text(destination, "IMG_0004.xmp"), "jpeg sidecar")
        XCTAssertEqual(text(destination, "IMG_0004.TIF.xmp"), "tiff sidecar")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: source.path), [])

        XCTAssertEqual(OriginalFileOperationService.rollBackMoves(report.updatedLocations, originals: [jpeg, tiff]), 2)
        XCTAssertEqual(text(source, "IMG_0004.xmp"), "jpeg sidecar")
        XCTAssertEqual(text(source, "IMG_0004.TIF.xmp"), "tiff sidecar")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
    }
}
