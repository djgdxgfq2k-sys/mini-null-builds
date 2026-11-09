import Foundation
import CoreGraphics

/// Page structure of a Goodnotes archive, read from `index.events.pb`. Checked against 84 real notebooks
/// (schemas 24, 31 and 35, 1 357 page backgrounds):
/// - event 54 is a page: field 2 page id, field 3.1 its template, field 4.1 its order key (field 4.2.1 version);
/// - event 55 moves a page: field 2 page id, field 3.1 a newer order key;
/// - event 2 is a template: field 2 id, field 4 background attachment, field 5 1-based PDF page, field 8 size;
/// - event 6 registers an attachment: field 1 id, field 2 the stored file id;
/// - the strokes of page P live in `notes/` under P's id with its last byte incremented (…A8FF → …A800).
enum GoodnotesLayout {
    struct Page: Equatable {
        var notesPath: String
        var size: CGSize?
        /// Archive path of the background PDF, if the page has one.
        var background: String?
        /// Zero-based page of `background`.
        var backgroundPage: Int
    }

    /// The note id Goodnotes stores a page's strokes under: the page UUID with its last byte plus one.
    static func noteID(forPage id: String) -> String? {
        guard id.count == 36, let last = UInt8(id.suffix(2), radix: 16) else { return nil }
        return String(id.dropLast(2)) + String(format: "%02X", last &+ 1)
    }

    private struct Order: Comparable {
        var key: String; var version: UInt64
        static func < (a: Order, b: Order) -> Bool { a.key.utf8.lexicographicallyPrecedes(b.key.utf8) }
    }

    /// Pages in document order. Notes that no page claims are appended in index order, so no ink is ever dropped.
    static func pages(_ files: [String: Data]) throws -> [Page] {
        guard let notesIndex = files["index.notes.pb"] else { throw NotebookError.invalid("Kein unterstütztes Notizarchiv.") }
        var notes: [(id: String, path: String)] = []
        for row in try WireMessage.records(notesIndex) {
            guard let id = row[1]?.string, let path = row[2]?.string else { continue }
            guard files[path] != nil else { throw NotebookError.invalid("Notizdaten fehlen.") }
            notes.append((id, path))
        }

        var attachmentPaths: [String: String] = [:]
        for row in (try? WireMessage.records(files["index.attachments.pb"] ?? Data())) ?? [] {
            if let id = row[1]?.string, let path = row[2]?.string { attachmentPaths[id] = path }
        }
        var aliases: [String: String] = [:]
        var templates: [String: (attachment: String?, pdfPage: Int, size: CGSize?)] = [:]
        var pageTemplate: [String: String] = [:]
        var order: [String: Order] = [:]
        var pageSequence: [String] = []

        func orderValue(_ field: WireField?) -> Order? {
            guard let message = try? field?.message(), let key = message[1]?.string else { return nil }
            let version = (try? message[2]?.message())?[1]?.integer ?? 0
            return Order(key: key, version: version)
        }
        func reference(_ field: WireField?) -> String? { (try? field?.message())?[1]?.string }

        // Events are a log; a damaged or unknown entry is skipped instead of failing the whole notebook.
        for event in (try? WireMessage.records(files["index.events.pb"] ?? Data())) ?? [] {
            if let body = try? event[6]?.message(), let id = body[1]?.string, let file = body[2]?.string { aliases[id] = file }
            if let body = try? event[2]?.message(), let id = body[2]?.string {
                var size: CGSize?
                if let s = try? body[8]?.message(), let w = s[1]?.float, let h = s[2]?.float, w > 0, h > 0, w <= 100_000, h <= 100_000 { size = CGSize(width: w, height: h) }
                let page = Int(body[5]?.integer ?? 1)
                templates[id] = (body[4]?.string, max(0, page - 1), size)
            }
            if let body = try? event[54]?.message(), let id = body[2]?.string {
                if pageTemplate[id] == nil && order[id] == nil { pageSequence.append(id) }
                if let template = reference(body[3]) { pageTemplate[id] = template }
                if let value = orderValue(body[4]), value.version >= (order[id]?.version ?? 0) { order[id] = value }
            }
            if let body = try? event[55]?.message(), let id = body[2]?.string,
               let value = orderValue(body[3]), value.version >= (order[id]?.version ?? 0) { order[id] = value }
        }

        func backgroundPath(_ attachment: String?) -> String? {
            guard let attachment else { return nil }
            let candidates = [attachmentPaths[attachment], aliases[attachment].map { "attachments/" + $0 }, "attachments/" + attachment]
            return candidates.compactMap { $0 }.first { files[$0]?.starts(with: Data("%PDF".utf8)) == true }
        }

        let sequence = pageSequence.enumerated().sorted { a, b in
            switch (order[a.element], order[b.element]) {
            case let (x?, y?) where x.key != y.key: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)

        let notePaths = Dictionary(notes.map { ($0.id.uppercased(), $0.path) }, uniquingKeysWith: { first, _ in first })
        var used = Set<String>()
        var result: [Page] = []
        for pageID in sequence {
            guard let noteID = noteID(forPage: pageID.uppercased()), let path = notePaths[noteID], !used.contains(path) else { continue }
            used.insert(path)
            let template = pageTemplate[pageID].flatMap { templates[$0] }
            result.append(Page(notesPath: path, size: template?.size, background: backgroundPath(template?.attachment), backgroundPage: template?.pdfPage ?? 0))
        }
        // Older archives match notes to templates by id, or have a single template for every page.
        for note in notes where !used.contains(note.path) {
            let template = templates[note.id] ?? (templates.count == 1 ? templates.values.first : nil)
            result.append(Page(notesPath: note.path, size: template?.size, background: backgroundPath(template?.attachment), backgroundPage: template?.pdfPage ?? 0))
        }
        return result
    }
}
