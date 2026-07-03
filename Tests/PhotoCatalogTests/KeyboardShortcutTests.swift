import AppKit
import XCTest
@testable import PhotoCatalog

final class KeyboardShortcutTests: XCTestCase {
    func testGlobalKeyCatcherPassesThroughOptionAndControlShortcuts() {
        XCTAssertTrue(KeyCatcher.shouldPassThroughGlobalShortcut([.option]))
        XCTAssertTrue(KeyCatcher.shouldPassThroughGlobalShortcut([.command, .option]))
        XCTAssertTrue(KeyCatcher.shouldPassThroughGlobalShortcut([.control]))
        XCTAssertFalse(KeyCatcher.shouldPassThroughGlobalShortcut([.command]))
        XCTAssertFalse(KeyCatcher.shouldPassThroughGlobalShortcut([.command, .shift]))
        XCTAssertFalse(KeyCatcher.shouldPassThroughGlobalShortcut([]))
    }

    func testMenuBackedCommandShortcutsPassThroughKeyCatcher() {
        XCTAssertTrue(KeyCatcher.shouldPassThroughMenuCommand("b", hasCommand: true))
        XCTAssertTrue(KeyCatcher.shouldPassThroughMenuCommand("r", hasCommand: true))
        XCTAssertTrue(KeyCatcher.shouldPassThroughMenuCommand("delete", hasCommand: true))
        XCTAssertFalse(KeyCatcher.shouldPassThroughMenuCommand("a", hasCommand: true))
        XCTAssertFalse(KeyCatcher.shouldPassThroughMenuCommand("b", hasCommand: false))
    }
}
