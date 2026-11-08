import SwiftUI

struct PageAddPopover: View {
    let insert: (String, Int) -> Void
    let currentPaper: String
    let paperColor: String
    let importMedia: (PageMediaKind, Int) -> Void
    @State private var position = 1
    init(currentPaper: String = "grid", paperColor: String = "#FFFFFF", importMedia: @escaping (PageMediaKind, Int) -> Void = { _, _ in }, insert: @escaping (String, Int) -> Void) { self.currentPaper = currentPaper; self.paperColor = paperColor; self.importMedia = importMedia; self.insert = insert }
    private var papers: [(String, String)] { [(currentPaper, "Aktuelle Vorlage"), ("lined", "Liniert schmal"), ("wide", "Liniert breit")] }
    var body: some View {
        VStack(spacing: 0) {
            Text("Seite hinzufügen").font(.system(size: 17, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 64)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Picker("Position", selection: $position) { Text("Vor dieser").tag(0); Text("Nach dieser").tag(1); Text("Letzte Seite").tag(2) }.pickerStyle(.segmented).frame(height: 32)
                    VStack(alignment: .leading, spacing: 7) { Text("Neue Vorlagen").font(.system(size: 15, weight: .semibold)); Text("Die hier gezeigten Vorlagen übernehmen wenn möglich die Eigenschaften der aktuellen Seite.").font(.system(size: 12)).foregroundStyle(Theme.secondary) }.padding(.horizontal, 8).padding(.top, 15)
                    HStack(spacing: 33) {
                        ForEach(papers, id: \.1) { paper, title in
                            Button { insert(paper, position) } label: { VStack(spacing: 16) { PaperTemplatePreview(paper: paper, color: paperColor).frame(width: 90, height: 129); Text(title).font(.system(size: 12)).lineLimit(1).minimumScaleFactor(0.85) }.frame(width: 90) }
                        }
                    }.padding(.leading, 4).padding(.top, 17)
                    VStack(spacing: 0) {
                        mediaRow(.templates, "Mehr Vorlagen …", asset: "segmentedControl/file-04")
                        mediaDivider
                        mediaRow(.photos, "Bild", asset: "images/image-01")
                        mediaDivider
                        mediaRow(.scan, "Dokumente scannen", asset: "newDocumentPopover/scan-document", catalog: OriginalAssets.toolbar, enabled: DocumentMediaPDF.canScan)
                        mediaDivider
                        mediaRow(.camera, "Foto aufnehmen", asset: "images/camera-01", enabled: DocumentMediaPDF.canUseCamera)
                        mediaDivider
                        mediaRow(.pdf, "Importieren", asset: "general/download-01")
                    }.background(Theme.pill, in: RoundedRectangle(cornerRadius: 26)).padding(.top, 28)
                }
                .padding(.horizontal, 16).padding(.bottom, 10)
            }
        }.frame(width: 390, height: 650).foregroundStyle(.white).background(Theme.popover).presentationBackground(Theme.popover).presentationCompactAdaptation(.popover).buttonStyle(.plain)
    }
    private var mediaDivider: some View { Divider().overlay(Theme.border.opacity(0.45)).padding(.leading, 54).padding(.trailing, 16) }
    private func mediaRow(_ kind: PageMediaKind, _ title: String, asset: String, catalog: Bundle? = OriginalAssets.icons, enabled: Bool = true) -> some View {
        Button { importMedia(kind, position) } label: { HStack(spacing: 12) { OriginalIcon(name: asset, catalog: catalog, size: 24); Text(title).font(.system(size: 15)); Spacer() }.padding(.horizontal, 14).frame(height: 54).contentShape(Rectangle()) }.disabled(!enabled).opacity(enabled ? 1 : 0.4)
    }
}

struct ExportPopover: View {
    let exportPage: () -> Void
    let exportAll: () -> Void
    let exportNative: () -> Void
    let exportOriginal: (() -> Void)?
    let printDocument: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Teilen und Exportieren").font(.system(size: 17, weight: .semibold)).frame(maxWidth: .infinity).padding(.top, 6)
            Text("Export").font(.system(size: 13)).foregroundStyle(Theme.secondary)
            ReferenceActionGroup {
                ReferenceActionRow("Diese Seite exportieren", asset: "files/file-download-01", action: exportPage)
                ReferenceActionRow("Alle exportieren", asset: "documentActionPopover/export-document", action: exportAll)
                ReferenceActionRow("Drucken", system: "printer", action: printDocument)
            }
            Text("Notizbuch").font(.system(size: 13)).foregroundStyle(Theme.secondary)
            ReferenceActionGroup {
                ReferenceActionRow("Mit allen Bearbeitungen", asset: "files/file-06", action: exportNative)
                if let exportOriginal { ReferenceActionRow("Unverändertes Goodnotes-Original", asset: "files/file-02", action: exportOriginal) }
            }
        }.padding(17).frame(width: 320).foregroundStyle(.white).background(Theme.popover).presentationBackground(Theme.popover).presentationCompactAdaptation(.popover)
    }
}

struct DocumentMorePopover: View {
    let pageNumber: Int
    let bookmarked: Bool
    let bookmark: () -> Void
    let rename: () -> Void
    let changeTemplate: (String) -> Void
    let readOnly: Binding<Bool>
    let finger: Binding<Bool>
    let report: () -> Void
    var pageCount = 1
    var page: NotebookPage? = nil
    var directory: URL? = nil
    var pageAction: (PageMenuAction) -> Void = { _ in }
    var rotatePage: (Int) -> Void = { _ in }
    var goToPage: (Int) -> Void = { _ in }
    @State private var goingToPage = false
    @State private var pageInput = ""
    var body: some View {
        VStack(spacing: 0) {
            Text("Mehr").font(.system(size: 17, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 64)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(spacing: 0) {
                        HStack {
                            Text("Seite „\(pageNumber)“").font(.system(size: 17, weight: .medium)); Spacer()
                            Group { if let page, let directory { NotebookPreview(page: page, directory: directory) } else { PaperTemplatePreview(paper: "blank") } }.frame(width: 35, height: 48)
                        }.padding(.horizontal, 16).frame(height: 66)
                        divider(full: true)
                        Button(action: bookmark) { rowLabel(bookmarked ? "Aus Favoriten entfernen" : "Zu Favoriten hinzufügen", asset: "general/bookmark", catalog: OriginalAssets.icons) }
                        divider()
                        Button { pageAction(.copy) } label: { rowLabel("Seite kopieren", asset: "thumbnails/copy") }
                        divider()
                        Menu { Button("90° nach rechts") { rotatePage(1) }; Button("180°") { rotatePage(2) }; Button("90° nach links") { rotatePage(-1) } } label: { rowLabel("Seite drehen", asset: "thumbnails/rotate", chevron: true) }
                        divider()
                        Button { pageAction(.outline) } label: { rowLabel("Seite zur Gliederung hinzufügen", asset: "thumbnails/document-outline") }
                        divider()
                        Menu { Button("Leer") { changeTemplate("blank") }; Button("Kariert") { changeTemplate("grid") }; Button("Gepunktet") { changeTemplate("dotted") }; Button("Liniert schmal") { changeTemplate("lined") }; Button("Liniert breit") { changeTemplate("wide") } } label: { rowLabel("Vorlage wechseln", asset: "documentActionPopover/palette", catalog: OriginalAssets.icons) }
                        divider()
                        Button { pageInput = "\(pageNumber)"; goingToPage = true } label: {
                            HStack(spacing: 12) { OriginalIcon(name: "arrows/arrow-square-right", catalog: OriginalAssets.icons, size: 24); Text("Gehe zu Seite"); Spacer(); Text("(1 – \(pageCount))").foregroundStyle(Theme.secondary).font(.system(size: 13)) }.font(.system(size: 15)).padding(.horizontal, 16).frame(height: 52)
                        }
                    }.background(Theme.pill, in: RoundedRectangle(cornerRadius: 26))
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Seite leeren oder löschen").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.secondary).padding(.horizontal, 15)
                        VStack(spacing: 0) {
                            rowLabel("Bestimmte Objekte löschen", asset: "object-clear", chevron: true).opacity(0.4)
                            divider()
                            Button { pageAction(.clear) } label: { rowLabel("Seite leeren", asset: "files/file-x-03", catalog: OriginalAssets.icons) }.foregroundStyle(Color(hex: Theme.inks[0]))
                            divider()
                            Button { pageAction(.trash) } label: { rowLabel("Seite in den Papierkorb legen", asset: "thumbnails/trash") }.foregroundStyle(Color(hex: Theme.inks[0]))
                        }.background(Theme.pill, in: RoundedRectangle(cornerRadius: 26))
                    }
                    ReferenceActionGroup {
                        ReferenceActionRow("Umbenennen", asset: "general/edit-01", action: rename)
                        Toggle("Nur lesen", isOn: readOnly).font(.system(size: 15)).padding(.horizontal, 14).frame(height: 44.5)
                        Toggle("Mit Finger zeichnen", isOn: finger).font(.system(size: 15)).padding(.horizontal, 14).frame(height: 44.5)
                        ReferenceActionRow("Importbericht", asset: "general/info-circle", action: report)
                    }
                }.padding(.horizontal, 17).padding(.top, 15).padding(.bottom, 17)
            }.scrollIndicators(.hidden)
        }.frame(width: 320, height: 665).foregroundStyle(.white).background(Theme.popover).presentationBackground(Theme.popover).presentationCompactAdaptation(.popover).buttonStyle(.plain)
            .alert("Gehe zu Seite", isPresented: $goingToPage) { TextField("1 – \(pageCount)", text: $pageInput).keyboardType(.numberPad); Button("Abbrechen", role: .cancel) {}; Button("Öffnen") { if let number = Int(pageInput), (1...max(1, pageCount)).contains(number) { goToPage(number - 1) } } }
    }
    private func divider(full: Bool = false) -> some View { Divider().overlay(Theme.border.opacity(0.45)).padding(.leading, full ? 16 : 55).padding(.trailing, 16) }
    private func rowLabel(_ title: String, asset: String, catalog: Bundle? = OriginalAssets.toolbar, chevron: Bool = false) -> some View {
        HStack(spacing: 12) {
            if asset == "object-clear" { ObjectClearIcon().stroke(.white, style: StrokeStyle(lineWidth: 1.5, lineCap: .round)).frame(width: 24, height: 24) }
            else { OriginalIcon(name: asset, catalog: catalog, size: 24) }
            Text(title).lineLimit(1).minimumScaleFactor(0.85); Spacer(minLength: 0); if chevron { Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Theme.secondary) }
        }.font(.system(size: 15)).padding(.horizontal, 16).frame(height: 52).contentShape(Rectangle())
    }
}

private struct ObjectClearIcon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for origin in [CGPoint(x: 2, y: 2), CGPoint(x: 2, y: 14), CGPoint(x: 14, y: 14)] { path.addRoundedRect(in: CGRect(x: origin.x * rect.width / 24, y: origin.y * rect.height / 24, width: rect.width / 4, height: rect.height / 4), cornerSize: CGSize(width: 0.8, height: 0.8)) }
        path.move(to: CGPoint(x: rect.width * 14 / 24, y: rect.height * 2 / 24)); path.addLine(to: CGPoint(x: rect.width * 20 / 24, y: rect.height * 8 / 24))
        path.move(to: CGPoint(x: rect.width * 20 / 24, y: rect.height * 2 / 24)); path.addLine(to: CGPoint(x: rect.width * 14 / 24, y: rect.height * 8 / 24))
        return path
    }
}

struct ReferenceActionGroup<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View { VStack(spacing: 0) { content }.background(Theme.pill, in: RoundedRectangle(cornerRadius: 16)) }
}
struct ReferenceActionRow: View {
    let title: String
    var asset: String? = nil
    var system: String? = nil
    let action: () -> Void
    init(_ title: String, asset: String? = nil, system: String? = nil, action: @escaping () -> Void) { self.title = title; self.asset = asset; self.system = system; self.action = action }
    var body: some View { Button(action: action) { ReferenceRowLabel(title: title, asset: asset, system: system) }.buttonStyle(.plain) }
}
struct ReferenceRowLabel: View {
    let title: String
    var asset: String? = nil
    var system: String? = nil
    var body: some View {
        HStack(spacing: 12) {
            if let asset { OriginalIcon(name: asset, catalog: OriginalAssets.icons, size: 20) }
            else if let system { Image(systemName: system).font(.system(size: 18)).frame(width: 20) }
            Text(title).font(.system(size: 15)); Spacer()
        }.padding(.horizontal, 14).frame(height: 44.5).contentShape(Rectangle())
    }
}
