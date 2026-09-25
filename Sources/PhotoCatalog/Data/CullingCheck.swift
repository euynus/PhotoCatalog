import Foundation

/// Culling keys keep the cursor's place, advance on Shift or auto-advance, and never move a batch.
enum CullingCheck {
    static func run() {
        MainActor.assumeIsolated { check() }
        print("--- culling rhythm assertions passed ---")
    }

    @MainActor
    private static func check() {
        assert(KeyCatcher.keyString(keyCode: 18, charactersIgnoringModifiers: "!") == "1"
               && KeyCatcher.keyString(keyCode: 29, charactersIgnoringModifiers: ")") == "0"
               && KeyCatcher.keyString(keyCode: 48, charactersIgnoringModifiers: "\t") == "tab",
               "Shift+digit and Tab reach the handler by key position")

        let app = AppState.selfCheckFixture()
        app.autoAdvance = false
        app.assets = Array(DemoData.assets.prefix(6)).map {
            var asset = $0
            asset.rating = 0
            asset.flag = .none
            return asset
        }
        app.duplicateGroupsCache = []

        app.select(Selection(type: .lib, id: "unrated", name: "未评分"))
        var ids = app.list.map(\.id)
        app.setPrimary(ids[1])
        _ = app.handleKey("3", hasCommand: false)
        assert(app.primaryId == ids[2] && app.list.count == 5,
               "rating inside 未评分 selects the photo that slid into the slot, not the first")

        app.select(Selection(type: .lib, id: "all", name: "全部照片"))
        ids = app.list.map(\.id)
        app.setPrimary(ids[0])
        _ = app.handleKey("p", hasCommand: false, hasShift: true)
        assert(app.primaryId == ids[1], "Shift with a flag key advances once")
        _ = app.handleKey("x", hasCommand: false)
        assert(app.primaryId == ids[1], "without Shift or auto-advance the cursor stays")

        app.autoAdvance = true
        _ = app.handleKey("2", hasCommand: false)
        assert(app.primaryId == ids[2], "auto-advance moves on after a rating")
        app.selectedIds = [ids[3], ids[4]]
        app.primaryId = ids[3]
        _ = app.handleKey("4", hasCommand: false)
        assert(app.primaryId == ids[3] && app.selectedIds == [ids[3], ids[4]],
               "a batch edit never moves the cursor")
        app.autoAdvance = false

        app.showInspector = true
        app.sidebarVisible = true
        _ = app.handleKey("tab", hasCommand: false)
        assert(!app.sidebarVisible && !app.showInspector, "Tab hides both side panels")
        _ = app.handleKey("tab", hasCommand: false)
        assert(app.sidebarVisible && app.showInspector, "Tab again brings both back")
    }
}
