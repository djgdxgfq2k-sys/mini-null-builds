import Foundation
import ZIPFoundation

/// Imports a whole Goodnotes library: a backup ZIP (folders of .goodnotes/.pdf files) or a folder
/// picked in Files. The folder tree is recreated and every notebook is imported one at a time, so a
/// multi-gigabyte backup never has to fit in memory.
enum LibraryImport {
    struct Summary: Equatable {
        var imported = 0
        var folders = 0
        var failed: [String] = []
    }
    struct Source { let path: [String]; let name: String; let load: () throws -> URL }
    struct FolderStyle: Equatable { var color: String; var symbol: String? }

    /// Goodnotes stores folder colours and symbols in `.goodnotesmeta` at the backup root:
    /// `{"items":[{"path":"Schule/Bio","color":"green","symbol":"none"}]}`. Colours are names or hex.
    static func folderStyles(_ data: Data) -> [String: FolderStyle] {
        struct Meta: Decodable { struct Item: Decodable { let path: String; let color: String?; let symbol: String? }; let items: [Item] }
        guard let meta = try? JSONDecoder().decode(Meta.self, from: data) else { return [:] }
        let palette = ReferenceLayout.folderPalette
        let named: [String: String] = [
            "black": palette[8], "gray": palette[16], "grey": palette[16], "white": palette[17],
            "red": palette[9], "orange": palette[10], "yellow": palette[11], "green": palette[12],
            "blue": palette[13], "purple": palette[14], "pink": palette[15], "brown": palette[1],
        ]
        let symbols: Set<String> = ["atom", "apple", "banknote", "beaker", "book", "briefcase", "building", "calculator", "codesnippet", "compass", "file", "globe", "graduation", "moonstar", "musicnote", "palette", "scales", "settings", "smile"]
        var result: [String: FolderStyle] = [:]
        for item in meta.items {
            guard let parts = components(item.path) else { continue }
            let raw = (item.color ?? "").trimmingCharacters(in: .whitespaces)
            let color: String
            if let mapped = named[raw.lowercased()] { color = mapped }
            else if raw.hasPrefix("#"), raw.count == 7, UInt32(raw.dropFirst(), radix: 16) != nil { color = raw.uppercased() }
            else { continue }
            let symbol = item.symbol.flatMap { symbols.contains($0) ? "folder-symbols/folder_icon_" + $0 : nil }
            result[parts.joined(separator: "/")] = FolderStyle(color: color, symbol: symbol)
        }
        return result
    }
    static func metaData(_ url: URL) -> Data? {
        if isFolder(url) { return try? Data(contentsOf: url.appendingPathComponent(".goodnotesmeta")) }
        guard let archive = try? Archive(url: url, accessMode: .read),
              let entry = archive.first(where: { $0.type == .file && $0.path == ".goodnotesmeta" }), entry.uncompressedSize < 4_000_000 else { return nil }
        var data = Data()
        _ = try? archive.extract(entry) { data.append($0) }
        return data
    }

    static let notebookExtensions: Set<String> = ["goodnotes", "pdf"]

    /// A backup holds notebooks inside it; a single exported notebook is itself the archive.
    static func isLibraryBackup(_ url: URL) -> Bool {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let archive = try? Archive(url: url, accessMode: .read) else { return false }
        var notebooks = 0
        for entry in archive where entry.type == .file {
            if entry.path == "schema.pb" || entry.path == "index.notes.pb" || entry.path == "nullmini/manifest.json" { return false }
            if notebookExtensions.contains(URL(fileURLWithPath: entry.path).pathExtension.lowercased()) { notebooks += 1 }
        }
        return notebooks > 0
    }

    static func isFolder(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }

    /// Safe folder components of a library path; nil when the path tries to leave the library.
    static func components(_ path: String) -> [String]? {
        let parts = path.split(separator: "/").map(String.init)
        guard !path.hasPrefix("/"), !path.contains("\\"), !parts.contains(".."), !parts.contains("."), !parts.isEmpty else { return nil }
        return parts
    }

    @MainActor static func importLibrary(_ url: URL, into store: LibraryStore, parent: String?, progress: @escaping (Int, Int, String) -> Void) async -> Summary {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        var summary = Summary()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("library-import-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let sources: [Source]
        do { sources = try await Task.detached(priority: .userInitiated) { try listSources(url, scratch: scratch) }.value }
        catch { summary.failed.append("\(url.lastPathComponent): \(error.localizedDescription)"); return summary }
        guard !sources.isEmpty else { summary.failed.append("\(url.lastPathComponent): keine Notizbücher gefunden"); return summary }
        let styles = await Task.detached(priority: .userInitiated) { metaData(url).map(folderStyles) ?? [:] }.value

        var folderIDs: [[String]: String] = [:]
        func folder(for path: [String]) -> String? {
            guard !path.isEmpty else { return parent }
            if let id = folderIDs[path] { return id }
            let above = folder(for: Array(path.dropLast()))
            let title = path[path.count - 1]
            // Importing the same backup twice reuses the folders that already exist.
            let style = styles[path.joined(separator: "/")]
            if var existing = store.items.first(where: { $0.folder && $0.trashed != true && $0.parent == above && $0.title == title }) {
                if let style, existing.color != style.color || existing.symbol != style.symbol { existing.color = style.color; existing.symbol = style.symbol; store.update(existing) }
                folderIDs[path] = existing.id; return existing.id
            }
            // Goodnotes folders without a stored colour are blue.
            guard var created = store.add(title: title, parent: above, folder: true, color: style?.color ?? ReferenceLayout.folderPalette[13]) else { return above }
            if let symbol = style?.symbol { created.symbol = symbol; store.update(created) }
            summary.folders += 1; folderIDs[path] = created.id; return created.id
        }

        for (index, source) in sources.enumerated() {
            progress(index, sources.count, source.name)
            let target = folder(for: source.path)
            do {
                let file = try await Task.detached(priority: .userInitiated) { try source.load() }.value
                _ = try await NotebookArchive.importAsync(file, into: store, parent: target)
                if file.path.hasPrefix(scratch.path) { try? FileManager.default.removeItem(at: file) }
                summary.imported += 1
            } catch {
                summary.failed.append("\((source.path + [source.name]).joined(separator: "/")): \(error.localizedDescription)")
            }
        }
        progress(sources.count, sources.count, "")
        return summary
    }

    /// Notebook files in library order, each extracted lazily so only one is on disk at a time.
    static func listSources(_ url: URL, scratch: URL) throws -> [Source] {
        if isFolder(url) {
            let root = url.standardizedFileURL.resolvingSymlinksInPath()
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
            var result: [Source] = []
            for case let file as URL in walker where notebookExtensions.contains(file.pathExtension.lowercased()) {
                let resolved = file.standardizedFileURL.resolvingSymlinksInPath()
                guard resolved.path.hasPrefix(root.path + "/") else { continue }
                let relative = String(resolved.path.dropFirst(root.path.count + 1))
                guard let parts = components(relative) else { continue }
                result.append(Source(path: Array(parts.dropLast()), name: parts[parts.count - 1], load: { resolved }))
            }
            return result.sorted { ($0.path + [$0.name]).joined(separator: "/").localizedStandardCompare(($1.path + [$1.name]).joined(separator: "/")) == .orderedAscending }
        }
        let archive = try Archive(url: url, accessMode: .read)
        var result: [Source] = []
        for entry in archive where entry.type == .file {
            guard notebookExtensions.contains(URL(fileURLWithPath: entry.path).pathExtension.lowercased()),
                  let parts = components(entry.path), !parts.contains(where: { $0.hasPrefix("__MACOSX") }) else { continue }
            let path = entry.path, name = parts[parts.count - 1]
            result.append(Source(path: Array(parts.dropLast()), name: name, load: {
                // Each notebook gets its own directory so its file name (the notebook title) is kept.
                let directory = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appendingPathComponent(name)
                let reader = try Archive(url: url, accessMode: .read)
                guard let member = reader[path] else { throw NotebookError.invalid("Eintrag fehlt im Backup.") }
                guard UInt64(member.uncompressedSize) <= UInt64(NotebookArchive.maxArchive) else { throw NotebookError.invalid("Notizbuch ist zu groß.") }
                _ = try reader.extract(member, to: file)
                return file
            }))
        }
        return result
    }
}
