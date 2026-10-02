import Foundation
import CoreGraphics

/// People: clustering and matching rules, the face model and alignment, naming / merging /
/// removing faces with their keywords, and faces from an earlier method analysed again.
enum FaceCheck {
    static func run() {
        checkRules()
        checkRecognition()
        MainActor.assumeIsolated { checkNaming() }
        print("--- people assertions passed ---")
    }

    /// A unit-length vector near axis `axis`, nudged by `jitter` along the next axis.
    private static func vector(_ axis: Int, _ jitter: Float, length: Int = FaceClustering.vectorLength) -> [Float] {
        var v = [Float](repeating: 0, count: length)
        v[axis] = 1
        v[(axis + 1) % length] = jitter
        let norm = (1 + jitter * jitter).squareRoot()
        return v.map { $0 / norm }
    }

    private static func face(_ id: String, _ asset: String, _ axis: Int, _ jitter: Float, quality: Float = 0.5,
                             person: String? = nil, confirmed: Bool = false, length: Int = FaceClustering.vectorLength,
                             box: CGRect = CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.2)) -> FaceRecord {
        FaceRecord(id: id, assetId: asset, box: box, quality: quality,
                   vector: vector(axis, jitter, length: length), person: person, confirmed: confirmed)
    }

    private static func checkRules() {
        let faces = [face("a1", "p1", 0, 0.05, quality: 0.9), face("a2", "p2", 0, 0.1), face("a3", "p3", 0, 0.15),
                     face("b1", "p1", 3, 0.05), face("b2", "p4", 3, 0.1), face("c1", "p5", 6, 0),
                     face("blur", "p6", 0, 0.05, quality: 0.05), face("print", "p7", 0, 0.05, length: 768)]
        let clusters = FaceClustering.clusters(faces)
        assert(clusters.map { Set($0.faceIds) } == [["a1", "a2", "a3"], ["b1", "b2"], ["c1"]],
               "nearby faces group together, largest group first; blurry faces and an earlier method's prints stay out")
        assert(clusters[0].id == "a1", "the clearest face seeds its group")

        let named = [face("n1", "q1", 3, 0, person: "B", confirmed: true), face("n2", "q2", 0, 0, person: "A")]
        let matches = FaceClustering.matches(for: faces, named: named)
        assert(matches["b1"] == "B" && matches["b2"] == "B" && matches["a1"] == nil,
               "unnamed faces take the name of a close confirmed face; unconfirmed names don't spread")
        assert(FaceClustering.person(fromKeyword: "人物/小明") == "小明" && FaceClustering.person(fromKeyword: "旅行") == nil
               && FaceClustering.cleanName(" A/B ") == "A-B", "person keywords and names are recognised")

        // analysed again: names follow the overlapping box; a named face not found again stays
        let left = CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.25), right = CGRect(x: 0.6, y: 0.2, width: 0.2, height: 0.25)
        let earlier = [face("e-f0", "e", 0, 0, person: "A", confirmed: true, length: 768, box: left),
                       face("e-f1", "e", 1, 0, person: "B", length: 768, box: right),
                       face("e-f2", "e", 2, 0, person: "C", confirmed: true, length: 768, box: CGRect(x: 0.4, y: 0.7, width: 0.1, height: 0.1)),
                       face("e-f3", "e", 3, 0, length: 768, box: CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1))]
        let again = FaceClustering.carryNames(from: earlier, to: [face("e-f0", "e", 4, 0, box: right.offsetBy(dx: 0.01, dy: 0)),
                                                                   face("e-f1", "e", 5, 0, box: left.insetBy(dx: 0.01, dy: 0.01)),
                                                                   face("e-f2", "e", 6, 0, box: CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1))])
        let byId = Dictionary(uniqueKeysWithValues: again.map { ($0.id, $0) })
        assert(byId["e-f0"]?.person == "B" && byId["e-f0"]?.confirmed == false && byId["e-f1"]?.person == "A"
               && byId["e-f1"]?.confirmed == true && byId["e-f2"]?.person == nil,
               "names and confirmation follow the face's box, not its number")
        assert(again.count == 4 && byId["e-f2-earlier"]?.person == "C" && byId["e-f2-earlier"]?.vector.isEmpty == true
               && byId["e-f2-earlier"]?.confirmed == true, "a named face not found again keeps its name, without a vector")
    }

    /// The bundled model and the alignment that feeds it.
    private static func checkRecognition() {
        guard let model = AIModels.model(.faceRecognition) else { return assertionFailure("the face recognition model is bundled") }
        // the template moved, turned and scaled is brought back onto itself
        let turn = CGAffineTransform(rotationAngle: 0.3).scaledBy(x: 2.5, y: 2.5).concatenating(CGAffineTransform(translationX: 400, y: 120))
        let moved = FaceService.template.map { $0.applying(turn) }
        let back = FaceService.similarity(from: moved, to: FaceService.template)
        assert(zip(moved, FaceService.template).allSatisfy { hypot($0.applying(back).x - $1.x, $0.applying(back).y - $1.y) < 1e-6 },
               "the similarity fit undoes a rotation, scale and shift")

        // a white dot where a face's left eye is lands on the template's left eye (top-left origins throughout)
        let width = 800, height = 600
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return assertionFailure("a canvas") }
        context.setFillColor(CGColor(gray: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        let eye = moved[0]
        context.fill(CGRect(x: eye.x - 6, y: CGFloat(height) - eye.y - 6, width: 12, height: 12))
        guard let photo = context.makeImage(), let crop = FaceService.aligned(photo, points: moved),
              let pixels = crop.dataProvider?.data, let bytes = CFDataGetBytePtr(pixels) else { return assertionFailure("an aligned face") }
        func brightness(_ point: CGPoint) -> UInt8 { bytes[Int(point.y) * crop.bytesPerRow + Int(point.x) * 4] }
        assert(crop.width == FaceService.side && brightness(FaceService.template[0]) > 200 && brightness(FaceService.template[1]) < 100,
               "alignment puts the left eye on the template's left eye, upright")

        guard let vector = FaceService.embedding(crop, model: model) else { return assertionFailure("the model answers") }
        let length = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        assert(vector.count == FaceClustering.vectorLength && abs(length - 1) < 1e-3, "faces come out as unit vectors of the model's length")
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
        let app = AppState.selfCheckFixture(store: store)
        app.assets = photos
        app.duplicateGroupsCache = []

        // faces an earlier method read wait to be analysed again, their photos counted as not analysed
        try? store.saveFaceScans([ids[0]: [face("old", ids[0], 0, 0.02, person: "旧名", confirmed: true, length: 768)]])
        app.loadFaces(from: store)
        assert(app.faceOutdatedCount == 1 && app.faceScannedCount == 0 && app.people.map(\.name) == ["旧名"],
               "an earlier method's faces mark their photo for analysing again, names kept meanwhile")

        try? store.saveFaceScans([
            ids[0]: [face("x0", ids[0], 0, 0.02, quality: 0.9), face("y0", ids[0], 4, 0.02)],
            ids[1]: [face("x1", ids[1], 0, 0.08)],
            ids[2]: [face("x2", ids[2], 0, 0.12)],
            ids[3]: [face("y3", ids[3], 4, 0.06)],
        ])
        app.loadFaces(from: store)
        let deadline = Date().addingTimeInterval(5)
        while app.faceClusters.count < 2, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        assert(app.faceClusters.map(\.faceIds.count) == [3, 2] && app.faceScannedCount == 4 && app.faceOutdatedCount == 0,
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
