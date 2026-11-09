import XCTest
@testable import PhotoCatalog

/// The keyword tally counts each keyword of the photos as shown, lists keywords in the order a
/// pass meets them and keeps the photo each is first met on (the keyword carry after an import
/// batch reads that). However it's split among threads, and for keywords in Chinese or written
/// in two Unicode forms (one `String`), it's what one plain pass gives.
final class KeywordTallyOrderTests: XCTestCase {
    private let shot = Date(timeIntervalSince1970: 1_791_800_000)

    private func photo(_ id: String, _ name: String, raw: Bool = false, keywords: [String], project: String = "",
                       deleted: Bool = false, master: String? = nil) -> Asset {
        Asset(id: id, pid: 0, ori: "l", thumb: "", preview: "", filename: name, type: raw ? "CR3" : "JPEG", isRaw: raw,
              folderId: "day", folderName: "day", date: shot, width: 1, height: 1, orientation: 1,
              camera: "Canon EOS R5", lens: "", focal: 50, aperture: 4, shutter: "1/100", iso: 100, colorSpace: "sRGB",
              fileMB: 1, rating: 0, flag: .none, keywords: keywords, title: "", caption: "", project: project,
              location: "", gps: (0, 0), status: .ready, importedAt: shot, deleted: deleted,
              localPath: "/Photos/day/" + name, isDemo: false, masterId: master)
    }

    private static let nfc = "caf\u{E9}", nfd = "cafe\u{301}"

    /// A RAW and the JPEG behind it (with a keyword only the JPEG has), a removed photo, a virtual
    /// copy, a keyword twice on one photo, and "café" in NFC and NFD, in the order `firstForm`
    /// says; then enough photos that chunks split everywhere.
    private func catalog(firstForm: String, secondForm: String) -> [Asset] {
        var photos = [
            photo("raw", "IMG_0001.CR3", raw: true, keywords: ["旅行", firstForm], project: firstForm),
            photo("jpeg", "IMG_0001.JPG", keywords: ["旅行", "只在 JPEG 上"], project: "JPEG"),
            photo("gone", "IMG_0002.JPG", keywords: ["已删除"], project: "已删除", deleted: true),
            photo("b", "IMG_0003.JPG", keywords: [secondForm, "家人"], project: secondForm),
            photo("c", "IMG_0004.JPG", keywords: ["Trip", "trip", "家人", "家人"]),
            photo("d", "IMG_0005.JPG", keywords: []),
            photo("copy", "IMG_0003.JPG", keywords: ["副本"], master: "b"),
            photo("e", "IMG_0006.JPG", keywords: ["猫", "旅行", secondForm], project: "猫"),
        ]
        let pool = ["sunset", "猫", "雪", firstForm, secondForm, "Trip", "山"]
        for index in 0..<40 {
            photos.append(photo("f\(index)", "IMG_1\(index).JPG",
                                keywords: (0..<index % 3).map { pool[(index * 5 + $0) % pool.count] },
                                project: index % 4 == 0 ? pool[index % pool.count] : ""))
        }
        return photos
    }

    /// The tally one plain pass over the photos as shown gives.
    private func plainTally(_ photos: [Asset], pairing: AssetPairing) -> AppState.KeywordTally {
        var order: [String] = []
        var counts: [String: Int] = [:]
        var first: [String: Int] = [:]
        for position in photos.indices where pairing.isShown(photos[position], at: position) {
            for keyword in photos[position].keywords {
                if counts[keyword] == nil {
                    order.append(keyword)
                    first[keyword] = position
                }
                counts[keyword, default: 0] += 1
            }
        }
        return (order, counts, first)
    }

    func testTallyKeepsOrderCountsAndFirstPhotos() throws {
        for (firstForm, secondForm) in [(Self.nfc, Self.nfd), (Self.nfd, Self.nfc)] {
            let photos = catalog(firstForm: firstForm, secondForm: secondForm)
            let pairing = AssetPairing.rawJpeg(photos)
            XCTAssertTrue(pairing.isHiddenCompanion("jpeg"), "the JPEG is behind its RAW")
            let expected = plainTally(photos, pairing: pairing)
            // what the plain pass gives, spelled out
            XCTAssertEqual(Array(expected.order.prefix(6)), ["旅行", firstForm, "家人", "Trip", "trip", "副本"])
            XCTAssertNil(expected.counts["只在 JPEG 上"], "a keyword only on a hidden JPEG isn't counted")
            XCTAssertNil(expected.counts["已删除"], "nor one only on a removed photo")
            XCTAssertEqual(expected.first["旅行"], 0)
            XCTAssertEqual(expected.first[Self.nfd], 0, "café is first met on the RAW, in either form")
            XCTAssertEqual(expected.first["家人"], 3)
            XCTAssertEqual(expected.first["副本"], 6, "a virtual copy is shown")

            for chunk in [1, 2, 3, 7, .max] {
                let tally = AppState.keywordCounts(of: photos, pairing: pairing, chunk: chunk)
                XCTAssertEqual(tally.order, expected.order, "order, chunks of \(chunk)")
                XCTAssertEqual(tally.counts, expected.counts, "counts, chunks of \(chunk)")
                XCTAssertEqual(tally.first, expected.first, "first photos, chunks of \(chunk)")
                // "café" is listed and counted as first met, in the form first met
                let cafe = try XCTUnwrap(tally.order.first { $0 == Self.nfc })
                XCTAssertEqual(Array(cafe.unicodeScalars), Array(firstForm.unicodeScalars), "chunks of \(chunk)")
                let key = try XCTUnwrap(tally.counts.index(forKey: Self.nfd))
                XCTAssertEqual(Array(tally.counts[key].key.unicodeScalars), Array(firstForm.unicodeScalars))
                XCTAssertEqual(tally.counts[key].value, expected.counts[Self.nfc])
                XCTAssertEqual(tally.counts["家人"], expected.counts["家人"])
            }
        }
    }

    /// Projects (and clients, cameras) are counted the same way: one count for both forms of a
    /// name, listed under the form first met, ties in the order a pass first meets them.
    func testMetadataCountsKeepTheFirstFormAndPhoto() {
        for (firstForm, secondForm) in [(Self.nfc, Self.nfd), (Self.nfd, Self.nfc)] {
            let photos = catalog(firstForm: firstForm, secondForm: secondForm)
            let pairing = AssetPairing.rawJpeg(photos)
            var order: [String] = []
            var counts: [String: Int] = [:]
            for position in photos.indices where pairing.isShown(photos[position], at: position) {
                let project = photos[position].project
                guard !project.isEmpty else { continue }
                if counts[project] == nil { order.append(project) }
                counts[project, default: 0] += 1
            }
            XCTAssertNil(counts["JPEG"])
            let expected = order.map { KeywordCount(name: $0, count: counts[$0] ?? 0) }.sorted { $0.count > $1.count }
            for chunk in [1, 2, 3, 7, .max] {
                let list = AppState.metadataCounts(photos, pairing: pairing, \.project, chunk: chunk).list
                XCTAssertEqual(list, expected, "chunks of \(chunk)")
                XCTAssertEqual(list.map { Array($0.name.unicodeScalars) }, expected.map { Array($0.name.unicodeScalars) },
                               "spelled as first met, chunks of \(chunk)")
            }
        }
    }
}
