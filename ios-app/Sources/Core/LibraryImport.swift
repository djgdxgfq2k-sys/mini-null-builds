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

        var folderIDs: [[String]: String] = [:]
        func folder(for path: [String]) -> String? {
            guard !path.isEmpty else { return parent }
            if let id = folderIDs[path] { return id }
            let above = folder(for: Array(path.dropLast()))
            let title = path[path.count - 1]
            // Importing the same backup twice reuses the folders that already exist.
            if let existing = store.items.first(where: { $0.folder && $0.trashed != true && $0.parent == above && $0.title == title }) {
                folderIDs[path] = existing.id; return existing.id
            }
            guard let created = store.add(title: title, parent: above, folder: true) else { return above }
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
