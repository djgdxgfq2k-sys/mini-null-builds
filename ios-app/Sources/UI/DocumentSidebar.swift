import SwiftUI
import PDFKit

@MainActor struct DocumentSidebar: View {
    let item: LibraryItem
    let directory: URL
    let mode: EditorPanel
    @Binding var pageIndex: Int
    let close: () -> Void
    let addPage: () -> Void
    let flush: () -> Void
    var pageAction: (PageMenuAction, Int) -> Void = { _, _ in }
    var restorePage: () -> Void = {}
    var showRecordings: () -> Void = {}
    @State private var query = ""
    @State private var results: [(Int, String)] = []
    @State private var bookmarksOnly = false
    @State private var selectedTab = 0
    @State private var searchScope = 0
    @State private var contextPage: String?
    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Text(mode == .search ? "Suchen" : "Seiten").font(.system(size: 15, weight: .semibold))
                HStack {
                    Menu {
                        Toggle("Nur Lesezeichen", isOn: $bookmarksOnly)
                        Button("Zuletzt entfernte Seite wiederherstellen", action: restorePage).disabled(item.deletedPages?.isEmpty != false)
                    } label: { Image(systemName: "ellipsis").frame(width: 50, height: 44) }
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark").font(.system(size: 19, weight: .light)).frame(width: 44, height: 44) }.accessibilityLabel("Seitenleiste schließen")
                }
            }.frame(height: 44).padding(.top, 10)
            if mode == .search {
                HStack { Image(systemName: "magnifyingglass"); TextField("Suchen", text: $query).textFieldStyle(.plain).onSubmit { search() } }.font(.system(size: 13)).padding(8).background(Theme.pill, in: Capsule())
                Picker("Suchen in", selection: $searchScope) { Text("Notizen").tag(0); Text("Gliederungen").tag(1) }.pickerStyle(.segmented).onChange(of: searchScope) { _, _ in search() }
                if query.isEmpty {
                    Spacer()
                    OriginalIcon(name: "files/file-search-02", catalog: OriginalAssets.icons, size: 108).foregroundStyle(Color(hex: "#A3B7DF"))
                    Text("Finde alles, was du brauchst").font(.system(size: 14, weight: .semibold)).padding(.top, 16)
                    Text("Suche nach PDF-Text und Dokument-Inhalten.").font(.system(size: 12)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center).frame(width: 230)
                    Spacer(); Spacer()
                } else {
                    ScrollView { VStack(alignment: .leading, spacing: 12) { ForEach(Array(results.enumerated()), id: \.offset) { _, result in Button { flush(); pageIndex = result.0 } label: { VStack(alignment: .leading, spacing: 5) { Text("Seite \(result.0 + 1)").font(.caption); Text(result.1).font(.system(size: 13)).lineLimit(4) }.padding(12).background(Theme.pill, in: RoundedRectangle(cornerRadius: 10)) } } } }
                    if results.isEmpty { Text("Keine Ergebnisse").foregroundStyle(Theme.secondary); Spacer() }
                }
            } else {
                HStack(spacing: 0) {
                    Button { selectedTab = 0 } label: { OriginalIcon(name: "segmentedControl/file-04", catalog: OriginalAssets.icons, size: 20).frame(maxWidth: .infinity).frame(height: 32).background(selectedTab == 0 ? Color(hex: "#656569") : .clear, in: Capsule()) }.accessibilityLabel("Seiten")
                    Button { selectedTab = 1 } label: { OriginalIcon(name: "segmentedControl/document-outline", catalog: OriginalAssets.icons, size: 20).frame(maxWidth: .infinity).frame(height: 32).background(selectedTab == 1 ? Color(hex: "#656569") : .clear, in: Capsule()) }.accessibilityLabel("Gliederung")
                    Button(action: showRecordings) { OriginalIcon(name: "segmentedControl/Transcripts", catalog: OriginalAssets.icons, size: 20).frame(maxWidth: .infinity).frame(height: 32) }.accessibilityLabel("Aufnahmen")
                }.background(Color(hex: "#393B3E"), in: Capsule())
                HStack { Menu { Button("Alle Seiten") { bookmarksOnly = false }; Button("Lesezeichen") { bookmarksOnly = true } } label: { HStack { Text(bookmarksOnly ? "Lesezeichen" : "Alle Seiten"); Image(systemName: "chevron.down").font(.system(size: 10)) }.font(.system(size: 15)).padding(.horizontal, 10).padding(.vertical, 5).background(Color(referenceHex: "#354554"), in: Capsule()) }.foregroundStyle(Color(referenceHex: "#6DB6F9")); Spacer() }
                if selectedTab == 1 {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(item.pages.enumerated()), id: \.element.id) { index, page in
                                if let title = page.outlineTitle {
                                    Button { flush(); pageIndex = index } label: { HStack { Text(title); Spacer(); Text("\(index + 1)").foregroundStyle(Theme.secondary) }.font(.system(size: 15)).padding(.vertical, 14) }
                                    Divider().overlay(Theme.border)
                                }
                            }
                            if !item.pages.contains(where: { $0.outlineTitle != nil }) { Text("Keine Gliederung").foregroundStyle(Theme.secondary).padding(.top, 40) }
                        }
                    }
                } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 23, alignment: .top), GridItem(.flexible(), alignment: .top)], spacing: 64) {
                        ForEach(Array(item.pages.enumerated()), id: \.element.id) { index, page in
                            if !(bookmarksOnly || mode == .bookmarks) || page.bookmarked {
                                VStack(alignment: .leading, spacing: 10) {
                                    Button { flush(); pageIndex = index } label: {
                                        pageThumbnail(page, active: index == pageIndex)
                                    }.accessibilityLabel("Seite \(index + 1)")
                                    HStack { Text("\(index + 1)"); Spacer(); Button { flush(); contextPage = page.id } label: { Image(systemName: "chevron.down").frame(width: 20, height: 14) }.accessibilityLabel("Optionen für Seite \(index + 1)")
                                        .popover(isPresented: Binding(get: { contextPage == page.id }, set: { if !$0 { contextPage = nil } }), arrowEdge: .leading) { PageContextPopover { action in contextPage = nil; pageAction(action, index) } }
                                    }.font(.system(size: 11)).frame(width: min(135, 175 * page.size.width / page.size.height)).frame(width: 135)
                                }.frame(width: 135)
                            }
                        }
                        Button(action: addPage) { RoundedRectangle(cornerRadius: 4).stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [4, 4])).frame(width: 130, height: 175).overlay { Image(systemName: "plus").font(.system(size: 25, weight: .light)).foregroundStyle(Theme.accent) } }.accessibilityLabel("Seite hinzufügen")
                    }.padding(.top, 14).padding(.bottom, 30)
                }.scrollIndicators(.hidden)
                }
            }
        }.padding(.horizontal, 17).foregroundStyle(.white).frame(maxHeight: .infinity).background(mode == .search ? Color(hex: "#140E0E") : Theme.pill)
            .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 0.5) }
    }
    private func pageThumbnail(_ page: NotebookPage, active: Bool) -> some View {
        let scale = min(135 / page.size.width, 175 / page.size.height)
        return NotebookPreview(page: page, directory: directory).frame(width: page.size.width * scale, height: page.size.height * scale)
            .overlay(alignment: .topTrailing) { OriginalIcon(name: page.bookmarked ? "thumbnails/bookmark-active" : "thumbnails/bookmark", size: 19).foregroundStyle(page.bookmarked ? Theme.accent : .gray) }
            .overlay { Rectangle().stroke(active ? Theme.accent : .clear, lineWidth: 2) }.frame(width: 135, height: 175, alignment: .bottom)
    }
    private func search() {
        results = []
        guard !query.isEmpty else { return }
        for (index, page) in item.pages.enumerated() {
            if searchScope == 1 { if let title = page.outlineTitle, title.localizedCaseInsensitiveContains(query) { results.append((index, title)) }; continue }
            if let name = page.pdf, let document = PDFDocument(url: directory.appendingPathComponent(name)), let text = document.page(at: page.pdfPage)?.string, text.localizedCaseInsensitiveContains(query) { results.append((index, text)) }
        }
    }
}
