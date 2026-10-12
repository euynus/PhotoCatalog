import AppKit
import XCTest
@testable import PhotoCatalog

final class KeyboardShortcutTests: XCTestCase {
    func testMenuBackedCommandShortcutsPassThroughKeyCatcher() {
        XCTAssertTrue(KeyCatcher.shouldPassThroughMenuCommand("b", hasCommand: true))
        XCTAssertTrue(KeyCatcher.shouldPassThroughMenuCommand("r", hasCommand: true))
        XCTAssertTrue(KeyCatcher.shouldPassThroughMenuCommand("delete", hasCommand: true))
        XCTAssertFalse(KeyCatcher.shouldPassThroughMenuCommand("a", hasCommand: true))
        XCTAssertFalse(KeyCatcher.shouldPassThroughMenuCommand("b", hasCommand: false))
    }

    func testKeyCatcherRecognizesAByHardwareKeyCode() {
        XCTAssertEqual(KeyCatcher.keyString(keyCode: 0, charactersIgnoringModifiers: nil), "a")
        XCTAssertEqual(KeyCatcher.keyString(keyCode: 0, charactersIgnoringModifiers: "A"), "a")
    }

    /// The filter bar's custom range is a pair of date pickers: an NSDatePicker takes typed digits
    /// itself, with no field editor, and they must not reach the grid as rating keys.
    @MainActor
    func testDatePickerCountsAsTextInput() {
        XCTAssertTrue(KeyCatcher.isTextInput(NSTextView()))
        XCTAssertTrue(KeyCatcher.isTextInput(NSDatePicker()), "a focused date picker is typed into")
        XCTAssertFalse(KeyCatcher.isTextInput(NSView()))
        XCTAssertFalse(KeyCatcher.isTextInput(NSButton()))
        XCTAssertFalse(KeyCatcher.isTextInput(nil))
    }

    /// A sheet is a window of its own: its keys never came from the library's window, so Esc
    /// stopped closing it and ⌘ shortcuts went to the menu items acting on the photos behind it.
    @MainActor
    func testEscapeClosesSheetAndCommandKeysStayOffPhotosBehindIt() throws {
        let app = AppState.selfCheckFixture()
        app.assets = Array(DemoData.assets.prefix(6))
        app.select(Selection(type: .lib, id: "all", name: "Sheet keys"))
        XCTAssertNotNil(app.primaryId)

        // Unshown windows: attaching a real sheet (beginSheet) would put both on screen.
        let frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        let host = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        let sheetWindow = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        let other = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        for window in [host, sheetWindow, other] { window.isReleasedWhenClosed = false }
        defer { for window in [host, sheetWindow, other] { window.close() } }
        let parent: (NSWindow) -> NSWindow? = { $0 === sheetWindow ? host : nil }

        var calls = 0
        func route(_ event: NSEvent, editing: Bool = false, composing: Bool = false) -> NSEvent? {
            KeyCatcher.routeEvent(event, hostWindow: host, presentsSheet: app.sheet != nil, isMenuTracking: false,
                                  isEditingText: editing, isComposingText: composing,
                                  sheetParent: parent) { key, command, shift in
                calls += 1
                return app.handleKey(key, hasCommand: command, hasShift: shift)
            }
        }
        func event(_ characters: String, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags = [],
                   in window: NSWindow) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, characters: characters,
                                           charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
        }

        app.sheet = "rename"
        let digit = try event("5", 23, in: sheetWindow)
        XCTAssertTrue(route(digit) === digit, "typing in the sheet stays the sheet's")
        XCTAssertEqual(calls, 0)
        let trash = try event("\u{7f}", 51, .command, in: sheetWindow)
        XCTAssertNil(route(trash), "⌘⌫ in a sheet must not reach Move Originals to Trash behind it")
        let selectAll = try event("a", 0, .command, in: sheetWindow)
        calls = 0
        XCTAssertTrue(route(selectAll, editing: true) === selectAll, "a field in the sheet keeps ⌘A")
        XCTAssertEqual(calls, 0)

        let escape = try event("\u{1b}", 53, in: sheetWindow)
        XCTAssertTrue(route(escape, editing: true, composing: true) === escape, "Esc first ends an input method's composition")
        XCTAssertEqual(app.sheet, "rename")
        XCTAssertNil(route(escape, editing: true), "Esc closes the sheet, from its text field too, as Cancel would")
        XCTAssertNil(app.sheet)

        calls = 0
        XCTAssertTrue(route(escape) === escape, "with no sheet up, a window attached as one (an alert) keeps its keys")
        app.sheet = "rename"
        let foreign = try event("\u{1b}", 53, in: other)
        XCTAssertTrue(route(foreign) === foreign, "Settings or any other window keeps its Esc")
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(app.sheet, "rename")
    }

    /// Esc reaches the key monitor before the sheet's own Cancel button, so it has to do what Cancel does.
    @MainActor
    func testEscapeCancelsDescribePhotosLikeItsCancelButton() throws {
        let app = AppState.selfCheckFixture()
        app.describeTargets = [try XCTUnwrap(DemoData.assets.first)]
        app.sheet = "describe"
        XCTAssertTrue(app.handleKey("escape", hasCommand: false))
        XCTAssertNil(app.sheet)
        XCTAssertTrue(app.describeTargets.isEmpty, "the photos taken for describing are let go")
    }

    func testInspectorToggleLabelDescribesAvailableAction() {
        XCTAssertEqual(inspectorToggleLabel(isVisible: true), "隐藏简介 (⌘I)")
        XCTAssertEqual(inspectorToggleLabel(isVisible: false), "显示简介 (⌘I)")
    }
}
