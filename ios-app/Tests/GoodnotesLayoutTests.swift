import XCTest
import UIKit
import PDFKit
import ZIPFoundation
@testable import NullMini

/// Builds Goodnotes archives with the structures found in a real 84-notebook backup.
@MainActor final class GoodnotesLayoutTests: XCTestCase {
    // MARK: Protobuf writer
    private func varint(_ value: UInt64) -> Data {
        var v = value, out = Data()
        repeat { var byte = UInt8(v & 0x7F); v >>= 7; if v != 0 { byte |= 0x80 }; out.append(byte) } while v != 0
        return out
    }
    private func field(_ n: Int, _ body: Data) -> Data { varint(UInt64(n << 3 | 2)) + varint(UInt64(body.count)) + body }
    private func field(_ n: Int, _ text: String) -> Data { field(n, Data(text.utf8)) }
    private func field(_ n: Int, int value: UInt64) -> Data { varint(UInt64(n << 3)) + varint(value) }
    private func field(_ n: Int, float value: Float) -> Data { var bits = value.bitPattern.littleEndian; return varint(UInt64(n << 3 | 5)) + Data(bytes: &bits, count: 4) }
    private func records(_ messages: [Data]) -> Data { messages.reduce(Data()) { $0 + varint(UInt64($1.count)) + $1 } }
    private func version(_ v: UInt64) -> Data { field(1, int: v) + field(2, int: 99) }

    private func template(_ id: String, attachment: String, page: UInt64, size: CGSize) -> Data {
        field(1, id) + field(2, field(1, "DOC") + field(2, id) + field(4, attachment) + field(5, int: page)
            + field(8, field(1, float: Float(size.width)) + field(2, float: Float(size.height))))
    }
    private func page(_ id: String, template: String, order: String, v: UInt64 = 1) -> Data {
        field(1, id) + field(54, field(1, "DOC") + field(2, id) + field(3, field(1, template) + field(2, version(1))) + field(4, field(1, order) + field(2, version(v))))
    }
    private func move(_ id: String, order: String, v: UInt64) -> Data {
        field(1, id) + field(55, field(1, "DOC") + field(2, id) + field(3, field(1, order) + field(2, version(v))))
    }
    private func attachment(_ id: String, file: String) -> Data { field(1, id) + field(6, field(1, id) + field(2, file) + field(6, "DOC")) }

    private func pdf(pages: Int, size: CGSize) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { context in
            for i in 0 ..< pages { context.beginPage(); UIColor.black.setFill(); UIRectFill(CGRect(x: 10, y: 10 + CGFloat(i) * 20, width: 50, height: 4)) }
        }
    }

    private let pageA = "11111111-1111-4111-8111-1111111111FF"   // strokes in …1100 (last byte wraps)
    private let pageB = "22222222-2222-4222-8222-222222222210"   // strokes in …2211
    private let pageC = "33333333-3333-4333-8333-333333333330"   // strokes in …3331

    private func archiveFiles() -> [String: Data] {
        let worksheet = pdf(pages: 3, size: CGSize(width: 600, height: 800))
        let lined = pdf(pages: 1, size: CGSize(width: 834.24, height: 1078.83))
        let noteA = "11111111-1111-4111-8111-111111111100", noteB = "22222222-2222-4222-8222-222222222211", noteC = "33333333-3333-4333-8333-333333333331"
        // Page C's notes hold one element that is not a stroke message (seen in two real notebooks).
        let junk = records([field(7, Data([0xFF, 0xFF, 0xFF]))])
        return [
            "schema.pb": field(1, int: 31),
            "index.notes.pb": records([noteB, noteA, noteC].map { field(1, $0) + field(2, "notes/" + $0) }),
            "index.attachments.pb": records([field(1, "LINED") + field(2, "attachments/LINED-FILE")]),
            "index.events.pb": records([
                attachment("SHEET", file: "SHEET-FILE"),
                template("T-LINED", attachment: "LINED", page: 1, size: CGSize(width: 834.24, height: 1078.83)),
                template("T-SHEET-2", attachment: "SHEET", page: 2, size: CGSize(width: 600, height: 800)),
                page(pageA, template: "T-LINED", order: "b"),
                page(pageB, template: "T-SHEET-2", order: "a"),
                page(pageC, template: "T-LINED", order: "c"),
                move(pageC, order: "Z", v: 2),            // moved to the front later
                move(pageB, order: "zzz", v: 0),           // an older order key never wins
            ]),
            "notes/" + noteA: Data(), "notes/" + noteB: Data(), "notes/" + noteC: junk,
            "attachments/LINED-FILE": lined,
            "attachments/SHEET-FILE": worksheet,
        ]
    }

    func testPagesFollowOrderKeysTemplatesAndShiftedNoteIDs() throws {
        XCTAssertEqual(GoodnotesLayout.noteID(forPage: pageA), "11111111-1111-4111-8111-111111111100")
        XCTAssertEqual(GoodnotesLayout.noteID(forPage: pageB), "22222222-2222-4222-8222-222222222211")
        let pages = try GoodnotesLayout.pages(archiveFiles())
        XCTAssertEqual(pages.map(\.notesPath), ["notes/33333333-3333-4333-8333-333333333331", "notes/22222222-2222-4222-8222-222222222211", "notes/11111111-1111-4111-8111-111111111100"])
        XCTAssertEqual(pages[1].background, "attachments/SHEET-FILE", "the background resolves through the attachment registry")
        XCTAssertEqual(pages[1].backgroundPage, 1, "Goodnotes counts PDF pages from 1")
        XCTAssertEqual(pages[0].background, "attachments/LINED-FILE", "the background resolves through index.attachments.pb")
        XCTAssertEqual(pages[0].size?.width ?? 0, 834.24, accuracy: 0.01)
    }

    func testNotebookImportsWithBackgroundsSharedPDFsAndUnreadableElements() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Biologie.goodnotes")
        try NotebookArchive.write(archiveFiles(), to: url)
        let store = LibraryStore(root: root.appendingPathComponent("library"))
        let item = try NotebookArchive.importFile(url, into: store, parent: nil)
        XCTAssertEqual(item.title, "Biologie")
        XCTAssertEqual(item.pages.count, 3)
        XCTAssertTrue(item.pages.allSatisfy { $0.pdf != nil }, "every page keeps its paper or worksheet background")
        XCTAssertEqual(item.pages[1].pdfPage, 1)
        XCTAssertEqual(item.pages[1].width, 600, accuracy: 0.01)
        XCTAssertEqual(item.pages[0].pdf, item.pages[2].pdf, "pages on the same template share one PDF file")
        let pdfs = try FileManager.default.contentsOfDirectory(at: store.directory(item.id), includingPropertiesForKeys: nil).filter { $0.pathExtension == "pdf" }
        XCTAssertEqual(pdfs.count, 2)
        XCTAssertTrue(item.warnings.contains { $0.contains("1 besondere") }, "\(item.warnings)")
        // The page's strokes are read straight from its archive member.
        XCTAssertNoThrow(try NotebookArchive.originalInk(page: item.pages[2], directory: store.directory(item.id)))
    }
}
