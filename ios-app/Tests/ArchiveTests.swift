import XCTest
import PencilKit
import CryptoKit
import UIKit
@testable import NullMini

final class WireTests:XCTestCase {
    func testVarintsAndTruncation() throws {
        XCTAssertEqual(try WireMessage(Data([8,150,1]))[1]?.integer,150)
        XCTAssertThrowsError(try WireMessage(Data([10,20,1])))
        XCTAssertThrowsError(try WireMessage.records(Data([12,8,1])))
        XCTAssertThrowsError(try WireMessage(Data([8]+Array(repeating:255,count:11))))
    }
    func testRawAndCompressedLZ4Blocks() throws {
        let raw = Data("bv4-".utf8)+Data([4,0,0,0])+Data("test".utf8)+Data("bv4$".utf8)
        XCTAssertEqual(try AppleLZ4.decode(raw),Data("test".utf8))
        let compressed = Data("bv41".utf8)+Data([8,0,0,0,6,0,0,0,0x40])+Data("abcd".utf8)+Data([4,0])+Data("bv4$".utf8)
        // compressed-size field includes the 1-byte token, 4 literals and 2-byte offset.
        var fixed = compressed; fixed[8] = 7
        XCTAssertEqual(try AppleLZ4.decode(fixed),Data("abcdabcd".utf8))
        XCTAssertThrowsError(try AppleLZ4.decode(Data("bv41".utf8)+Data([4,0,0,0,3,0,0,0,0,0,0])+Data("bv4$".utf8)))
    }
    func testTraversalAndDuplicatePathsAreRejected() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".zip")
        defer { try? FileManager.default.removeItem(at:url) }
        try NotebookArchive.write(["../escape":Data([1])],to:url)
        XCTAssertThrowsError(try NotebookArchive.entries(url))
    }
}

@MainActor final class ArchiveTests:XCTestCase {
    func testCreationDatesKeepLegacyIndexesReadableAndSurviveEdits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root), index = root.appendingPathComponent("library.json")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [[String: Any]])
        for i in legacy.indices { legacy[i].removeValue(forKey: "created") }
        try JSONSerialization.data(withJSONObject: legacy).write(to: index)
        let reopened = LibraryStore(root: root)
        XCTAssertEqual(reopened.items.count, store.items.count)
        XCTAssertTrue(reopened.items.allSatisfy { $0.created == nil })
        var book = try XCTUnwrap(reopened.add(title: "Created date"))
        let created = try XCTUnwrap(book.created)
        book.modified = created.addingTimeInterval(3600); reopened.update(book)
        let saved = try XCTUnwrap(LibraryStore(root: root).item(book.id))
        XCTAssertEqual(saved.created, created)
        XCTAssertEqual(saved.modified, created.addingTimeInterval(3600))
    }
    func testAllReferenceArchivesKeepOriginalBytes() throws {
        let fixtures = try XCTUnwrap(Bundle(for:Self.self).resourceURL)
        for name in ["sample","sample_strokes","sample_strokes_2","sample_whiteboard"] {
            let input = try XCTUnwrap(Bundle(for:Self.self).url(forResource:name,withExtension:"goodnotes") ?? Bundle(for:Self.self).url(forResource:name,withExtension:"goodnotes",subdirectory:"Fixtures"),"Fixture missing in \(fixtures)")
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at:root) }
            let store = LibraryStore(root:root)
            let item = try NotebookArchive.importFile(input,into:store,parent:nil)
            XCTAssertFalse(item.pages.isEmpty)
            let output = root.appendingPathComponent("roundtrip.goodnotes")
            try NotebookArchive.exportOriginal(directory:store.directory(item.id),to:output)
            XCTAssertEqual(SHA256.hash(data:try Data(contentsOf:input)),SHA256.hash(data:try Data(contentsOf:output)))
        }
    }
    func testNativeRoundTripKeepsPageSizeAndNewStrokes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = LibraryStore(root:root)
        var item = try XCTUnwrap(store.add(title:"Roundtrip"))
        item.pages[0].width = 1122; item.pages[0].height = 1452; item.pages[0].paperColor = "#F7F6E9"
        item.kind = .whiteboard; item.color = "display-p3:#84DA69"; store.update(item)
        let drawing = PKDrawing(strokes:[StrokeFactory.stroke(points:[CGPoint(x:11,y:12),CGPoint(x:91,y:33)],color:.blue,width:3)])
        try DrawingDisk.save(drawing,directory:store.directory(item.id),page:item.pages[0].id)
        let url = root.appendingPathComponent("roundtrip.nullmini")
        try NotebookArchive.exportNative(item:item,directory:store.directory(item.id),to:url)
        let imported = try NotebookArchive.importFile(url,into:store,parent:nil)
        XCTAssertEqual(imported.pages[0].width,1122); XCTAssertEqual(imported.pages[0].height,1452)
        XCTAssertEqual(imported.pages[0].paperColor, "#F7F6E9")
        XCTAssertEqual(imported.kind, .whiteboard); XCTAssertEqual(imported.color, "display-p3:#84DA69")
        let restored = try DrawingDisk.load(store.directory(imported.id),imported.pages[0].id)
        XCTAssertEqual(restored.strokes.count,1); XCTAssertEqual(restored.strokes[0].path.first?.location.x,11)
    }
    func testFolderMoveRejectsCycles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = LibraryStore(root:root)
        let parent = try XCTUnwrap(store.add(title:"Parent",folder:true))
        let child = try XCTUnwrap(store.add(title:"Child",parent:parent.id,folder:true))
        store.move(parent.id,into:child.id)
        XCTAssertNil(store.item(parent.id)?.parent)
    }
    func testCorruptLibraryIndexIsNotOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let url = root.appendingPathComponent("library.json"), original = Data("broken-library".utf8)
        try original.write(to:url)
        let store = LibraryStore(root:root)
        XCTAssertNil(store.add(title:"Must not overwrite"))
        XCTAssertThrowsError(try store.save())
        XCTAssertEqual(try Data(contentsOf:url),original)
    }
    func testFolderTrashAndRestoreKeepDescendantDrawings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = LibraryStore(root:root)
        let folder = try XCTUnwrap(store.add(title:"Bio",folder:true,color:"#34C759"))
        let book = try XCTUnwrap(store.add(title:"Notizen",parent:folder.id))
        let drawing = PKDrawing(strokes:[StrokeFactory.stroke(points:[.zero,CGPoint(x:30,y:20)],color:.black,width:2)])
        try DrawingDisk.save(drawing,directory:store.directory(book.id),page:book.pages[0].id)
        store.open(book.id); store.trash(folder.id)
        XCTAssertTrue(store.isTrashed(book.id)); XCTAssertNil(store.active)
        let reloaded = LibraryStore(root:root)
        reloaded.restore(folder.id)
        XCTAssertFalse(reloaded.isTrashed(book.id))
        XCTAssertEqual(try DrawingDisk.load(reloaded.directory(book.id),book.pages[0].id).strokes.count,1)
    }
    func testPDFTextRemainsDarkInDarkMode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = LibraryStore(root:root)
        var book = try XCTUnwrap(store.add(title:"Dark mode")); book.pages[0].paper = "blank"; store.update(book)
        let boxes = [TextBox(text:"Dunkler Text",x:40,y:40,width:240,height:80)]
        try JSONEncoder().encode(boxes).write(to:store.directory(book.id).appendingPathComponent(book.pages[0].id+".texts.json"))
        let url = root.appendingPathComponent("dark-mode.pdf"); var failure:Error?
        UITraitCollection(userInterfaceStyle:.dark).performAsCurrent {
            do { try NotebookArchive.exportPDF(item:book,directory:store.directory(book.id),to:url) } catch { failure = error }
        }
        if let failure { throw failure }
        let pdf = try XCTUnwrap(CGPDFDocument(url as CFURL)), page = try XCTUnwrap(pdf.page(at:1))
        var pixels = [UInt8](repeating:255,count:595*842*4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data:buffer.baseAddress,width:595,height:842,bitsPerComponent:8,bytesPerRow:595*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.drawPDFPage(page)
        }
        let dark = stride(from:0,to:pixels.count,by:4).filter { pixels[$0] < 80 && pixels[$0+1] < 80 && pixels[$0+2] < 80 }.count
        XCTAssertGreaterThan(dark,100)
    }
}
