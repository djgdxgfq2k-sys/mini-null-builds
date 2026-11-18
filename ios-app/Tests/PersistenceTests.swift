import XCTest
import PencilKit
@testable import NullMini

@MainActor final class PersistenceTests: XCTestCase {
    func testStrokeIsOnDiskAfterFlushEvenBeforeDebounceFires() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let page = NotebookPage(), commands = CanvasCommands(), coordinator = CanvasSurface.Coordinator(page: page, directory: root, commands: commands)
        let view = PageViewport(page: page, directory: root); coordinator.attach(view)
        let points = (0 ... 5).map { PKStrokePoint(location: CGPoint(x: 10 + CGFloat($0) * 5, y: 20), timeOffset: Double($0) * 0.01, size: CGSize(width: 2, height: 2), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2) }
        coordinator.append([PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))])
        XCTAssertTrue(coordinator.persist(force: false))
        XCTAssertEqual(try DrawingDisk.load(root, page.id).strokes.count, 1)
    }
}
