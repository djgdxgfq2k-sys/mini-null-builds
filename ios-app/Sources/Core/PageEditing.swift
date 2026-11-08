import Foundation
import PDFKit

@MainActor enum PageEditing {
    private static func locate(_ pageID: String, bookID: String, store: LibraryStore) throws -> (LibraryItem, Int) {
        guard let item = store.item(bookID), let index = item.pages.firstIndex(where: { $0.id == pageID }) else { throw NotebookError.invalid("Die Seite ist nicht mehr vorhanden.") }
        return (item, index)
    }
    private static func commit(_ item: LibraryItem, store: LibraryStore) throws {
        store.update(item)
        guard store.item(item.id) == item else { throw NotebookError.invalid(store.error ?? "Die Seitenänderung konnte nicht gesichert werden.") }
    }
    @discardableResult static func insert(relativeTo pageID: String, after: Bool, bookID: String, store: LibraryStore, paper: String? = nil, paperColor: String? = nil, atEnd: Bool = false) throws -> Int {
        var (item, index) = try locate(pageID, bookID: bookID, store: store)
        let source = item.pages[index]
        var page = NotebookPage(width: source.width, height: source.height, paper: paper ?? source.paper, paperColor: paperColor ?? source.paperColor)
        page.rotation = source.rotation
        let position = atEnd ? item.pages.count : index + (after ? 1 : 0)
        item.pages.insert(page, at: position); item.modified = Date(); try commit(item, store: store)
        return position
    }
    @discardableResult static func insertPDF(_ url: URL, relativeTo pageID: String, position: Int, bookID: String, store: LibraryStore) throws -> Int {
        var (item, index) = try locate(pageID, bookID: bookID, store: store)
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= NotebookArchive.maxEntry, let pdf = PDFDocument(data: data), pdf.pageCount > 0 else { throw NotebookError.invalid("Die PDF-Datei ist ungültig oder zu groß.") }
        let filename = UUID().uuidString + ".pdf", destination = store.directory(bookID).appendingPathComponent(filename)
        var pages: [NotebookPage] = []
        for number in 0..<pdf.pageCount {
            guard let page = pdf.page(at: number) else { throw NotebookError.invalid("Eine PDF-Seite konnte nicht geladen werden.") }
            let size = page.bounds(for: .cropBox).size
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0, size.width <= 100000, size.height <= 100000 else { throw NotebookError.invalid("Ungültige PDF-Seitengröße.") }
            pages.append(NotebookPage(width: size.width, height: size.height, pdf: filename, pdfPage: number, paper: "blank"))
        }
        let insertion = position == 2 ? item.pages.count : index + (position == 0 ? 0 : 1)
        do {
            try data.write(to: destination, options: .atomic)
            item.pages.insert(contentsOf: pages, at: insertion); item.modified = Date(); try commit(item, store: store)
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
        return insertion
    }
    @discardableResult static func duplicate(_ pageID: String, bookID: String, store: LibraryStore) throws -> Int {
        var (item, index) = try locate(pageID, bookID: bookID, store: store)
        let source = item.pages[index]; var page = source; page.id = UUID().uuidString
        let directory = store.directory(bookID); var created: [URL] = []
        do {
            for suffix in [".drawing", ".texts.json"] {
                let from = directory.appendingPathComponent(source.id + suffix), to = directory.appendingPathComponent(page.id + suffix)
                if FileManager.default.fileExists(atPath: from.path) { try FileManager.default.copyItem(at: from, to: to); created.append(to) }
            }
            item.pages.insert(page, at: index + 1); item.modified = Date(); try commit(item, store: store)
            return index + 1
        } catch { for file in created { try? FileManager.default.removeItem(at: file) }; throw error }
    }
    static func rotate(_ pageID: String, turns: Int = 1, bookID: String, store: LibraryStore) throws {
        var (item, index) = try locate(pageID, bookID: bookID, store: store)
        item.pages[index].rotation = (item.pages[index].quarterTurns + turns % 4 + 4) % 4
        item.modified = Date(); try commit(item, store: store)
    }
    static func setOutline(_ title: String, pageID: String, bookID: String, store: LibraryStore) throws {
        var (item, index) = try locate(pageID, bookID: bookID, store: store)
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        item.pages[index].outlineTitle = value.isEmpty ? nil : value
        try commit(item, store: store)
    }
    @discardableResult static func move(_ pageID: String, to destination: Int, bookID: String, store: LibraryStore) throws -> Int {
        var (item, index) = try locate(pageID, bookID: bookID, store: store)
        let page = item.pages.remove(at: index), position = min(max(0, destination), item.pages.count)
        item.pages.insert(page, at: position); item.modified = Date(); try commit(item, store: store)
        return position
    }
    @discardableResult static func remove(_ pageID: String, clearOnly: Bool, bookID: String, store: LibraryStore) throws -> Int {
        var (item, index) = try locate(pageID, bookID: bookID, store: store)
        let old = item.pages[index]
        item.deletedPages = (item.deletedPages ?? []) + [old]
        if clearOnly {
            var replacement = old; replacement.id = UUID().uuidString; replacement.sourceNotes = nil
            item.pages[index] = replacement
        } else {
            item.pages.remove(at: index)
            if item.pages.isEmpty { var replacement = NotebookPage(width: old.width, height: old.height, paper: old.paper, paperColor: old.paperColor); replacement.rotation = old.rotation; item.pages.append(replacement) }
        }
        item.modified = Date(); try commit(item, store: store)
        return min(index, item.pages.count - 1)
    }
    @discardableResult static func restoreLast(at position: Int, bookID: String, store: LibraryStore) throws -> Int {
        guard var item = store.item(bookID), var history = item.deletedPages, let page = history.popLast() else { throw NotebookError.invalid("Es gibt keine entfernte Seite.") }
        let index = min(max(0, position), item.pages.count)
        item.pages.insert(page, at: index); item.deletedPages = history; item.modified = Date(); try commit(item, store: store)
        return index
    }
}
