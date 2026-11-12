import XCTest
import Combine
import PencilKit
import UIKit
@testable import NullMini

@MainActor final class PerformanceRegressionTests: XCTestCase {
    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testDeferredLibrarySavesCannotOverwriteCheckpoint() async throws {
        let root = try workspace(), store = LibraryStore(root: root)
        var book = try XCTUnwrap(store.add(title: "Start"))
        book.title = "Zwischenstand"; store.update(book, deferred: true)
        book.title = "Aktuell"; store.update(book, deferred: true)
        try store.save()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(LibraryStore(root: root).item(book.id)?.title, "Aktuell")
    }

    func testUnchangedUpdateDoesNotPublishLibraryAgain() throws {
        let store = LibraryStore(root: try workspace())
        let book = try XCTUnwrap(store.add(title: "Unverändert"))
        var publications = 0
        let subscription = store.$items.dropFirst().sink { _ in publications += 1 }
        store.update(book)
        XCTAssertEqual(publications, 0)
        withExtendedLifetime(subscription) {}
    }

    func testIndexedLookupAndTrashCacheSurviveReloadAndMove() throws {
        let root = try workspace(), store = LibraryStore(root: root)
        let folder = try XCTUnwrap(store.add(title: "Ordner", folder: true))
        let book = try XCTUnwrap(store.add(title: "Notizen", parent: folder.id))
        XCTAssertFalse(store.isTrashed(book.id))
        store.trash(folder.id)
        XCTAssertTrue(store.isTrashed(book.id))
        let reopened = LibraryStore(root: root)
        XCTAssertEqual(reopened.item(book.id), book)
        XCTAssertTrue(reopened.isTrashed(book.id))
        reopened.move(book.id, into: nil)
        XCTAssertFalse(reopened.isTrashed(book.id))
    }

    func testEvictingCleanPagesDoesNotCreateDrawingFiles() throws {
        let root = try workspace(), commands = CanvasCommands()
        let viewport = NotebookViewport(directory: root, commands: commands)
        let pages = (0..<80).map { _ in NotebookPage() }
        viewport.frame = CGRect(x: 0, y: 0, width: 1180, height: 706)
        viewport.synchronize(pages: pages, settings: ToolSettings(), selected: 0)
        viewport.layoutIfNeeded()
        viewport.synchronize(pages: pages, settings: ToolSettings(), selected: 79)
        viewport.flush()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        XCTAssertLessThanOrEqual(viewport.livePageCount, 16)
    }

    func testSidebarResizePreservesZoomAndPrefetchStaysAtBaseScale() throws {
        let root = try workspace(), commands = CanvasCommands()
        let viewport = NotebookViewport(directory: root, commands: commands)
        let pages = (0..<20).map { _ in NotebookPage() }
        viewport.frame = CGRect(x: 0, y: 0, width: 1180, height: 706)
        viewport.synchronize(pages: pages, settings: ToolSettings(), selected: 0)
        viewport.layoutIfNeeded()
        viewport.scroll.setZoomScale(6, animated: false)
        viewport.scrollViewDidEndZooming(viewport.scroll, with: nil, atScale: 6)
        viewport.frame.size.width = 805; viewport.layoutIfNeeded()
        XCTAssertEqual(viewport.scroll.zoomScale, 6, accuracy: 0.001)
        let scales = pages.compactMap { viewport.coordinator(for: $0.id)?.viewport?.outerZoom }
        XCTAssertTrue(scales.contains(1), "offscreen prefetch must not allocate deep-zoom canvases")
        XCTAssertTrue(scales.contains(6), "the visible page must retain sharp zoom")
    }

    func testDeferredUndoStaysOnThePageThatReceivedTheCommand() async throws {
        let root = try workspace(), commands = CanvasCommands()
        let a = NotebookPage(), b = NotebookPage()
        let first = CanvasSurface.Coordinator(page: a, directory: root, commands: commands)
        let firstView = PageViewport(page: a, directory: root); first.attach(firstView)
        first.append([StrokeFactory.stroke(points: [.zero, CGPoint(x: 30, y: 20)], color: .black, width: 2)])
        first.canvasViewDidBeginUsingTool(firstView.canvas)
        commands.undo()
        let second = CanvasSurface.Coordinator(page: b, directory: root, commands: commands)
        let secondView = PageViewport(page: b, directory: root); second.attach(secondView)
        second.append([StrokeFactory.stroke(points: [.zero, CGPoint(x: 50, y: 40)], color: .blue, width: 2)])
        first.canvasViewDidEndUsingTool(firstView.canvas)
        let finished = expectation(description: "Deferred undo completed")
        DispatchQueue.main.async { finished.fulfill() }
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertTrue(firstView.canvas.drawing.strokes.isEmpty)
        XCTAssertEqual(secondView.canvas.drawing.strokes.count, 1)
    }
}
