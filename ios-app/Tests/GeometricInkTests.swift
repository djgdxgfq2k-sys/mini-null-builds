import XCTest
import PencilKit
import UIKit
@testable import NullMini

@MainActor final class GeometricInkTests: XCTestCase {
    func testFilledEllipseKeepsClippedFillAndOutlineAfterSaving() throws {
        var settings = ToolSettings(); settings.tool = .geometry; settings.color = "#FF0000"; settings.fillShapes = true; settings.fillOpacity = 0.5
        let points = GeometricShape.ellipse.points(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 120, y: 100), samples: [])
        let drawing = PKDrawing(strokes: GeometricInk.strokes(points: points, settings: settings, closed: true))
        let restored = try PKDrawing(data: drawing.dataRepresentation())
        XCTAssertEqual(restored.strokes.count, 2); XCTAssertNotNil(restored.strokes.first?.mask)
        let image = restored.image(from: CGRect(x: 0, y: 0, width: 140, height: 120), scale: 1)
        let cgImage = try XCTUnwrap(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: 140 * 120 * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 140, height: 120, bitsPerComponent: 8, bytesPerRow: 560, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: 140, height: 120))
        }
        XCTAssertGreaterThan(pixels[(60 * 140 + 70) * 4 + 3], 50, "Filled interior is missing")
        XCTAssertEqual(pixels[(21 * 140 + 21) * 4 + 3], 0, "Fill escaped the ellipse mask")
        let attachment = XCTAttachment(image: image); attachment.name = "saved-filled-ellipse"; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testDashedShapeHasGapsAndSurvivesNotebookExport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root), item = try XCTUnwrap(store.add(title: "Shapes"))
        var settings = ToolSettings(); settings.strokePattern = .dashed
        let points = GeometricShape.rectangle.points(from: CGPoint(x: 20, y: 30), to: CGPoint(x: 120, y: 90), samples: [])
        let drawing = PKDrawing(strokes: GeometricInk.strokes(points: points, settings: settings, closed: true))
        XCTAssertGreaterThan(drawing.strokes.count, 10)
        try DrawingDisk.save(drawing, directory: store.directory(item.id), page: item.pages[0].id)
        let url = root.appendingPathComponent("shapes.nullmini")
        try NotebookArchive.exportNative(item: item, directory: store.directory(item.id), to: url)
        let imported = try NotebookArchive.importFile(url, into: store, parent: nil)
        XCTAssertEqual(try DrawingDisk.load(store.directory(imported.id), imported.pages[0].id).strokes.count, drawing.strokes.count)
    }
}
