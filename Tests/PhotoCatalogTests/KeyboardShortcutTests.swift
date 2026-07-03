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
}
