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

/// The pairing worked out as it was before it was made fast, kept as the oracle the fast one must
/// agree with photo for photo: which RAW each JPEG/HEIC hides behind, in the same order.
final class AssetPairingOracleTests: XCTestCase {
    private struct Random {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func pick<T>(_ values: [T]) -> T { values[Int(next() % UInt64(values.count))] }
        mutating func chance(_ percent: UInt64) -> Bool { next() % 100 < percent }
    }

    /// Photos named from a small pool, so names meet: case and Unicode variants of one name, RAWs
    /// with and without their JPEGs, other cameras' and other moments' same-named files, removed
    /// photos, virtual copies, files without a path, an extension or a name before the dot.
    static func tangle(_ count: Int, seed: UInt64, idPrefix: String = "p") -> [Asset] {
        var random = Random(state: seed)
        let shot = Date(timeIntervalSince1970: 1_791_800_000)
        let folders = ["/Photos/a", "/Photos/A", "/Photos/Ü", "/Photos/ü", "/Photos/日本", "/Volumes/Card/DCIM/100CANON"]
        let names: [(Int) -> String] = [{ "IMG_\($0)" }, { "img_\($0)" }, { "IMG_\($0)" }, { "café\($0)" },
                                         { "CAFÉ\($0)" }, { "cafe\u{301}\($0)" }, { "IMG_\u{212A}\($0 % 9)" },
                                         { "IMG_k\($0 % 9)" }, { "照片\($0)" }, { _ in "x" }, { _ in "" }]
        let extensions: [(String, Bool)] = [("CR3", true), ("cr3", true), ("NEF", true), ("JPG", false), ("jpg", false),
                                            ("JPEG", false), ("Jpeg", false), ("HEIC", false), ("heif", false),
                                            ("TIFF", false), ("PNG", false), ("ＪＰＧ", false)]
        let cameras = ["Canon EOS R5", " Canon EOS R5 ", "canon eos r5", "", "Apple iPhone 15 Pro", "SONY ILCE-7M4"]
        let offsets: [TimeInterval] = [0, 0, 0, 0.5, 1.9, 2, 3600]
        return (0..<count).map { index in
            let folder = random.pick(folders)
            let name = random.pick(names)(Int(random.next() % 100))
            var (ext, raw) = random.pick(extensions)
            if random.chance(3) { raw.toggle() }   // what the file says it is, whatever it's called
            let file = random.chance(4) ? name : random.chance(3) ? "." + ext : "\(name).\(ext)"
            let path: String? = random.chance(3) ? nil : "\(folder)/\(file)"
            return Asset(id: "\(idPrefix)\(index)", pid: 0, ori: "l", thumb: "", preview: "", filename: file, type: ext,
                         isRaw: raw, folderId: "f", folderName: "f", date: shot.addingTimeInterval(random.pick(offsets)),
                         width: 1, height: 1, orientation: 1, camera: random.pick(cameras), lens: "", focal: 1,
                         aperture: 1, shutter: "", iso: 1, colorSpace: "", fileMB: 1, rating: 0, flag: .none,
                         keywords: [], title: "", caption: "", location: "", gps: (0, 0), status: .ready,
                         importedAt: shot, deleted: random.chance(5), localPath: path,
                         masterId: random.chance(5) ? "\(idPrefix)0" : nil)
        }
    }

    func testPairsAsTheOracleDoes() {
        for seed: UInt64 in [1, 2, 3, 4, 5] {
            let photos = Self.tangle(4_000, seed: seed)
            let pairing = AssetPairing.rawJpeg(photos)
            let oracle = Self.oracle(photos)
            XCTAssertGreaterThan(oracle.primaryByCompanion.count, 50, "the tangle pairs photos")
            XCTAssertEqual(pairing.companionsByPrimary, oracle.companionsByPrimary, "seed \(seed)")
            XCTAssertEqual(pairing.primaryByCompanion, oracle.primaryByCompanion, "seed \(seed)")
            for (position, photo) in photos.enumerated() {
                XCTAssertEqual(pairing.isShown(photo, at: position), pairing.shows(photo), "seed \(seed), \(photo.id)")
            }
        }
    }

    /// `AssetPairing.rawJpeg` as it was (a706ebc), the dictionaries only.
    static func oracle(_ assets: [Asset]) -> (companionsByPrimary: [String: [String]], primaryByCompanion: [String: String]) {
        var keyed: [(hash: UInt64, index: Int)] = []
        for index in assets.indices {
            let asset = assets[index]
            guard !asset.deleted, !asset.isVirtualCopy, let path = asset.localPath else { continue }
            let (stem, ext) = PathString.splitExtension(path)
            guard asset.isRaw || AssetPairing.companionExtensions.contains(ext.lowercased()) else { continue }
            keyed.append((stemHash(stem), index))
        }
        keyed.sort { $0.hash < $1.hash }
        var companionsByPrimary: [String: [String]] = [:]
        var primaryByCompanion: [String: String] = [:]
        var start = 0
        while start < keyed.count {
            var end = start + 1
            while end < keyed.count, keyed[end].hash == keyed[start].hash { end += 1 }
            if end - start > 1 {
                let members = keyed[start..<end].map(\.index)
                let byStem = Dictionary(grouping: members) {
                    PathString.splitExtension(assets[$0].localPath ?? "").stem.lowercased()
                }
                for group in byStem.values where group.count > 1 {
                    let raws = group.filter { assets[$0].isRaw }
                    guard raws.count == 1 else { continue }
                    let raw = assets[raws[0]]
                    let companions = group.filter {
                        !assets[$0].isRaw && isSameShot((raw.camera, raw.date), (assets[$0].camera, assets[$0].date))
                    }.map { assets[$0].id }
                    guard !companions.isEmpty else { continue }
                    companionsByPrimary[raw.id] = companions
                    for id in companions { primaryByCompanion[id] = raw.id }
                }
            }
            start = end
        }
        return (companionsByPrimary, primaryByCompanion)
    }

    private static func isSameShot(_ a: (camera: String, date: Date), _ b: (camera: String, date: Date)) -> Bool {
        guard abs(a.date.timeIntervalSince(b.date)) < 2 else { return false }
        let left = a.camera.trimmingCharacters(in: .whitespaces)
        let right = b.camera.trimmingCharacters(in: .whitespaces)
        return left.isEmpty || right.isEmpty || left.caseInsensitiveCompare(right) == .orderedSame
    }

    private static func stemHash(_ stem: Substring) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in stem.utf8 {
            guard byte < 0x80 else { return fnv(stem.lowercased().utf8) }
            let folded = (0x41...0x5A).contains(byte) ? byte + 0x20 : byte
            hash = (hash ^ UInt64(folded)) &* 0x100_0000_01b3
        }
        return hash
    }

    private static func fnv(_ bytes: String.UTF8View) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return hash
    }
}
