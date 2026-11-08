import Foundation
import ZIPFoundation
import PDFKit
import PencilKit
import UIKit

enum NotebookArchive {
    static let maxEntry = 128 * 1024 * 1024
    static let maxArchive = 512 * 1024 * 1024
    static func entries(_ url: URL) throws -> [String: Data] {
        let archive = try Archive(url: url, accessMode: .read)
        var result: [String: Data] = [:]; var total = 0
        for entry in archive {
            guard entry.type == .file else { continue }
            let path = entry.path
            guard !path.hasPrefix("/"), !path.contains("\\"), !path.split(separator: "/").contains(".."), !path.contains(":"), result[path] == nil else { throw NotebookError.invalid("Unsicherer oder doppelter ZIP-Pfad.") }
            guard UInt64(entry.uncompressedSize) <= UInt64(maxEntry), total <= maxArchive - Int(entry.uncompressedSize) else { throw NotebookError.invalid("Das Archiv ist zu groß.") }
            var data = Data()
            let checksum = try archive.extract(entry) { part in
                guard data.count <= maxEntry - part.count else { throw NotebookError.invalid("ZIP-Eintrag ist zu groß.") }
                data.append(part)
            }
            guard checksum == entry.checksum, UInt64(data.count) == entry.uncompressedSize else { throw NotebookError.invalid("ZIP-Prüfsumme stimmt nicht überein.") }
            total += data.count; result[path] = data
            guard result.count <= 20000 else { throw NotebookError.invalid("Zu viele ZIP-Einträge.") }
        }
        return result
    }
    static func write(_ entries: [String: Data], to url: URL) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".zip")
        defer { try? FileManager.default.removeItem(at: temp) }
        let archive = try Archive(url: temp, accessMode: .create)
        for name in entries.keys.sorted() {
            guard let data = entries[name] else { continue }
            try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { position, size in
                data.subdata(in: Int(position) ..< Int(position) + size)
            }
        }
        try Data(contentsOf: temp).write(to: url, options: .atomic)
    }
    @MainActor static func importFile(_ url:URL,into store:LibraryStore,parent:String?) throws -> LibraryItem {
        let item = try parseFile(url,root:store.root,parent:parent)
        do { try store.acceptImported(item); return item }
        catch { try? FileManager.default.removeItem(at:store.directory(item.id)); throw error }
    }
    @MainActor static func importAsync(_ url:URL,into store:LibraryStore,parent:String?) async throws -> LibraryItem {
        let root = store.root
        let item = try await Task.detached(priority:.userInitiated) { try parseFile(url,root:root,parent:parent) }.value
        do { try store.acceptImported(item); return item }
        catch { try? FileManager.default.removeItem(at:store.directory(item.id)); throw error }
    }
    private static func parseFile(_ url:URL,root:URL,parent:String?) throws -> LibraryItem {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        var item = LibraryItem(parent: parent, title: url.deletingPathExtension().lastPathComponent)
        item.created = item.modified
        let directory = root.appendingPathComponent(item.id,isDirectory:true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: directory) } }
        if url.pathExtension.lowercased() == "pdf" {
            guard let pdf = PDFDocument(url: url), pdf.pageCount > 0 else { throw NotebookError.invalid("PDF kann nicht gelesen werden.") }
            try Data(contentsOf: url).write(to: directory.appendingPathComponent("background.pdf"), options: .atomic)
            for i in 0 ..< pdf.pageCount {
                guard let p = pdf.page(at: i) else { continue }; let size = p.bounds(for: .cropBox).size
                guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0, size.width <= 100000, size.height <= 100000 else { throw NotebookError.invalid("PDF enthält ungültige Seitengrößen.") }
                item.pages.append(NotebookPage(width: size.width, height: size.height, pdf: "background.pdf", pdfPage: i, paper: "blank"))
            }
        } else {
            let files = try entries(url)
            if let manifest = files["nullmini/manifest.json"] {
                let decoded = try JSONDecoder().decode(ArchiveManifest.self, from: manifest)
                guard decoded.version == 1 else { throw NotebookError.invalid("Neuere NullMini-Version benötigt.") }
                let newID = item.id; item = decoded.item; item.id = newID; item.parent = parent
                guard !item.pages.isEmpty, Set(item.pages.map(\.id)).count == item.pages.count else { throw NotebookError.invalid("Leere oder doppelte Seitenmetadaten.") }
                // Paths in our manifest are validated separately from ZIP member paths.
                let allPages = item.pages + (item.deletedPages ?? [])
                guard Set(allPages.map(\.id)).count == allPages.count else { throw NotebookError.invalid("Doppelte Seitenmetadaten.") }
                for p in allPages {
                    guard UUID(uuidString: p.id) != nil, p.width.isFinite, p.height.isFinite, p.width > 0, p.height > 0, p.width <= 100000, p.height <= 100000 else { throw NotebookError.invalid("Ungültige Seitenmetadaten.") }
                    if let name = p.pdf { guard name == URL(fileURLWithPath: name).lastPathComponent else { throw NotebookError.invalid("Ungültiger PDF-Pfad.") } }
                    guard (0...3).contains(p.rotation ?? 0) else { throw NotebookError.invalid("Ungültige Seitendrehung.") }
                }
                for (name,data) in files where name.hasPrefix("nullmini/files/") {
                    let leaf = String(name.dropFirst("nullmini/files/".count))
                    guard !leaf.contains("/"), !leaf.isEmpty else { throw NotebookError.invalid("Ungültiger Dateipfad.") }
                    try data.write(to: directory.appendingPathComponent(leaf), options: .atomic)
                }
            } else {
                guard let schemaData = files["schema.pb"], let notesIndex = files["index.notes.pb"] else { throw NotebookError.invalid("Kein unterstütztes Notizarchiv.") }
                let schema = try WireMessage(schemaData)[1]?.integer ?? 0
                guard schema > 0 else { throw NotebookError.invalid("Archiv-Schema fehlt.") }
                item.warnings.append("Originalarchiv bleibt unverändert. Die Vektordarstellung und Seitenzuordnung dieses Schemas sind noch nicht vollständig validiert.")
                let records = try WireMessage.records(notesIndex)
                let events = try WireMessage.records(files["index.events.pb"] ?? Data())
                var templates: [(String, String?, CGSize)] = []
                for event in events {
                    guard let e = try event[2]?.message(), let id = e[2]?.string, let sz = try e[8]?.message(), let w = sz[1]?.float, let h = sz[2]?.float, w > 0, h > 0, w <= 100000, h <= 100000 else { continue }
                    templates.append((id, e[4]?.string, CGSize(width: w, height: h)))
                }
                for row in records {
                    guard let key = row[1]?.string, let path = row[2]?.string, let data = files[path] else { throw NotebookError.invalid("Notizdaten fehlen.") }
                    let exact = templates.first { $0.0 == key }
                    let template = exact ?? (templates.count == 1 ? templates.first : nil)
                    var page = NotebookPage(sourceNotes: path, paper: "blank")
                    if let size = template?.2 { page.width = size.width; page.height = size.height }
                    if let attachment = template?.1, let pdfData = files["attachments/" + attachment], pdfData.starts(with: Data("%PDF".utf8)) {
                        let name = page.id + ".pdf"; try pdfData.write(to: directory.appendingPathComponent(name), options: .atomic); page.pdf = name
                    }
                    let ink = try OriginalInk.read(data)
                    if ink.unsupported > 0 { item.warnings.append("\(ink.unsupported) Spezialstriche auf Seite \(item.pages.count + 1) werden als Originaldaten aufbewahrt; Darstellung noch unbestätigt.") }
                    item.pages.append(page)
                }
                guard !item.pages.isEmpty else { throw NotebookError.invalid("Keine lesbaren Seiten gefunden.") }
                item.originalName = url.lastPathComponent
                try Data(contentsOf: url).write(to: directory.appendingPathComponent("original.goodnotes"), options: .atomic)
            }
        }
        committed = true; return item
    }
    static func originalInk(page: NotebookPage, directory: URL) throws -> OriginalInk {
        guard let path = page.sourceNotes else { return OriginalInk() }
        let files = try entries(directory.appendingPathComponent("original.goodnotes"))
        guard let data = files[path] else { throw NotebookError.invalid("Originale Striche fehlen.") }
        return try OriginalInk.read(data)
    }
    static func exportNative(item: LibraryItem, directory: URL, to url: URL) throws {
        var files = ["nullmini/manifest.json": try JSONEncoder().encode(ArchiveManifest(item: item))]
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.lastPathComponent != "library.json" {
            files["nullmini/files/" + file.lastPathComponent] = try Data(contentsOf: file)
        }
        try write(files, to: url)
    }
    static func exportOriginal(directory: URL, to url: URL) throws {
        // Exact byte-for-byte round trip, including ZIP metadata and unrecognized fields.
        try Data(contentsOf: directory.appendingPathComponent("original.goodnotes")).write(to: url, options: .atomic)
    }
    @MainActor static func exportPDF(item: LibraryItem, directory: URL, to url: URL) throws {
        guard let first = item.pages.first else { throw NotebookError.invalid("Keine Seiten vorhanden.") }
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: first.size))
        var inks: [String: OriginalInk] = [:]; var drawings: [String: PKDrawing] = [:]; var texts:[String:[TextBox]] = [:]
        for page in item.pages {
            let ink = try originalInk(page: page, directory: directory)
            guard ink.unsupported == 0 else { throw NotebookError.invalid("Diese Seite enthält noch nicht unterstützte Spezialstriche. Teile das unveränderte Original oder das vollständige NullMini-Notizbuch, damit keine Inhalte verloren gehen.") }
            inks[page.id] = ink; drawings[page.id] = try DrawingDisk.load(directory, page.id)
            let textURL = directory.appendingPathComponent(page.id + ".texts.json")
            if FileManager.default.fileExists(atPath:textURL.path) { texts[page.id] = try JSONDecoder().decode([TextBox].self,from:Data(contentsOf:textURL)) }
        }
        try renderer.writePDF(to: url) { context in
            for page in item.pages {
                let bounds = CGRect(origin: .zero, size: page.nativeSize)
                context.beginPage(withBounds: CGRect(origin: .zero, size: page.size), pageInfo: [:])
                let c = context.cgContext; c.saveGState(); page.applyRotation(to: c)
                UIColor(hex: page.paperColor ?? "#FFFFFF").setFill(); c.fill(bounds)
                if let name = page.pdf, let pdf = PDFDocument(url: directory.appendingPathComponent(name)), let p = pdf.page(at: page.pdfPage) {
                    c.saveGState(); c.translateBy(x: 0, y: bounds.height); c.scaleBy(x: 1, y: -1)
                    let originalBounds = p.bounds(for: .cropBox)
                    if originalBounds.width > 0, originalBounds.height > 0 {
                        c.scaleBy(x: bounds.width / originalBounds.width, y: bounds.height / originalBounds.height)
                        c.translateBy(x: -originalBounds.minX, y: -originalBounds.minY); p.draw(with: .cropBox, to: c)
                    }
                    c.restoreGState()
                } else { PaperView.paint(c, bounds: bounds, paper: page.paper) }
                for s in inks[page.id]?.strokes ?? [] {
                    c.saveGState(); c.setFillColor(s.color.cgColor); c.setStrokeColor(s.color.cgColor); c.setLineWidth(s.width); c.setLineCap(.round); c.setLineJoin(.round); c.addPath(s.path)
                    if s.filled { c.fillPath() } else { c.strokePath() }; c.restoreGState()
                }
                // PencilKit public image API; source drawing stays vector data in .nullmini.
                let imageScale = min(3,4096/max(bounds.width,bounds.height))
                drawings[page.id]?.paperImage(from: bounds, scale: imageScale).draw(in: bounds)
                for box in texts[page.id] ?? [] { (box.text as NSString).draw(in:CGRect(x:box.x+5,y:box.y+8,width:max(1,box.width-10),height:box.height),withAttributes:[.font:UIFont.systemFont(ofSize:20),.foregroundColor:UIColor(hex:"#1E1B1B")]) }
                c.restoreGState()
            }
        }
    }
}
