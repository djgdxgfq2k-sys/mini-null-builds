import Foundation
import SwiftUI
import PencilKit
import UIKit

struct NotebookPage: Identifiable, Codable, Hashable {
    var id = UUID().uuidString
    var width: Double = 595
    var height: Double = 842
    var pdf: String?
    var pdfPage = 0
    var sourceNotes: String?
    var bookmarked = false
    var paper = "lined"
    var paperColor: String?
    var rotation: Int?
    var outlineTitle: String?
    var nativeSize: CGSize { CGSize(width: width, height: height) }
    var quarterTurns: Int { ((rotation ?? 0) % 4 + 4) % 4 }
    var size: CGSize { quarterTurns % 2 == 0 ? nativeSize : CGSize(width: height, height: width) }
    func applyRotation(to context: CGContext) {
        switch quarterTurns {
        case 1: context.translateBy(x: height, y: 0); context.rotate(by: .pi / 2)
        case 2: context.translateBy(x: width, y: height); context.rotate(by: .pi)
        case 3: context.translateBy(x: 0, y: width); context.rotate(by: -.pi / 2)
        default: break
        }
    }
}

enum NotebookKind: String, Codable { case notebook, whiteboard }

struct LibraryItem: Identifiable, Codable, Equatable {
    var id = UUID().uuidString
    var parent: String?
    var title: String
    var kind: NotebookKind?
    var folder = false
    var color = "#34C759"
    var symbol: String?
    var trashed: Bool?
    var favorite = false
    var created: Date?
    var modified = Date()
    var pages: [NotebookPage] = []
    var deletedPages: [NotebookPage]?
    var originalName: String?
    var warnings: [String] = []
}

struct ArchiveManifest: Codable {
    var version = 1
    var item: LibraryItem
}

@MainActor final class LibraryStore: ObservableObject {
    @Published private(set) var items: [LibraryItem] = []
    @Published var opened: [String] = []
    @Published var active: String?
    @Published var error: String?
    let root: URL
    private var writable = true
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Notebooks", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            let index = self.root.appendingPathComponent("library.json")
            if FileManager.default.fileExists(atPath: index.path) {
                items = try JSONDecoder().decode([LibraryItem].self, from: Data(contentsOf: index))
            } else { try seed() }
        } catch { writable = false; self.error = "Bibliothek konnte nicht geladen werden: \(error.localizedDescription)" }
    }
    func directory(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    func item(_ id: String?) -> LibraryItem? { items.first { $0.id == id } }
    func save() throws {
        guard writable else { throw NotebookError.invalid("Der gespeicherte Bibliotheksindex ist nicht lesbar und wird nicht überschrieben.") }
        try JSONEncoder().encode(items).write(to: root.appendingPathComponent("library.json"), options: .atomic)
    }
    @discardableResult func add(title: String, parent: String? = nil, folder: Bool = false, color: String = "#34C759") -> LibraryItem? {
        guard writable else { error = "Der gespeicherte Bibliotheksindex muss zuerst wiederhergestellt werden."; return nil }
        var item = LibraryItem(parent: parent, title: title, folder: folder, color: color, pages: folder ? [] : [NotebookPage()])
        item.created = item.modified
        do {
            try FileManager.default.createDirectory(at: directory(item.id), withIntermediateDirectories: true)
            items.append(item); try save(); return item
        } catch { items.removeAll { $0.id == item.id }; self.error = error.localizedDescription; return nil }
    }
    func update(_ item: LibraryItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        let old = items[i]; items[i] = item
        do { try save() } catch { items[i] = old; self.error = error.localizedDescription }
    }
    func move(_ id: String, into parent: String?) {
        guard var it = item(id), id != parent else { return }
        var cursor = parent; var visited = Set<String>()
        while let p = cursor { guard p != id, visited.insert(p).inserted else { return }; cursor = item(p)?.parent }
        it.parent = parent; update(it)
    }
    func open(_ id: String) { guard let it = item(id), !it.folder else { return }; if !opened.contains(id) { opened.append(id) }; active = id }
    func close(_ id: String) { opened.removeAll { $0 == id }; if active == id { active = opened.last } }
    func addPage(_ id: String, paper: String = "lined") {
        guard var it = item(id) else { return }; var page = NotebookPage(); page.paper = paper
        it.pages.append(page); it.modified = Date(); update(it)
    }
    func toggleFavorite(_ id: String) { guard var it = item(id) else { return }; it.favorite.toggle(); update(it) }
    func isTrashed(_ id: String) -> Bool {
        var cursor: String? = id; var seen = Set<String>()
        while let current = cursor, seen.insert(current).inserted, let it = item(current) {
            if it.trashed == true { return true }; cursor = it.parent
        }
        return false
    }
    func trash(_ id: String) {
        guard var it = item(id) else { return }; it.trashed = true; update(it)
        for openedID in opened where isTrashed(openedID) { close(openedID) }
    }
    func restore(_ id: String) {
        guard var it = item(id) else { return }; it.trashed = nil
        if let parent = it.parent, isTrashed(parent) { it.parent = nil }; update(it)
    }
    func seed() throws {
        for (title, color) in zip(Theme.subjects, Theme.folders) {
            var it = LibraryItem(title: title, folder: true, color: color); it.created = it.modified; items.append(it)
        }
        var book = LibraryItem(title: "Mein Notizbuch", color: "#255799", favorite: true, pages: [NotebookPage()]); book.created = book.modified; items.append(book)
        for it in items { try FileManager.default.createDirectory(at: directory(it.id), withIntermediateDirectories: true) }
        try save()
    }
    func acceptImported(_ item: LibraryItem) throws { items.append(item); do { try save() } catch { items.removeAll { $0.id == item.id }; throw error } }
}

enum DrawingDisk {
    static func url(_ directory: URL, _ page: String) -> URL { directory.appendingPathComponent("\(page).drawing") }
    static func load(_ directory: URL, _ page: String) throws -> PKDrawing {
        let url = url(directory, page)
        guard FileManager.default.fileExists(atPath: url.path) else { return PKDrawing() }
        return try PKDrawing(data: Data(contentsOf: url))
    }
    static func save(_ drawing: PKDrawing, directory: URL, page: String) throws {
        try drawing.dataRepresentation().write(to: url(directory, page), options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}

enum Theme {
    static let library = Color.black
    static let sidebar = Color(hex: "#101010")
    static let canvas = Color(hex: "#1B1C1C")
    static let border = Color(hex: "#515356")
    static let secondary = Color(hex: "#98989D")
    static let accent = Color(referenceHex: "#3F8EF7")
    static let activeTool = Color(referenceHex: "#CAD2DE")
    static let top = OriginalAssets.color("Background/DocumentView/colorNavSecondary", fallback: "#23315C")
    static let toolbar = OriginalAssets.color("Background/DocumentView/colorNavPrimary", fallback: "#314B7B")
    static let pill = Color(hex: "#2A2C2C")
    static let popover = Color(hex: "#1B1C1C")
    static let libraryAccent = Color(referenceHex: "#3879BF")
    static let selectedRow = Color(referenceHex: "#343636")
    static let folders = [12, 10, 9, 14, 16, 11, 13, 4].map { ReferenceLayout.folderPalette[$0] }
    static let subjects = ["Bio", "Chemie", "Deutsch", "Englisch", "Geschichte", "Kunst", "Mathe", "Physik"]
    static let inks = ["display-p3:#E04E47", "display-p3:#69A7F8", "display-p3:#6FC35D", "#FEFDFE", "#000001", "display-p3:#EFCB4A"]
    static let libraryDate: DateFormatter = {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "de_DE"); formatter.dateFormat = "dd.MM.yyyy, HH:mm"; return formatter
    }()
}
extension Color {
    init(hex: String) { self.init(uiColor: UIColor(hex: hex)) }
    /// Screenshot samples are Display P3; ordinary persisted hex strings remain sRGB.
    init(referenceHex: String) { self.init(hex: "display-p3:" + referenceHex) }
}
extension UIColor {
    convenience init(hex: String) {
        let prefix = "display-p3:"
        let isDisplayP3 = hex.hasPrefix(prefix)
        let value = isDisplayP3 ? String(hex.dropFirst(prefix.count)) : hex
        let n = UInt64(value.trimmingCharacters(in: CharacterSet.alphanumerics.inverted), radix: 16) ?? 0
        let r = CGFloat((n >> 16) & 255) / 255, g = CGFloat((n >> 8) & 255) / 255, b = CGFloat(n & 255) / 255
        if isDisplayP3 { self.init(displayP3Red: r, green: g, blue: b, alpha: 1) }
        else { self.init(red: r, green: g, blue: b, alpha: 1) }
    }
}
