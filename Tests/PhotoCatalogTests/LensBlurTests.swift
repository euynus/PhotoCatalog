import XCTest
import CoreGraphics
@testable import PhotoCatalog

final class LensBlurTests: XCTestCase {
    /// Depth by column: the left half far (0), the right half near (1).
    private let leftFarRightNear = DepthMap.Map(width: 2, height: 1, values: [0, 1])

    func testPickFocusReadsTheDepthUnderThePointer() {
        let size = CGSize(width: 6000, height: 4000)
        let plain = DevelopSettings()
        XCTAssertEqual(leftFarRightNear.depth(atFinished: CGPoint(x: 0.25, y: 0.5), settings: plain, sourceSize: size),
                       0, accuracy: 1e-6)
        XCTAssertEqual(leftFarRightNear.depth(atFinished: CGPoint(x: 0.75, y: 0.5), settings: plain, sourceSize: size),
                       1, accuracy: 1e-6)
    }

    func testPickFocusFollowsAQuarterTurn() {
        let size = CGSize(width: 6000, height: 4000)
        var turned = DevelopSettings()
        turned.rotation = 1   // clockwise: the photo's left edge is now at the top
        XCTAssertEqual(leftFarRightNear.depth(atFinished: CGPoint(x: 0.5, y: 0.25), settings: turned, sourceSize: size),
                       0, accuracy: 1e-6)
        XCTAssertEqual(leftFarRightNear.depth(atFinished: CGPoint(x: 0.5, y: 0.75), settings: turned, sourceSize: size),
                       1, accuracy: 1e-6)
    }
}
