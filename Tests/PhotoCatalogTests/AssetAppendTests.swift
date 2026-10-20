import XCTest
@testable import PhotoCatalog

/// Photos added at the end of the catalog (an import batch, a tethered shot, virtual copies) carry
/// what's derived from every photo on to themselves — the id index, the RAW+JPEG pairing, the
/// library, keyword, project, client, camera and lens counts, the sidebar's counts, the capture
/// dates and the folders — exactly as working it all out again would give it, including for the
/// earlier photos a new RAW hides or a second RAW of their name shows again.
final class AssetAppendTests: DerivedCacheTestCase {
    /// Adds `photos` as an import batch does, then checks that what's derived was carried on as
    /// `dropped` says and is what a recount gives, and that the list and the id lookups follow.
    @MainActor
    private func append(_ photos: [Asset], to app: AppState, _ name: String, dropping dropped: [String] = [],
                        file: StaticString = #filePath, line: UInt = #line) {
        check(app, name, dropping: dropped, { app.appendAssets(photos) }, file: file, line: line)
    }


    @MainActor
    func testImportBatchesCarryWhatsDerivedOnAsARecountWouldGiveIt() throws {
        let app = try catalog()

        append([photo("n1", "IMG_0001.JPG", keywords: ["trip"], project: "Wedding")], to: app, "a JPEG after its RAW")
        XCTAssertTrue(app.assetPairing.isHiddenCompanion("n1"))

        append([photo("n2", "IMG_0004.CR3", offset: 30, keywords: ["trip"])], to: app, "a RAW after its JPEG and HEIC")
        XCTAssertEqual(app.assetPairing.companionsByPrimary["n2"], ["a4j", "a4h"])
        XCTAssertEqual(app.countForAlbum(app.albums[0]), 1, "the album's JPEG and HEIC now behind the RAW")

        // the JPEG is the first photo with "home": a pass would meet it elsewhere now
        append([photo("n3", "IMG_0003.CR3", offset: 20)], to: app, "a RAW hiding the photo a keyword is first met on",
               dropping: ["keywords"])
        XCTAssertNil(app.keywordList.first { $0.name == "home" })
        XCTAssertNil(app.projectList.first { $0.name == "Garden" })

        append([photo("n4", "IMG_0005.CR3")], to: app, "another camera's photo by the same name, hours apart")
        XCTAssertNil(app.assetPairing.companionsByPrimary["n4"])

        // edits patch the same caches in between: what they leave must carry on as exactly
        XCTAssertTrue(app.setRating(5, on: ["f5"]))
        XCTAssertTrue(app.mutate(["f2"]) { $0.keywords = ["city", "trip", "dusk"] })
        XCTAssertTrue(app.mutate(["a1"]) { $0.project = "Moved" })   // Wedding's first photo
        XCTAssertTrue(app.mutate(["f5"]) { $0.client = "Acme" })
        append([photo("n4b", "IMG_095.CR3", offset: 5 * 40 * 86_400, keywords: ["dusk", "trip"], project: "Wedding",
                      client: "Acme")],
               to: app, "after edits, a RAW taking the JPEG of a photo they edited")
        XCTAssertEqual(app.assetPairing.companionsByPrimary["n4b"], ["f5"])

        append([photo("n5", "IMG_0006.NEF", offset: 60)], to: app, "a second RAW of a name: the pair is ambiguous")
        XCTAssertFalse(app.assetPairing.isHiddenCompanion("a6j"), "its JPEG shown again")

        var copy = app.asset(id: "a1")!.virtualCopy(id: "n8", name: "副本 1")
        copy.rating = 5
        append([photo("n6r", "IMG_0200.CR3", offset: 400), photo("n6j", "IMG_0200.JPG", offset: 400.5),
                photo("n7", "IMG_0201.JPG", keywords: ["gone"], deleted: true), copy,
                photo("n9", "sub/IMG_0202.JPG", camera: "FUJIFILM X-T4", lens: "XF23mmF1.4 R", offset: -86_400,
                      keywords: ["night", "trip"], project: "Launch", client: " Zed ", gps: (1, 2), status: .offline),
                photo("n10", "sub/deep/IMG_0203.JPG", flag: .pick, keywords: ["night"])],
               to: app, "a pair, a removed photo, a virtual copy and new values in one batch")
        XCTAssertTrue(app.assetPairing.isHiddenCompanion("n6j"))
        XCTAssertEqual(app.countForAlbum(app.albums[0]), 1, "a new photo the album already lists")

        append([photo("n11", "new/IMG_0300.JPG"), photo("n11b", "sub/later/on/IMG_0301.JPG")], to: app,
               "photos in folders the tree hasn't got, put in it")
        XCTAssertNotNil(folder("new", in: app))
        XCTAssertEqual(folder("sub/later", in: app).map(app.countForFolderTreeItem), 1)
        XCTAssertEqual(folder("sub", in: app).map(app.countForFolderTreeItem), 5, "its four and the new one below it")

        // with pairing off, every file is a photo of its own
        app.pairRawAndJpeg = false
        append([photo("n12", "IMG_0400.CR3"), photo("n13", "IMG_0400.JPG")], to: app, "pairing off",
               dropping: ["pairing"])
    }

    /// A pairing carried on through photos added in batches pairs as working it out from all the
    /// photos at once does, whatever the batches: the photos of the pairing oracle, cut anywhere.
    func testPairingCarriedThroughBatchesIsTheWholePairing() {
        for seed: UInt64 in [11, 12, 13] {
            let photos = AssetPairingOracleTests.tangle(1_500, seed: seed)
            let cuts = [0, 1, 2, 3, 50, 51, 333, 700, 701, 702, 999, 1_200, 1_201, 1_499, 1_500]
            var pairing = AssetPairing.rawJpeg(Array(photos.prefix(cuts[0])))
            var flipped = 0
            for (from, to) in zip(cuts, cuts.dropFirst()) {
                let before = AssetPairing.rawJpeg(Array(photos.prefix(from)))
                guard let changed = pairing.append(Array(photos.prefix(to)), from: from) else {
                    return XCTFail("seed \(seed): carried on from \(from)")
                }
                let whole = AssetPairing.rawJpeg(Array(photos.prefix(to)))
                XCTAssertEqual(pairing, whole, "seed \(seed): \(from)..<\(to)")
                // the earlier photos whose being hidden changed, and only they
                let expected = (0..<from).filter { before.isHiddenCompanion(photos[$0].id) != whole.isHiddenCompanion(photos[$0].id) }
                XCTAssertEqual(changed.sorted(), expected, "seed \(seed): \(from)..<\(to)")
                flipped += expected.count
            }
            XCTAssertGreaterThan(flipped, 0, "seed \(seed): some batch hid or showed an earlier photo")
        }
        var pairing = AssetPairing.rawJpeg([])
        XCTAssertNil(pairing.append(AssetPairingOracleTests.tangle(10, seed: 1), from: 5), "not the pairing of those photos")
    }

    /// An import into an album (Add to Album in the import options) puts each batch's photos in
    /// the album as it adds them: the album's count moves with them, and nothing in the sidebar is
    /// counted again from every photo.
    @MainActor
    func testImportBatchIntoAnAlbumCarriesTheSidebarOn() throws {
        let app = try catalog()
        work(app)
        let rebuilds = app.sidebarCountIndexRebuilds
        app.addImportBatch([photo("n20", "IMG_0300.JPG", keywords: ["trip"]), photo("n21r", "IMG_0301.CR3"),
                            photo("n21j", "IMG_0301.JPG")], revivedIds: [], album: ("album", "Album"))
        XCTAssertEqual(app.countForAlbum(app.albums[0]), 5, "two new photos shown in it (the RAW's JPEG behind it)")
        app.addImportBatch([photo("n22", "IMG_0302.JPG")], revivedIds: [], album: ("al-new", "New"))
        XCTAssertEqual(app.albums.map(\.id), ["album", "al-new"])
        XCTAssertEqual(app.countForAlbum(app.albums[1]), 1, "a new album, its batch counted in")
        XCTAssertEqual(app.sidebarCounts, app.recountedSidebarCounts())
        XCTAssertEqual(app.sidebarCountIndexRebuilds, rebuilds, "the sidebar's counts carried on, not recounted")
    }
}
