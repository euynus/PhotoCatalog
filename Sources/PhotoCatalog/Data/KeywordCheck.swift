import Foundation

/// Keyword management: rename (with sub-keywords), merge and delete across the catalog.
enum KeywordCheck {
    static func run() {
        checkRules()
        MainActor.assumeIsolated { checkCatalogEdits() }
        print("--- keyword management assertions passed ---")
    }

    private static func checkRules() {
        let photo = ["旅行", "旅行/日本", "旅行/日本/东京", "海"]
        assert(KeywordService.replacing("旅行/日本", with: "旅行/Japan", in: photo)
               == ["旅行", "旅行/Japan", "旅行/Japan/东京", "海"], "renaming carries sub-keywords along")
        assert(KeywordService.replacing("旅行", with: "出行", in: photo)
               == ["出行", "出行/日本", "出行/日本/东京", "海"], "renaming a parent renames the whole tree")
        assert(KeywordService.replacing("海", with: "旅行", in: photo) == ["旅行", "旅行/日本", "旅行/日本/东京"],
               "renaming onto an existing keyword merges them")
        assert(KeywordService.replacing("旅行/日本", with: nil, in: photo) == ["旅行", "海"],
               "deleting removes the keyword and what is under it, keeping its parent")
        assert(KeywordService.replacing("旅", with: "X", in: photo) == photo, "prefixes of a name don't match")
        assert(KeywordService.replacing("海", with: "自然/海", in: ["海"]) == ["自然", "自然/海"],
               "moving under a new parent adds the parent")
    }

    @MainActor
    private static func checkCatalogEdits() {
        let app = AppState.selfCheckFixture()
        app.assets = DemoData.assets
        app.duplicateGroupsCache = []
        let travel = app.photoIds(withKeyword: "旅行")
        let scenery = app.photoIds(withKeyword: "风光")
        assert(!travel.isEmpty && !scenery.isEmpty, "the demo catalog has keywords to work with")

        app.select(Selection(type: .keyword, id: "旅行", name: "旅行"))
        assert(app.renameKeyword("旅行", to: "出行"), "rename succeeds")
        assert(app.photoIds(withKeyword: "旅行").isEmpty && app.photoIds(withKeyword: "出行") == travel,
               "every photo moves to the new name")
        assert(app.selection.type == .keyword && app.selection.id == "出行", "the sidebar follows the rename")
        assert(!app.renameKeyword("出行", to: "出行/子"), "a keyword can't move into its own subtree")

        assert(app.renameKeyword("风光", to: "出行"), "renaming onto an existing keyword merges")
        assert(app.photoIds(withKeyword: "出行") == travel.union(scenery)
               && app.keywordList.contains { $0.name == "出行" && $0.count == travel.union(scenery).count }
               && !app.keywordList.contains { $0.name == "风光" }, "a merge unites both photo sets")

        assert(app.deleteKeyword("出行"), "delete succeeds")
        assert(app.photoIds(withKeyword: "出行").isEmpty && app.selection.type == .lib,
               "delete clears the keyword everywhere and leaves its sidebar entry")
    }
}
