import Foundation
import Observation

enum AssetEditCheck {
    static func run() {
        MainActor.assumeIsolated {
            checkCombinedEdits()
            checkMixedBatch()
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("pc-asset-edits-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try checkExplicitReviewTargets(in: directory)
                try checkSidecarEdit(in: directory)
            } catch {
                fatalError("Asset edit check failed: \(error)")
            }
        }
        print("--- asset edit assertions passed ---")
    }

    @MainActor
    private static func fixture() -> AppState {
        let app = AppState.selfCheckFixture()
        app.assets = Array(DemoData.assets.prefix(3)).map {
            var asset = $0
            asset.rating = 0
            asset.flag = .none
            asset.keywords = ["before"]
            asset.deleted = false
            return asset
        }
        app.duplicateGroupsCache = []
        app.select(Selection(type: .lib, id: "all", name: "Asset edits"))
        return app
    }

    @MainActor
    private static func checkCombinedEdits() {
        let app = fixture()
        let undo = UndoManager()
        undo.groupsByEvent = false
        app.undoManager = undo
        var filters = Filters()
        filters.minRating = 4
        app.setFilters(filters)
        let id = app.assets[0].id
        assert(app.libraryCounts.unrated == 3 && app.photoList.isEmpty,
               "warm both count and filtered-list caches before a combined edit")
        _ = app.keywordList
        let invalidated = CancellationFlag()
        withObservationTracking {
            _ = app.libraryCounts
            _ = app.photoList
            _ = app.keywordList
        } onChange: { invalidated.set() }
        undo.beginUndoGrouping()
        assert(app.mutate([id], undoName: "Combined edit", writingSidecars: false) {
            $0.rating = 5
            $0.keywords = ["after"]
        })
        undo.endUndoGrouping()
        assert(invalidated.isSet, "cache hits still register observable dependencies")
        assert(app.libraryCounts.unrated == 2,
               "a combined rating/keyword edit updates warmed review counts")
        assert(app.photoList.map(\.id) == [id],
               "a combined rating/keyword edit changes rating-filter membership")
        assert(app.keywordList.first { $0.name == "after" }?.count == 1
               && app.keywordList.first { $0.name == "before" }?.count == 2,
               "the same combined edit also updates warmed keyword counts")
        undo.undo()
        assert(app.libraryCounts.unrated == 3 && app.photoList.isEmpty
               && app.keywordList.first { $0.name == "before" }?.count == 3,
               "undo restores both effects and filtered membership")
        undo.redo()
        assert(app.libraryCounts.unrated == 2 && app.photoList.map(\.id) == [id]
               && app.keywordList.first { $0.name == "after" }?.count == 1,
               "redo reapplies both effects")
    }

    @MainActor
    private static func checkMixedBatch() {
        let app = fixture()
        let first = app.assets[0].id, second = app.assets[1].id
        app.select(Selection(type: .lib, id: "unrated", name: "Unrated"))
        assert(app.photoList.count == 3 && app.libraryCounts.unrated == 3)
        _ = app.keywordList
        assert(app.mutate([first, second], writingSidecars: false) { asset in
            if asset.id == first { asset.rating = 4 }
            if asset.id == second { asset.keywords = ["batch"] }
        })
        assert(app.libraryCounts.unrated == 2 && !app.photoList.contains { $0.id == first }
               && app.keywordList.first { $0.name == "batch" }?.count == 1,
               "different photos in one batch contribute all their effects")

        app.setSort(Sort(field: .rating, descending: true))
        app.select(Selection(type: .lib, id: "all", name: "All"))
        let before = app.photoList
        assert(app.mutate([second], writingSidecars: false) { $0.title = "Metadata only" })
        assert(app.photoList == before, "metadata-only edits keep a rating-sorted list's identity")
        assert(app.mutate([second], writingSidecars: false) { $0.rating = 5; $0.title = "Mixed" })
        assert(app.photoList != before && app.photoList.first?.id == second,
               "combined edits re-sort a rating-dependent list")
    }

    @MainActor
    private static func checkExplicitReviewTargets(in directory: URL) throws {
        let raws = DemoData.assets.filter(\.isRaw)
        func photo(_ base: Asset, _ name: String) -> Asset {
            var asset = base
            asset.localPath = directory.appendingPathComponent(name).path
            asset.filename = name
            asset.isDemo = false
            asset.deleted = false
            asset.rating = 0
            asset.flag = .none
            asset.colorLabel = nil
            return asset
        }
        let raw = photo(raws[0], "Paired.CR3")
        let jpeg = photo(DemoData.assets.first { !$0.isRaw }!, "Paired.JPG")
        let solo = photo(raws[1], "Solo.CR3")
        let store = try CatalogStore(packageURL: directory.appendingPathComponent("Review.photolibrary"))
        try store.upsert([raw, jpeg, solo])
        let app = AppState.selfCheckFixture(store: store)
        let pairing = app.pairRawAndJpeg, automaticXMP = app.autoWriteXMPSidecar
        defer {
            app.pairRawAndJpeg = pairing
            app.autoWriteXMPSidecar = automaticXMP
        }
        app.pairRawAndJpeg = true
        app.autoWriteXMPSidecar = false
        app.assets = [raw, jpeg, solo]
        app.duplicateGroupsCache = []
        app.select(Selection(type: .lib, id: "all", name: "Review"))
        app.setPrimary(solo.id)
        let before = app.photoList
        assert(app.libraryCounts.unrated == 2 && before.count == 2)
        let undo = UndoManager()
        undo.groupsByEvent = false
        app.undoManager = undo
        undo.beginUndoGrouping()
        assert(app.setRating(4, on: [raw.id]))
        undo.endUndoGrouping()
        let pairIDs: Set<String> = [raw.id, jpeg.id]
        assert(app.assets.filter { pairIDs.contains($0.id) }.allSatisfy { $0.rating == 4 }
               && app.asset(id: solo.id)?.rating == 0 && app.selectedIds == [solo.id],
               "an explicit review target expands its pair without editing the selection")
        assert(app.photoList == before && app.libraryCounts.unrated == 1,
               "explicit review edits preserve list identity and count each pair once")
        undo.undo()
        assert(app.assets.allSatisfy { $0.rating == 0 } && app.libraryCounts.unrated == 2,
               "explicit review undo restores both files")
        undo.redo()
        assert(app.assets.filter { pairIDs.contains($0.id) }.allSatisfy { $0.rating == 4 })
        undo.beginUndoGrouping()
        assert(app.setFlag(.pick, on: [raw.id]) && app.setColor(.green, on: [raw.id]))
        undo.endUndoGrouping()
        assert(app.libraryCounts.picks == 1 && app.photoList == before)
        let saved = try store.loadAssets()
        assert(saved.filter { pairIDs.contains($0.id) }.allSatisfy {
            $0.rating == 4 && $0.flag == .pick && $0.colorLabel == .green
        }, "all review commands persist the explicit pair")

        undo.removeAllActions()
        let counts = app.libraryCounts
        try store.db.execChecked("""
        CREATE TRIGGER reject_review BEFORE UPDATE OF rating ON assets
        WHEN NEW.id='\(jpeg.id)' BEGIN SELECT RAISE(ABORT, 'blocked review'); END;
        """)
        assert(!app.setRating(1, on: [raw.id]), "a rejected pair update reports failure")
        assert(app.assets.filter { pairIDs.contains($0.id) }.allSatisfy { $0.rating == 4 }
               && app.photoList == before && app.libraryCounts == counts && !undo.canUndo,
               "failed persistence publishes neither edits nor an undo action")
        let rejected = try store.loadAssets()
        assert(rejected.filter { pairIDs.contains($0.id) }.allSatisfy { $0.rating == 4 },
               "the paired database update rolls back together")
        assert(!app.setFlag(.pick, on: ["missing"]) && !app.setRating(8, on: [raw.id]) && !undo.canUndo,
               "missing targets and invalid ratings do not create undo actions")

        app.undoManager = nil
        let demo = DemoData.assets.last!
        app.assets.append(demo)
        assert(app.setRating(3, on: [demo.id]) && store.assetCount() == 3,
               "demo review changes remain in memory even with a live catalog")
    }

    @MainActor
    private static func checkSidecarEdit(in directory: URL) throws {
        var asset = DemoData.assets[0]
        asset.localPath = directory.appendingPathComponent("Sidecar.CR3").path
        asset.isDemo = false
        asset.deleted = false
        asset.rating = 0
        asset.flag = .none
        asset.keywords = ["before"]
        let store = try CatalogStore(packageURL: directory.appendingPathComponent("Sidecar.photolibrary"))
        try store.upsert([asset])
        let app = AppState.selfCheckFixture(store: store)
        app.assets = [asset]
        app.duplicateGroupsCache = []
        app.select(Selection(type: .lib, id: "unrated", name: "Sidecar"))
        assert(app.photoList.count == 1 && app.libraryCounts.unrated == 1)
        _ = app.keywordList
        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmp:Rating="5">
        <dc:subject><rdf:Bag><rdf:li>sidecar</rdf:li></rdf:Bag></dc:subject>
        </rdf:Description></rdf:RDF></x:xmpmeta>
        """
        let sidecar = XMPSidecar.sidecarURL(for: URL(fileURLWithPath: asset.localPath!))
        try Data(xml.utf8).write(to: sidecar)
        assert(app.readMetadataFromFiles([asset.id], undoable: false) == 1)
        assert(app.libraryCounts.unrated == 0 && app.photoList.isEmpty
               && app.keywordList.first?.name == "sidecar",
               "reading rating and keywords from XMP refreshes the live list and counts")
        let saved = try store.loadAssets().first
        assert(saved?.rating == 5 && saved?.keywords == ["sidecar"],
               "the combined sidecar edit also persists")
    }
}
