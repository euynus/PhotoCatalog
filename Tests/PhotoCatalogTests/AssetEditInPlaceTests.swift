import XCTest
@testable import PhotoCatalog

/// Photos changed where they are in the catalog — Move to Trash and Remove from Catalog, a rename,
/// a move to another folder, a drive going offline and coming back, a rescan's changed file,
/// removed photos imported again, undo and redo of those — carry what's derived from every photo
/// on through the change, exactly as working it all out again would give it: a removed RAW shows
/// its JPEG again, a renamed JPEG can pair or unpair, a moved photo changes folders' counts.
final class AssetEditInPlaceTests: DerivedCacheTestCase {
    /// Removes the photos as Move to Trash and Remove from Catalog do.
    @MainActor
    private func remove(_ ids: Set<String>, from app: AppState) {
        XCTAssertTrue(app.mutate(ids) { $0.deleted = true })
    }

    @MainActor
    func testRemovedPhotosCarryWhatsDerivedOn() throws {
        let app = try catalog()
        check(app, "a RAW removed: its JPEG shows again") { remove(["a6r"], from: app) }
        XCTAssertFalse(app.assetPairing.isHiddenCompanion("a6j"))
        XCTAssertTrue(app.list.contains { $0.id == "a6j" })

        check(app, "a JPEG behind its RAW removed") { remove(["a2j"], from: app) }
        XCTAssertNil(app.assetPairing.companionsByPrimary["a2r"])

        // the JPEG is the first photo with "home": a pass would meet the keyword elsewhere now
        check(app, "the photo a keyword is first met on removed", dropping: ["keywords"]) {
            remove(["a3j"], from: app)
        }
        XCTAssertNil(app.keywordList.first { $0.name == "home" })
        XCTAssertNil(app.projectList.first { $0.name == "Garden" }, "its project on no photo now")
        XCTAssertEqual(app.clientList.first { $0.name == "Bob" }?.count, 1, "its client on another photo still")

        check(app, "photos removed together, the last one in a subfolder among them",
              dropping: ["folder tree", "folder counts"]) { remove(["f3", "b2", "a5j"], from: app) }
        XCTAssertNil(folder("sub/deep", in: app))
        XCTAssertEqual(app.countForAlbum(app.albums[0]), 2)
    }

    @MainActor
    func testRenamesPairAndUnpairCarryWhatsDerivedOn() throws {
        let app = try catalog()
        // f0 shares IMG_0001.CR3's camera and moment: named alike, it's that RAW's JPEG
        check(app, "a JPEG renamed to pair with a RAW") {
            XCTAssertTrue(app.applyRenamedOriginals(["f0": root.appendingPathComponent("IMG_0001.JPG")]))
        }
        XCTAssertEqual(app.assetPairing.companionsByPrimary["a1"], ["f0"])

        check(app, "renamed back: a photo of its own again") {
            XCTAssertTrue(app.applyRenamedOriginals(["f0": root.appendingPathComponent("IMG_090.JPG")]))
        }
        XCTAssertNil(app.assetPairing.companionsByPrimary["a1"])

        check(app, "a RAW's JPEG renamed away from it") {
            XCTAssertTrue(app.applyRenamedOriginals(["a2j": root.appendingPathComponent("IMG_0002b.JPG")]))
        }
        XCTAssertFalse(app.assetPairing.isHiddenCompanion("a2j"))

        check(app, "a RAW renamed onto its JPEG's new name, the pair together again") {
            XCTAssertTrue(app.applyRenamedOriginals(["a2r": root.appendingPathComponent("IMG_0002b.CR3")]))
        }
        XCTAssertEqual(app.assetPairing.companionsByPrimary["a2r"], ["a2j"])
    }

    @MainActor
    func testMovesBetweenFoldersCarryWhatsDerivedOn() throws {
        let app = try catalog()
        let sub = root.appendingPathComponent("sub"), deep = sub.appendingPathComponent("deep")
        check(app, "a photo moved to a subfolder another photo is in") {
            XCTAssertTrue(app.applyMovedOriginalLocations(["b1": deep.appendingPathComponent("IMG_0100.JPG")]))
        }
        XCTAssertEqual(folder("sub/deep", in: app).map(app.countForFolderTreeItem), 2)

        check(app, "a pair moved together into a subfolder") {
            XCTAssertTrue(app.applyMovedOriginalLocations([
                "a6r": sub.appendingPathComponent("IMG_0006.CR3"), "a6j": sub.appendingPathComponent("IMG_0006.JPG"),
            ]))
        }
        XCTAssertEqual(app.assetPairing.companionsByPrimary["a6r"], ["a6j"])
        XCTAssertEqual(folder("sub", in: app).map(app.countForFolderTreeItem), 3)

        check(app, "a RAW moved away from its JPEG") {
            XCTAssertTrue(app.applyMovedOriginalLocations(["a6r": root.appendingPathComponent("IMG_0006.CR3")]))
        }
        XCTAssertNil(app.assetPairing.companionsByPrimary["a6r"])

        check(app, "photos moved into a folder the tree hasn't got") {
            XCTAssertTrue(app.applyMovedOriginalLocations([
                "f2": root.appendingPathComponent("new/IMG_092.JPG"), "f3": root.appendingPathComponent("new/more/IMG_093.JPG"),
            ]))
        }
        XCTAssertNotNil(folder("new/more", in: app))

        check(app, "the last photos moved out of a folder", dropping: ["folder tree", "folder counts"]) {
            XCTAssertTrue(app.applyMovedOriginalLocations([
                "f2": root.appendingPathComponent("IMG_092.JPG"), "f3": root.appendingPathComponent("IMG_093.JPG"),
            ]))
        }
        XCTAssertNil(folder("new", in: app))

        check(app, "a photo moved out of every source folder") {
            XCTAssertTrue(app.applyMovedOriginalLocations(["f4": scratch.appendingPathComponent("Elsewhere/IMG_094.JPG")]))
        }
    }

    @MainActor
    func testRemovedPhotosImportedAgainCarryWhatsDerivedOn() throws {
        let app = try catalog()
        let returning = try XCTUnwrap(app.asset(id: "a6r"))
        let jpeg = try XCTUnwrap(app.asset(id: "f5"))
        remove(["a6r", "f5"], from: app)
        check(app, "a photo removed this session imported again, in its place") {
            app.addImportBatch([returning], revivedIds: ["a6r"], album: nil)
        }
        XCTAssertEqual(app.assets.firstIndex { $0.id == "a6r" }, 7, "where it was")
        XCTAssertTrue(app.assetPairing.isHiddenCompanion("a6j"), "its JPEG behind it again")

        // as a catalog opened again has it: removed photos aren't read in
        app.applyLoadedCatalogForScaleCheck(app.assets.filter { !$0.deleted }, from: app.store!)
        app.duplicateGroupsCache = []
        check(app, "one removed in an earlier session, added after the others") {
            app.addImportBatch([jpeg], revivedIds: ["f5"], album: nil)
        }
        XCTAssertEqual(app.assets.last?.id, "f5")
    }

    @MainActor
    func testImportAgainIntoAnAlbumCarriesTheSidebarOn() throws {
        let app = try catalog()
        let returning = try XCTUnwrap(app.asset(id: "a3j"))
        remove(["a3j"], from: app)
        XCTAssertEqual(app.countForAlbum(app.albums[0]), 2)
        // the JPEG was the first photo with "home", recounted as it left: back where it was, it's first again
        check(app, "a removed photo the album still lists imported into it again") {
            app.addImportBatch([returning, photo("n1", "IMG_0400.JPG")], revivedIds: ["a3j"], album: ("album", "Album"))
        }
        XCTAssertEqual(app.countForAlbum(app.albums[0]), 4)
    }

    /// A drive unplugged takes a thousand photos offline at once; plugged in again, they're back.
    @MainActor
    func testPhotosGoingOfflineAndBackCarryWhatsDerivedOn() throws {
        let app = try catalog()
        let more = (0..<1_100).map { index in
            photo("d\(index)", "drive/\(index / 100)/IMG_\(2_000 + index / 2).\(index % 2 == 0 ? "CR3" : "JPG")",
                  offset: Double(index / 2) * 600, rating: index % 4, keywords: index % 3 == 0 ? ["trip"] : [],
                  client: index % 7 == 0 ? "Drive" : "")
        }
        check(app, "a thousand photos on another drive imported") { app.appendAssets(more) }
        func available(_ status: AssetStatus) -> [AssetAvailabilityUpdate] {
            app.assets.filter { $0.id.hasPrefix("d") && $0.id != "d1099" }.map {
                AssetAvailabilityUpdate(assetId: $0.id, status: status, localPath: $0.localPath)
            }
        }
        check(app, "1,099 photos offline") { app.applyAvailabilityChanges(available(.offline)) }
        XCTAssertEqual(app.libraryCounts.missingOffline, 1_100, "the missing photo and every offline file")
        XCTAssertEqual(app.countForSmartAlbum(app.smartAlbums.first { $0.id == "offline" }!), 550)
        check(app, "and back") { app.applyAvailabilityChanges(available(.ready)) }
        XCTAssertEqual(app.libraryCounts.missingOffline, 1)
    }

    /// A change of a file's time together with what the photo says (a rating, keywords, a project,
    /// a place) moves each count it's in, the photo shown before and after.
    @MainActor
    func testTimeAndMetadataChangedTogetherCarryWhatsDerivedOn() throws {
        let app = try catalog()
        check(app, "a capture time, rating, keywords, project and place changed at once") {
            XCTAssertTrue(app.mutate(["f3"]) {
                $0.date = $0.date.addingTimeInterval(2 * 86_400)
                $0.rating = 5
                $0.keywords = ["city", "dusk"]
                $0.project = "Launch"
                $0.gps = (30.5, 114.3)
                $0.location = Asset.locationLabel((30.5, 114.3))
            })
        }
        XCTAssertEqual(app.libraryCounts.places, 2)
        XCTAssertEqual(app.projectList.first { $0.name == "Launch" }?.count, 1)

        check(app, "a capture time and a place changed, nothing else counted") {
            XCTAssertTrue(app.mutate(["f4"]) {
                $0.date = $0.date.addingTimeInterval(3600)
                $0.gps = (1.5, 2.5)
                $0.location = Asset.locationLabel((1.5, 2.5))
            })
        }
        XCTAssertEqual(app.libraryCounts.places, 3)
    }

    /// A rescan reads an original changed on disk again and puts it in place of the photo it was.
    @MainActor
    func testRescannedChangedFileCarriesWhatsDerivedOn() async throws {
        let source = scratch.appendingPathComponent("Source")
        let files = (0..<3).map { source.appendingPathComponent("sub/IMG_\($0).jpg") }
        for (index, file) in files.enumerated() { try makeTestJPEG(at: file, shade: index) }
        let package = scratch.appendingPathComponent("Library.photolibrary")
        let store = try CatalogStore(packageURL: package)
        try store.addSourceRoot(id: "source-1", displayName: "Source", path: source.path, bookmark: nil)
        var imported = ImportCoordinator(store: store)
            .importFiles(files, from: source, sourceRootId: "source-1", folderName: "Source")
        for index in imported.indices { imported[index].keywords = ["kept"] }
        try store.upsert(imported)

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))
        try await waitUntil("launch check finished") { !app.isCheckingOriginals }
        try makeTestJPEG(at: files[1], shade: 9)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_900_000_000)],
                                              ofItemAtPath: files[1].path)
        let rebuilds = begin(app)
        let before = try XCTUnwrap(app.assets.first { $0.localPath == files[1].path })
        try await rescanToCompletion(app)
        let after = try XCTUnwrap(app.assets.first { $0.id == before.id })
        XCTAssertNotEqual(after.quickHash, before.quickHash, "the changed file was read again")
        XCTAssertEqual(app.assets.firstIndex { $0.id == before.id }, 1, "in its place")
        verify(app, "a rescan's changed file", since: rebuilds)
    }

    /// Undo and redo of a removal and of a capture-time change replay them in place, carrying
    /// what's derived on as the change itself did.
    @MainActor
    func testUndoAndRedoCarryWhatsDerivedOn() throws {
        let app = try catalog()
        let undo = UndoManager()
        undo.groupsByEvent = false   // no run loop here to close event groups
        app.undoManager = undo
        func step(_ action: () -> Void) {
            undo.beginUndoGrouping()
            action()
            undo.endUndoGrouping()
        }
        app.selectedIds = ["a6r"]
        check(app, "Remove from Catalog of a pair") { step { app.removeSelected() } }
        XCTAssertEqual(app.assets.filter(\.deleted).map(\.id), ["a6r", "a6j"])
        check(app, "its undo") { undo.undo() }
        XCTAssertTrue(app.assetPairing.isHiddenCompanion("a6j"))
        check(app, "its redo") { undo.redo() }
        XCTAssertEqual(app.assets.filter(\.deleted).map(\.id), ["a6r", "a6j"])
        check(app, "undone again") { undo.undo() }

        // two seconds apart the RAW and its JPEG are two photos
        app.selectedIds = ["a6j"]
        check(app, "a JPEG's capture time moved off its RAW's") { step { app.shiftCaptureTime(hours: 0, minutes: 1) } }
        XCTAssertFalse(app.assetPairing.isHiddenCompanion("a6j"))
        check(app, "its undo") { undo.undo() }
        XCTAssertTrue(app.assetPairing.isHiddenCompanion("a6j"))
        check(app, "its redo") { undo.redo() }
        XCTAssertFalse(app.assetPairing.isHiddenCompanion("a6j"))

        // a day and a half on: the capture dates move it to another day
        app.selectedIds = ["f2"]
        let day = app.captureDateGroups
        check(app, "a capture time moved to another day") { step { app.shiftCaptureTime(hours: 36) } }
        XCTAssertNotEqual(app.captureDateGroups, day)
        check(app, "its undo") { undo.undo() }
        XCTAssertEqual(app.captureDateGroups, day)
    }
}
