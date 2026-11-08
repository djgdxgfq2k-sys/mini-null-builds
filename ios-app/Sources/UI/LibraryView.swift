import SwiftUI
import UniformTypeIdentifiers
import PhotosUI

@MainActor struct LibraryView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var folder: String?
    @State private var sidebarShown = true
    @State private var newPopover = false
    @State private var notebookCreation = false
    @State private var whiteboardCreation = false
    @State private var notifications = false
    @State private var librarySection: String?
    @State private var scanning = false
    @State private var takingPhoto = false
    @State private var choosingImage = false
    @State private var photoItem: PhotosPickerItem?
    @State private var favorites = false
    @State private var trash = false
    @State private var query = ""
    @State private var searchShown = false
    @State private var importing = false
    @State private var importBusy = false
    @State private var creatingFolder = false
    @State private var title = ""
    @State private var color = Theme.folders[0]
    @State private var sort = LibrarySort.title
    @State private var ascending = true
    @State private var filter = "Alle"
    @State private var listLayout = false
    @State private var activeMenu: LibraryMenuKind?
    @State private var selecting = false
    @State private var selectedIDs = Set<String>()
    @State private var contextID: String?
    @State private var editItem: LibraryItem?
    @State private var editing: LibraryEdit?
    @State private var renaming = false
    init(showFolderCreation: Bool = false, sidebarShown: Bool = true, menu: LibraryMenuKind? = nil, folderID: String? = nil) {
        _creatingFolder = State(initialValue: showFolderCreation)
        _sidebarShown = State(initialValue: sidebarShown)
        _activeMenu = State(initialValue: menu)
        _folder = State(initialValue: folderID)
    }
    private var visible: [LibraryItem] {
        sort.ordered(store.items.filter { item in
            if librarySection != nil { return false }
            let location = trash ? item.trashed == true : (!store.isTrashed(item.id) && (favorites ? item.favorite : (query.isEmpty ? item.parent == folder : true)))
            return location && (query.isEmpty || item.title.localizedCaseInsensitiveContains(query)) && (filter == "Alle" || (filter == "Ordner" ? item.folder : !item.folder))
        }, ascending: ascending)
    }
    private var breadcrumbs: [LibraryItem] {
        var result: [LibraryItem] = []; var cursor = folder; var seen = Set<String>()
        while let id = cursor, let item = store.item(id), seen.insert(id).inserted { result.insert(item, at: 0); cursor = item.parent }
        return result
    }
    private var heading: String { if let librarySection { return librarySection }; return trash ? "Papierkorb" : (favorites ? "Favoriten" : (store.item(folder)?.title ?? "Dokumente")) }
    var body: some View {
        ZStack {
            libraryContent.blur(radius: creatingFolder ? 30 : 0).allowsHitTesting(!creatingFolder).accessibilityHidden(creatingFolder)
            if creatingFolder {
                FolderCreationView(onDismiss: { creatingFolder = false }) { name, color, symbol in
                    if var item = store.add(title: name, parent: folder, folder: true, color: color) { item.symbol = symbol; store.update(item) }
                }
            }
        }
        .overlayPreferenceValue(LibraryMenuAnchorKey.self) { anchors in menuOverlay(anchors) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .zip, UTType(importedAs: "com.goodnotesapp.goodnotes.v5"), UTType(exportedAs: "studio.nullmini.notebook")]) { result in
            Task {
                importBusy = true; defer { importBusy = false }
                do { let url = try result.get(); let item = try await NotebookArchive.importAsync(url, into: store, parent: folder); store.open(item.id) }
                catch { store.error = error.localizedDescription }
            }
        }
        .overlay { if importBusy { ProgressView("Notizbuch importieren …").padding(24).background(Theme.pill, in: RoundedRectangle(cornerRadius: 16)).overlay { RoundedRectangle(cornerRadius: 16).stroke(Theme.border) } } }
        .sheet(isPresented: $notebookCreation) {
            NotebookCreationView { name, paper, paperColor, size in
                if var item = store.add(title: name, parent: folder, color: "#FFFFFF") { item.pages[0].paper = paper; item.pages[0].paperColor = paperColor; item.pages[0].width = Double(size.width); item.pages[0].height = Double(size.height); store.update(item); store.open(item.id) }
            }
        }
        .sheet(isPresented: $whiteboardCreation) {
            WhiteboardCreationView { name, paper, color, template in
                if let template {
                    Task {
                        do { try await WhiteboardTemplate.create(template, dark: color == "#1B1C1C", title: name, store: store, parent: folder) }
                        catch { store.error = error.localizedDescription }
                    }
                } else if var item = store.add(title: name, parent: folder, color: color) {
                    item.kind = .whiteboard; item.pages[0].width = 1122; item.pages[0].height = 842
                    item.pages[0].paper = paper; item.pages[0].paperColor = color
                    store.update(item); store.open(item.id)
                }
            }
        }
        .photosPicker(isPresented: $choosingImage, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, value in
            guard let value else { return }
            Task {
                do {
                    guard let data = try await value.loadTransferable(type: Data.self), let image = UIImage(data: data) else { throw NotebookError.invalid("Das Bild konnte nicht geladen werden.") }
                    await importImages([image], title: "Bild")
                } catch { store.error = error.localizedDescription }
            }
        }
        .fullScreenCover(isPresented: $scanning) {
            DocumentScanner { result in
                scanning = false
                switch result { case .success(let images): Task { await importImages(images, title: "Dokumentenscan") }; case .failure(let error): store.error = error.localizedDescription }
            }.ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $takingPhoto) { DocumentCamera { images in takingPhoto = false; Task { await importImages(images, title: "Foto") } }.ignoresSafeArea() }
        .sheet(item: $editing) { action in editSheet(action) }
        .alert("Umbenennen", isPresented: $renaming) {
            TextField("Name", text: $title); Button("Abbrechen", role: .cancel) {}
            Button("Sichern") { if var item = editItem, !title.trimmingCharacters(in: .whitespaces).isEmpty { item.title = title.trimmingCharacters(in: .whitespaces); store.update(item) } }
        }
    }
    private func menuOverlay(_ anchors: [LibraryMenuKind: Anchor<CGRect>]) -> some View {
        GeometryReader { geometry in
            if let activeMenu, let anchor = anchors[activeMenu], !creatingFolder {
                let bounds = geometry[anchor]
                let height: CGFloat = activeMenu == .filter ? 118 : 288
                let left = activeMenu == .filter ? bounds.minX : bounds.maxX + 7.5 - 224
                let x = min(max(16, left), max(16, geometry.size.width - 240))
                let y = min(max(0, bounds.minY - 6), max(0, geometry.size.height - height - 16))
                Color.clear.contentShape(Rectangle()).onTapGesture { self.activeMenu = nil }
                Group {
                    if activeMenu == .filter {
                        LibraryFilterMenu(selected: filter) { filter = $0; self.activeMenu = nil }
                    } else {
                        LibraryLayoutMenu(listLayout: listLayout, sort: sort, ascending: ascending, selectObjects: { selecting = true; selectedIDs.removeAll(); self.activeMenu = nil }, setLayout: { listLayout = $0; self.activeMenu = nil }, setSort: { criterion in
                            if sort == criterion { ascending.toggle() } else { sort = criterion; ascending = criterion == .title || criterion == .kind }
                            self.activeMenu = nil
                        })
                    }
                }.position(x: x + 112, y: y + height / 2)
            }
        }
    }
    private var libraryContent: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                if sidebarShown && geo.size.width > 800 {
                    sidebar.frame(width: ReferenceLayout.sidebar).background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 26))
                        .overlay { RoundedRectangle(cornerRadius: 26).stroke(.white.opacity(0.1), lineWidth: 0.75) }
                        .padding(.leading, 10).padding(.bottom, 10)
                }
                VStack(alignment: .leading, spacing: 0) {
                    topChrome
                    if folder == nil {
                        Text(heading).font(.system(size: 32, weight: .bold)).padding(.top, 14).padding(.bottom, 22).padding(.horizontal, 20)
                    }
                    libraryToolbar.padding(.horizontal, 20).padding(.top, folder == nil ? 0 : 22)
                    if searchShown {
                        HStack { Image(systemName: "magnifyingglass"); TextField("Suchen", text: $query).textFieldStyle(.plain); Button { query = ""; searchShown = false } label: { Image(systemName: "xmark.circle.fill") } }
                            .padding(10).background(Theme.pill, in: Capsule()).padding(.horizontal, 20).padding(.top, 15)
                    }
                    ScrollView {
                        if listLayout {
                            LazyVStack(spacing: 0) { ForEach(visible) { item in itemRow(item); Divider().overlay(Theme.border) } }.padding(.horizontal, 20).padding(.top, 20)
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 172, maximum: 230), spacing: 18, alignment: .top)], alignment: .leading, spacing: 58) {
                                ForEach(visible) { item in itemCard(item) }
                            }.padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 40)
                        }
                        if visible.isEmpty {
                            ContentUnavailableView(librarySection ?? (trash ? "Papierkorb ist leer" : "Keine Ergebnisse"), systemImage: trash ? "trash" : "doc.text.magnifyingglass", description: Text(query.isEmpty ? "Hier werden deine Dokumente angezeigt." : "Keine Dokumente für diese Suche.")).padding(.top, 80)
                        }
                    }.scrollIndicators(.hidden)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.foregroundStyle(.white).tint(Theme.accent).buttonStyle(.plain)
        }.background(Theme.library.ignoresSafeArea())
    }
    private var topChrome: some View {
        HStack(spacing: 10) {
            if !sidebarShown { Button { sidebarShown = true } label: { Image(systemName: "sidebar.left").frame(width: 44, height: 40).background(Color(hex: "#181818"), in: Capsule()) }.accessibilityLabel("Seitenleiste einblenden") }
            if folder != nil { Button { folder = store.item(folder)?.parent } label: { Image(systemName: "chevron.left").frame(width: 40, height: 40).background(Color(hex: "#181818"), in: Circle()) }.accessibilityLabel("Zurück") }
            Spacer()
            if folder != nil { Text(heading).font(.system(size: 15, weight: .semibold)); Spacer() }
            HStack(spacing: 0) {
                Button { searchShown.toggle() } label: { OriginalIcon(name: "general/search-lg", catalog: OriginalAssets.icons, size: 23).frame(width: 54, height: 40) }.accessibilityLabel("Suchen")
                Button { notifications.toggle() } label: { Image(systemName: "bell").font(.system(size: 22)).frame(width: 54, height: 40) }.accessibilityLabel("Benachrichtigungen")
                    .popover(isPresented: $notifications) {
                        VStack { HStack { Button { notifications = false } label: { Image(systemName: "xmark") }; Spacer(); Text("Benachrichtigungen").font(.system(size: 15, weight: .semibold)); Spacer() }.padding(); Spacer(); Text("Keine neuen Benachrichtigungen").font(.system(size: 13)).foregroundStyle(Theme.secondary); Spacer() }.frame(width: 330, height: 540).background(Theme.popover).presentationBackground(Theme.popover)
                    }
                Menu {
                    Button("Dokumente", systemImage: "folder") { navigate() }
                    Button("Papierkorb", systemImage: "trash") { navigate(trash: true) }
                } label: { Image(systemName: "person.fill").font(.system(size: 16)).frame(width: 32, height: 32).background(Color(hex: "#9A5235"), in: Circle()).frame(width: 46, height: 40) }.accessibilityLabel("Profil")
            }.background(Color(hex: "#181818"), in: Capsule()).overlay { Capsule().stroke(.white.opacity(0.1), lineWidth: 0.75) }
        }.padding(.horizontal, 10).frame(height: 44)
    }
    private var libraryToolbar: some View {
        Group {
            if selecting { selectionToolbar } else { browsingToolbar }
        }.frame(height: 36)
    }
    private var browsingToolbar: some View {
        HStack(spacing: 16) {
            Button { activeMenu = activeMenu == .filter ? nil : .filter } label: { HStack(spacing: 13) { Image(systemName: "line.3.horizontal.decrease").font(.system(size: 21)); Text(filter).font(.system(size: 15)) }.frame(height: 36).contentShape(Rectangle()) }
                .anchorPreference(key: LibraryMenuAnchorKey.self, value: .bounds) { [.filter: $0] }
            Spacer(minLength: 0)
            if !trash && librarySection == nil {
                Button { newPopover.toggle() } label: { Label("Neu", systemImage: "plus").font(.system(size: 15)).frame(width: 88, height: 36).background(Theme.libraryAccent, in: Capsule()) }
                    .popover(isPresented: $newPopover, arrowEdge: .top) { newDocumentMenu }
            }
            Button { activeMenu = activeMenu == .layout ? nil : .layout } label: { Image(systemName: listLayout ? "list.bullet" : "square.grid.2x2").font(.system(size: 20)).frame(width: 26, height: 36) }.accessibilityLabel("Ansicht und Sortierung")
                .anchorPreference(key: LibraryMenuAnchorKey.self, value: .bounds) { [.layout: $0] }
            Rectangle().fill(Theme.border).frame(width: 0.5, height: 28)
            Image(systemName: "icloud").font(.system(size: 21)).frame(width: 28).accessibilityLabel("Auf diesem Gerät gespeichert")
        }.frame(height: 36)
    }
    private var selectionToolbar: some View {
        HStack(spacing: 16) {
            Button("Abbrechen") { selecting = false; selectedIDs.removeAll() }
            Text("\(selectedIDs.count) ausgewählt").font(.system(size: 13)).foregroundStyle(Theme.secondary)
            Spacer()
            Button("Alle auswählen") { selectedIDs = Set(visible.map(\.id)) }
            Button {
                let selected = store.items.filter { selectedIDs.contains($0.id) }
                let favorite = !selected.allSatisfy(\.favorite)
                for var item in selected { item.favorite = favorite; store.update(item) }
            } label: { Image(systemName: "star") }.disabled(selectedIDs.isEmpty).accessibilityLabel("Favoriten ändern")
            Button { for id in selectedIDs { store.trash(id) }; selectedIDs.removeAll(); selecting = false } label: { Image(systemName: "trash") }.disabled(selectedIDs.isEmpty).accessibilityLabel("Auswahl in Papierkorb")
        }.font(.system(size: 15)).foregroundStyle(Theme.accent)
    }
    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack { Spacer(); Button { sidebarShown = false } label: { Image(systemName: "sidebar.left").font(.system(size: 22)).frame(width: 44, height: 44) }.accessibilityLabel("Seitenleiste ausblenden") }.padding(.horizontal, 10).padding(.bottom, 8)
            sideButton("Dokumente", symbol: "folder.fill", selected: !favorites && !trash && librarySection == nil) { navigate() }
            sideButton("Favoriten", symbol: "bookmark", selected: favorites) { navigate(favorites: true) }
            sideButton("Geteilt", symbol: "person.2", selected: librarySection == "Geteilt") { navigate(); librarySection = "Geteilt" }
            sideButton("Marketplace", symbol: "storefront", selected: librarySection == "Marketplace") { navigate(); librarySection = "Marketplace" }
            Spacer()
        }.frame(maxHeight: .infinity)
    }
    private func sideButton(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8.5) {
                if let asset = ["Dokumente": "documents", "Favoriten": "favorite", "Geteilt": "shared-documents", "Marketplace": "marketplace"][title] {
                    OriginalIcon(name: "tabbar/" + asset + (selected ? "-active" : ""), catalog: OriginalAssets.icons, size: 24, original: true)
                } else { Image(systemName: symbol).font(.system(size: 22)).frame(width: 23) }
                Text(title).font(.system(size: 15, weight: selected ? .semibold : .regular)); Spacer()
            }.padding(.horizontal, 17).frame(height: 48).foregroundStyle(.white).background(selected ? Theme.selectedRow : .clear, in: Capsule())
        }.padding(.horizontal, 16)
    }
    private func navigate(favorites: Bool = false, trash: Bool = false) { self.favorites = favorites; self.trash = trash; librarySection = nil; folder = nil; filter = "Alle"; selecting = false; selectedIDs.removeAll(); activeMenu = nil }
    private var newDocumentMenu: some View {
        NewDocumentPopover(
            notebook: { newPopover = false; notebookCreation = true },
            whiteboard: { newPopover = false; whiteboardCreation = true },
            importFile: { newPopover = false; importing = true },
            quickNote: { newPopover = false; if let item = store.add(title: "Unbenannt", parent: folder) { store.open(item.id) } },
            scan: { newPopover = false; scanning = true },
            image: { newPopover = false; choosingImage = true },
            camera: { newPopover = false; takingPhoto = true },
            folder: { newPopover = false; creatingFolder = true },
            canScan: DocumentMediaPDF.canScan,
            canUseCamera: DocumentMediaPDF.canUseCamera
        )
    }
    private func importImages(_ images: [UIImage], title: String) async {
        guard !images.isEmpty else { return }
        importBusy = true; defer { importBusy = false }
        do {
            let url = try DocumentMediaPDF.write(images)
            defer { try? FileManager.default.removeItem(at: url) }
            var item = try await NotebookArchive.importAsync(url, into: store, parent: folder)
            item.title = title; store.update(item); store.open(item.id)
        } catch { store.error = error.localizedDescription }
    }
    private func open(_ item: LibraryItem) {
        if selecting { if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) } else { selectedIDs.insert(item.id) }; return }
        if trash { return }; if item.folder { folder = item.id; favorites = false } else { store.open(item.id) }
    }
    private func itemCard(_ item: LibraryItem) -> some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                Button { open(item) } label: {
                    Group {
                        if item.folder { FolderArtwork(color: item.color, symbol: item.symbol).frame(width: 146, height: 126).frame(height: 152, alignment: .bottom) }
                        else if let page = item.pages.first {
                            if item.kind == .whiteboard { WhiteboardArtwork(page: page, directory: store.directory(item.id)).frame(width: 162, height: 122).frame(height: 152, alignment: .bottom) }
                            else { NotebookPreview(page: page, directory: store.directory(item.id)).frame(width: 134, height: 152) }
                        }
                    }.frame(width: 146, height: 152, alignment: .bottom)
                }
                Button { if selecting { open(item) } else { store.toggleFavorite(item.id) } } label: { Image(systemName: selecting ? (selectedIDs.contains(item.id) ? "checkmark.circle.fill" : "circle") : (item.favorite ? "star.fill" : "star")).font(.system(size: 19)).foregroundStyle(selecting ? Theme.accent : Color(hex: "#BDBDBD")).frame(width: 30, height: 30) }
                    .padding(.trailing, item.folder ? 10 : 14).padding(.top, item.folder ? 39 : 5).accessibilityLabel(selecting ? (selectedIDs.contains(item.id) ? "Auswahl aufheben" : "Auswählen") : (item.favorite ? "Aus Favoriten entfernen" : "Zu Favoriten hinzufügen"))
            }.frame(width: 146, height: 152).frame(maxWidth: .infinity)
            HStack(spacing: 4) { Text(item.title).font(.system(size: 13.5)).lineLimit(2).multilineTextAlignment(.center); chevron(item) }.frame(minHeight: 28).padding(.top, 9)
            Text(Theme.libraryDate.string(from: item.modified)).font(.system(size: 10)).foregroundStyle(Color(hex: "#8A8989")).lineLimit(1)
        }.contextMenu { contextActions(item) }
    }
    private func itemRow(_ item: LibraryItem) -> some View {
        HStack(spacing: 16) {
            Button { open(item) } label: { HStack(spacing: 16) { Image(systemName: item.folder ? (item.symbol ?? "folder.fill") : "book.closed.fill").font(.system(size: 26)).foregroundStyle(Color(hex: item.color)); VStack(alignment: .leading, spacing: 4) { Text(item.title).foregroundStyle(.white); Text(Theme.libraryDate.string(from: item.modified)).font(.caption).foregroundStyle(Theme.secondary) } }.frame(maxWidth: .infinity, alignment: .leading) }
            Button { if selecting { open(item) } else { store.toggleFavorite(item.id) } } label: { Image(systemName: selecting ? (selectedIDs.contains(item.id) ? "checkmark.circle.fill" : "circle") : (item.favorite ? "star.fill" : "star")).foregroundStyle(selecting ? Theme.accent : Theme.secondary) }; chevron(item)
        }.padding(.vertical, 14).contextMenu { contextActions(item) }
    }
    private func chevron(_ item: LibraryItem) -> some View {
        Button { contextID = item.id } label: { Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.secondary).frame(width: 24, height: 32) }.accessibilityLabel("Optionen für \(item.title)")
            .popover(isPresented: Binding(get: { contextID == item.id }, set: { if !$0 { contextID = nil } }), arrowEdge: .top) {
                VStack(spacing: 0) {
                    if trash { menuRow("Wiederherstellen", symbol: "arrow.uturn.backward") { store.restore(item.id); contextID = nil } }
                    else {
                        if item.folder { menuRow("Farbe anpassen", symbol: "paintpalette") { edit(item, action: .color) }; menuRow("Symbol festlegen", symbol: "star.square") { edit(item, action: .symbol) }; Divider().overlay(Theme.border) }
                        menuRow("Umbenennen", symbol: "pencil") { editItem = item; title = item.title; contextID = nil; renaming = true }
                        menuRow("Bewegen", symbol: "folder") { edit(item, action: .move) }
                        Divider().overlay(Theme.border)
                        menuRow("In Papierkorb", symbol: "trash", destructive: true) { store.trash(item.id); contextID = nil }
                    }
                }.padding(.vertical, 6).frame(width: 260).background(Theme.pill).presentationBackground(Theme.pill).presentationCompactAdaptation(.popover)
            }
    }
    private func menuRow(_ label: String, symbol: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { HStack { Text(label); Spacer(); Image(systemName: symbol) }.font(.system(size: 15)).foregroundStyle(destructive ? Color.red : .white).padding(.horizontal, 17).frame(height: 44).contentShape(Rectangle()) }.buttonStyle(.plain)
    }
    @ViewBuilder private func contextActions(_ item: LibraryItem) -> some View {
        if trash { Button("Wiederherstellen", systemImage: "arrow.uturn.backward") { store.restore(item.id) } }
        else {
            if item.folder { Button("Farbe anpassen", systemImage: "paintpalette") { edit(item, action: .color) }; Button("Symbol festlegen", systemImage: "star.square") { edit(item, action: .symbol) } }
            Button("Umbenennen", systemImage: "pencil") { editItem = item; title = item.title; renaming = true }
            Button("Bewegen", systemImage: "folder") { edit(item, action: .move) }
            Button("In Papierkorb", systemImage: "trash", role: .destructive) { store.trash(item.id) }
        }
    }
    private func edit(_ item: LibraryItem, action: LibraryEdit) { editItem = item; contextID = nil; editing = action }
    private func colorChoices(selected: String, action: @escaping (String) -> Void) -> some View {
        FolderColorGrid(selected: selected, action: action)
    }
    private func editSheet(_ action: LibraryEdit) -> some View {
        NavigationStack {
            Form {
                if let item = editItem {
                    if action == .color { colorChoices(selected: item.color) { c in var updated = item; updated.color = c; store.update(updated); editing = nil } }
                    if action == .symbol {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 48))], spacing: 18) {
                            ForEach(["folder", "star", "leaf", "flask", "book", "globe", "clock", "paintpalette", "function", "atom", "graduationcap", "heart"], id: \.self) { symbol in Button { var updated = item; updated.symbol = symbol == "folder" ? nil : symbol; store.update(updated); editing = nil } label: { Image(systemName: symbol).font(.system(size: 25)).frame(width: 44, height: 44).foregroundStyle(Theme.accent) } }
                        }
                    }
                    if action == .move {
                        Button("Dokumente", systemImage: "folder") { store.move(item.id, into: nil); editing = nil }
                        ForEach(store.items.filter { $0.folder && $0.id != item.id && !store.isTrashed($0.id) }) { target in Button(target.title, systemImage: "folder") { store.move(item.id, into: target.id); editing = nil } }
                    }
                }
            }.goodnotesSheet().navigationTitle(action.rawValue).navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { editing = nil } } }
        }.presentationDetents([.medium]).preferredColorScheme(.dark)
    }
}
private enum LibraryEdit: String, Identifiable { case color = "Farbe anpassen", symbol = "Symbol festlegen", move = "Bewegen"; var id: String { rawValue } }
