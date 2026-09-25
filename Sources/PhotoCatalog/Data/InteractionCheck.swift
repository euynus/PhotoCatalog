import AppKit

enum InteractionCheck {
    static func run() {
        MainActor.assumeIsolated {
            check()
            checkPhotoListIdentity()
            checkListPositions()
        }
        print("--- interaction routing assertions passed ---")
    }

    /// Cursor and membership lookups find a few photos from the last position or with one
    /// pass, and use the position index for batches; either way edits land in place.
    @MainActor
    private static func checkListPositions() {
        let app = AppState.selfCheckFixture()
        app.assets = Array(DemoData.assets.prefix(40)).map {
            var asset = $0
            asset.rating = 0
            asset.flag = .none
            return asset
        }
        app.duplicateGroupsCache = []
        app.select(Selection(type: .lib, id: "all", name: "Position check"))
        let ids = app.list.map(\.id)
        func listMatchesCatalog() -> Bool {
            let byId = Dictionary(uniqueKeysWithValues: app.assets.map { ($0.id, $0) })
            return app.list.map(\.id) == ids
                && app.list.allSatisfy { byId[$0.id]?.rating == $0.rating && byId[$0.id]?.flag == $0.flag }
        }

        app.setPrimary(ids[10])
        _ = app.handleKey("right", hasCommand: false)
        assert(app.primaryId == ids[11], "arrow keys step through the list")
        _ = app.setRating(3)
        assert(listMatchesCatalog() && app.list[11].rating == 3, "a rating lands on the photo just moved to")

        app.selectedIds = [ids[2], ids[30], ids[39]]
        app.primaryId = ids[30]
        _ = app.setRating(2)
        assert(listMatchesCatalog() && [2, 30, 39].allSatisfy { app.list[$0].rating == 2 },
               "a few scattered edits are found by one pass")

        app.selectedIds = Set(ids[12..<32])
        app.primaryId = ids[12]
        _ = app.setFlag(.pick)
        assert(listMatchesCatalog() && (12..<32).allSatisfy { app.list[$0].flag == .pick },
               "a batch edit lands in place")

        app.setPrimary(ids[25])
        _ = app.handleKey("left", hasCommand: false)
        assert(app.primaryId == ids[24], "navigation starts from the current photo, never an old position")
        app.setSort(Sort(field: .name, descending: true))
        let resorted = app.list.map(\.id)
        let moved = resorted.firstIndex(of: ids[24]) ?? 0
        _ = app.handleKey("right", hasCommand: false)
        assert(moved != 24 && app.primaryId == resorted[min(moved + 1, resorted.count - 1)],
               "after a re-sort navigation follows the new order")
        app.setSort(Sort())

        var rated = Filters()
        rated.minRating = 2
        app.selectedIds = [ids[2], ids[5], ids[30]]
        app.primaryId = ids[30]
        app.setFilters(rated)
        assert(app.selectedIds == [ids[2], ids[30]] && app.primaryId == ids[30],
               "a filter keeps just the visible photos of a small selection")
        app.setFilters(Filters())
        app.selectedIds = Set(ids[0..<20])
        app.primaryId = ids[2]
        app.setFilters(rated)
        assert(app.selectedIds == [ids[2], ids[11]] && app.primaryId == ids[2],
               "and of a large one")
    }

    /// Views compare `photoList` by identity alone, so an unchanged identity must always mean
    /// the same photos in the same order, while edits patched into place keep it.
    @MainActor
    private static func checkPhotoListIdentity() {
        let app = AppState.selfCheckFixture()
        app.assets = Array(DemoData.assets.prefix(12)).map {
            var asset = $0
            asset.rating = 0
            return asset
        }
        app.duplicateGroupsCache = []
        app.select(Selection(type: .lib, id: "all", name: "Photo list check"))
        let before = app.photoList
        guard let first = before.first else { return assertionFailure("the fixture lists photos") }
        app.setPrimary(first.id)
        _ = app.handleKey("4", hasCommand: false)
        let rated = app.photoList
        assert(rated == before && rated.map(\.id) == before.map(\.id)
               && rated.first { $0.id == first.id }?.rating == 4,
               "a rating patched into the list keeps its identity and shows the new value")

        app.setSort(Sort(field: .name, descending: true))
        let resorted = app.photoList
        assert(resorted != rated, "a new order is a new list")
        var filters = app.filters
        filters.minRating = 4
        app.setFilters(filters)
        let filtered = app.photoList
        assert(filtered != resorted && filtered.map(\.id) == [first.id], "a filtered list is a new list")
        assert(app.photoList == filtered, "reading an unchanged list keeps its identity")
    }

    @MainActor
    private static func check() {
        let app = AppState.selfCheckFixture()
        app.assets = Array(DemoData.assets.prefix(6)).map {
            var asset = $0
            asset.rating = 0
            return asset
        }
        app.duplicateGroupsCache = []
        app.select(Selection(type: .lib, id: "all", name: "Interaction check"))
        assert(!app.isLoadingCatalog && !app.hasOpenCatalog && app.onboarded,
               "fixture must reach real keyboard handling without opening a catalog")
        assert(app.assets.allSatisfy(\.isDemo), "rating checks must never write XMP sidecars")

        var calls = 0
        func route(_ event: NSEvent, menu: Bool = false, editing: Bool = false) -> NSEvent? {
            KeyCatcher.routeEvent(event, isMenuTracking: menu, isEditingText: editing) { key, command, shift in
                calls += 1
                return app.handleKey(key, hasCommand: command, hasShift: shift)
            }
        }

        let all = Set(app.list.map(\.id))
        let selected = app.selectedIds
        let invert = event("a", keyCode: 0, modifiers: [.command, .shift])
        let result = route(invert)
        if result != nil { _ = app.invertVisibleSelection() } // Model the downstream menu action.
        assert(result == nil && calls == 1 && app.selectedIds == all.subtracting(selected),
               "handled shortcuts are consumed exactly once, never repeated by the menu")

        calls = 0
        let unhandled = event("q", keyCode: 12)
        assert(route(unhandled) === unhandled && calls == 1,
               "unhandled events retain their identity after one handler call")
        let find = event("f", keyCode: 3, modifiers: .command)
        let focusToken = app.searchFocusToken
        calls = 0
        assert(route(find) === find && calls == 0 && app.searchFocusToken == focusToken,
               "menu-owned shortcuts pass through without invoking the photo handler")
        let modifierSets: [NSEvent.ModifierFlags] = [[.option], [.control], [.command, .option]]
        for flags in modifierSets {
            let shortcut = event("p", keyCode: 35, modifiers: flags)
            assert(route(shortcut) === shortcut && calls == 0, "system shortcuts pass through")
        }

        let escape = event("\u{1b}", keyCode: 53)
        app.filterOpen = true
        app.view = .loupe
        let beforeTyping = app.selectedIds
        for key in [escape, event("p", keyCode: 35), event("a", keyCode: 0, modifiers: .command)] {
            assert(route(key, menu: true) === key && calls == 0,
                   "native menu tracking must bypass application shortcuts")
            assert(route(key, editing: true) === key && calls == 0,
                   "text input, including select-all and Escape, belongs to the responder")
        }
        assert(app.filterOpen && app.view == .loupe && app.selectedIds == beforeTyping,
               "menu or text events must not change the underlying filter, view or selection")
        assert(route(escape) == nil && calls == 1 && !app.filterOpen && app.view == .loupe,
               "after tracking ends, Escape closes the filter exactly once")
        assert(route(escape) == nil && calls == 2 && app.view == .grid,
               "subsequent Escape returns from Loupe, proving loading did not swallow the checks")

        assert(app.canChangeVisibleSelection && app.selectAllVisible() && app.selectedIds == all,
               "grid select-all remains available through the shared menu capability")
        assert(app.invertVisibleSelection() && app.selectedIds.isEmpty && app.primaryId == nil,
               "grid inversion still works through the direct method")
        let ids = app.list.map(\.id)
        app.selectCell(ids[0], shift: false, meta: false)
        app.selectCell(ids[1], shift: false, meta: true)
        app.enterCompare()
        let compared = Set(app.compareIds)
        let primary = app.primaryId
        assert(compared.count == 2 && all.count > compared.count && !app.canChangeVisibleSelection,
               "Compare must disable the same capability read by both selection menu items")
        assert(!app.selectAllVisible() && !app.invertVisibleSelection(),
               "direct selection methods fail closed in Compare")
        for shortcut in [event("a", keyCode: 0, modifiers: .command), invert] {
            calls = 0
            assert(route(shortcut) == nil && calls == 1,
                   "disabled Compare shortcuts are consumed without falling through to menus")
        }
        assert(app.selectedIds == compared && Set(app.compareIds) == compared && app.primaryId == primary,
               "keyboard, menu capability and direct methods preserve the compared selection")
        let foldersBefore = app.folderTree
        let datesBefore = app.captureDateGroups.map(\.count)
        let unratedBefore = app.libraryCounts.unrated
        _ = app.list   // a current list cache takes the in-place patch path
        assert(route(event("5", keyCode: 23)) == nil,
               "rating shortcuts must reach the current Compare selection")
        assert(app.assets.allSatisfy { $0.rating == (compared.contains($0.id) ? 5 : 0) },
               "no photo outside the Compare panels may be rated")
        assert(app.libraryCounts.unrated == unratedBefore - compared.count,
               "review edits refresh rating-dependent counts")
        assert(app.folderTree == foldersBefore && app.captureDateGroups.map(\.count) == datesBefore,
               "review edits keep the folder and capture-date trees")
        assert(app.libraryCounts.unrated
               == app.assets.filter { !$0.deleted && $0.rating == 0 && $0.flag != .reject }.count,
               "patched library counts match a full count")
        let patched = app.list
        var resort = app.sort
        resort.descending.toggle(); app.setSort(resort)
        resort.descending.toggle(); app.setSort(resort)
        assert(app.list.map(\.id) == patched.map(\.id) && app.list.map(\.rating) == patched.map(\.rating),
               "a list patched after a review edit matches a full recompute")

        app.view = .grid
        app.sheet = "settings"
        assert(!app.canChangeVisibleSelection && !app.selectAllVisible() && !app.invertVisibleSelection()
               && app.selectedIds == compared, "overlay sheets also block direct selection commands")

        app.sheet = nil
        let datedBefore = app.captureDateGroups.reduce(0) { $0 + $1.count }
        assert(app.mutate([ids[0]]) { $0.deleted = true }
               && app.captureDateGroups.reduce(0) { $0 + $1.count } == datedBefore - 1,
               "structural edits still rebuild the capture-date tree")

        app.view = .grid
        app.selectCell(ids[1], shift: false, meta: false)
        assert(app.handleKey("z", hasCommand: false) && app.view == .loupe && app.loupeZoom == .actualSize,
               "Z from the grid opens the photo at 1:1")
        assert(app.handleKey("right", hasCommand: false) && app.loupeZoom == .actualSize,
               "stepping to the next photo keeps the zoom")
        assert(app.handleKey("escape", hasCommand: false) && app.view == .loupe && app.loupeZoom == nil,
               "Esc leaves zoom before leaving Loupe")
        assert(app.handleKey("escape", hasCommand: false) && app.view == .grid, "a second Esc returns to the grid")
    }

    private static func event(_ characters: String, keyCode: UInt16,
                              modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                          timestamp: 0, windowNumber: 0, context: nil,
                                          characters: characters, charactersIgnoringModifiers: characters,
                                          isARepeat: false, keyCode: keyCode) else {
            preconditionFailure("Could not create the interaction-check event")
        }
        return event
    }
}
