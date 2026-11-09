import AppKit
import XCTest
@testable import PhotoCatalog

/// The ⌘ keys the menu bar owns are one set: the key monitor lets them go on to the menu (all but
/// ⌘A, which the library answers itself), and while a sheet is up every one is kept from the
/// photos behind it. ⌘A and ⇧⌘A say what they did the same way from the key and from the menu.
final class CommandShortcutKeysTests: CatalogTestCase {
    /// A key that types each key of the set on a US layout, and the characters it types.
    private static let typed: [String: (code: UInt16, characters: String)] = [
        "n": (45, "n"), "o": (31, "o"), "f": (3, "f"), "i": (34, "i"), "e": (14, "e"), "r": (15, "r"),
        ",": (43, ","), "b": (11, "b"), "s": (1, "s"), "a": (0, "a"), "=": (24, "="), "+": (24, "+"),
        "-": (27, "-"), "0": (29, "0"), "delete": (117, "\u{F728}"), "backspace": (51, "\u{7f}"),
    ]

    @MainActor
    private func library() -> AppState {
        let app = AppState.selfCheckFixture()
        app.assets = Array(DemoData.assets.prefix(6))
        app.select(Selection(type: .lib, id: "all", name: "Command keys"))
        XCTAssertNotNil(app.primaryId)
        return app
    }

    /// Unshown windows: attaching a real sheet (beginSheet) would put both on screen.
    @MainActor
    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    @MainActor
    private func commandEvent(_ key: String, in window: NSWindow) throws -> NSEvent {
        let typed = try XCTUnwrap(Self.typed[key], "a key for \(key)")
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: typed.characters,
            charactersIgnoringModifiers: typed.characters, isARepeat: false, keyCode: typed.code))
        XCTAssertEqual(KeyCatcher.keyString(keyCode: event.keyCode,
                                            charactersIgnoringModifiers: event.charactersIgnoringModifiers), key)
        return event
    }

    func testTheSetIsTheMenusKeysAndCommandA() {
        XCTAssertEqual(AppState.commandShortcutKeys, [
            "n", "o", "i", ",", "e", "delete", "backspace", "f", "=", "+", "-", "0", "r", "b", "s", "a",
        ])
        XCTAssertEqual(Set(Self.typed.keys), AppState.commandShortcutKeys)
    }

    @MainActor
    func testTheMenusKeysPassThroughTheKeyMonitorAndCommandAStaysWithTheLibrary() throws {
        for key in AppState.commandShortcutKeys {
            XCTAssertEqual(KeyCatcher.shouldPassThroughMenuCommand(key, hasCommand: true), key != "a", "⌘\(key)")
            XCTAssertFalse(KeyCatcher.shouldPassThroughMenuCommand(key, hasCommand: false), key)
        }
        for key in ["q", "w", "z", "c", "1", "escape", "left", "return"] {
            XCTAssertFalse(KeyCatcher.shouldPassThroughMenuCommand(key, hasCommand: true), "⌘\(key) isn't the menu's")
        }

        let app = library()
        let visible = Set(app.list.map(\.id))
        let host = window()
        defer { host.close() }
        for key in AppState.commandShortcutKeys {
            let event = try commandEvent(key, in: host)
            var handled: [String] = []
            let routed = KeyCatcher.routeEvent(event, hostWindow: host, isMenuTracking: false, isEditingText: false) {
                handled.append($0)
                return app.handleKey($0, hasCommand: $1, hasShift: $2)
            }
            if key == "a" {
                XCTAssertNil(routed, "⌘A is answered by the library")
                XCTAssertEqual(handled, ["a"])
            } else {
                XCTAssertTrue(routed === event, "⌘\(key) goes on to the menu")
                XCTAssertEqual(handled, [], "⌘\(key) isn't handled twice")
            }
        }
        XCTAssertEqual(app.selectedIds, visible, "⌘A selected the list")
        XCTAssertEqual(app.toastCenter.toasts.last?.message, "已全选当前列表")
    }

    @MainActor
    func testASheetKeepsEveryOneOfTheKeysFromThePhotosBehindIt() throws {
        let app = library()
        let host = window(), sheetWindow = window()
        defer { for window in [host, sheetWindow] { window.close() } }
        let parent: (NSWindow) -> NSWindow? = { $0 === sheetWindow ? host : nil }

        app.sheet = "rename"
        let before = (selected: app.selectedIds, primary: app.primaryId, view: app.view,
                      inspector: app.showInspector, filterOpen: app.filterOpen, thumbSize: app.thumbSize,
                      assets: app.assets.map(\.id), toasts: app.toastCenter.toasts.count)
        for key in AppState.commandShortcutKeys {
            XCTAssertTrue(app.handleKey(key, hasCommand: true), "⌘\(key)")
            XCTAssertTrue(app.handleKey(key, hasCommand: true, hasShift: true), "⇧⌘\(key)")
            let event = try commandEvent(key, in: sheetWindow)
            let routed = KeyCatcher.routeEvent(event, hostWindow: host, presentsSheet: true, isMenuTracking: false,
                                               isEditingText: false, sheetParent: parent) {
                app.handleKey($0, hasCommand: $1, hasShift: $2)
            }
            XCTAssertNil(routed, "⌘\(key) from the sheet stops at the monitor")
        }
        XCTAssertFalse(app.handleKey("q", hasCommand: true), "another ⌘ key stays the sheet's or the menu's")
        XCTAssertFalse(app.handleKey("5", hasCommand: false), "typing stays the sheet's")

        XCTAssertEqual(app.sheet, "rename")
        XCTAssertEqual(app.selectedIds, before.selected)
        XCTAssertEqual(app.primaryId, before.primary)
        XCTAssertEqual(app.view, before.view)
        XCTAssertEqual(app.showInspector, before.inspector)
        XCTAssertEqual(app.filterOpen, before.filterOpen)
        XCTAssertEqual(app.thumbSize, before.thumbSize)
        XCTAssertEqual(app.assets.map(\.id), before.assets, "nothing trashed or removed")
        XCTAssertEqual(app.toastCenter.toasts.count, before.toasts, "nothing done, nothing said")
    }

    @MainActor
    func testSelectAllAndInvertSayWhatTheyDidFromTheKeyAndTheMenu() {
        let app = library()
        let visible = Set(app.list.map(\.id))

        XCTAssertTrue(app.handleKey("a", hasCommand: true))
        XCTAssertEqual(app.selectedIds, visible)
        XCTAssertEqual(app.toastCenter.toasts.last?.message, "已全选当前列表")
        XCTAssertTrue(app.handleKey("a", hasCommand: true, hasShift: true))
        XCTAssertTrue(app.selectedIds.isEmpty)
        XCTAssertEqual(app.toastCenter.toasts.last?.message, "已反选当前列表")

        // the menu's items
        var toasts = app.toastCenter.toasts.count
        XCTAssertTrue(app.selectAllVisibleAnnouncing())
        XCTAssertEqual(app.selectedIds, visible)
        XCTAssertEqual(app.toastCenter.toasts.count, toasts + 1)
        XCTAssertEqual(app.toastCenter.toasts.last?.message, "已全选当前列表")
        XCTAssertTrue(app.invertVisibleSelectionAnnouncing())
        XCTAssertTrue(app.selectedIds.isEmpty)
        XCTAssertEqual(app.toastCenter.toasts.last?.message, "已反选当前列表")

        // where the selection can't change, the key is taken and nothing is said
        app.selectedIds = [visible.sorted()[0]]
        app.view = .compare
        toasts = app.toastCenter.toasts.count
        XCTAssertTrue(app.handleKey("a", hasCommand: true))
        XCTAssertFalse(app.selectAllVisibleAnnouncing())
        XCTAssertFalse(app.invertVisibleSelectionAnnouncing())
        XCTAssertEqual(app.selectedIds.count, 1)
        XCTAssertEqual(app.toastCenter.toasts.count, toasts)

        // with nothing listed, the key goes on and nothing is said
        app.view = .grid
        app.setSearch("no photo is called this")
        XCTAssertTrue(app.list.isEmpty)
        XCTAssertFalse(app.handleKey("a", hasCommand: true))
        XCTAssertFalse(app.handleKey("a", hasCommand: true, hasShift: true))
        XCTAssertEqual(app.toastCenter.toasts.count, toasts)
    }
}
