import XCTest
import PencilKit
import UIKit
@testable import NullMini

@MainActor final class ShapeRecognitionTests: XCTestCase {
    override func setUp() async throws { try await super.setUp(); InkInputView.acceptsInput = true }
    override func tearDown() async throws { InkInputView.acceptsInput = false; try await super.tearDown() }
    func testLineEllipsePolygonAndUnrecognizedHandwriting() throws {
        let line = (0...30).map { i in CGPoint(x: CGFloat(i * 5), y: i % 2 == 0 ? 20 : 22) }
        let straight = try XCTUnwrap(ShapeRecognition.recognize(line))
        XCTAssertFalse(straight.closed); XCTAssertEqual(straight.points.count, 2)
        let circle = GeometricShape.ellipse.points(from: CGPoint(x: 20, y: 30), to: CGPoint(x: 180, y: 140), samples: [])
        let ellipse = try XCTUnwrap(ShapeRecognition.recognize(circle))
        XCTAssertTrue(ellipse.closed); XCTAssertGreaterThan(ellipse.points.count, 40)
        let rectangle = GeometricShape.rectangle.points(from: CGPoint(x: 20, y: 30), to: CGPoint(x: 180, y: 140), samples: [])
        let box = try XCTUnwrap(ShapeRecognition.recognize(rectangle))
        XCTAssertTrue(box.closed); XCTAssertEqual(box.points.count, 5)
        let triangle = GeometricShape.triangle.points(from: CGPoint(x: 20, y: 30), to: CGPoint(x: 180, y: 140), samples: [])
        XCTAssertEqual(ShapeRecognition.recognize(triangle)?.points.count, 4)
        let writing = [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 80), CGPoint(x: 0, y: 160), CGPoint(x: 50, y: 240), CGPoint(x: 0, y: 320)]
        XCTAssertNil(ShapeRecognition.recognize(writing))
    }
    func testHeldShapeScalesRotatesAndSnapsEndpoints() throws {
        let line = RecognizedShape(points: [CGPoint(x: 20, y: 20), CGPoint(x: 100, y: 20)], closed: false)
        let moved = line.adjusted(from: CGPoint(x: 100, y: 20), to: CGPoint(x: 20, y: 180))
        XCTAssertEqual(moved.points[0], CGPoint(x: 20, y: 20))
        XCTAssertEqual(moved.points[1].x, 20, accuracy: 0.001); XCTAssertEqual(moved.points[1].y, 180, accuracy: 0.001)
        let near = RecognizedShape(points: [CGPoint(x: 20, y: 20), CGPoint(x: 195, y: 197)], closed: false)
        XCTAssertEqual(near.snapped(to: [CGPoint(x: 200, y: 200)]).points.last, CGPoint(x: 200, y: 200))
    }
    func testDrawShapeKeepsRawInputUntilHeldThenCommitsEditableFill() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let page = NotebookPage(), commands = CanvasCommands(), coordinator = CanvasSurface.Coordinator(page: page, directory: root, commands: commands)
        let view = PageViewport(page: page, directory: root); coordinator.attach(view)
        var settings = ToolSettings(); settings.tool = .shapes; settings.fillShapes = true; settings.color = "#FF0000"
        coordinator.configure(settings)
        XCTAssertFalse(view.inkInput.isHidden); XCTAssertTrue(view.interaction.isHidden)
        let points = GeometricShape.rectangle.points(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 180), samples: [])
        view.inkInput.beginStroke(InkSample(point: points[0], time: 0))
        view.inkInput.addSamples(points.dropFirst().enumerated().map { InkSample(point: $0.element, time: Double($0.offset + 1) / 120) })
        XCTAssertTrue(coordinator.drawing.strokes.isEmpty)
        view.inkInput.recognizeHeldShape()
        view.inkInput.addSamples([InkSample(point: CGPoint(x: 50, y: 60), time: 1)])
        view.inkInput.endStroke()
        let done = expectation(description: "Shape committed"); DispatchQueue.main.async { done.fulfill() }; await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(coordinator.drawing.strokes.count, 2); XCTAssertNotNil(coordinator.drawing.strokes.first?.mask)
        XCTAssertGreaterThan(coordinator.drawing.bounds.width, 190)
        let restored = try DrawingDisk.load(root, page.id)
        XCTAssertEqual(restored.strokes.count, 2); XCTAssertNotNil(restored.strokes.first?.mask)
        let image = restored.image(from: CGRect(x: 0, y: 0, width: 300, height: 250), scale: 1)
        let attachment = XCTAttachment(image: image); attachment.name = "synthetic-held-scaled-shape"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
