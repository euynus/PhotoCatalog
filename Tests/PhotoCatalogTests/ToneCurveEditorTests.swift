import XCTest
import CoreGraphics
@testable import PhotoCatalog

/// Dragging on the tone curve: a 200-point square, a curve with one point in the middle.
final class ToneCurveEditorTests: XCTestCase {
    private let side: CGFloat = 200
    private let curve = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.6), CurvePoint(x: 1, y: 1)]

    /// A few points off the middle point, still within reach of it.
    private var nearMiddle: CGPoint { CGPoint(x: 0.5 * side + 4, y: (1 - 0.6) * side - 3) }

    @MainActor
    func testClickOnAPointLeavesItWhereItIs() throws {
        let drag = try XCTUnwrap(ToneCurveEditor.dragging(curve, from: nearMiddle, by: .zero, side: side))
        XCTAssertEqual(drag.index, 1)
        XCTAssertEqual(drag.points, curve)
    }

    @MainActor
    func testClickOffTheCurveAddsAPointOnIt() throws {
        // well above the curve at a quarter of the input
        let drag = try XCTUnwrap(ToneCurveEditor.dragging(curve, from: CGPoint(x: 0.25 * side, y: 40), by: .zero, side: side))
        XCTAssertEqual(drag.index, 1)
        XCTAssertEqual(drag.points.count, 4)
        XCTAssertEqual(drag.points[1].x, 0.25, accuracy: 1e-9)
        XCTAssertEqual(drag.points[1].y, ToneCurve.evaluate(curve, at: 0.25), accuracy: 1e-9, "the curve keeps its shape")
    }

    @MainActor
    func testDragMovesThePointByHowFarThePointerMoved() throws {
        let drag = try XCTUnwrap(ToneCurveEditor.dragging(curve, from: nearMiddle, by: CGSize(width: 20, height: -30), side: side))
        XCTAssertEqual(drag.points[1].x, 0.6, accuracy: 1e-9)
        XCTAssertEqual(drag.points[1].y, 0.75, accuracy: 1e-9)
    }

    @MainActor
    func testEndsMoveUpAndDownOnly() throws {
        let drag = try XCTUnwrap(ToneCurveEditor.dragging(curve, from: CGPoint(x: 2, y: side - 2), by: CGSize(width: 30, height: -40),
                                                          side: side))
        XCTAssertEqual(drag.index, 0)
        XCTAssertEqual(drag.points[0].x, 0)
        XCTAssertEqual(drag.points[0].y, 0.2, accuracy: 1e-9)
    }

    @MainActor
    func testAPointStaysBetweenItsNeighbors() throws {
        let drag = try XCTUnwrap(ToneCurveEditor.dragging(curve, from: nearMiddle, by: CGSize(width: 150, height: 0), side: side))
        XCTAssertEqual(drag.points[1].x, 1 - ToneCurve.minimumGap, accuracy: 1e-9)
    }
}
