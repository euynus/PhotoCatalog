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

    func testInspectorToggleLabelDescribesAvailableAction() {
        XCTAssertEqual(inspectorToggleLabel(isVisible: true), "隐藏简介 (⌘I)")
        XCTAssertEqual(inspectorToggleLabel(isVisible: false), "显示简介 (⌘I)")
    }
}
