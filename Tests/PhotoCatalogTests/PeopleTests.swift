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
