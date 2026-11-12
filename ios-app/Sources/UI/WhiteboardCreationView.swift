import SwiftUI

/// Original blueprint previews. The opaque contents.dat object graphs are never presented as editable objects.
struct WhiteboardTemplate: Identifiable {
    let name: String
    var id: String { name }
    static let sections: [(String, [WhiteboardTemplate])] = [
        ("Zusammenarbeit", ["Daily Standup", "Icebreaker", "Retrospective", "Team Meeting"]),
        ("Bildung", ["Study Board", "KWL Chart"]),
        ("Brainstorming", ["Brainstorming", "Brainstorming (Large)", "Crazy 8s", "Idea Poster", "Spider Map"]),
        ("Planung", ["Project Planning", "SWOT Analysis"]),
        ("Diagramme", ["2-Venn Diagram", "3-Venn Diagram", "Concept Map", "Flowchart"])
    ].map { ($0.0, $0.1.map { WhiteboardTemplate(name: $0) }) }

    func image(dark: Bool = false) -> UIImage? {
        guard let root = Bundle.main.resourceURL else { return nil }
        let path = root.appendingPathComponent("OriginalAssets/WhiteboardTemplates/\(name)-\(dark ? "dark" : "light").jpg")
        return UIImage(contentsOfFile: path.path)
    }

    @MainActor static func create(_ template: WhiteboardTemplate, dark: Bool, title: String, store: LibraryStore, parent: String?) async throws {
        guard let image = template.image(dark: dark) else { throw NotebookError.invalid("Die Vorlage konnte nicht geladen werden.") }
        let pdf = try DocumentMediaPDF.write([image])
        defer { try? FileManager.default.removeItem(at: pdf) }
        var item = try await NotebookArchive.importAsync(pdf, into: store, parent: parent)
        item.title = title; item.kind = .whiteboard
        store.update(item); store.open(item.id)
    }
}

struct WhiteboardCreationView: View {
    @Environment(\.dismiss) private var dismiss
    let create: (String, String, String, WhiteboardTemplate?) -> Void
    @State private var title = ""
    @State private var paper = "dotted"
    @State private var color = "#FFFFFF"
    @State private var template: WhiteboardTemplate?
    private let patterns = [("dotted", "Gepunktetes Raster"), ("grid", "Kariert"), ("lined", "Liniert"), ("blank", "Leer")]
    private var patternName: String { patterns.first { $0.0 == paper }?.1 ?? "Leer" }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 25, weight: .light)).frame(width: 44, height: 44).background(Theme.pill, in: Circle()).overlay { Circle().stroke(.white.opacity(0.1), lineWidth: 0.75) } }.accessibilityLabel("Abbrechen")
                Spacer(); Text("Neues Whiteboard").font(.system(size: 17, weight: .semibold)); Spacer()
                Button {
                    create(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Unbenanntes Whiteboard" : title, paper, color, template); dismiss()
                } label: { Image(systemName: "checkmark").font(.system(size: 27, weight: .light)).frame(width: 44, height: 44).background(Color(referenceHex: "#7CAFE7"), in: Circle()) }.accessibilityLabel("Whiteboard erstellen")
            }.padding(10)
            HStack(alignment: .top, spacing: 13) {
                VStack(spacing: 14) {
                    Text("HINTERGRUND").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    Group {
                        if let image = template?.image(dark: color == "#1B1C1C") { Image(uiImage: image).resizable().scaledToFit() }
                        else { WhiteboardBackgroundPreview(paper: paper, color: color) }
                    }.frame(width: 204, height: 152).clipShape(RoundedRectangle(cornerRadius: 14))
                    Text(template?.name ?? patternName).font(.system(size: 12)).lineLimit(1)
                    if template != nil { Text("Vorlage als festes Hintergrundbild").font(.system(size: 10)).foregroundStyle(Theme.secondary) }
                }.frame(width: 244)
                VStack(alignment: .leading, spacing: 16) {
                    VStack(spacing: 0) {
                        HStack(spacing: 16) { Text("Name"); TextField("Unbenanntes Whiteboard", text: $title) }.frame(height: 44).padding(.horizontal, 16)
                        Divider().padding(.leading, 16)
                        HStack { Text("Sprache"); Spacer(); Text("Deutsch").foregroundStyle(Theme.secondary); chevron }.frame(height: 44).padding(.horizontal, 16)
                    }.background(Theme.pill, in: RoundedRectangle(cornerRadius: 24))
                    VStack(alignment: .leading, spacing: 8) {
                        Text("HINTERGRUND").font(.system(size: 12)).foregroundStyle(Theme.secondary).padding(.leading, 16)
                        VStack(spacing: 0) {
                            Menu {
                                ForEach(patterns, id: \.0) { value, label in Button(label) { paper = value; template = nil } }
                            } label: { HStack { Text("Muster"); Spacer(); Text(patternName).foregroundStyle(Theme.secondary); Image(systemName: "chevron.up.chevron.down").font(.system(size: 13)).foregroundStyle(Theme.secondary) }.frame(height: 44).padding(.horizontal, 16) }
                            Divider().padding(.leading, 16)
                            Menu { Button("Weiß") { color = "#FFFFFF" }; Button("Dunkel") { color = "#1B1C1C" } } label: {
                                HStack { Text("Farbe"); Spacer(); Circle().fill(Color(hex: color)).frame(width: 22, height: 22); Text(color == "#FFFFFF" ? "Weiß" : "Dunkel").foregroundStyle(Theme.secondary); chevron }.frame(height: 44).padding(.horizontal, 16)
                            }
                        }.background(Theme.pill, in: RoundedRectangle(cornerRadius: 24))
                    }
                }.font(.system(size: 15)).frame(width: 340)
            }.frame(height: 214, alignment: .top).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 46).padding(.top, 36).padding(.bottom, 36)
            Divider().overlay(Theme.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text("Lege mit einer Vorlage los").font(.system(size: 20, weight: .semibold))
                    ForEach(WhiteboardTemplate.sections, id: \.0) { title, entries in
                        VStack(alignment: .leading, spacing: 28) {
                            Text(title).font(.system(size: 15, weight: .semibold)).padding(.horizontal, 20)
                            ScrollView(.horizontal) {
                                HStack(alignment: .top, spacing: 16) {
                                    ForEach(entries) { entry in
                                        Button { template = entry } label: {
                                            VStack(spacing: 14) {
                                                if let image = entry.image(dark: color == "#1B1C1C") { Image(uiImage: image).resizable().scaledToFit().frame(width: 206, height: 154.5).clipShape(RoundedRectangle(cornerRadius: 15)).overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(template?.id == entry.id ? Theme.accent : .clear, lineWidth: 3) } }
                                                Text(entry.name).font(.system(size: 12))
                                            }.frame(width: 206)
                                        }.accessibilityHint("Als festen Whiteboard-Hintergrund auswählen")
                                    }
                                }.padding(.horizontal, 20)
                            }.scrollIndicators(.hidden)
                        }.padding(.horizontal, -20)
                    }
                }.padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 30)
            }.scrollIndicators(.hidden)
        }.foregroundStyle(.white).background(Theme.popover).presentationBackground(Theme.popover).presentationCornerRadius(34).preferredColorScheme(.dark).modifier(ReferenceFormSizing()).buttonStyle(.solidPlain)
    }
    private var chevron: some View { Image(systemName: "chevron.down").font(.system(size: 12)).foregroundStyle(Theme.secondary) }
}

private struct WhiteboardBackgroundPreview: View {
    let paper: String
    let color: String
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hex: color)))
            var path = Path()
            for y in stride(from: CGFloat(15), to: size.height, by: 20) {
                if paper == "dotted" {
                    for x in stride(from: CGFloat(12), to: size.width, by: 20) { path.addEllipse(in: CGRect(x: x, y: y, width: 2, height: 2)) }
                } else if paper != "blank" { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)) }
            }
            if paper == "grid" { for x in stride(from: CGFloat(12), to: size.width, by: 20) { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)) } }
            if paper == "dotted" { context.fill(path, with: .color(Color(hex: "#DDDDDD"))) }
            else { context.stroke(path, with: .color(Color(hex: "#D0D2D3")), lineWidth: 0.5) }
        }
    }
}

@MainActor struct WhiteboardArtwork: View {
    let page: NotebookPage
    let directory: URL
    var revision = 0
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                if let catalog = OriginalAssets.library { Image("canvases/back/canvas_back", bundle: catalog).resizable().scaledToFit() }
                NotebookPreview(page: page, directory: directory, revision: revision).padding(.horizontal, geometry.size.width * 0.025).padding(.top, geometry.size.height * 0.025).padding(.bottom, geometry.size.height * 0.06)
                if let catalog = OriginalAssets.library { Image("canvases/front/canvas_front", bundle: catalog).resizable().scaledToFit().frame(width: geometry.size.width * 0.77).offset(y: 4) }
            }
        }
    }
}
