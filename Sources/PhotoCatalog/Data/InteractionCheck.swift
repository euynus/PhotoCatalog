import AppKit

enum InteractionCheck {
    static func run() {
        MainActor.assumeIsolated { check() }
        print("--- interaction routing assertions passed ---")
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
        let unhandled = event("z", keyCode: 6)
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
        assert(route(event("5", keyCode: 23)) == nil,
               "rating shortcuts must reach the current Compare selection")
        assert(app.assets.allSatisfy { $0.rating == (compared.contains($0.id) ? 5 : 0) },
               "no photo outside the Compare panels may be rated")

        app.view = .grid
        app.sheet = "settings"
        assert(!app.canChangeVisibleSelection && !app.selectAllVisible() && !app.invertVisibleSelection()
               && app.selectedIds == compared, "overlay sheets also block direct selection commands")
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
