import XCTest
import PencilKit
@testable import NullMini

final class TapeInkTests: XCTestCase {
    private func samples(_ points: [CGPoint]) -> [InkSample] { points.enumerated().map { InkSample(point: $1, time: Double($0) / 120) } }
    private var tapeSettings: ToolSettings { var s = ToolSettings(); s.tool = .marker; s.tape = true; return s }

    func testDragLaysOneStraightOpaqueStrip() throws {
        let strokes = InkBuilder.strokes(samples([CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 40), CGPoint(x: 110, y: 12)]), settings: tapeSettings, creationDate: Date(), seed: 1)
        let strip = try XCTUnwrap(strokes.first)
        XCTAssertEqual(strokes.count, 1)
        XCTAssertTrue(TapeInk.isTape(strip))
        XCTAssertEqual(strip.path.first?.location.y ?? 0, 10, accuracy: 0.01)
        XCTAssertEqual(strip.path.last?.location.x ?? 0, 110, accuracy: 0.01)
        XCTAssertTrue(strip.path.allSatisfy { abs($0.location.y - (10 + ($0.location.x - 10) * 0.02)) < 0.05 }, "the strip is a straight line from start to end")
    }

    func testTapPeelsAndCoversTheStripUnderIt() throws {
        let strip = try XCTUnwrap(InkBuilder.strokes(samples([CGPoint(x: 0, y: 50), CGPoint(x: 200, y: 50)]), settings: tapeSettings, creationDate: Date(), seed: 1).first)
        let ink = StrokeFactory.stroke(points: [CGPoint(x: 0, y: 0), CGPoint(x: 30, y: 30)], color: .black, width: 2)
        let drawing = PKDrawing(strokes: [ink, strip])
        let probe = try XCTUnwrap(InkBuilder.strokes(samples([CGPoint(x: 100, y: 52)]), settings: tapeSettings, creationDate: Date(), seed: 1).first)
        XCTAssertTrue(TapeInk.isProbe(probe))
        XCTAssertFalse(TapeInk.isTape(probe))
        let peeled = try XCTUnwrap(TapeInk.toggled(drawing, at: CGPoint(x: 100, y: 52)))
        XCTAssertEqual(peeled.strokes[1].ink.color.cgColor.alpha, TapeInk.peeledAlpha, accuracy: 0.01)
        XCTAssertTrue(TapeInk.isTape(peeled.strokes[1]), "a peeled strip is still tape")
        let covered = try XCTUnwrap(TapeInk.toggled(peeled, at: CGPoint(x: 150, y: 45)))
        XCTAssertEqual(covered.strokes[1].ink.color.cgColor.alpha, TapeInk.coveredAlpha, accuracy: 0.01)
        XCTAssertNil(TapeInk.toggled(drawing, at: CGPoint(x: 100, y: 120)), "a tap beside the strip changes nothing")
    }

    func testClearKindsSeparatePensHighlightersAndTape() throws {
        let strip = try XCTUnwrap(InkBuilder.strokes(samples([CGPoint(x: 0, y: 50), CGPoint(x: 200, y: 50)]), settings: tapeSettings, creationDate: Date(), seed: 1).first)
        let pen = StrokeFactory.stroke(points: [CGPoint(x: 0, y: 0), CGPoint(x: 30, y: 30)], color: .black, width: 2)
        let marker = PKStroke(ink: PKInk(.marker, color: .yellow), path: pen.path)
        XCTAssertTrue(ClearKind.pens.removes(pen)); XCTAssertFalse(ClearKind.pens.removes(strip)); XCTAssertFalse(ClearKind.pens.removes(marker))
        XCTAssertTrue(ClearKind.highlighters.removes(marker)); XCTAssertFalse(ClearKind.highlighters.removes(pen))
        XCTAssertTrue(ClearKind.tape.removes(strip)); XCTAssertFalse(ClearKind.tape.removes(pen))
    }
}
