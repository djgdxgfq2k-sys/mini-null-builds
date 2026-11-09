import XCTest
import UIKit
import ZIPFoundation
@testable import NullMini

@MainActor final class LibraryImportTests: XCTestCase {
    private func pdf() -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 300)).pdfData { context in
            context.beginPage(); UIColor.black.setFill(); UIRectFill(CGRect(x: 20, y: 20, width: 40, height: 4))
        }
    }

    private func backup(_ entries: [String: Data], at url: URL) throws {
        let archive = try Archive(url: url, accessMode: .create)
        for (name, data) in entries.sorted(by: { $0.key < $1.key }) {
            try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { position, size in
                data.subdata(in: Int(position) ..< Int(position) + size)
            }
        }
    }

    func testBackupZipRecreatesFoldersAndNotebooks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = root.appendingPathComponent("Goodnotes_Backup.zip")
        try backup([
            ".goodnotesmeta": Data("{}".utf8),
            "Lose Notiz.pdf": pdf(),
            "Schule/Mathe/Unterricht/Q1 Unterricht.pdf": pdf(),
            "Schule/Mathe/Klausur.pdf": pdf(),
            "Schule/Geo/EU.pdf": pdf(),
            "../Ausbruch.pdf": pdf(),
        ], at: zip)
        XCTAssertTrue(LibraryImport.isLibraryBackup(zip))

        let store = LibraryStore(root: root.appendingPathComponent("library"))
        let before = store.items.count
        var reported: [String] = []
        let summary = await LibraryImport.importLibrary(zip, into: store, parent: nil) { _, _, name in if !name.isEmpty { reported.append(name) } }
        XCTAssertEqual(summary.imported, 4, "failed: \(summary.failed)")
        XCTAssertEqual(summary.folders, 4)
        XCTAssertTrue(summary.failed.isEmpty, "\(summary.failed)")
        XCTAssertEqual(store.items.count, before + 8)
        XCTAssertFalse(reported.contains("Ausbruch.pdf"), "paths leaving the backup must be skipped")

        func folder(_ title: String, in parent: String?) throws -> String {
            try XCTUnwrap(store.items.first { $0.folder && $0.title == title && $0.parent == parent }?.id, "missing folder \(title)")
        }
        let schule = try folder("Schule", in: nil)
        let mathe = try folder("Mathe", in: schule)
        let unterricht = try folder("Unterricht", in: mathe)
        _ = try folder("Geo", in: schule)
        let lesson = try XCTUnwrap(store.items.first { $0.title == "Q1 Unterricht" })
        XCTAssertEqual(lesson.parent, unterricht)
        XCTAssertFalse(lesson.folder); XCTAssertEqual(lesson.pages.count, 1)
        XCTAssertNil(try XCTUnwrap(store.items.first { $0.title == "Lose Notiz" }).parent)

        // A second import reuses the folders instead of duplicating them.
        let again = await LibraryImport.importLibrary(zip, into: store, parent: nil) { _, _, _ in }
        XCTAssertEqual(again.folders, 0)
        XCTAssertEqual(store.items.filter { $0.folder && $0.title == "Schule" }.count, 1)
    }

    func testSingleNotebookArchiveIsNotALibrary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = root.appendingPathComponent("Notiz.goodnotes")
        try backup(["schema.pb": Data([8, 1]), "index.notes.pb": Data(), "attachments/a.pdf": pdf()], at: zip)
        XCTAssertFalse(LibraryImport.isLibraryBackup(zip))
    }

    func testFolderPickedInFilesImportsItsTree() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let picked = root.appendingPathComponent("Goodnotes")
        try FileManager.default.createDirectory(at: picked.appendingPathComponent("Physik"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try pdf().write(to: picked.appendingPathComponent("Physik/Wellen.pdf"))
        try pdf().write(to: picked.appendingPathComponent("Start.pdf"))
        let store = LibraryStore(root: root.appendingPathComponent("library"))
        let summary = await LibraryImport.importLibrary(picked, into: store, parent: nil) { _, _, _ in }
        XCTAssertEqual(summary.imported, 2, "\(summary.failed)")
        let physik = try XCTUnwrap(store.items.first { $0.folder && $0.title == "Physik" }?.id)
        XCTAssertEqual(try XCTUnwrap(store.items.first { $0.title == "Wellen" }).parent, physik)
    }
}
