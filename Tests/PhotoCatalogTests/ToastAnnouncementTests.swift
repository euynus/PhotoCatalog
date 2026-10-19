import XCTest
import AppKit
@testable import PhotoCatalog

/// A toast is gone after 2.2 s and is the only report of some failures, so VoiceOver reads each
/// one as it appears; warnings interrupt, other news waits its turn.
@MainActor
final class ToastAnnouncementTests: XCTestCase {
    func testPushedToastsAreAnnounced() {
        let center = ToastCenter()
        var spoken: [(message: String, priority: NSAccessibilityPriorityLevel)] = []
        center.announce = { spoken.append(($0, $1)) }

        center.push("保存失败，更改未写入目录库", "warning")
        center.push("已导出 3 张照片", "check")

        XCTAssertEqual(spoken.map(\.message), ["保存失败，更改未写入目录库", "已导出 3 张照片"])
        XCTAssertEqual(spoken.map(\.priority.rawValue),
                       [NSAccessibilityPriorityLevel.high.rawValue, NSAccessibilityPriorityLevel.medium.rawValue])
    }

    func testAppToastsReachTheAnnouncement() {
        let app = AppState.selfCheckFixture()
        var spoken: [String] = []
        app.toastCenter.announce = { message, _ in spoken.append(message) }

        app.push("请先选择照片", "warning")
        app.push(verbatim: "IMG_0001.jpg", "info")

        XCTAssertEqual(spoken, [app.toastCenter.toasts[0].message, "IMG_0001.jpg"])
    }
}
