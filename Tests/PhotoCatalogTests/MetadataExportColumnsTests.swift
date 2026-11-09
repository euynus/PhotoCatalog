import Foundation
import XCTest
@testable import PhotoCatalog

/// The metadata CSV's header and each row's values come from one list of columns, and the
/// files stay as they were: same columns in the same order, each value written the same way.
final class MetadataExportColumnsTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-metadata-columns-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
        super.tearDown()
    }

    /// The header as it was written out before the columns were listed with their values.
    private let oldHeader = [
        "assetId", "filename", "rating", "flag", "colorLabel", "keywords", "title", "caption",
        "author", "copyright", "makerNotes", "project", "client",
        "captureDate", "fileModifiedAt", "fileCreatedAt", "hasICCProfile",
        "gpsLatitude", "gpsLongitude", "gpsAltitude", "camera", "lens", "originalPath",
    ].joined(separator: ",")

    private func asset(id: String, filename: String, camera: String = "", lens: String = "") -> Asset {
        Asset(id: id, pid: 1, ori: "l", thumb: "", preview: "", filename: filename, type: "JPG", isRaw: false,
              folderId: "f", folderName: "F", date: Date(timeIntervalSince1970: 1_767_323_045), width: 4000,
              height: 3000, orientation: 1, camera: camera, lens: lens, focal: 0, aperture: 0, shutter: "", iso: 0,
              colorSpace: "sRGB", fileMB: 1, rating: 0, flag: .none, keywords: [], title: "", caption: "",
              location: "", gps: (0, 0), status: .ready, importedAt: Date(timeIntervalSince1970: 0), isDemo: false)
    }

    /// Every field set, with text that needs quoting or a formula guard.
    private func populated() -> Asset {
        var a = asset(id: "r0123456789abcdef", filename: "IMG_0001.CR3", camera: "Canon EOS R5",
                      lens: "RF 24-70mm, F2.8")
        a.rating = 5
        a.flag = .pick
        a.colorLabel = .red
        a.keywords = ["trip", "=sum", "a,b"]
        a.title = "Title, with comma"
        a.caption = "She said \"hi\"\nnext line"
        a.author = "-Author"
        a.copyright = "© 2026 写真"
        a.makerNotes = "+notes"
        a.project = "@project"
        a.client = "Client"
        a.fileModifiedAt = Date(timeIntervalSince1970: 1_767_400_000)
        a.fileCreatedAt = Date(timeIntervalSince1970: 1_767_300_000)
        a.hasICCProfile = true
        a.gps = (35.5, -122.25)
        a.gpsAltitude = -12.5
        a.localPath = "/Volumes/卡/DCIM/IMG_0001.CR3"
        return a
    }

    /// No coordinates of its own, but a location that reads as them: its GPS columns say 0.0.
    private func locatedByText() -> Asset {
        var a = asset(id: "v89abcdef01234567", filename: "loc.jpg")
        a.location = "35.5, 139.7"
        return a
    }

    private func exportedCSV(_ assets: [Asset]) throws -> String {
        let url = folder.appendingPathComponent("\(UUID().uuidString).csv")
        XCTAssertTrue(ExportService.exportMetadataCSV(assets, to: url))
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testHeaderIsTheOldOne() throws {
        XCTAssertEqual(try exportedCSV([]), oldHeader + "\n")
        XCTAssertEqual(try exportedCSV([populated()]).components(separatedBy: "\n").first, oldHeader)
    }

    /// The rows as the old code wrote them, byte for byte: a full photo, an empty one, and one
    /// whose location is only text.
    func testRowsAreTheOldOnes() throws {
        let expected = oldHeader + "\n"
            + "r0123456789abcdef,IMG_0001.CR3,5,pick,red,\"trip;=sum;a,b\",\"Title, with comma\","
            + "\"She said \"\"hi\"\"\nnext line\",'-Author,© 2026 写真,'+notes,'@project,Client,"
            + "2026-01-02T03:04:05Z,2026-01-03T00:26:40Z,2026-01-01T20:40:00Z,true,35.5,-122.25,-12.5,"
            + "Canon EOS R5,\"RF 24-70mm, F2.8\",/Volumes/卡/DCIM/IMG_0001.CR3\n"
            + ",,0,none,,,,,,,,,,2026-01-02T03:04:05Z,,,false,,,,,,\n"
            + "v89abcdef01234567,loc.jpg,0,none,,,,,,,,,,2026-01-02T03:04:05Z,,,false,0.0,0.0,,,,\n"
        XCTAssertEqual(try exportedCSV([populated(), asset(id: "", filename: ""), locatedByText()]), expected)
    }

    /// The JSON export has the CSV's columns, by the same names.
    func testJSONKeysAreTheCSVColumns() throws {
        let url = folder.appendingPathComponent("metadata.json")
        XCTAssertTrue(ExportService.exportMetadataJSON([populated(), asset(id: "", filename: "")], to: url))
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        let header = try XCTUnwrap(try exportedCSV([]).components(separatedBy: "\n").first)
        let columns = Set(header.components(separatedBy: ","))
        XCTAssertEqual(columns.count, 23)
        for row in rows { XCTAssertEqual(Set(row.keys), columns) }
    }
}
