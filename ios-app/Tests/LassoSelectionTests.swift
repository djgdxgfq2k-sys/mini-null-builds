import XCTest
import PencilKit
import UIKit
@testable import NullMini

@MainActor final class LassoSelectionTests: XCTestCase {
    private func drawing() -> PKDrawing {
        PKDrawing(strokes: [
            StrokeFactory.stroke(points: [CGPoint(x: 20, y: 20), CGPoint(x: 60, y: 20)], color: .black, width: 2),
            StrokeFactory.stroke(points: [CGPoint(x: 200, y: 200), CGPoint(x: 240, y: 200)], color: .black, width: 2)
        ])
    }
    func testFreehandLoopIsClosedFromEndToStartWithAStraightLine() {
        // An open "U" drawn around the first stroke: the closing edge runs straight from the end back to the start.
        let open = [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 40), CGPoint(x: 80, y: 40), CGPoint(x: 80, y: 0)]
        XCTAssertEqual(LassoSelection.indices(in: drawing(), polygon: open), IndexSet([0]))
        let path = LassoSelection.polygonPath(open)
        XCTAssertTrue(path.contains(CGPoint(x: 40, y: 2), using: .winding))
        XCTAssertEqual(path.boundingBoxOfPath, CGRect(x: 0, y: 0, width: 80, height: 40))
    }
    func testRectangularLassoUsesStartAndCurrentPointAsCorners() {
        let rect = LassoSelection.rectangle(from: CGPoint(x: 250, y: 250), to: CGPoint(x: 150, y: 150))
        XCTAssertEqual(LassoSelection.polygonPath(rect).boundingBoxOfPath, CGRect(x: 150, y: 150, width: 100, height: 100))
        XCTAssertEqual(LassoSelection.indices(in: drawing(), polygon: rect), IndexSet([1]))
    }
    func testStrokeMostlyOutsideTheLoopIsNotSelected() {
        let loop = LassoSelection.rectangle(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 30, y: 40))
        XCTAssertTrue(LassoSelection.indices(in: drawing(), polygon: loop).isEmpty)
    }
    func testMoveDuplicateDeleteAndRecolor() {
        let base = drawing()
        let moved = LassoSelection.translated(base, [0], by: CGPoint(x: 10, y: 5))
        XCTAssertEqual(moved.strokes[0].renderBounds.minX, base.strokes[0].renderBounds.minX + 10, accuracy: 0.01)
        XCTAssertEqual(moved.strokes[1].renderBounds, base.strokes[1].renderBounds)
        let (copied, copies) = LassoSelection.duplicated(base, [0])
        XCTAssertEqual(copied.strokes.count, 3); XCTAssertEqual(copies, IndexSet([2]))
        XCTAssertEqual(copied.strokes[2].renderBounds.minX, base.strokes[0].renderBounds.minX + 20, accuracy: 0.01)
        XCTAssertEqual(LassoSelection.removing(base, [0]).strokes.count, 1)
        let red = LassoSelection.recolored(base, [1], color: .red)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        red.strokes[1].ink.color.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertGreaterThan(r, 0.9); XCTAssertLessThan(g, 0.1)
        base.strokes[0].ink.color.getRed(&r, green: &g, blue: &b, alpha: &a)
        var r0: CGFloat = 0; red.strokes[0].ink.color.getRed(&r0, green: nil, blue: nil, alpha: nil)
        XCTAssertEqual(r0, r, accuracy: 0.01)
    }
    func testLassoReplacesNativePencilKitLassoOnThePage() {
        let view = PageViewport(page: NotebookPage(), directory: FileManager.default.temporaryDirectory)
        var settings = ToolSettings(); settings.tool = .lasso
        view.setTool(settings, writable: true)
        XCTAssertFalse(view.lasso.isHidden); XCTAssertFalse(view.canvas.isUserInteractionEnabled)
        settings.tool = .pen; view.setTool(settings, writable: true)
        XCTAssertTrue(view.lasso.isHidden)
    }
}
