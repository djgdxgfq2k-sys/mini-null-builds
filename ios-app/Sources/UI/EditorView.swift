import SwiftUI
import PDFKit

@MainActor struct EditorView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.openWindow) private var openWindow
    let bookID: String
    /// Set when this editor lives in its own window (opened with "In neuem Fenster öffnen").
    var separateWindow = false
    var initialPageID: String? = nil
    @StateObject private var commands = CanvasCommands()
    @State private var settings = ToolSettingsStore.load()
    @State private var toolPopover: EditorTool?
    @State private var pageIndex = 0
    @State private var panel: EditorPanel?
    @StateObject private var studyTimer = StudyTimer()
    @StateObject private var zoom = ZoomState()
    @ObservedObject private var ruler = RulerState.shared
    @State private var studying = false
    @State private var sidebar: EditorPanel?
    @State private var colorPopover = false
    @State private var writingMenu = false
    @State private var customizingToolbar = false
    @State private var moreTools = false
    @State private var accessories = false
    @State private var widthPopover: Int?
    @State private var addingPage = false
    @State private var sharing = false
    @State private var moreDocument = false
    @State private var shareURL: URL?
    @State private var query = ""
    @State private var searchResults: [(Int,String)] = []
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var actionPageID: String?
    @State private var outlineEditing = false
    @State private var outlineName = ""
    @State private var movingPage = false
    @State private var movePosition = 0
    @State private var destructivePageAction: PageMenuAction?
    @State private var pageMedia: PageMediaRequest?
    @State private var pencilHistory = PencilToolHistory()
    @State private var pencilPalette: PencilPalette?
    @State private var pencilAnchor: CGPoint?
    private var item: LibraryItem? { store.item(bookID) }
    private var page: NotebookPage? { guard let pages = item?.pages, pages.indices.contains(pageIndex) else { return nil }; return pages[pageIndex] }
    var body: some View {
        VStack(spacing: 0) {
            tabs
            toolbar
            HStack(spacing: 0) {
                if let sidebar, let item {
                    DocumentSidebar(item: item, directory: store.directory(bookID), mode: sidebar, pageIndex: $pageIndex, close: { self.sidebar = nil }, addPage: { addPage(page?.paper ?? "blank") }, flush: { commands.flush() }, pageAction: handlePageAction, restorePage: restorePage, showRecordings: { panel = .audio })
                        .frame(width: ReferenceLayout.pageSidebar)
                }
                ZStack(alignment: .top) {
                    Theme.canvas
                    if let page {
                        NotebookCanvas(pages: item?.pages ?? [], directory: store.directory(bookID), settings: settings, commands: commands, pageIndex: $pageIndex)
                        floatingControls
                        VStack { Spacer(); HStack { pageNavigation; Spacer() }.padding(.leading, 20).padding(.bottom, 33) }
                        KnightOverlay(commands: commands, pageSize: page.size, directory: store.directory(bookID)).id("extensions-" + page.id)
                    }
                }
            }
        }.ignoresSafeArea(edges: .bottom).background(Theme.top.ignoresSafeArea(edges: .top)).buttonStyle(.solidPlain)
        .overlay { pencilGestures }
        .modifier(EditorPageImport(bookID: bookID, commands: commands, pageIndex: $pageIndex, request: $pageMedia))
        .overlay { if ruler.visible { RulerOverlay(state: ruler) } }
        .animation(.easeInOut(duration: 0.2), value: ruler.visible)
        .overlay(alignment: .bottom) {
            if zoom.visible, let page {
                ZoomPanel(state: zoom, commands: commands, settings: settings, page: page, directory: store.directory(bookID))
                    .frame(height: 300).transition(.move(edge: .bottom))
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.9), value: zoom.visible)
        .overlay(alignment: .bottom) { if studyTimer.visible { StudyTimerPill(timer: studyTimer).padding(.bottom, zoom.visible ? 316 : 28) } }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: studyTimer.visible)
        .fullScreenCover(isPresented: $studying) { if let item { FlashcardStudyView(item: item, directory: store.directory(bookID)) } }
        .onAppear {
            if let initialPageID, let index = item?.pages.firstIndex(where: { $0.id == initialPageID }) { pageIndex = index }
            if store.openRecorder { store.openRecorder = false; DispatchQueue.main.async { panel = .audio } }
            // Errors can arrive while SwiftUI tears the editor down; publish them on the next run loop turn.
            commands.reportError = { message in DispatchQueue.main.async { store.error = message } }
            commands.didFinishErasing = { if settings.eraserAutoDeselect && settings.tool == .eraser { settings.tool = .pen } }
        }
        .onChange(of: settings.color) { _, color in InkPaletteStore().remember(color) }
        .onChange(of: settings.tool) { old, new in pencilHistory.record(from: old, to: new) }
        .onChange(of: settings.readOnly) { _, value in if value { pencilPalette = nil } }
        .onChange(of: settings) { _, value in ToolSettingsStore.save(value) }
        .onDisappear { commands.flush() }
        .sheet(item: $panel) { p in sheet(p) }
        .sheet(isPresented: $customizingToolbar) { ToolbarCustomizationView(settings: $settings) }
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) { if let shareURL { ShareView(url: shareURL) } }
        .alert("Notizbuch umbenennen", isPresented: $renaming) { TextField("Name", text: $newTitle); Button("Abbrechen", role: .cancel) {}; Button("Sichern") { if var item, !newTitle.trimmingCharacters(in: .whitespaces).isEmpty { item.title = newTitle; store.update(item) } } }
        .alert("Zur Gliederung hinzufügen", isPresented: $outlineEditing) {
            TextField("Name", text: $outlineName)
            Button("Abbrechen", role: .cancel) {}
            Button("Sichern") {
                guard let actionPageID else { return }
                let title = outlineName
                commands.afterInput { do { try PageEditing.setOutline(title, pageID: actionPageID, bookID: bookID, store: store) } catch { store.error = error.localizedDescription } }
            }
        }
        .confirmationDialog(destructivePageAction == .clear ? "Seite leeren?" : "Seite entfernen?", isPresented: Binding(get: { destructivePageAction != nil }, set: { if !$0 { destructivePageAction = nil } }), titleVisibility: .visible, presenting: destructivePageAction) { action in
            Button(action == .clear ? "Seite leeren" : "In den Papierkorb", role: .destructive) { if let actionPageID { performPageAction(action, pageID: actionPageID) }; destructivePageAction = nil }
            Button("Abbrechen", role: .cancel) { destructivePageAction = nil }
        } message: { _ in Text("Die vorherige Seite lässt sich über das Seitenmenü wiederherstellen.") }
        .sheet(isPresented: $movingPage) {
            NavigationStack {
                Form {
                    Picker("Position im aktuellen Notizbuch", selection: $movePosition) { ForEach(0..<(item?.pages.count ?? 0), id: \.self) { index in Text("Seite \(index + 1)").tag(index) } }
                }.goodnotesSheet().navigationTitle("Seite bewegen").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { movingPage = false } }; ToolbarItem(placement: .confirmationAction) { Button("Bewegen") { if let actionPageID { performPageAction(.move, pageID: actionPageID) }; movingPage = false } } }
            }.presentationDetents([.medium])
        }
    }
    private func handlePencilAction(_ action: UIPencilPreferredAction, point: CGPoint?) {
        guard !settings.readOnly, settings.pencilConnected else { return }
        commands.afterInput {
            if let tool = pencilHistory.tool(for: action, current: settings.tool) {
                pencilPalette = nil; toolPopover = nil; settings.tool = tool
            } else {
                guard var palette = PencilPalette.preferred(for: action) else { return }
                if palette == .attributes && ![.pen, .pencil, .marker, .eraser, .lasso, .shapes, .laser].contains(settings.tool) { palette = .tools }
                pencilAnchor = point
                pencilPalette = pencilPalette == palette ? nil : palette
            }
        }
    }
    private var pencilGestures: some View {
        GeometryReader { geometry in
            PencilGestureView(enabled: !settings.readOnly && settings.pencilConnected, perform: handlePencilAction)
                .popover(item: $pencilPalette, attachmentAnchor: .point(PencilPalette.anchor(pencilAnchor, in: geometry.size))) { palette in
                    switch palette {
                    case .tools: PencilToolPalette(settings: $settings, commands: commands, showColors: { pencilPalette = .colors }, showAttributes: { pencilPalette = .attributes })
                    case .colors: InkColorPalette(settings: $settings)
                    case .attributes: ToolOptionsView(tool: settings.tool, settings: $settings, openMath: { commands.flush(); panel = .math })
                    }
                }
        }
    }
    private var pageNavigation: some View {
        Menu {
            Button("Vorherige Seite") { go(-1) }.disabled(pageIndex == 0)
            Button("Nächste Seite") { go(1) }.disabled(pageIndex + 1 >= (item?.pages.count ?? 0))
            Button("Alle Seiten") { sidebar = .pages }
        } label: {
            Text("\(pageIndex + 1) von \(item?.pages.count ?? 0)").font(.system(size: 14)).foregroundStyle(Color(hex: "#9A9A9A")).padding(.horizontal, 9).frame(height: 21).background(Color(hex: "#29292A"), in: Capsule())
        }
    }
    private var tabs: some View {
        HStack(spacing: 0) {
            Button { commands.flush(); store.active = nil } label: { OriginalIcon(name: "navbar/home", size: 16).frame(width: ReferenceLayout.home, height: ReferenceLayout.tabs) }.accessibilityLabel("Startseite")
            GeometryReader { geometry in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(store.opened, id: \.self) { id in
                            HStack(spacing: 0) {
                                if id == bookID {
                                    Menu {
                                        Button("Umbenennen", systemImage: "pencil") { newTitle = item?.title ?? ""; renaming = true }
                                        Button("Lesezeichen", systemImage: "bookmark") { sidebar = .bookmarks }
                                        Button("Schließen", systemImage: "xmark") { commands.flush(); store.close(id) }
                                    } label: { tabTitle(id, active: true) }.accessibilityLabel("Dokumentoptionen")
                                } else {
                                    Button { commands.flush(); store.active = id } label: { tabTitle(id, active: false) }
                                }
                                Button { commands.flush(); store.close(id) } label: { Image(systemName: "xmark").font(.system(size: 8)).foregroundStyle(Color(hex: "#A7ADBD")).frame(width: 40, height: ReferenceLayout.tabs) }.accessibilityLabel("\(store.item(id)?.title ?? "Tab") schließen")
                            }.font(.system(size: 14, weight: .medium)).foregroundStyle(id == bookID ? .white : Color(hex: "#A7ADBD"))
                                .frame(width: min(ReferenceLayout.tabMax, max(180, geometry.size.width / CGFloat(max(store.opened.count, 1)))), height: ReferenceLayout.tabs)
                                .background(id == bookID ? Theme.toolbar : .clear, in: UnevenRoundedRectangle(topLeadingRadius: 8.5, topTrailingRadius: 8.5))
                        }
                    }
                }
            }
        }.foregroundStyle(Color(hex: "#A7ADBD")).frame(height: ReferenceLayout.tabs).background(Theme.top)
    }
    private func tabTitle(_ id: String, active: Bool) -> some View {
        HStack(spacing: 8) { Text(store.item(id)?.title ?? "Unbenannt").lineLimit(1); if active { Image(systemName: "chevron.down").font(.system(size: 9)) }; Spacer(minLength: 5) }.padding(.leading, 13).frame(maxWidth: .infinity).frame(height: ReferenceLayout.tabs).contentShape(Rectangle())
    }
    private var toolbar: some View {
        GeometryReader { geometry in
            // A Pencil tap drifts a little; a scroll view that cannot scroll must not swallow it as a pan.
            ScrollView(.horizontal, showsIndicators: false) {
                ZStack {
                    HStack(spacing: 0) {
                        iconButton("navbar/sidebar", "Seiten", selected: sidebar == .pages || sidebar == .bookmarks) { sidebar = sidebar == .pages ? nil : .pages }
                        iconButton("navbar/search", "Suchen", selected: sidebar == .search) { sidebar = sidebar == .search ? nil : .search }
                        iconButton("nexus/agent", "Assistent", selected: panel == .assistant) { commands.flush(); panel = .assistant }
                        if item?.kind == .flashcards { Button { commands.flush(); studying = true } label: { Label("Lernen", systemImage: "rectangle.on.rectangle.angled").font(.system(size: 14, weight: .semibold)).padding(.horizontal, 12).frame(height: 32).background(Color(referenceHex: "#263A60"), in: Capsule()) }.accessibilityLabel("Lernset lernen") }
                        iconButton(settings.readOnly ? "newToolbar/document-mode-edit" : "newToolbar/document_mode", "Lesemodus", selected: settings.readOnly) { settings.readOnly.toggle() }
                        Spacer(minLength: 0)
                        Button { commands.toggleKnight?() } label: { BucketIcon().stroke(.white, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)).frame(width: 17, height: 20).frame(width: 44, height: 44) }.accessibilityLabel("Ritter ein- oder ausblenden")
                        Button { addingPage.toggle() } label: { OriginalIcon(name: "navbar/addPage").frame(width: 44, height: 44) }.accessibilityLabel("Seite hinzufügen")
                            .popover(isPresented: $addingPage) { PageAddPopover(currentPaper: page?.paper ?? "blank", paperColor: page?.paperColor ?? "#FFFFFF", importMedia: { kind, position in addingPage = false; if let page { pageMedia = PageMediaRequest(kind: kind, anchorID: page.id, position: position) } }) { paper, position in addingPage = false; addPage(paper, position: position) } }
                        Button { sharing.toggle() } label: { OriginalIcon(name: "navbar/share").frame(width: 44, height: 44) }.accessibilityLabel("Teilen und Exportieren")
                            .popover(isPresented: $sharing) { ExportPopover(exportPage: { sharing = false; export(.pdf, currentPage: true) }, exportAll: { sharing = false; export(.pdf) }, exportNative: { sharing = false; export(.native) }, exportOriginal: item?.originalName == nil ? nil : { sharing = false; export(.original) }, printDocument: { sharing = false; printDocument() }) }
                        Button { moreDocument.toggle() } label: { OriginalIcon(name: "navbar/more-circle", size: 36).frame(width: 44, height: 44) }.accessibilityLabel("Mehr")
                            .popover(isPresented: $moreDocument) {
                                DocumentMorePopover(pageNumber: pageIndex + 1, bookmarked: page?.bookmarked == true, bookmark: { bookmark() }, rename: { moreDocument = false; newTitle = item?.title ?? ""; renaming = true }, changeTemplate: { paper in changeTemplate(paper); moreDocument = false }, readOnly: $settings.readOnly, finger: $settings.finger, report: { moreDocument = false; panel = .report }, pageCount: item?.pages.count ?? 1, page: page, directory: store.directory(bookID), pageAction: { action in moreDocument = false; handlePageAction(action, index: pageIndex) }, rotatePage: rotatePage, goToPage: { index in moreDocument = false; commands.afterInput { pageIndex = min(max(0, index), max(0, (item?.pages.count ?? 1) - 1)) } }, clearObjects: { kind in moreDocument = false; commands.clear(kind) })
                            }
                    }
                    HStack(spacing: 0) {
                        // Order and artwork of the original iPad toolbar: hand | lasso, pen, eraser, text, objects, image, shapes, sticky note, laser | audio.
                        mainTool(.hand, name: "newToolbar/selection"); toolbarDivider
                        if settings.toolbarTools.contains(.lasso) { mainTool(.lasso, name: settings.rectangularLasso ? "newToolbar/lasso/lasso_rectangular" : "newToolbar/lasso/lasso") }
                        if settings.toolbarTools.contains(.pen) { mainTool(.pen, name: "newToolbar/writing_tools/writing_tools") }
                        if settings.toolbarTools.contains(.eraser) { mainTool(.eraser, name: "newToolbar/eraser/eraser_stroke") }
                        mainTool(.text, name: "newToolbar/text")
                        mainTool(.elements, name: "newToolbar/element")
                        toolbarAction("newToolbar/image", "Bilder") { if let page { pageMedia = PageMediaRequest(kind: .photos, anchorID: page.id, position: 1) } }
                        if settings.toolbarTools.contains(.geometry) { mainTool(.geometry, name: "newToolbar/shapes") }
                        toolbarAction("newToolbar/sticky_note", "Notizzettel") { settings.readOnly = false; settings.tool = .text; DispatchQueue.main.async { commands.addStickyNote() } }
                        if settings.toolbarTools.contains(.laser) { mainTool(.laser, name: "newToolbar/laser_pointer") }
                        toolbarDivider
                        iconButton("mediaAndDevices/microphone-01", "Aufnahmen") { panel = .audio }
                        Button { accessories.toggle() } label: {
                            ZStack(alignment: .topLeading) {
                                OriginalIcon(name: "newToolbar/accessories3").position(x: 27.75, y: 22)
                                Image(systemName: "chevron.down").font(.system(size: 9)).position(x: 47.5, y: 22)
                            }.frame(width: 66, height: 44)
                        }
                            .accessibilityLabel("Zubehör").popover(isPresented: $accessories, arrowEdge: .top) {
                                ReferenceToolMenu(title: "Zubehör", entries: [("Aufnahmen anzeigen", "navbar/recordings"), ("Zoom-Ansicht", "newToolbar/accessories/zoom"), ("Lineal", "newToolbar/accessories/ruler"), ("Zeitmesser", "newToolbar/accessories/timer")], enabled: [0, 1, 2, 3]) { index in accessories = false; if index == 0 { panel = .audio } else if index == 1 { commands.flush(); zoom.visible.toggle() } else if index == 2 { ruler.visible.toggle() } else if index == 3 { studyTimer.visible ? studyTimer.close() : studyTimer.start() } }
                            }
                        Color.clear.frame(width: 3, height: 44).allowsHitTesting(false)
                    }.frame(height: 44)
                }.frame(width: max(850, geometry.size.width), height: 44)
            }.scrollBounceBehavior(.basedOnSize, axes: .horizontal).scrollDisabled(geometry.size.width >= 850)
        }.frame(height: ReferenceLayout.toolbar).background(Theme.toolbar).foregroundStyle(.white)
            .animation(EditorMotion.selection, value: settings.tool)
    }
    private func toolbarAction(_ name: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { OriginalIcon(name: name, size: 24).frame(width: 36, height: 36).frame(width: 50, height: 44) }
            .buttonStyle(ToolbarPressStyle()).accessibilityLabel(label)
    }
    private var toolbarDivider: some View { Rectangle().fill(Color(referenceHex: "#5D7297")).frame(width: 0.5, height: 24).padding(.horizontal, 2) }
    private func mainTool(_ tool: EditorTool, name: String) -> some View {
        let selected = settings.tool == tool || (tool == .pen && [.marker, .shapes, .pencil].contains(settings.tool))
        let selectedName = name + "_selected"
        let artwork = selected && OriginalAssets.image(selectedName, in: OriginalAssets.toolbar) != nil ? selectedName : name
        return Button {
            if selected && [.geometry, .hand, .text, .elements].contains(tool) { return }
            if selected { toolPopover = toolPopover == settings.tool ? nil : settings.tool }
            else { toolPopover = nil; settings.tool = tool }
        } label: {
            OriginalIcon(name: artwork, size: 24, original: selected && artwork != name).foregroundStyle(selected ? Color(referenceHex: "#1D1B1B") : .white).frame(width: 36, height: 36).background(selected ? Theme.activeTool : .clear, in: RoundedRectangle(cornerRadius: 11)).frame(width: 50, height: 44)
        }.buttonStyle(ToolbarPressStyle()).accessibilityLabel(tool.label).accessibilityAddTraits(settings.tool == tool ? .isSelected : [])
            .popover(isPresented: Binding(get: { toolPopover == tool }, set: { if !$0 { toolPopover = nil } }), arrowEdge: .top) { ToolOptionsView(tool: tool, settings: $settings, openMath: { toolPopover = nil; commands.flush(); panel = .math }) }
    }
    private var floatingControls: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    Button { commands.undo() } label: { OriginalIcon(name: "toolbar/tool_undo", size: 24).frame(width: 44, height: 45).opacity(commands.canUndo ? 1 : 0.5) }.accessibilityLabel("Widerrufen")
                    Button { commands.redo() } label: { OriginalIcon(name: "toolbar/tool_redo", size: 24).frame(width: 44, height: 45).opacity(commands.canRedo ? 1 : 0.5) }.accessibilityLabel("Wiederholen")
                }.foregroundStyle(.white).frame(width: 89, height: 45).goodnotesPill().padding(.leading, 7.5)
                if ![.lasso, .laser, .hand, .text, .elements].contains(settings.tool) && !settings.readOnly {
                    contextPill.frame(width: min(settings.tool == .geometry ? 459 : (settings.tool == .eraser ? 362 : min(660, 380 + CGFloat(contextColors.count) * 44)), max(260, geometry.size.width - 210)), height: 45)
                        .position(x: max(geometry.size.width / 2, 265), y: 22.5)
                        .transition(.opacity)
                }
            }.padding(.top, ReferenceLayout.floatingGap)
            .animation(EditorMotion.subbar, value: settings.tool)
            .animation(EditorMotion.selection, value: settings.color)
            .animation(EditorMotion.selection, value: settings.width)
        }.frame(height: 58)
    }
    private var contextPill: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            if settings.tool == .geometry { ShapeContextToolbar(settings: $settings) }
            else if settings.tool == .eraser { EraserContextToolbar(settings: $settings, selectType: { toolPopover = .eraser }, clearPage: { handlePageAction(.clear, index: pageIndex) }) }
            else {
            HStack(spacing: 0) {
                // Original writing-tool row: pen, pencil, highlighter, tape, shapes. The selected tool shows its
                // body artwork with the nib layer tinted in the current ink color, plus a chevron for its options.
                writingSlot(.pen, label: "Stift").padding(.leading, 2)
                writingSlot(.pencil, label: "Bleistift")
                writingSlot(.marker, label: "Textmarker")
                Button { toolPopover = nil; settings.tool = .marker; settings.tape = true } label: {
                    WritingToolIcon(base: "newToolbar/writing_tools/tools/tape", selected: tapeSelected, color: settings.tapeColor, colorLayer: "")
                        .frame(width: 44, height: 36).background(tapeSelected ? Color(referenceHex: "#4D8292") : .clear, in: RoundedRectangle(cornerRadius: 11)).frame(height: 45)
                }.accessibilityLabel("Klebeband").accessibilityAddTraits(tapeSelected ? .isSelected : [])
                writingSlot(.shapes, label: "Draw Shape")
                Rectangle().fill(Theme.border).frame(width: 0.5, height: 28).padding(.horizontal, 4)
                ForEach(settings.widthPresets.indices, id: \.self) { index in
                    let width = settings.widthPresets[index]
                    Button { if settings.width == width && settings.tool != .eraser { widthPopover = index }; settings.width = width } label: {
                        Group {
                            if settings.tool == .eraser { OriginalIcon(name: "newToolbar/eraser_size/eraser_" + (width == 1 ? "small" : (width == 2 ? "medium" : "large")), size: width == 1 ? 24 : (width == 2 ? 32 : 42), original: true) }
                            else { Capsule().fill(.white).frame(width: 17, height: width) }
                        }.frame(width: 37, height: 37).background(settings.width == width ? Color(hex: "#484A4D") : .clear, in: RoundedRectangle(cornerRadius: 11)).frame(width: 44, height: 45)
                    }.accessibilityLabel("Stärke \(Int(width))")
                        .popover(isPresented: Binding(get: { widthPopover == index }, set: { if !$0 { widthPopover = nil } })) { StrokeOptionsPopover(settings: $settings, presetIndex: index) }
                }
                if settings.tool != .eraser {
                    ForEach(contextColors, id: \.self) { color in
                        Button { if settings.color == color { colorPopover = true } else { settings.color = color } } label: {
                            Circle().fill(Color(hex: color)).frame(width: 20, height: 20).overlay { if settings.color == color { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(color == Theme.inks[3] ? .black : .white) } }
                                .background { if settings.color == color { Circle().fill(Color(hex: "#484A4D")).frame(width: 30, height: 30) } }.frame(width: 44, height: 45)
                        }.accessibilityLabel("Farbe \(color)")
                    }
                }
            }.frame(height: 45)
            }
        }.foregroundStyle(.white).goodnotesPill()
            .popover(isPresented: $colorPopover) { InkColorPalette(settings: $settings) }
    }
    private var contextColors: [String] { Theme.inks.contains(settings.color) ? Theme.inks : [settings.color] + Theme.inks }
    private var tapeSelected: Bool { settings.tool == .marker && settings.tape }
    private func writingSlot(_ tool: EditorTool, label: String) -> some View {
        let selected = settings.tool == tool && !(tool == .marker && settings.tape)
        return Button { if selected { toolPopover = tool } else { toolPopover = nil; settings.tape = false; settings.tool = tool } } label: {
            HStack(spacing: 0) {
                WritingToolIcon(base: writingArtwork(tool), selected: selected, color: settings.color, colorLayer: writingColorLayer(tool))
                if selected { Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).frame(width: 10) }
            }.frame(width: selected ? 54 : 44, height: 36)
                .background(selected ? Color(referenceHex: "#4D8292") : .clear, in: RoundedRectangle(cornerRadius: 11))
                .frame(height: 45)
        }.accessibilityLabel(label).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func writingArtwork(_ tool: EditorTool) -> String {
        switch tool {
        case .pencil: return "newToolbar/writing_tools/tools/pencil"
        case .marker: return "newToolbar/writing_tools/tools/highlighter"
        case .shapes: return "newToolbar/pen_shapes"
        default: return "newToolbar/writing_tools/tools/" + (settings.penStyle == .fountain ? "fountain_pen" : (settings.penStyle == .brush ? "brush_pen" : "ball_pen"))
        }
    }
    private func writingColorLayer(_ tool: EditorTool) -> String {
        switch tool {
        case .pencil: return "_selected_color"
        case .marker: return "_selected_color_" + (settings.straightHighlighter ? "straight" : "freehand")
        case .shapes: return ""
        default: return "_selected_color_" + (settings.strokePattern == .dashed ? "dashed" : (settings.strokePattern == .dotted ? "dotted" : "solid"))
        }
    }
    private var penAsset: String {
        if settings.tool == .pencil { return "toolbar/tool_hb_pencil" }
        if settings.tool == .marker { return "toolbar/tool_highlighter" }
        if settings.tool == .shapes { return "toolbar/tool_shapes" }
        return "toolbar/tool_" + (settings.penStyle == .fountain ? "fountainpen" : (settings.penStyle == .brush ? "brushpen" : "ballpen"))
    }
    private func iconButton(_ name: String, _ label: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        let canvas: CGFloat = name == "navbar/search" ? 44 : (name == "navbar/microphone" ? 36 : 24)
        return Button(action: action) { OriginalIcon(name: name, size: canvas).frame(width: 36, height: 36).background(selected ? Color(referenceHex: "#263A60") : .clear, in: RoundedRectangle(cornerRadius: 11)).frame(width: 44, height: 44) }.buttonStyle(ToolbarPressStyle()).accessibilityLabel(label)
    }
    private func go(_ amount:Int) { commands.flush(); pageIndex = max(0,min((item?.pages.count ?? 1)-1,pageIndex+amount)) }
    private func handlePageAction(_ action: PageMenuAction, index: Int) {
        guard let item, item.pages.indices.contains(index) else { return }
        let page = item.pages[index]; actionPageID = page.id
        switch action {
        case .outline: outlineName = page.outlineTitle ?? "Seite \(index + 1)"; outlineEditing = true
        case .move: movePosition = index; movingPage = true
        case .clear, .trash: destructivePageAction = action
        case .window: commands.flush(); openWindow(id: "notebook", value: NotebookWindowTarget(bookID: bookID, pageID: page.id))
        default: performPageAction(action, pageID: page.id)
        }
    }
    private func performPageAction(_ action: PageMenuAction, pageID: String) {
        let destination = movePosition
        commands.afterInput {
            do {
                switch action {
                case .before, .after: pageIndex = try PageEditing.insert(relativeTo: pageID, after: action == .after, bookID: bookID, store: store)
                case .duplicate: pageIndex = try PageEditing.duplicate(pageID, bookID: bookID, store: store)
                case .rotate: try PageEditing.rotate(pageID, bookID: bookID, store: store)
                case .move: pageIndex = try PageEditing.move(pageID, to: destination, bookID: bookID, store: store)
                case .clear, .trash: pageIndex = try PageEditing.remove(pageID, clearOnly: action == .clear, bookID: bookID, store: store)
                case .copy, .export:
                    guard var selection = store.item(bookID), let page = selection.pages.first(where: { $0.id == pageID }) else { return }
                    selection.pages = [page]
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("Seite-" + UUID().uuidString + ".pdf")
                    try NotebookArchive.exportPDF(item: selection, directory: store.directory(bookID), to: url)
                    if action == .copy { defer { try? FileManager.default.removeItem(at: url) }; UIPasteboard.general.setData(try Data(contentsOf: url), forPasteboardType: "com.adobe.pdf") }
                    else { shareURL = url }
                default: break
                }
            } catch { store.error = error.localizedDescription }
        }
    }
    private func restorePage() {
        commands.afterInput { do { pageIndex = try PageEditing.restoreLast(at: pageIndex, bookID: bookID, store: store) } catch { store.error = error.localizedDescription } }
    }
    private func rotatePage(_ turns: Int) {
        moreDocument = false; guard let pageID = page?.id else { return }
        commands.afterInput { do { try PageEditing.rotate(pageID, turns: turns, bookID: bookID, store: store) } catch { store.error = error.localizedDescription } }
    }
    private func addPage(_ paper: String, position: Int = 1) {
        guard let pageID = page?.id else { return }
        commands.afterInput {
            do { pageIndex = try PageEditing.insert(relativeTo: pageID, after: position != 0, bookID: bookID, store: store, paper: paper, atEnd: position == 2) }
            catch { store.error = error.localizedDescription }
        }
    }
    private func changeTemplate(_ paper: String) {
        guard var item, item.pages.indices.contains(pageIndex), item.pages[pageIndex].pdf == nil else { return }
        item.pages[pageIndex].paper = paper; store.update(item)
    }
    private func printDocument() {
        commands.flush(); guard let item else { return }
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Print-" + UUID().uuidString + ".pdf")
            try NotebookArchive.exportPDF(item: item, directory: store.directory(bookID), to: url)
            let controller = UIPrintInteractionController.shared
            controller.printingItem = url; controller.present(animated: true)
        } catch { store.error = error.localizedDescription }
    }
    private func bookmark() { guard var item, item.pages.indices.contains(pageIndex) else { return }; item.pages[pageIndex].bookmarked.toggle(); store.update(item) }
    private func export(_ kind: ExportKind, currentPage: Bool = false) {
        commands.flush(); guard var item else { return }
        if currentPage, let page { item.pages = [page] }
        do {
            let ext = kind == .pdf ? "pdf" : (kind == .original ? "goodnotes" : "nullmini")
            let name = item.title.replacingOccurrences(of:"/",with:"-").replacingOccurrences(of:"\\",with:"-")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name+"."+ext)
            switch kind {
            case .pdf: try NotebookArchive.exportPDF(item:item,directory:store.directory(bookID),to:url)
            case .native: try NotebookArchive.exportNative(item:item,directory:store.directory(bookID),to:url)
            case .original: try NotebookArchive.exportOriginal(directory:store.directory(bookID),to:url)
            }
            shareURL = url
        } catch { store.error = error.localizedDescription }
    }
    @ViewBuilder private func sheet(_ p:EditorPanel) -> some View {
        NavigationStack {
            Group {
                switch p {
                case .pages,.bookmarks:
                    ScrollView { LazyVGrid(columns:[GridItem(.adaptive(minimum:140))],spacing:20) {
                        ForEach(Array((item?.pages ?? []).enumerated()),id:\.element.id) { index,p in
                            if panel != .bookmarks || p.bookmarked {
                                Button { commands.flush(); pageIndex = index; panel = nil } label: {
                                    VStack { RoundedRectangle(cornerRadius:6).fill(.white).frame(width:110,height:145).overlay { Image(systemName:p.bookmarked ? "bookmark.fill" : "doc.text").font(.largeTitle).foregroundStyle(Theme.toolbar) }.shadow(color:.black.opacity(0.08),radius:5); Text("Seite \(index+1)").font(.caption) }.padding(10).background(index == pageIndex ? Theme.accent.opacity(0.18) : .clear,in:RoundedRectangle(cornerRadius:10))
                                }
                            }
                        }
                    }.padding() }.background(Theme.library)
                case .search:
                    List { TextField("Text in PDF-Hintergründen suchen",text:$query).onSubmit { searchPDF() }; ForEach(Array(searchResults.enumerated()),id:\.offset) { _,result in Button { pageIndex = result.0; panel = nil } label: { VStack(alignment:.leading) { Text("Seite \(result.0+1)").font(.caption).foregroundStyle(.secondary); Text(result.1).lineLimit(3) } } } }
                case .report: List(item?.warnings ?? [],id:\.self) { Text($0) }
                case .audio: ListenerView()
                case .assistant, .math: AssistantPanel(page: page, directory: store.directory(bookID), math: p == .math)
                }
            }.goodnotesSheet().navigationTitle(p.title).navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement:.confirmationAction) { Button("Fertig") { panel = nil } } }
        }.presentationDetents([.large])
    }
    private func searchPDF() {
        searchResults = []; guard let item, !query.isEmpty else { return }
        for (i,p) in item.pages.enumerated() {
            if let name = p.pdf, let doc = PDFDocument(url:store.directory(bookID).appendingPathComponent(name)), let text = doc.page(at:p.pdfPage)?.string, text.localizedCaseInsensitiveContains(query) { searchResults.append((i,text)) }
        }
    }
}
enum ExportKind { case pdf, native, original }
enum EditorPanel: String, Identifiable {
    case pages, bookmarks, search, audio, report, assistant, math
    var id: String { rawValue }
    var title: String { switch self { case .pages:return "Seiten"; case .bookmarks:return "Lesezeichen"; case .search:return "Suchen"; case .audio:return "Audio"; case .report:return "Importbericht"; case .assistant:return "Assistent"; case .math:return "Mathe-Assistenz" } }
}
@MainActor struct ShareView: UIViewControllerRepresentable {
    let url:URL
    func makeUIViewController(context:Context) -> UIActivityViewController { UIActivityViewController(activityItems:[url],applicationActivities:nil) }
    func updateUIViewController(_ uiViewController:UIActivityViewController,context:Context) {}
}
struct BucketIcon: Shape {
    func path(in r:CGRect) -> Path {
        var p = Path(); p.move(to:CGPoint(x:r.width*0.15,y:r.height*0.3)); p.addLine(to:CGPoint(x:r.width*0.27,y:r.height*0.94)); p.addQuadCurve(to:CGPoint(x:r.width*0.73,y:r.height*0.94),control:CGPoint(x:r.width*0.5,y:r.height)); p.addLine(to:CGPoint(x:r.width*0.85,y:r.height*0.3)); p.addEllipse(in:CGRect(x:r.width*0.15,y:r.height*0.2,width:r.width*0.7,height:r.height*0.2)); p.move(to:CGPoint(x:r.width*0.2,y:r.height*0.3)); p.addQuadCurve(to:CGPoint(x:r.width*0.8,y:r.height*0.3),control:CGPoint(x:r.width*0.5,y:-r.height*0.2)); return p
    }
}
