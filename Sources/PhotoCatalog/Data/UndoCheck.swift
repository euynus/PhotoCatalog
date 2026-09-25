import Foundation

/// Catalog edits undo and redo through the window's UndoManager.
enum UndoCheck {
    static func run() {
        MainActor.assumeIsolated { check() }
        print("--- undo/redo assertions passed ---")
    }

    @MainActor
    private static func check() {
        let undo = UndoManager()
        undo.groupsByEvent = false   // no run loop here to close event groups
        let app = AppState.selfCheckFixture()
        app.undoManager = undo
        app.assets = Array(DemoData.assets.prefix(4)).map {
            var asset = $0
            asset.rating = 0
            asset.flag = .none
            asset.keywords = []
            return asset
        }
        app.duplicateGroupsCache = []
        app.select(Selection(type: .lib, id: "all", name: "Undo check"))
        let first = app.list[0].id
        app.setPrimary(first)
        func asset(_ id: String) -> Asset { app.assets.first { $0.id == id }! }
        func step(_ action: () -> Void) {
            undo.beginUndoGrouping()
            action()
            undo.endUndoGrouping()
        }

        step { _ = app.handleKey("3", hasCommand: false) }
        assert(asset(first).rating == 3 && undo.canUndo && undo.undoActionName == "评分",
               "a rating registers a named undo step")
        undo.undo()
        assert(asset(first).rating == 0 && app.libraryCounts.unrated == 4 && undo.canRedo,
               "undo restores the rating and its counts")
        undo.redo()
        assert(asset(first).rating == 3 && app.libraryCounts.unrated == 3, "redo reapplies it")

        step { app.addKeyword("撤销") }
        assert(asset(first).keywords == ["撤销"])
        undo.undo()
        assert(asset(first).keywords.isEmpty && asset(first).rating == 3,
               "undoing a keyword leaves the earlier rating in place")

        step { app.removeSelected() }
        assert(asset(first).deleted && !app.list.contains { $0.id == first })
        undo.undo()
        assert(!asset(first).deleted && app.list.contains { $0.id == first },
               "undo brings a photo removed from the catalog back into the list")
    }
}
