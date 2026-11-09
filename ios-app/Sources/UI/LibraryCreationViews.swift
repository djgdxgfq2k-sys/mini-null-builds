import SwiftUI

struct FolderColorGrid: View {
    let selected: String
    let action: (String) -> Void
    @State private var custom = Color.blue
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 12), count: 9), spacing: 12) {
            ForEach(ReferenceLayout.folderPalette, id: \.self) { color in
                Button { action(color) } label: {
                    Circle().fill(Color(hex: color)).frame(width: 23, height: 23)
                        .overlay { if color == selected { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white) } }
                        .background { if color == selected { Circle().fill(.white.opacity(0.08)).frame(width: 37, height: 37) } }
                }.accessibilityLabel(color).accessibilityAddTraits(color == selected ? .isSelected : [])
            }
            ColorPicker("Eigene Farbe", selection: $custom, supportsOpacity: false).labelsHidden().frame(width: 26, height: 26).opacity(0.02)
                .overlay { OriginalIcon(name: "folder-palette/rainbow", catalog: OriginalAssets.library, size: 23, original: true).allowsHitTesting(false) }
                .onChange(of: custom) { _, value in action(UIColor(value).displayP3Hex) }
        }.frame(width: 330).padding(.vertical, 10).buttonStyle(.solidPlain)
    }
}

struct FolderCreationView: View {
    @Environment(\.dismiss) private var dismiss
    let create: (String, String, String?) -> Void
    let onDismiss: (() -> Void)?
    @State private var title = ""
    @State private var color = ReferenceLayout.folderPalette[13]
    @State private var symbol: String?
    @State private var tab = 0
    init(onDismiss: (() -> Void)? = nil, create: @escaping (String, String, String?) -> Void) { self.onDismiss = onDismiss; self.create = create }
    private func close() { if let onDismiss { onDismiss() } else { dismiss() } }
    private let symbols = ["atom", "apple", "banknote", "beaker", "book", "briefcase", "building", "calculator", "codesnippet", "compass", "file", "globe", "graduation", "moonstar", "musicnote", "palette", "scales", "settings", "smile"]
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack {
                    roundButton("xmark", color: Color(hex: "#181818")) { close() }
                    Spacer(); Text("Neuer Ordner").font(.system(size: 17, weight: .semibold)); Spacer()
                    roundButton("checkmark", color: Color(referenceHex: "#3F8EF7")) { create(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Unbenannt" : title, color, symbol); close() }
                }.padding(.horizontal, 10).padding(.top, 4).offset(y: -6)
                Spacer(minLength: 20)
                FolderArtwork(color: color, symbol: symbol).frame(width: 202, height: 174).frame(width: 180, height: 155).offset(y: -3.5).padding(.bottom, 42)
                TextField("Unbenannt", text: $title).font(.system(size: 24)).multilineTextAlignment(.center)
                    .frame(height: 30).background(Color(hex: "#404040"), in: Capsule()).overlay { Capsule().stroke(.white.opacity(0.12), lineWidth: 1) }
                    .frame(maxWidth: min(geometry.size.width * 0.7, 826)).padding(.bottom, 16).offset(y: -12)
                Picker("Ordner anpassen", selection: $tab) { Text("Farbe").tag(0); Text("Icon").tag(1) }.pickerStyle(.segmented).frame(width: 358).padding(.bottom, 7).offset(y: -12)
                Group {
                    if tab == 0 { FolderColorGrid(selected: color) { color = $0 } }
                    else {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(36)), count: 8), spacing: 8) {
                            Button { symbol = nil } label: { Image(systemName: "nosign").frame(width: 30, height: 30) }
                            ForEach(symbols, id: \.self) { value in
                                let name = "folder-symbols/folder_icon_" + value
                                Button { symbol = name } label: { OriginalIcon(name: name, catalog: OriginalAssets.library, size: 25).frame(width: 36, height: 36).background(symbol == name ? Theme.selectedRow : .clear, in: RoundedRectangle(cornerRadius: 7)) }
                            }
                        }
                    }
                }.frame(height: 116).offset(y: -12)
                Spacer(minLength: 30)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.foregroundStyle(.white).background(Color(hex: "#1C1C1C").opacity(0.7).ignoresSafeArea()).preferredColorScheme(.dark)
    }
    private func roundButton(_ symbol: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 25, weight: .light)).frame(width: 44, height: 44).background(color, in: Circle()).overlay { Circle().stroke(.white.opacity(0.08), lineWidth: 0.75) } }
    }
}

enum NotebookPaperSize: String, CaseIterable {
    case a4 = "A4, Hochformat", a4Landscape = "A4, Querformat", a5 = "A5, Hochformat", letter = "Letter, Hochformat"
    var size: CGSize {
        switch self { case .a4: return CGSize(width: 595, height: 842); case .a4Landscape: return CGSize(width: 842, height: 595); case .a5: return CGSize(width: 420, height: 595); case .letter: return CGSize(width: 612, height: 792) }
    }
}

struct NotebookCreationView: View {
    @Environment(\.dismiss) private var dismiss
    let create: (String, String, String, CGSize, String?) -> Void
    @State private var title = ""
    @State private var coverOn = true
    @State private var coverColor = NotebookCover.colors[0]
    @State private var paper = "grid"
    @State private var paperColor = "#FFFFFF"
    @State private var paperSize = NotebookPaperSize.a4
    private let yellowPaper = "display-p3:#EEEEC5"
    private let darkPaper = "display-p3:#3F3B3B"
    private let papers = [("blank", "Leer"), ("dotted", "Gepunktet"), ("grid", "Kariert"), ("lined", "Liniert schmal"), ("wide", "Liniert breit")]
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 25, weight: .light)).frame(width: 44, height: 44).background(Theme.pill, in: Circle()).overlay { Circle().stroke(.white.opacity(0.1), lineWidth: 0.75) } }
                Spacer(); Text("Neues Notizbuch").font(.system(size: 17, weight: .semibold)); Spacer()
                Button { create(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Unbenanntes Notizbuch" : title, paper, paperColor, paperSize.size, coverOn ? coverColor : nil); dismiss() } label: { Image(systemName: "checkmark").font(.system(size: 27, weight: .light)).frame(width: 44, height: 44).background(Color(referenceHex: "#7CAFE7"), in: Circle()) }
            }.padding(10)
            HStack(alignment: .top, spacing: 28) {
                VStack(spacing: 0) {
                    Text("PAPIER").font(.system(size: 11)).foregroundStyle(Theme.secondary).frame(height: 13)
                    PaperTemplatePreview(paper: paper, color: paperColor, notebookCorners: true).frame(width: 126, height: 178).padding(.top, 14)
                    Text(papers.first(where: { $0.0 == paper })?.1 ?? "").font(.system(size: 14)).frame(height: 17).padding(.top, 8)
                }.padding(.top, 11).padding(.bottom, 12).frame(width: 160).background(Theme.pill, in: RoundedRectangle(cornerRadius: 24))
                    .overlay(alignment: .bottom) { Capsule().fill(Theme.libraryAccent).frame(width: 64, height: 4).offset(y: 2) }.frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 12) {
                    VStack(spacing: 0) {
                        HStack(spacing: 16) { Text("Titel"); TextField("Unbenanntes Notizbuch", text: $title) }.frame(height: 44).padding(.horizontal, 16)
                        Divider().padding(.leading, 16)
                        HStack { Text("Sprache"); Spacer(); Text("Auto Detect").foregroundStyle(Theme.secondary); Image(systemName: "chevron.down").font(.system(size: 12)).foregroundStyle(Theme.secondary) }.frame(height: 44).padding(.horizontal, 16)
                        Divider().padding(.leading, 16)
                        Toggle("Umschlag", isOn: $coverOn.animation(.easeInOut(duration: 0.2))).frame(height: 44).padding(.horizontal, 16)
                        if coverOn {
                            Divider().padding(.leading, 16)
                            HStack(spacing: 10) {
                                ForEach(NotebookCover.colors, id: \.self) { color in
                                    Button { coverColor = color } label: {
                                        RoundedRectangle(cornerRadius: 4).fill(Color(hex: color)).frame(width: 24, height: 30)
                                            .overlay(alignment: .trailing) { Rectangle().fill(.black.opacity(0.3)).frame(width: 3).padding(.trailing, 4) }
                                            .overlay { RoundedRectangle(cornerRadius: 5).stroke(coverColor == color ? Theme.accent : .clear, lineWidth: 2).padding(-3) }
                                    }.buttonStyle(.solidPlain).accessibilityLabel("Umschlagfarbe")
                                }
                            }.frame(height: 48).padding(.horizontal, 16).transition(.opacity)
                        }
                    }.font(.system(size: 15)).background(Theme.pill, in: RoundedRectangle(cornerRadius: 24))
                    Text("PAPIER-VORLAGEN").font(.system(size: 11)).tracking(0.2).foregroundStyle(Theme.secondary).padding(.leading, 16).offset(y: 5)
                    VStack(spacing: 0) {
                        Menu { ForEach(NotebookPaperSize.allCases, id: \.self) { choice in Button(choice.rawValue) { paperSize = choice } } } label: { HStack { Text("Größe"); Spacer(); Text(paperSize.rawValue).foregroundStyle(Theme.secondary); Image(systemName: "chevron.down").font(.system(size: 12)).foregroundStyle(Theme.secondary) }.frame(height: 44).padding(.horizontal, 16) }
                        Divider().padding(.leading, 16)
                        Menu { Button("Weiß") { paperColor = "#FFFFFF" }; Button("Gelb") { paperColor = yellowPaper }; Button("Dunkel") { paperColor = darkPaper } } label: { HStack { Text("Farbe"); Spacer(); Circle().fill(Color(hex: paperColor)).frame(width: 20, height: 20); Text(paperColor == "#FFFFFF" ? "Weiß" : (paperColor == yellowPaper ? "Gelb" : "Dunkel")).foregroundStyle(Theme.secondary); Image(systemName: "chevron.down").font(.system(size: 12)).foregroundStyle(Theme.secondary) }.frame(height: 44).padding(.horizontal, 16) }
                    }.font(.system(size: 15)).background(Theme.pill, in: RoundedRectangle(cornerRadius: 24))
                }.frame(width: 340).padding(.top, -4)
            }.padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 17)
            Divider().overlay(Theme.border)
            VStack(alignment: .leading, spacing: 20) {
                HStack { Text("Papier-Vorlagen").font(.system(size: 20, weight: .semibold)); Spacer(); Text("Bearbeiten").font(.system(size: 15)).foregroundStyle(Theme.accent.opacity(0.5)) }
                Text("Herkömmlich").font(.system(size: 18, weight: .semibold))
                HStack(spacing: 34) {
                    ForEach(papers, id: \.0) { value, label in
                        VStack(spacing: 12) {
                            Button { paper = value } label: {
                                VStack(spacing: 16) {
                                    PaperTemplatePreview(paper: value, color: paperColor, notebookCorners: true).frame(height: 154).overlay(alignment: .bottom) { if value == paper { Image(systemName: "checkmark.circle.fill").font(.system(size: 28)).foregroundStyle(Theme.libraryAccent).background(.white, in: Circle()).offset(y: 6) } }
                                    Text(label).font(.system(size: 12)).lineLimit(1)
                                }
                            }
                            HStack(spacing: 4) {
                                ForEach([yellowPaper, "#FFFFFF", darkPaper], id: \.self) { color in
                                    Button { paper = value; paperColor = color } label: { Circle().fill(Color(hex: color)).frame(width: 12, height: 12) }.accessibilityLabel(label + " " + color)
                                }
                            }
                        }.frame(width: 108)
                    }
                }.padding(.leading, 5).frame(width: 672, alignment: .leading).padding(.top, 3)
                Text("Weitere Vorlagen").font(.system(size: 15, weight: .semibold)).padding(.top, -4)
            }.padding(.horizontal, 20).padding(.top, 24)
            Spacer(minLength: 12)
        }.foregroundStyle(.white).background(Theme.popover).presentationBackground(Theme.popover).presentationCornerRadius(34).preferredColorScheme(.dark).modifier(ReferenceFormSizing())
    }
}

struct ReferenceFormSizing: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18.0, macCatalyst 18.0, *) {
            content.frame(minWidth: 0, idealWidth: 712, maxWidth: 712, minHeight: 0, idealHeight: 726, maxHeight: 726, alignment: .top).presentationSizing(.fitted)
        } else {
            content.frame(idealWidth: 712, idealHeight: 726, alignment: .top).presentationDetents([.height(726)])
        }
    }
}

struct PaperTemplatePreview: View {
    let paper: String
    var color = "#FFFFFF"
    var notebookCorners = false
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hex: color)))
            if paper != "blank" {
                var lines = Path()
                let scale = size.width / 595
                let gap: CGFloat = (paper == "wide" ? 25 : 16) * scale
                let top: CGFloat = paper == "grid" ? 8 * scale : (paper == "dotted" ? 15 * scale : 50 * scale)
                let bottom: CGFloat = paper == "grid" || paper == "dotted" ? size.height : min(size.height, top + size.height * 0.8)
                for y in stride(from: top, to: bottom, by: gap) {
                    if paper == "dotted" { for x in stride(from: CGFloat(10) * scale, to: size.width, by: gap) { lines.addEllipse(in: CGRect(x: x, y: y, width: scale, height: scale)) } }
                    else { lines.move(to: CGPoint(x: 0, y: y)); lines.addLine(to: CGPoint(x: size.width, y: y)) }
                }
                if paper == "grid" { for x in stride(from: CGFloat(8) * scale, to: size.width, by: gap) { lines.move(to: CGPoint(x: x, y: 0)); lines.addLine(to: CGPoint(x: x, y: size.height)) } }
                if paper == "dotted" { context.fill(lines, with: .color(.gray.opacity(0.4))) } else { context.stroke(lines, with: .color(Color(hex: "#D0D2D3")), lineWidth: 0.5 * scale) }
            }
        }.clipShape(UnevenRoundedRectangle(topLeadingRadius: notebookCorners ? 2 : 3, bottomLeadingRadius: notebookCorners ? 2 : 3, bottomTrailingRadius: notebookCorners ? 8 : 3, topTrailingRadius: notebookCorners ? 8 : 3))
    }
}

extension UIColor {
    var rgbHex: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        let source = cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil).map { UIColor(cgColor: $0) } ?? self
        source.getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }
}
