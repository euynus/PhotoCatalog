import XCTest
import SwiftUI
import AppKit
@testable import PhotoCatalog

/// A crop drag shows its crop as a draft until the mouse comes up. When the tool goes first (the
/// crop closed or the photo changed mid-drag), the draft must go with it: left behind, the photo
/// showed the unsaved crop when it came back, and hovering a preset showed nothing meanwhile.
@MainActor
final class CropEditorDraftTests: XCTestCase {
    override func setUp() {
        super.setUp()
        openingNoCatalogAtLaunch()
    }

    private func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        return try XCTUnwrap(context.makeImage())
    }

    private func settle(_ hosting: NSView) {
        for _ in 0..<5 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            hosting.layoutSubtreeIfNeeded()
        }
    }

    func testClosingTheCropToolMidDragDropsItsDraft() throws {
        let app = AppState()
        let asset = try XCTUnwrap(app.assets.first)
        let hosting = NSHostingView(rootView: AnyView(
            CropEditor(asset: asset, image: try image(), settings: .neutral).environment(app)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        settle(hosting)

        // as a drag on the crop's edge publishes it
        var cropped = DevelopSettings()
        cropped.crop = DevelopCrop(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        app.updateDevelopDraft(cropped, for: asset.id)

        hosting.rootView = AnyView(Color.clear)
        settle(hosting)
        XCTAssertNil(app.developDraft, "the crop dragged when the tool closed is not kept")
        XCTAssertEqual(app.developSettings(for: asset.id).crop, DevelopSettings.neutral.crop)
    }
}
