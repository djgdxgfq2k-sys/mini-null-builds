import XCTest
import PencilKit
import UIKit
@testable import NullMini

@MainActor final class NotebookStackTests: XCTestCase {
    func testLongNotebookUnloadsDistantPagesAndReloadsSavedInk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let commands = CanvasCommands(), viewport = NotebookViewport(directory: root, commands: commands)
        let pages = (0..<80).map { _ in NotebookPage() }
        viewport.frame = CGRect(x: 0, y: 0, width: 1180, height: 706)
        viewport.synchronize(pages: pages, settings: ToolSettings(), selected: 0); viewport.layoutIfNeeded()
        let first = try XCTUnwrap(viewport.coordinator(for: pages[0].id))
        first.append([StrokeFactory.stroke(points: [.zero, CGPoint(x: 90, y: 80)], color: .red, width: 2)])
        viewport.synchronize(pages: pages, settings: ToolSettings(), selected: 79)
        XCTAssertLessThanOrEqual(viewport.livePageCount, 16)
        XCTAssertNil(viewport.coordinator(for: pages[0].id))
        XCTAssertTrue(commands.target === viewport.coordinator(for: pages[79].id))
        viewport.synchronize(pages: pages, settings: ToolSettings(), selected: 0)
        let restored = try XCTUnwrap(viewport.coordinator(for: pages[0].id))
        XCTAssertFalse(restored === first)
        XCTAssertEqual(restored.drawing.strokes.count, 1)
    }

    func testFailedSaveKeepsOffscreenDrawingInMemory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let commands = CanvasCommands(), viewport = NotebookViewport(directory: root, commands: commands)
        let pages = (0..<20).map { _ in NotebookPage() }
        var errors: [String] = []; commands.reportError = { errors.append($0) }
        viewport.frame = CGRect(x: 0, y: 0, width: 1180, height: 706)
        viewport.synchronize(pages: pages, settings: ToolSettings(), selected: 0); viewport.layoutIfNeeded()
        let first = try XCTUnwrap(viewport.coordinator(for: pages[0].id))
        first.append([StrokeFactory.stroke(points: [.zero, CGPoint(x: 90, y: 80)], color: .blue, width: 2)])
        let url = DrawingDisk.url(root, pages[0].id)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var edited = false; commands.afterInput { edited = true }
        XCTAssertFalse(edited, "Page editing must wait until current ink can be saved")
        viewport.synchronize(pages: pages, settings: ToolSettings(), selected: 19)
        XCTAssertTrue(viewport.coordinator(for: pages[0].id) === first)
        XCTAssertEqual(first.drawing.strokes.count, 1)
        XCTAssertFalse(errors.isEmpty)
        try FileManager.default.removeItem(at: url)
        XCTAssertTrue(first.persist())
        XCTAssertEqual(try DrawingDisk.load(root, pages[0].id).strokes.count, 1)
    }

    func testPageSwitchAndToolUpdatesRetainIndependentDrawings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let commands = CanvasCommands(), viewport = NotebookViewport(directory: root, commands: commands)
        let pages = [NotebookPage(), NotebookPage()]
        viewport.frame = CGRect(x: 0, y: 0, width: 1180, height: 706)
        viewport.synchronize(pages: pages, settings: ToolSettings(), selected: 0); viewport.layoutIfNeeded()
        XCTAssertEqual(viewport.scroll.panGestureRecognizer.minimumNumberOfTouches, 1)
        XCTAssertFalse(viewport.scroll.panGestureRecognizer.allowedTouchTypes.contains(NSNumber(value: UITouch.TouchType.stylus.rawValue)))
        let first = try XCTUnwrap(viewport.coordinator(for: pages[0].id))
        let second = try XCTUnwrap(viewport.coordinator(for: pages[1].id))
        first.append([StrokeFactory.stroke(points: [.zero, CGPoint(x: 100, y: 100)], color: .red, width: 2)])
        second.append([StrokeFactory.stroke(points: [.zero, CGPoint(x: 50, y: 80)], color: .blue, width: 4)])
        for index in 0..<20 {
            var settings = ToolSettings(); settings.tool = index % 2 == 0 ? .pen : .eraser
            viewport.synchronize(pages: pages, settings: settings, selected: index % 2)
        }
        XCTAssertTrue(viewport.coordinator(for: pages[0].id) === first)
        XCTAssertTrue(viewport.coordinator(for: pages[1].id) === second)
        XCTAssertEqual(first.drawing.strokes.count, 1); XCTAssertEqual(second.drawing.strokes.count, 1)
        viewport.flush()
        XCTAssertEqual(try DrawingDisk.load(root, pages[0].id).strokes.count, 1)
        XCTAssertEqual(try DrawingDisk.load(root, pages[1].id).strokes.count, 1)
        var readOnly = ToolSettings(); readOnly.readOnly = true
        viewport.synchronize(pages: pages, settings: readOnly, selected: 0)
        XCTAssertFalse(try XCTUnwrap(first.canvas).isUserInteractionEnabled)
        XCTAssertFalse(try XCTUnwrap(second.canvas).isUserInteractionEnabled)
    }
}
