import XCTest
import PencilKit
@testable import NullMini

/// Strokes PencilKit writes are rebuilt by the pen engine once the Pencil lifts.
@MainActor final class RestyleTests: XCTestCase {
    private func setUp(_ settings: ToolSettings) throws -> (CanvasSurface.Coordinator, PageViewport, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let page = NotebookPage(), commands = CanvasCommands(), coordinator = CanvasSurface.Coordinator(page: page, directory: root, commands: commands)
        let view = PageViewport(page: page, directory: root); coordinator.attach(view)
        coordinator.configure(settings)
        return (coordinator, view, root)
    }
    private func native(_ points: [CGPoint], created: Date, duration: TimeInterval) -> PKStroke {
        let controls = points.enumerated().map { i, p in PKStrokePoint(location: p, timeOffset: duration * Double(i) / Double(max(1, points.count - 1)), size: CGSize(width: 2, height: 2), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2) }
        return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: controls, creationDate: created))
    }
    /// Plays the callbacks PencilKit sends for one stroke, in the order seen on the device.
    private func write(_ stroke: PKStroke, coordinator: CanvasSurface.Coordinator, view: PageViewport) async throws {
        coordinator.canvasViewDidBeginUsingTool(view.canvas)
        coordinator.canvasViewDidEndUsingTool(view.canvas)
        view.canvas.drawing = PKDrawing(strokes: view.canvas.drawing.strokes + [stroke])
        coordinator.canvasViewDrawingDidChange(view.canvas)
        try await Task.sleep(nanoseconds: 300_000_000)
    }

    func testDashedPatternAppliesToPencilKitStrokes() async throws {
        var settings = ToolSettings(); settings.tool = .pen; settings.strokePattern = .dashed; settings.width = 2
        let (coordinator, view, root) = try setUp(settings); defer { try? FileManager.default.removeItem(at: root) }
        let line = (0 ... 40).map { CGPoint(x: 50 + CGFloat($0) * 5, y: 100) }
        try await write(native(line, created: Date(), duration: 0.4), coordinator: coordinator, view: view)
        XCTAssertGreaterThan(coordinator.drawing.strokes.count, 3, "a dashed line is several pieces")
    }

    func testHoldingAfterACircleTurnsItIntoAShape() async throws {
        var settings = ToolSettings(); settings.tool = .pen; settings.drawAndHold = true
        let (coordinator, view, root) = try setUp(settings); defer { try? FileManager.default.removeItem(at: root) }
        let wobbly = (0 ... 60).map { i -> CGPoint in let a = CGFloat(i) / 60 * 2 * .pi; let r: CGFloat = 60 + (i % 3 == 0 ? 5 : -5); return CGPoint(x: 200 + cos(a) * r, y: 200 + sin(a) * r) }
        // Drawn in 0.6 s, then the Pencil rested a second before lifting.
        try await write(native(wobbly, created: Date().addingTimeInterval(-1.6), duration: 0.6), coordinator: coordinator, view: view)
        let stroke = try XCTUnwrap(coordinator.drawing.strokes.last)
        let distances = stroke.path.map { hypot($0.location.x - 200, $0.location.y - 200) }
        XCTAssertLessThan((distances.max() ?? 0) - (distances.min() ?? 0), 4, "the held circle is a clean circle")
    }

    func testThinnestPenStaysVisibleAfterLifting() async throws {
        var settings = ToolSettings(); settings.tool = .pen; settings.penStyle = .ballpoint; settings.width = 0.1417322856119756
        let (coordinator, view, root) = try setUp(settings); defer { try? FileManager.default.removeItem(at: root) }
        let line = (0 ... 30).map { CGPoint(x: 50 + CGFloat($0) * 4, y: 120) }
        try await write(native(line, created: Date(), duration: 0.3), coordinator: coordinator, view: view)
        let stroke = try XCTUnwrap(coordinator.drawing.strokes.last)
        let thinnest = stroke.path.map(\.size.width).min() ?? 0
        XCTAssertGreaterThanOrEqual(thinnest, InkBuilder.minimumWidth(.pen) - 0.001, "a 0.05 mm stroke must not shrink below what PencilKit showed while writing")
    }
}
