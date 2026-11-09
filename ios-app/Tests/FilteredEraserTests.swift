import XCTest
import PencilKit
import UIKit
@testable import NullMini

@MainActor final class FilteredEraserTests: XCTestCase {
    private func stroke(_ type: PKInk.InkType, y: CGFloat, color: UIColor) -> PKStroke {
        let line = StrokeFactory.stroke(points: [CGPoint(x: 20, y: y), CGPoint(x: 160, y: y)], color: color, width: 10)
        return PKStroke(ink: PKInk(type, color: color), path: line.path)
    }
    func testStrokeFilterPreservesExcludedInkAndUndoRestoresWholeDrawing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let page = NotebookPage()
        let pen = stroke(.pen, y: 30, color: .red), pencil = stroke(.pencil, y: 60, color: .blue), marker = stroke(.marker, y: 90, color: .green)
        let drawing = PKDrawing(strokes: [pen, pencil, marker])
        try DrawingDisk.save(drawing, directory: root, page: page.id)
        let commands = CanvasCommands(), coordinator = CanvasSurface.Coordinator(page: page, directory: root, commands: commands)
        let viewport = PageViewport(page: page, directory: root)
        let host = UIViewController(); host.view.addSubview(viewport); viewport.frame = CGRect(x: 0, y: 0, width: 600, height: 600)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 600)); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        coordinator.attach(viewport)
        viewport.canvas.becomeFirstResponder()
        let initial = coordinator.drawing
        var settings = ToolSettings(); settings.tool = .eraser; settings.eraserFilters.pen = false; settings.eraserFilters.pencil = false
        coordinator.configure(settings)
        let undo = try XCTUnwrap(viewport.canvas.undoManager)
        undo.beginUndoGrouping()
        XCTAssertFalse(viewport.canvas.isUserInteractionEnabled)
        XCTAssertFalse(viewport.interaction.isHidden)
        viewport.onInteraction?(true)
        viewport.onErase?([CGPoint(x: 90, y: 10), CGPoint(x: 90, y: 110)])
        XCTAssertEqual(coordinator.drawing.strokes.count, 2, "Filtered erasing must update while the input moves")
        var deferred = false; commands.afterInput { deferred = true }; XCTAssertFalse(deferred)
        viewport.onInteraction?(false)
        let done = expectation(description: "Deferred filtered eraser")
        DispatchQueue.main.async { done.fulfill() }
        await fulfillment(of: [done], timeout: 2)
        undo.endUndoGrouping()
        XCTAssertTrue(deferred)
        XCTAssertEqual(coordinator.drawing.strokes.map { $0.ink.inkType }, [.pen, .pencil])
        let expected = Array(initial.strokes.prefix(2))
        for (actual, original) in zip(coordinator.drawing.strokes, expected) {
            XCTAssertEqual(actual.ink.inkType, original.ink.inkType); XCTAssertEqual(actual.ink.color, original.ink.color)
            XCTAssertEqual(actual.transform, original.transform)
            XCTAssertEqual(actual.randomSeed, original.randomSeed); XCTAssertNil(actual.mask); XCTAssertNil(original.mask)
            XCTAssertEqual(actual.path.creationDate, original.path.creationDate); XCTAssertEqual(actual.path.count, original.path.count)
            for (a, b) in zip(actual.path, original.path) {
                XCTAssertEqual(a.location, b.location); XCTAssertEqual(a.timeOffset, b.timeOffset); XCTAssertEqual(a.size, b.size)
                XCTAssertEqual(a.opacity, b.opacity); XCTAssertEqual(a.force, b.force); XCTAssertEqual(a.azimuth, b.azimuth); XCTAssertEqual(a.altitude, b.altitude)
            }
        }
        // Independently constructed PKDrawing envelopes can differ; compare the protected stroke content and pixels.
        XCTAssertEqual(try pixels(coordinator.drawing), try pixels(PKDrawing(strokes: expected)), "Excluded ink rendered differently")
        XCTAssertEqual(try DrawingDisk.load(root, page.id).strokes.count, 2)
        commands.undo()
        XCTAssertEqual(coordinator.drawing.strokes.count, 3)
        XCTAssertEqual(coordinator.drawing.dataRepresentation(), initial.dataRepresentation())
    }
    func testCancelledLiveEraseRestoresTheDrawingWithoutAddingUndo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let page = NotebookPage(), commands = CanvasCommands()
        try DrawingDisk.save(PKDrawing(strokes: [stroke(.marker, y: 50, color: .green)]), directory: root, page: page.id)
        let coordinator = CanvasSurface.Coordinator(page: page, directory: root, commands: commands), view = PageViewport(page: page, directory: root)
        coordinator.attach(view)
        var settings = ToolSettings(); settings.tool = .eraser; settings.eraserFilters.pen = false; coordinator.configure(settings)
        let original = coordinator.drawing.dataRepresentation()
        view.onInteraction?(true); view.onErase?([CGPoint(x: 90, y: 10), CGPoint(x: 90, y: 90)])
        XCTAssertTrue(coordinator.drawing.strokes.isEmpty)
        view.onEraseCancelled?(); view.onInteraction?(false)
        let done = expectation(description: "Erase cancelled"); DispatchQueue.main.async { done.fulfill() }; await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(coordinator.drawing.dataRepresentation(), original)
        XCTAssertFalse(view.canvas.undoManager?.canUndo ?? true)
    }
    private func pixels(_ drawing: PKDrawing) throws -> Data {
        let image = try XCTUnwrap(drawing.image(from: CGRect(x: 0, y: 0, width: 200, height: 120), scale: 1).cgImage)
        var bytes = [UInt8](repeating: 0, count: 200 * 120 * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 200, height: 120, bitsPerComponent: 8, bytesPerRow: 800, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: 200, height: 120))
        }
        return Data(bytes)
    }
    func testStandardEraserCutsTheTouchedPieceAcrossTheWholeWidth() throws {
        let line = StrokeFactory.stroke(points: (0...70).map { CGPoint(x: 20 + CGFloat($0) * 2, y: 50) }, color: .black, width: 4)
        let erased = try XCTUnwrap(FilteredEraser.erase(PKDrawing(strokes: [line]), points: [CGPoint(x: 90, y: 20), CGPoint(x: 90, y: 80)], diameter: 16, style: .standard, filters: EraserFilters()))
        XCTAssertEqual(erased.strokes.count, 2, "A cut through the middle leaves the two ends")
        for piece in erased.strokes {
            XCTAssertNil(piece.mask, "Standard erasing cuts the path instead of masking it")
            for point in piece.path.interpolatedPoints(by: .distance(1)) { XCTAssertGreaterThan(abs(point.location.x - 90), 8, "ink left under the eraser") }
        }
        let xs = erased.strokes.flatMap { $0.path.map(\.location.x) }
        XCTAssertLessThan(xs.min() ?? 99, 22); XCTAssertGreaterThan(xs.max() ?? 0, 158)
        // Touching only the very end removes it without leaving a speck behind.
        let tip = try XCTUnwrap(FilteredEraser.erase(PKDrawing(strokes: [line]), points: [CGPoint(x: 168, y: 50)], diameter: 16, style: .standard, filters: EraserFilters()))
        XCTAssertEqual(tip.strokes.count, 1)
        XCTAssertLessThan(tip.strokes[0].path.map(\.location.x).max() ?? 999, 158.5)
        // Untouched strokes are kept as they are.
        XCTAssertNil(FilteredEraser.erase(PKDrawing(strokes: [line]), points: [CGPoint(x: 90, y: 120)], diameter: 16, style: .standard, filters: EraserFilters()))
    }
    func testStandardAndFilteredErasingUseTheOverlay() {
        var settings = ToolSettings(); settings.tool = .eraser
        settings.eraserStyle = .stroke; XCTAssertFalse(FilteredEraser.needsOverlay(settings))
        settings.eraserStyle = .precision; XCTAssertFalse(FilteredEraser.needsOverlay(settings))
        settings.eraserStyle = .standard; XCTAssertTrue(FilteredEraser.needsOverlay(settings))
        settings.eraserStyle = .stroke; settings.eraserFilters.marker = false; XCTAssertTrue(FilteredEraser.needsOverlay(settings))
    }
    func testBitmapFilterUsesPretransformMasksAndKeepsRandomSeed() throws {
        let base = stroke(.pen, y: 30, color: .red)
        let transform = CGAffineTransform(translationX: 20, y: 30)
        let mask = UIBezierPath(rect: CGRect(x: 20, y: 20, width: 140, height: 20))
        let original = PKStroke(ink: base.ink, path: base.path, transform: transform, mask: mask, randomSeed: base.randomSeed)
        var filters = EraserFilters(); filters.marker = false
        let erased = try XCTUnwrap(FilteredEraser.erase(PKDrawing(strokes: [original]), points: [CGPoint(x: 100, y: 40), CGPoint(x: 100, y: 80)], diameter: 16, style: .precision, filters: filters))
        let restored = try PKDrawing(data: erased.dataRepresentation()), result = try XCTUnwrap(restored.strokes.first)
        XCTAssertEqual(result.randomSeed, original.randomSeed); XCTAssertEqual(result.transform, transform)
        let image = restored.image(from: CGRect(x: 0, y: 0, width: 200, height: 120), scale: 1)
        let cgImage = try XCTUnwrap(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: 200 * 120 * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 200, height: 120, bitsPerComponent: 8, bytesPerRow: 800, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.translateBy(x: 0, y: 120); context?.scaleBy(x: 1, y: -1)
            context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: 200, height: 120))
        }
        XCTAssertGreaterThan(pixels[(60 * 200 + 60) * 4 + 3], 200, "Un-erased ink was lost")
        XCTAssertEqual(pixels[(60 * 200 + 100) * 4 + 3], 0, "The bitmap eraser did not cut the transformed stroke")
        XCTAssertEqual(pixels[(60 * 200 + 30) * 4 + 3], 0, "The original clipping mask was lost")
    }
}
