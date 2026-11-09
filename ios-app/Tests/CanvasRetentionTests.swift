import XCTest
import PencilKit
import UIKit
@testable import NullMini

@MainActor final class CanvasRetentionTests:XCTestCase {
    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:url) }; return url
    }
    func testHundredStrokesSurviveToolbarUpdatesAndReload() throws {
        let directory = try workspace(), page = NotebookPage(), commands = CanvasCommands()
        let coordinator = CanvasSurface.Coordinator(page:page,directory:directory,commands:commands)
        let viewport = PageViewport(page:page,directory:directory); coordinator.attach(viewport)
        for i in 0..<100 {
            let stroke = StrokeFactory.stroke(points:[CGPoint(x:10,y:CGFloat(i+20)),CGPoint(x:80,y:CGFloat(i+20))],color:.black,width:2)
            viewport.canvas.drawing = PKDrawing(strokes:viewport.canvas.drawing.strokes+[stroke])
            coordinator.canvasViewDrawingDidChange(viewport.canvas)
            var settings = ToolSettings(); settings.color = i%2 == 0 ? "#255799" : "#1E1B1B"; settings.width = CGFloat(i%4+1)
            coordinator.configure(settings)
            XCTAssertEqual(viewport.canvas.drawing.strokes.count,i+1)
            XCTAssertEqual(coordinator.drawing.strokes.count,i+1)
        }
        let reloaded = try DrawingDisk.load(directory,page.id)
        XCTAssertEqual(reloaded.strokes.count,100)
        for i in 0..<100 { XCTAssertEqual(reloaded.strokes[i].path.first?.location.x,10) }
    }
    func testCommandWaitsUntilPencilLifts() async throws {
        let directory = try workspace(), page = NotebookPage(), commands = CanvasCommands()
        let coordinator = CanvasSurface.Coordinator(page:page,directory:directory,commands:commands)
        let viewport = PageViewport(page:page,directory:directory); coordinator.attach(viewport)
        coordinator.canvasViewDidBeginUsingTool(viewport.canvas)
        let stroke = StrokeFactory.stroke(points:[.zero,CGPoint(x:20,y:20)],color:.black,width:2)
        commands.append([stroke])
        XCTAssertTrue(coordinator.drawing.strokes.isEmpty)
        coordinator.canvasViewDidEndUsingTool(viewport.canvas)
        let done = expectation(description:"Deferred Pencil command")
        DispatchQueue.main.async { done.fulfill() }
        await fulfillment(of:[done],timeout:2)
        XCTAssertEqual(coordinator.drawing.strokes.count,1)
    }
    func testUnreadableDrawingNeverGetsOverwritten() throws {
        let directory = try workspace(), page = NotebookPage(), commands = CanvasCommands()
        let corrupt = Data("corrupt-but-preserve-me".utf8), url = DrawingDisk.url(directory,page.id)
        try corrupt.write(to:url)
        let coordinator = CanvasSurface.Coordinator(page:page,directory:directory,commands:commands)
        let viewport = PageViewport(page:page,directory:directory); coordinator.attach(viewport); coordinator.persist()
        XCTAssertEqual(try Data(contentsOf:url),corrupt)
        XCTAssertFalse(viewport.canvas.isUserInteractionEnabled)
    }
    func testPageStateIsIsolated() throws {
        let directory = try workspace(), a = NotebookPage(), b = NotebookPage()
        let drawing = PKDrawing(strokes:[StrokeFactory.stroke(points:[.zero,CGPoint(x:20,y:20)],color:.black,width:2)])
        try DrawingDisk.save(drawing,directory:directory,page:a.id)
        XCTAssertTrue(try DrawingDisk.load(directory,b.id).strokes.isEmpty)
        XCTAssertEqual(try DrawingDisk.load(directory,a.id).strokes.count,1)
    }
    func testPencilInputCanBeDisconnectedWithoutChangingSavedInk() throws {
        let directory = try workspace(), page = NotebookPage(), commands = CanvasCommands()
        let coordinator = CanvasSurface.Coordinator(page: page, directory: directory, commands: commands)
        let viewport = PageViewport(page: page, directory: directory); coordinator.attach(viewport)
        coordinator.append([StrokeFactory.stroke(points: [.zero, CGPoint(x: 70, y: 90)], color: .blue, width: 2)])
        let before = try Data(contentsOf: DrawingDisk.url(directory, page.id))
        var settings = ToolSettings(); settings.tool = .pencil; coordinator.configure(settings)
        XCTAssertEqual((viewport.canvas.tool as? PKInkingTool)?.inkType, .pencil)
        settings.pencilConnected = false; settings.finger = true; coordinator.configure(settings)
        XCTAssertEqual(viewport.canvas.drawingPolicy, .anyInput)
        XCTAssertTrue(viewport.canvas.drawingGestureRecognizer.allowedTouchTypes.contains(NSNumber(value: UITouch.TouchType.pencil.rawValue)), "an unpaired Pencil must still write")
        XCTAssertEqual(viewport.scroll.panGestureRecognizer.minimumNumberOfTouches, 2)
        settings.pencilConnected = true; settings.finger = false; coordinator.configure(settings)
        XCTAssertEqual(viewport.canvas.drawingPolicy, .pencilOnly)
        XCTAssertTrue(viewport.canvas.drawingGestureRecognizer.allowedTouchTypes.contains(NSNumber(value: UITouch.TouchType.pencil.rawValue)))
        XCTAssertFalse(viewport.canvas.drawingGestureRecognizer.allowedTouchTypes.contains(NSNumber(value: UITouch.TouchType.direct.rawValue)))
        XCTAssertEqual(try Data(contentsOf: DrawingDisk.url(directory, page.id)), before)
        XCTAssertEqual(coordinator.drawing.strokes.count, 1)
    }
}
