import XCTest
@testable import PhotoCatalog

/// People: naming, renaming and deleting people, with their `人物/…` keywords and undo.
final class PeopleTests: CatalogTestCase {
    private var savedAutoWriteXMP: Any?
    private var undo: UndoManager!

    override func setUp() {
        super.setUp()
        savedAutoWriteXMP = UserDefaults.standard.object(forKey: "pc_autoWriteXMP")
        undo = UndoManager()
        undo.groupsByEvent = false   // no run loop here to close event groups
    }

    override func tearDown() {
        if let savedAutoWriteXMP {
            UserDefaults.standard.set(savedAutoWriteXMP, forKey: "pc_autoWriteXMP")
        } else {
            UserDefaults.standard.removeObject(forKey: "pc_autoWriteXMP")
        }
        undo = nil
        super.tearDown()
    }

    // ---------- a person no photo is tagged with ----------

    @MainActor
    func testRenamingAPersonOnlySuggestedRenamesTheFaces() throws {
        let (app, store, ids) = try appWithFaces([face("s0", on: 0, person: "小刚", confirmed: false)])
        XCTAssertEqual(app.people.map(\.name), ["小刚"])

        step { app.renamePerson("小刚", to: "阿刚") }

        XCTAssertEqual(app.people.map(\.name), ["阿刚"], "the person is renamed though no photo carries the keyword")
        XCTAssertEqual(app.face("s0")?.person, "阿刚")
        XCTAssertEqual(try store.loadFaces().first { $0.id == "s0" }?.person, "阿刚", "the new name is saved")
        XCTAssertEqual(app.asset(id: ids[0])?.keywords, [], "a suggestion still tags nothing")
        undo.undo()
        XCTAssertEqual(app.people.map(\.name), ["小刚"], "undo takes the old name back")
    }

    @MainActor
    func testDeletingAPersonOnlySuggestedUnnamesTheFaces() throws {
        let (app, store, _) = try appWithFaces([face("s0", on: 0, person: "小刚", confirmed: false),
                                                face("s1", on: 1, person: "小刚", confirmed: false)])

        step { app.deletePerson("小刚") }

        XCTAssertTrue(app.people.isEmpty, "the person is deleted though no photo carries the keyword")
        XCTAssertNil(app.face("s0")?.person)
        XCTAssertTrue(try store.loadFaces().allSatisfy { $0.person == nil }, "the faces are saved unnamed")
        undo.undo()
        XCTAssertEqual(app.people.first?.faceIds.count, 2, "undo names the faces again")
    }

    // ---------- undoing a name takes back only the keywords it added ----------

    @MainActor
    func testUndoingANameKeepsThePersonKeywordThePhotoAlreadyHad() throws {
        let (app, store, ids) = try appWithFaces([face("y0", on: 0)], keywords: [0: ["人物/小刚", "海"]])

        step { app.nameFaces(["y0"], as: "小刚") }
        XCTAssertEqual(app.people.map(\.name), ["小刚"])
        undo.undo()

        XCTAssertNil(app.face("y0")?.person, "undo takes the name back")
        XCTAssertEqual(app.asset(id: ids[0])?.keywords, ["人物", "人物/小刚", "海"],
                       "the photo keeps the person keyword it had before")
        XCTAssertEqual(try store.loadAssets().first { $0.id == ids[0] }?.keywords, ["人物", "人物/小刚", "海"],
                       "in the catalog too")
    }

    @MainActor
    func testUndoingAConfirmationKeepsThePersonKeywordThePhotoAlreadyHad() throws {
        let (app, store, ids) = try appWithFaces([face("s0", on: 0, person: "小刚", confirmed: false)],
                                                 keywords: [0: ["人物/小刚"]])

        step { app.confirmFaces(of: "小刚") }
        XCTAssertEqual(app.face("s0")?.confirmed, true)
        undo.undo()

        XCTAssertEqual(app.face("s0")?.confirmed, false, "undo takes the confirmation back")
        XCTAssertEqual(app.asset(id: ids[0])?.keywords, ["人物", "人物/小刚"], "the photo keeps its person keyword")
        XCTAssertEqual(try store.loadAssets().first { $0.id == ids[0] }?.keywords, ["人物", "人物/小刚"])
    }

    @MainActor
    func testUndoingANameTakesBackOnlyTheKeywordItAdded() throws {
        let (app, store, ids) = try appWithFaces([face("x1", on: 1)])

        step { app.nameFaces(["x1"], as: "小明") }
        XCTAssertEqual(app.asset(id: ids[1])?.keywords, ["人物", "人物/小明"], "naming tags the photo")
        // a keyword arriving without an undo step of its own, as from a sidecar read
        XCTAssertTrue(app.mutate([ids[1]]) { $0.keywords.append("海") })
        undo.undo()

        XCTAssertEqual(app.asset(id: ids[1])?.keywords, ["海"], "undo takes the person keyword back, and only it")
        XCTAssertEqual(try store.loadAssets().first { $0.id == ids[1] }?.keywords, ["海"])
        undo.redo()
        XCTAssertEqual(app.face("x1")?.person, "小明", "redo names the face again")
        XCTAssertEqual(Set(app.asset(id: ids[1])?.keywords ?? []), ["人物", "人物/小明", "海"], "and tags the photo again")
    }

    @MainActor
    func testUndoingNotThisPersonPutsTheKeywordBack() throws {
        let (app, _, ids) = try appWithFaces([face("x1", on: 1)])
        step { app.nameFaces(["x1"], as: "小明") }

        step { app.removeFaceFromPerson("x1") }
        XCTAssertEqual(app.asset(id: ids[1])?.keywords, [], "the photo loses the keyword with its only face")
        undo.undo()

        XCTAssertEqual(app.face("x1")?.person, "小明")
        XCTAssertEqual(app.asset(id: ids[1])?.keywords, ["人物", "人物/小明"], "undo puts the keyword back")
    }

    @MainActor
    func testUndoingARenameOrDeleteOfATaggedPersonPutsNamesAndKeywordsBack() throws {
        let (app, store, ids) = try appWithFaces([face("x0", on: 0), face("x1", on: 1)])
        step { app.nameFaces(["x0", "x1"], as: "小明") }

        step { app.renamePerson("小明", to: "明明") }
        XCTAssertEqual(app.asset(id: ids[0])?.keywords, ["人物", "人物/明明"])
        undo.undo()
        XCTAssertEqual(app.people.map(\.name), ["小明"], "undoing a rename takes the old name back")
        XCTAssertEqual(app.asset(id: ids[0])?.keywords, ["人物", "人物/小明"], "and the old keyword")
        undo.redo()
        XCTAssertEqual(app.people.map(\.name), ["明明"], "redo renames again")
        XCTAssertEqual(app.asset(id: ids[1])?.keywords, ["人物", "人物/明明"])

        step { app.deletePerson("明明") }
        XCTAssertTrue(app.people.isEmpty)
        XCTAssertEqual(app.asset(id: ids[0])?.keywords, [])
        undo.undo()
        XCTAssertEqual(app.people.first?.photoCount, 2, "undoing a delete names the faces again")
        XCTAssertEqual(app.asset(id: ids[0])?.keywords, ["人物", "人物/明明"], "and tags their photos again")
        XCTAssertEqual(try store.loadAssets().first { $0.id == ids[1] }?.keywords, ["人物", "人物/明明"])
    }

    // ---------- photos removed from the catalog ----------

    @MainActor
    func testFacesOfRemovedPhotosLeavePeopleUntilTheRemovalIsUndone() async throws {
        let (app, _, ids) = try appWithFaces([face("a0", on: 0, person: "小明", confirmed: true),
                                              face("a1", on: 1, person: "小明", confirmed: true),
                                              face("c2", on: 2, axis: 4), face("c3", on: 3, axis: 4)],
                                             keywords: [0: ["人物/小明"], 1: ["人物/小明"]])
        try await waitUntil("the unnamed faces are grouped") { app.faceClusters.map(\.faceIds.count) == [2] }
        XCTAssertEqual(app.people.first?.photoCount, 2)

        app.selectedIds = [ids[1], ids[3]]
        app.primaryId = ids[1]
        step { app.removeSelected() }

        XCTAssertEqual(app.people.first?.photoCount, 1, "a removed photo no longer counts for its people")
        XCTAssertEqual(app.people.first?.faceIds, ["a0"], "nor shows its faces")
        try await waitUntil("a removed photo's faces leave the unnamed groups", timeout: 2) {
            app.faceClusters.map(\.faceIds) == [["c2"]]
        }

        undo.undo()

        XCTAssertEqual(app.people.first?.photoCount, 2, "undoing the removal brings the faces back")
        try await waitUntil("and puts them back in their group", timeout: 2) {
            app.faceClusters.map { Set($0.faceIds) } == [["c2", "c3"]]
        }
    }

    @MainActor
    func testNamingLeavesFacesAndKeywordsOfRemovedPhotosAlone() throws {
        let (app, _, ids) = try appWithFaces([face("c2", on: 2, axis: 4), face("c3", on: 3, axis: 4)])
        app.selectedIds = [ids[3]]
        app.primaryId = ids[3]
        step { app.removeSelected() }

        // the faces of a group as a view listed them before the removal
        step { app.nameFaces(["c2", "c3"], as: "小红") }

        XCTAssertEqual(app.face("c2")?.person, "小红")
        XCTAssertEqual(app.asset(id: ids[2])?.keywords, ["人物", "人物/小红"])
        XCTAssertNil(app.face("c3")?.person, "a face in a removed photo isn't named")
        XCTAssertEqual(app.asset(id: ids[3])?.keywords, [], "and its photo isn't tagged")

        step { app.confirmFaces(of: "小红", ids: ["c3"]) }
        XCTAssertNil(app.face("c3")?.person, "nor confirmed")
        XCTAssertEqual(app.asset(id: ids[3])?.keywords, [])
    }

    // ---------- fixture ----------

    /// One undo step, as one user action makes.
    private func step(_ action: () -> Void) {
        undo.beginUndoGrouping()
        action()
        undo.endUndoGrouping()
    }

    /// A face on photo `index`, near axis `axis` (faces near one axis look like one person).
    private func face(_ id: String, on index: Int, axis: Int = 0, jitter: Float = 0.02, person: String? = nil,
                      confirmed: Bool = false) -> FaceRecord {
        var vector = [Float](repeating: 0, count: FaceClustering.vectorLength)
        vector[axis] = 1
        vector[(axis + 1) % vector.count] = jitter
        let norm = (1 + jitter * jitter).squareRoot()
        return FaceRecord(id: id, assetId: photoId(index), box: CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.2),
                          quality: 0.6, vector: vector.map { $0 / norm }, person: person, confirmed: confirmed)
    }

    private func photoId(_ index: Int) -> String { "people-photo-\(index)" }

    /// A scratch catalog of `count` photos (with the given keywords) whose analysis found `faces`.
    @MainActor
    private func appWithFaces(_ faces: [FaceRecord], count: Int = 4,
                              keywords: [Int: [String]] = [:]) throws -> (AppState, CatalogStore, [String]) {
        let photos = (0..<count).map { index in
            Asset(id: photoId(index), pid: 1, ori: "l", thumb: "", preview: "", filename: "p\(index).jpg", type: "JPG",
                  isRaw: false, folderId: "src-people", folderName: "Source",
                  date: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 3600), width: 80, height: 60,
                  orientation: 1, camera: "", lens: "", focal: 0, aperture: 0, shutter: "", iso: 0, colorSpace: "sRGB",
                  fileMB: 0.01, rating: 0, flag: .none, keywords: KeywordService.normalize(keywords[index] ?? []),
                  title: "", caption: "", location: "", gps: (0, 0), status: .ready, importedAt: .now,
                  localPath: scratch.appendingPathComponent("Source/p\(index).jpg").path, isDemo: false)
        }
        let store = try CatalogStore(packageURL: scratch.appendingPathComponent("People.photolibrary"))
        try store.upsert(photos)
        try store.saveFaceScans(Dictionary(grouping: faces, by: \.assetId))
        let app = AppState.selfCheckFixture(store: store)
        app.runsBackgroundMaintenance = false
        app.autoWriteXMPSidecar = false   // nothing beside the scratch catalog
        app.assets = photos
        app.duplicateGroupsCache = []
        app.loadFaces(from: store)
        app.undoManager = undo
        return (app, store, photos.map(\.id))
    }
}
