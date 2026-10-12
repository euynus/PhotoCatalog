import XCTest
import SwiftUI
import AppKit
@testable import PhotoCatalog

/// Settings → Files → Shift Capture Times → Set to This Time: the time picked is the capture time
/// kept, which is wall clock anchored to UTC, so the picker has to show and edit it in UTC.
@MainActor
final class SettingsCaptureTimeTests: XCTestCase {
    private func datePickers(in view: NSView) -> [NSDatePicker] {
        (view as? NSDatePicker).map { [$0] } ?? view.subviews.flatMap(datePickers)
    }

    func testSetToThisTimePickerShowsAndEditsTheCaptureWallClock() throws {
        let app = AppState.selfCheckFixture()
        app.settingsStartCategory = "files"
        let hosting = NSHostingView(rootView: SettingsSheet().environment(app))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 560), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }

        // the sheet opens at Files once it has appeared
        var pickers: [NSDatePicker] = []
        let deadline = Date().addingTimeInterval(5)
        while pickers.isEmpty && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            hosting.layoutSubtreeIfNeeded()
            pickers = datePickers(in: hosting)
        }
        XCTAssertEqual(pickers.count, 1, "Settings → Files has the one date picker of Shift Capture Times")
        let picker = try XCTUnwrap(pickers.first)

        // what it shows is what is stored: 10:00 picked is kept as 10:00, not 02:00 in China
        XCTAssertEqual(picker.timeZone, TimeZone.captureWallClock)
        XCTAssertEqual(picker.calendar?.timeZone, TimeZone.captureWallClock)
        // and it starts at the time on this Mac's clock, as a capture time
        XCTAssertEqual(picker.dateValue.timeIntervalSince(Date.now.captureWallClock()), 0, accuracy: 120)
    }
}
