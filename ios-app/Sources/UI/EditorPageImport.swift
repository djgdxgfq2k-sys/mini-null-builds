import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

enum PageMediaKind: Equatable { case templates, pdf, photos, scan, camera }
struct PageMediaRequest: Identifiable, Equatable {
    let id = UUID()
    let kind: PageMediaKind
    let anchorID: String
    let position: Int
}

@MainActor struct EditorPageImport: ViewModifier {
    @EnvironmentObject private var store: LibraryStore
    let bookID: String
    let commands: CanvasCommands
    @Binding var pageIndex: Int
    @Binding var request: PageMediaRequest?
    @State private var activeRequest: PageMediaRequest?
    @State private var photo: PhotosPickerItem?
    @State private var busy = false
    func body(content: Content) -> some View {
        content
            .onChange(of: request, initial: true) { _, target in if let target { activeRequest = target; if target.kind == .photos { photo = nil } } }
            .fileImporter(isPresented: presented(.pdf), allowedContentTypes: [.pdf]) { result in
                guard let target = activeRequest else { return }; request = nil
                switch result { case .success(let url): insert(url, target: target); case .failure(let error): if (error as NSError).code != NSUserCancelledError { store.error = error.localizedDescription } }
            }
            .photosPicker(isPresented: presented(.photos), selection: $photo, matching: .images)
            .onChange(of: photo) { _, selected in
                guard let selected, let target = activeRequest else { return }; busy = true
                Task {
                    do {
                        guard let data = try await selected.loadTransferable(type: Data.self), let image = UIImage(data: data) else { throw NotebookError.invalid("Das Bild konnte nicht geladen werden.") }
                        insert([image], target: target)
                    } catch { busy = false; request = nil; store.error = error.localizedDescription }
                }
            }
            .fullScreenCover(isPresented: presented(.scan)) {
                DocumentScanner { result in
                    guard let target = activeRequest else { return }; request = nil
                    switch result { case .success(let images): insert(images, target: target); case .failure(let error): store.error = error.localizedDescription }
                }.ignoresSafeArea()
            }
            .fullScreenCover(isPresented: presented(.camera)) { DocumentCamera { images in guard let target = activeRequest else { return }; request = nil; insert(images, target: target) }.ignoresSafeArea() }
            .sheet(isPresented: presented(.templates)) {
                PageTemplateChooser { paper, color in
                    guard let target = activeRequest else { return }; request = nil
                    commands.afterInput {
                        do { pageIndex = try PageEditing.insert(relativeTo: target.anchorID, after: target.position != 0, bookID: bookID, store: store, paper: paper, paperColor: color, atEnd: target.position == 2) }
                        catch { store.error = error.localizedDescription }
                    }
                }
            }
            .overlay {
                if busy { ZStack { Color.black.opacity(0.2).ignoresSafeArea(); ProgressView("Seiten werden hinzugefügt …").padding(24).background(Theme.pill, in: RoundedRectangle(cornerRadius: 18)) } }
            }
    }
    private func presented(_ kind: PageMediaKind) -> Binding<Bool> { Binding(get: { request?.kind == kind }, set: { if !$0 { request = nil } }) }
    private func insert(_ images: [UIImage], target: PageMediaRequest) {
        guard !images.isEmpty else { busy = false; return }
        do { let url = try DocumentMediaPDF.write(images); insert(url, target: target, temporary: true) }
        catch { busy = false; store.error = error.localizedDescription }
    }
    private func insert(_ url: URL, target: PageMediaRequest, temporary: Bool = false) {
        busy = true
        commands.afterInput(onFailure: { busy = false; request = nil; if temporary { try? FileManager.default.removeItem(at: url) } }) {
            defer { busy = false; request = nil; if temporary { try? FileManager.default.removeItem(at: url) } }
            do { pageIndex = try PageEditing.insertPDF(url, relativeTo: target.anchorID, position: target.position, bookID: bookID, store: store) }
            catch { store.error = error.localizedDescription }
        }
    }
}

private struct PageTemplateChooser: View {
    @Environment(\.dismiss) private var dismiss
    let insert: (String, String) -> Void
    @State private var color = "#FFFFFF"
    private let papers = [("blank", "Leer"), ("dotted", "Gepunktet"), ("grid", "Kariert"), ("lined", "Liniert schmal"), ("wide", "Liniert breit")]
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Picker("Papierfarbe", selection: $color) { Text("Weiß").tag("#FFFFFF"); Text("Gelb").tag("#F7F6E9"); Text("Dunkel").tag("#3F3B3B") }.pickerStyle(.segmented)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 24) {
                        ForEach(papers, id: \.0) { paper, title in Button { insert(paper, color); dismiss() } label: { VStack(spacing: 12) { PaperTemplatePreview(paper: paper, color: color).frame(width: 95, height: 135); Text(title).font(.system(size: 13)) } } }
                    }
                }.padding(24)
            }.goodnotesSheet().navigationTitle("Vorlagen").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
        }.presentationDetents([.medium, .large])
    }
}
