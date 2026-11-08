import XCTest
import PencilKit
import PDFKit
@testable import NullMini

@MainActor final class PageEditingTests: XCTestCase {
    func testDuplicateRotationAndExportKeepEditableDrawingBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root)
        var book = try XCTUnwrap(store.add(title: "Pages"))
        book.pages[0].width = 400; book.pages[0].height = 600; book.pages[0].paper = "blank"; store.update(book)
        let page = book.pages[0], directory = store.directory(book.id)
        let drawing = PKDrawing(strokes: [StrokeFactory.stroke(points: [CGPoint(x: 40, y: 60), CGPoint(x: 80, y: 60)], color: .red, width: 20)])
        try DrawingDisk.save(drawing, directory: directory, page: page.id)
        let drawingURL = DrawingDisk.url(directory, page.id), before = try Data(contentsOf: drawingURL)
        let text = try JSONEncoder().encode([TextBox(text: "Editable", x: 10, y: 10, width: 120, height: 40)])
        try text.write(to: directory.appendingPathComponent(page.id + ".texts.json"))
        let index = try PageEditing.duplicate(page.id, bookID: book.id, store: store)
        let duplicate = try XCTUnwrap(store.item(book.id)?.pages[index])
        XCTAssertNotEqual(duplicate.id, page.id)
        XCTAssertEqual(try Data(contentsOf: DrawingDisk.url(directory, duplicate.id)), before)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(duplicate.id + ".texts.json")), text)
        let commands = CanvasCommands(), viewport = NotebookViewport(directory: directory, commands: commands)
        viewport.frame = CGRect(x: 0, y: 0, width: 1180, height: 706)
        viewport.synchronize(pages: try XCTUnwrap(store.item(book.id)).pages, settings: ToolSettings(), selected: 0); viewport.layoutIfNeeded()
        let coordinator = try XCTUnwrap(viewport.coordinator(for: page.id))
        try PageEditing.rotate(page.id, bookID: book.id, store: store)
        let rotated = try XCTUnwrap(store.item(book.id)?.pages.first)
        viewport.synchronize(pages: try XCTUnwrap(store.item(book.id)).pages, settings: ToolSettings(), selected: 0)
        XCTAssertTrue(viewport.coordinator(for: page.id) === coordinator)
        XCTAssertEqual(coordinator.viewport?.document.bounds.size, page.nativeSize)
        XCTAssertEqual(coordinator.viewport?.content.bounds.size, rotated.size)
        XCTAssertEqual(coordinator.drawing.strokes.count, 1)
        XCTAssertEqual(rotated.size, CGSize(width: 600, height: 400))
        let thumbnail = try NotebookThumbnail.render(page: rotated, directory: directory, width: 300)
        XCTAssertEqual(thumbnail.size, CGSize(width: 300, height: 200))
        XCTAssertGreaterThan(try meanRedX(thumbnail), 225)
        var selection = try XCTUnwrap(store.item(book.id)); selection.pages = [rotated]
        let pdfURL = root.appendingPathComponent("rotated.pdf")
        try NotebookArchive.exportPDF(item: selection, directory: directory, to: pdfURL)
        let pdf = try XCTUnwrap(PDFDocument(url: pdfURL)), pdfPage = try XCTUnwrap(pdf.page(at: 0))
        XCTAssertEqual(pdfPage.bounds(for: .cropBox).size, rotated.size)
        let imported = try NotebookArchive.importFile(pdfURL, into: store, parent: nil)
        let pdfThumbnail = try NotebookThumbnail.render(page: imported.pages[0], directory: store.directory(imported.id), width: 300)
        XCTAssertGreaterThan(try meanRedX(pdfThumbnail), 225)
        for _ in 0..<3 { try PageEditing.rotate(page.id, bookID: book.id, store: store) }
        XCTAssertEqual(store.item(book.id)?.pages.first?.size, page.nativeSize)
        XCTAssertEqual(try Data(contentsOf: drawingURL), before)
        let attachment = XCTAttachment(image: thumbnail); attachment.name = "rotated-editable-page"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testClearTrashAndRestoreKeepOriginalInkAndNativeHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root), book = try XCTUnwrap(store.add(title: "History")), page = book.pages[0]
        let drawing = PKDrawing(strokes: [StrokeFactory.stroke(points: [.zero, CGPoint(x: 90, y: 80)], color: .blue, width: 2)])
        try DrawingDisk.save(drawing, directory: store.directory(book.id), page: page.id)
        let bytes = try Data(contentsOf: DrawingDisk.url(store.directory(book.id), page.id))
        try PageEditing.setOutline("Chapter", pageID: page.id, bookID: book.id, store: store)
        _ = try PageEditing.remove(page.id, clearOnly: true, bookID: book.id, store: store)
        let cleared = try XCTUnwrap(store.item(book.id)?.pages.first)
        XCTAssertNotEqual(cleared.id, page.id)
        XCTAssertTrue(try DrawingDisk.load(store.directory(book.id), cleared.id).strokes.isEmpty)
        XCTAssertEqual(try Data(contentsOf: DrawingDisk.url(store.directory(book.id), page.id)), bytes)
        let url = root.appendingPathComponent("history.nullmini")
        try NotebookArchive.exportNative(item: XCTUnwrap(store.item(book.id)), directory: store.directory(book.id), to: url)
        let imported = try NotebookArchive.importFile(url, into: store, parent: nil)
        XCTAssertEqual(imported.deletedPages?.first?.outlineTitle, "Chapter")
        let restoredIndex = try PageEditing.restoreLast(at: 0, bookID: imported.id, store: store)
        let restored = try XCTUnwrap(store.item(imported.id)?.pages[restoredIndex])
        XCTAssertEqual(restored.id, page.id)
        XCTAssertEqual(try Data(contentsOf: DrawingDisk.url(store.directory(imported.id), restored.id)), bytes)
        _ = try PageEditing.remove(restored.id, clearOnly: false, bookID: imported.id, store: store)
        XCTAssertFalse(try XCTUnwrap(store.item(imported.id)).pages.contains(where: { $0.id == restored.id }))
        _ = try PageEditing.restoreLast(at: 0, bookID: imported.id, store: store)
        XCTAssertEqual(try DrawingDisk.load(store.directory(imported.id), restored.id).strokes.count, 1)
    }

    func testFailedIndexWriteRollsBackDuplicateFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root), book = try XCTUnwrap(store.add(title: "Unwritable")), directory = store.directory(book.id)
        try DrawingDisk.save(PKDrawing(), directory: directory, page: book.pages[0].id)
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let index = root.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at: index); try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        XCTAssertThrowsError(try PageEditing.duplicate(book.pages[0].id, bookID: book.id, store: store))
        XCTAssertEqual(store.item(book.id), book)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), before)
    }

    func testMediaPagesKeepPDFBytesAndExistingInkAtInsertionPoint() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root)
        var book = try XCTUnwrap(store.add(title: "Media")); book.pages[0].rotation = 1; book.pages[0].paperColor = "#F7F6E9"; store.update(book)
        let original = book.pages[0], directory = store.directory(book.id)
        let drawing = PKDrawing(strokes: [StrokeFactory.stroke(points: [.zero, CGPoint(x: 70, y: 90)], color: .blue, width: 2)])
        try DrawingDisk.save(drawing, directory: directory, page: original.id)
        let ink = try Data(contentsOf: DrawingDisk.url(directory, original.id))
        let incoming = root.appendingPathComponent("incoming.pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 200))
        try renderer.writePDF(to: incoming) { context in context.beginPage(); context.beginPage(withBounds: CGRect(x: 0, y: 0, width: 200, height: 300), pageInfo: [:]) }
        let source = try Data(contentsOf: incoming)
        XCTAssertEqual(try PageEditing.insertPDF(incoming, relativeTo: original.id, position: 0, bookID: book.id, store: store), 0)
        var edited = try XCTUnwrap(store.item(book.id))
        XCTAssertEqual(edited.pages.count, 3); XCTAssertEqual(edited.pages[2].id, original.id)
        XCTAssertEqual(edited.pages[0].size, CGSize(width: 300, height: 200)); XCTAssertEqual(edited.pages[1].size, CGSize(width: 200, height: 300))
        let filename = try XCTUnwrap(edited.pages[0].pdf)
        XCTAssertEqual(edited.pages[1].pdf, filename); XCTAssertEqual(edited.pages[1].pdfPage, 1)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(filename)), source)
        let end = try PageEditing.insert(relativeTo: original.id, after: true, bookID: book.id, store: store, paper: "grid", atEnd: true)
        edited = try XCTUnwrap(store.item(book.id))
        XCTAssertEqual(end, 3); XCTAssertEqual(edited.pages[end].size, original.size)
        XCTAssertEqual(edited.pages[end].paperColor, original.paperColor); XCTAssertEqual(edited.pages[end].paper, "grid")
        XCTAssertEqual(try Data(contentsOf: DrawingDisk.url(directory, original.id)), ink)
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        let index = root.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at: index); try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        XCTAssertThrowsError(try PageEditing.insertPDF(incoming, relativeTo: original.id, position: 1, bookID: book.id, store: store))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), before)
        XCTAssertEqual(store.item(book.id), edited)
    }

    private func meanRedX(_ image: UIImage) throws -> Double {
        let cgImage = try XCTUnwrap(image.cgImage), width = 300, height = 200
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        }
        var total = 0, count = 0
        for y in 0..<height { for x in 0..<width { let i = (y * width + x) * 4; if pixels[i] > 180 && pixels[i+1] < 100 && pixels[i+2] < 100 { total += x; count += 1 } } }
        XCTAssertGreaterThan(count, 0)
        return Double(total) / Double(max(1, count))
    }
}
