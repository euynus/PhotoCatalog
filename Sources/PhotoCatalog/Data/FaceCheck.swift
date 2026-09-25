import Foundation

/// People: clustering and matching rules, and naming / merging / removing faces with their keywords.
enum FaceCheck {
    static func run() {
        checkRules()
        MainActor.assumeIsolated { checkNaming() }
        print("--- people assertions passed ---")
    }

    /// A unit-length 8-d vector near axis `axis`, nudged by `jitter` along the next axis.
    private static func vector(_ axis: Int, _ jitter: Float) -> [Float] {
        var v = [Float](repeating: 0, count: 8)
        v[axis] = 1
        v[(axis + 1) % 8] = jitter
        let norm = (1 + jitter * jitter).squareRoot()
        return v.map { $0 / norm }
    }

    private static func face(_ id: String, _ asset: String, _ axis: Int, _ jitter: Float, quality: Float = 0.5,
                             person: String? = nil, confirmed: Bool = false) -> FaceRecord {
        FaceRecord(id: id, assetId: asset, box: CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.2), quality: quality,
                   vector: vector(axis, jitter), person: person, confirmed: confirmed)
    }

    private static func checkRules() {
        let faces = [face("a1", "p1", 0, 0.05, quality: 0.9), face("a2", "p2", 0, 0.1), face("a3", "p3", 0, 0.15),
                     face("b1", "p1", 3, 0.05), face("b2", "p4", 3, 0.1), face("c1", "p5", 6, 0),
                     face("blur", "p6", 0, 0.05, quality: 0.1)]
        let clusters = FaceClustering.clusters(faces)
        assert(clusters.map { Set($0.faceIds) } == [["a1", "a2", "a3"], ["b1", "b2"], ["c1"]],
               "nearby faces group together, largest group first; blurry faces stay out")
        assert(clusters[0].id == "a1", "the clearest face seeds its group")

        let named = [face("n1", "q1", 3, 0, person: "B", confirmed: true), face("n2", "q2", 0, 0, person: "A")]
        let matches = FaceClustering.matches(for: faces, named: named)
        assert(matches["b1"] == "B" && matches["b2"] == "B" && matches["a1"] == nil,
               "unnamed faces take the name of a close confirmed face; unconfirmed names don't spread")
        assert(FaceClustering.person(fromKeyword: "人物/小明") == "小明" && FaceClustering.person(fromKeyword: "旅行") == nil
               && FaceClustering.cleanName(" A/B ") == "A-B", "person keywords and names are recognised")
    }

    @MainActor
    private static func checkNaming() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pc-faces-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        guard let store = try? CatalogStore(packageURL: directory.appendingPathComponent("Faces.photolibrary")) else {
            preconditionFailure("could not create a scratch catalog")
        }
        let photos = DemoData.assets.prefix(4).enumerated().map { index, base -> Asset in
            var asset = base
            asset.localPath = "/tmp/pc-faces/\(index).jpg"
            asset.isDemo = false
            asset.keywords = []
            return asset
        }
        try? store.upsert(photos)
        let ids = photos.map(\.id)
        try? store.saveFaceScans([
            ids[0]: [face("x0", ids[0], 0, 0.02, quality: 0.9), face("y0", ids[0], 4, 0.02)],
            ids[1]: [face("x1", ids[1], 0, 0.08)],
            ids[2]: [face("x2", ids[2], 0, 0.12)],
            ids[3]: [face("y3", ids[3], 4, 0.06)],
        ])
        let app = AppState.selfCheckFixture(store: store)
        app.assets = photos
        app.duplicateGroupsCache = []
        app.loadFaces(from: store)
        let deadline = Date().addingTimeInterval(5)
        while app.faceClusters.count < 2, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        assert(app.faceClusters.map(\.faceIds.count) == [3, 2] && app.faceScannedCount == 4,
               "saved faces load and group into people-sized clusters")

        let undo = UndoManager()
        undo.groupsByEvent = false
        app.undoManager = undo
        undo.beginUndoGrouping()
        app.nameFaces(["x0", "x1", "x2"], as: "小明")
        undo.endUndoGrouping()
        let tagged = { (id: String) in app.asset(id: id)?.keywords.contains("人物/小明") == true }
        assert(app.people.map(\.name) == ["小明"] && app.people[0].photoCount == 3 && tagged(ids[0]) && tagged(ids[2])
               && !tagged(ids[3]), "naming a group tags exactly its photos")
        assert(app.faceClusters.map(\.faceIds) == [["y0", "y3"]], "named faces leave the unnamed groups")
        assert((try? store.loadFaces())?.first { $0.id == "x1" }?.person == "小明", "names persist")
        undo.undo()
        assert(app.people.isEmpty && !tagged(ids[0]), "one undo takes the name and the keywords back")
        undo.redo()
        assert(app.people.first?.photoCount == 3 && tagged(ids[1]), "redo names them again")
        app.undoManager = nil

        app.nameFaces(["y0", "y3"], as: "小明")
        assert(app.people.count == 1 && app.people[0].photoCount == 4, "a second group named alike merges into the person")
        app.removeFaceFromPerson("y3")
        assert(!tagged(ids[3]) && tagged(ids[0]), "not-this-person drops the keyword only where no other face is them")

        app.renamePerson("小明", to: "明明")
        assert(app.people.map(\.name) == ["明明"] && app.asset(id: ids[1])?.keywords.contains("人物/明明") == true
               && app.face("x1")?.person == "明明", "renaming a person renames faces and keywords")
        app.deletePerson("明明")
        assert(app.people.isEmpty && app.face("x1")?.person == nil
               && !(app.asset(id: ids[1])?.keywords.contains { $0.hasPrefix("人物") } ?? true),
               "deleting a person un-names the faces and removes the keyword")

        // a person keyword typed by hand is left alone when faces in the photo are named
        _ = app.mutate([ids[3]]) { $0.keywords = KeywordService.normalize(["人物/小红", "海"]) }
        app.nameFaces(["y3"], as: "小刚")
        let manual = app.asset(id: ids[3])?.keywords ?? []
        assert(manual.contains("人物/小红") && manual.contains("人物/小刚") && manual.contains("海"),
               "naming faces never removes other person keywords")

        // a suggestion (unconfirmed) tags nothing until the user confirms it
        try? store.setFacePeople(["x2": ("小刚", false)])
        app.loadFaces(from: store)
        assert(app.asset(id: ids[2])?.keywords.contains("人物/小刚") == false
               && app.people.first { $0.name == "小刚" }?.unconfirmed == 1, "suggestions wait for confirmation")
        app.confirmFaces(of: "小刚")
        assert(app.asset(id: ids[2])?.keywords.contains("人物/小刚") == true && app.face("x2")?.confirmed == true,
               "confirming tags the photo")
    }
}
