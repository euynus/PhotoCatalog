import XCTest
@testable import PhotoCatalog

/// A RAW and its JPEG/HEIC are one photo only when they are one exposure: the same camera,
/// the same moment — not merely the same name in the same folder.
final class AssetPairingTests: XCTestCase {
    private let shot = Date(timeIntervalSince1970: 1_791_800_000)

    private func photo(_ id: String, _ name: String, raw: Bool, camera: String, offset: TimeInterval = 0) -> Asset {
        Asset(id: id, pid: 0, ori: "l", thumb: "", preview: "", filename: name,
              type: raw ? "CR3" : "JPEG", isRaw: raw, folderId: "day", folderName: "2026-10-12",
              date: shot.addingTimeInterval(offset), width: 6000, height: 4000, orientation: 1,
              camera: camera, lens: "", focal: 50, aperture: 4, shutter: "1/100", iso: 100,
              colorSpace: "sRGB", fileMB: 1, rating: 0, flag: .none, keywords: [], title: "", caption: "",
              location: "", gps: (0, 0), status: .ready, importedAt: shot,
              localPath: "/Photos/2026/2026-10-12/" + name)
    }

    func testAnotherCamerasPhotoByTheSameNameIsNotAPair() {
        let canon = photo("canon", "IMG_1234.CR3", raw: true, camera: "Canon EOS R5")
        let iphone = photo("iphone", "IMG_1234.HEIC", raw: false, camera: "Apple iPhone 15 Pro", offset: 3 * 3600)

        let pairing = AssetPairing.rawJpeg([canon, iphone])

        XCTAssertNil(pairing.primaryByCompanion[iphone.id], "the iPhone photo isn't hidden behind the Canon RAW")
        XCTAssertTrue(pairing.shows(iphone))
    }

    func testSameCamerasPhotosTakenAtDifferentTimesAreNotAPair() {
        // the camera's counter came round again: one name, two shots hours apart
        let raw = photo("raw", "IMG_1234.CR3", raw: true, camera: "Canon EOS R5")
        let jpeg = photo("jpeg", "IMG_1234.JPG", raw: false, camera: "Canon EOS R5", offset: 5 * 3600)

        XCTAssertTrue(AssetPairing.rawJpeg([raw, jpeg]).isEmpty)
    }

    func testRawAndJpegOfOneShotPair() {
        let raw = photo("raw", "IMG_1234.CR3", raw: true, camera: "Canon EOS R5")
        let jpeg = photo("jpeg", "IMG_1234.JPG", raw: false, camera: "Canon EOS R5")
        let heic = photo("heic", "IMG_1234.HEIC", raw: false, camera: "")   // a camera unknown proves nothing

        let pairing = AssetPairing.rawJpeg([raw, jpeg, heic])

        XCTAssertEqual(Set(pairing.companionsByPrimary[raw.id] ?? []), [jpeg.id, heic.id])
        XCTAssertFalse(pairing.shows(jpeg))
    }
}
