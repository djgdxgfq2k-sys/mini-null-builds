import SwiftUI

@MainActor struct ToolOptionsView: View {
    let tool: EditorTool
    @Binding var settings: ToolSettings
    var initiallyScrolled = false
    var openMath: (() -> Void)? = nil
    @State private var writingAids = false
    @StateObject private var quickStyles = PenQuickStyleStore()
    @State private var penSettings = false
    @State private var managingStyles = false

    static func panelSize(for tool: EditorTool) -> CGSize {
        switch tool {
        case .pen: return CGSize(width: 393, height: 610)
        case .eraser: return CGSize(width: 393, height: 219)
        case .marker, .pencil: return CGSize(width: 393, height: 384)
        case .shapes: return CGSize(width: 393, height: 426)
        case .lasso: return CGSize(width: 393, height: 663)
        case .laser: return CGSize(width: 320, height: 178)
        default: return CGSize(width: 320, height: 200)
        }
    }
    var body: some View {
        ZStack(alignment: .top) {
            ScrollView { panelContent.padding(.top, 64) }
                .defaultScrollAnchor(initiallyScrolled ? .bottom : .top)
            Text(title).font(.system(size: 17, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 64)
                .background(LinearGradient(stops: [.init(color: Theme.popover, location: 0), .init(color: Theme.popover, location: 0.7), .init(color: Theme.popover.opacity(0), location: 1)], startPoint: .top, endPoint: .bottom))
        }.frame(width: Self.panelSize(for: tool).width, height: Self.panelSize(for: tool).height)
            .foregroundStyle(.white).background(Theme.popover).tint(Theme.accent).buttonStyle(.solidPlain)
            .presentationBackground(Theme.popover).presentationCompactAdaptation(.popover)
            .sheet(isPresented: $managingStyles) { QuickStyleManager(store: quickStyles, settings: $settings) }
    }
    @ViewBuilder private var panelContent: some View {
        switch tool {
        case .pen: penPanel
        case .eraser: eraserPanel
        case .marker: markerPanel
        case .pencil: pencilPanel
        case .shapes: shapePanel
        case .lasso: lassoPanel
        case .laser: laserPanel
        default: EmptyView()
        }
    }
    private var penPanel: some View {
        VStack(spacing: 0) {
            StrokeSample(lineWidth: 5.5, pattern: settings.strokePattern).frame(width: 200, height: 61).offset(x: -0.5, y: 0.75).frame(height: 126.5)
            HStack(spacing: 8) {
                ForEach(PenStyle.allCases, id: \.self) { style in
                    let base = "toolbar/tool_" + (style == .fountain ? "fountainpen" : (style == .brush ? "brushpen" : "ballpen"))
                    option(style.rawValue, asset: base, selectedAsset: base + "_selected_alternate", catalog: OriginalAssets.icons, size: 36, original: true, height: 96, selected: settings.penStyle == style) { settings.penStyle = style }
                }
            }.padding(.horizontal, 20)
            stabilization.padding(.horizontal, 16).padding(.top, 18.5)
            sectionTitle("Einstellungen").padding(.top, 24.5).padding(.bottom, 8)
            VStack(spacing: 0) {
                Button { penSettings = true } label: { settingsRow("Stift-Einstellungen", chevron: true) }
                    .popover(isPresented: $penSettings) { penDetail }
                rowDivider
                Button { writingAids = true } label: { settingsRow("Schreibhilfen", chevron: true) }
                    .popover(isPresented: $writingAids) { WritingAidsView(settings: $settings) }
                rowDivider
                Button { openMath?() } label: { settingsRow("Mathe-Assistenz", chevron: true) }
            }.background(Theme.pill, in: RoundedRectangle(cornerRadius: 26)).padding(.horizontal, 16)
            sectionTitle("Schnellzugriffsstile").padding(.top, 18).padding(.bottom, 12)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(quickStyles.styles) { style in
                        Button { style.apply(to: &settings) } label: {
                            VStack(spacing: 1) { StrokeSample(color: Color(hex: style.color), lineWidth: 1.5, pattern: style.pattern ?? .solid).frame(width: 24, height: 22); Text(String(format: "%.1f", style.width / 2.83464567)).font(.system(size: 7)).foregroundStyle(Theme.secondary) }.frame(width: 30, height: 36)
                        }
                    }
                    Button { quickStyles.add(settings) } label: { Image(systemName: "plus.circle.dashed").font(.system(size: 32, weight: .ultraLight)).foregroundStyle(Theme.secondary).frame(width: 36, height: 36) }.accessibilityLabel("Aktuellen Stil speichern")
                }.padding(.horizontal, 27)
            }.frame(height: 42)
            Button { managingStyles = true } label: {
                HStack { Text("Palette für Kurzbefehle verwalten"); Spacer(); Text("\(quickStyles.styles.count) \(quickStyles.styles.count == 1 ? "Stil" : "Stile")").foregroundStyle(Theme.secondary); Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Theme.secondary) }.font(.system(size: 15)).padding(.horizontal, 16).frame(height: 52)
            }.background(Theme.pill, in: Capsule()).padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 20)
        }
    }
    private var eraserPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(EraserStyle.allCases, id: \.self) { style in
                    let asset = "toolbar/tool_" + (style == .precision ? "eraser" : (style == .standard ? "segment_eraser" : "object_eraser"))
                    option(style.rawValue, asset: asset, selectedAsset: asset + "_selected_alternate", catalog: OriginalAssets.icons, size: style == .precision ? 24 : 36, original: true, height: 90, selected: settings.eraserStyle == style) { settings.eraserStyle = style }
                }
            }.padding(.horizontal, 20).padding(.top, 17)
            Text(settings.eraserStyle == .stroke ? "Ganze Striche durch einmaliges Berühren löschen" : "Lösche nur die berührten Bereiche").font(.system(size: 12)).foregroundStyle(Theme.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 31).padding(.top, 12)
        }
    }
    private var markerPanel: some View {
        VStack(spacing: 0) {
            stabilization.padding(.horizontal, 16).padding(.top, 17)
            sectionTitle("Einstellungen").padding(.top, 24).padding(.bottom, 8)
            VStack(spacing: 0) {
                toggle("Verzögerung reduzieren", value: $settings.reduceLatency)
                rowDivider
                toggle("Gerade Linie zeichnen", value: $settings.straightHighlighter)
                rowDivider
                pencilConnection
            }.background(Theme.pill, in: RoundedRectangle(cornerRadius: 26)).padding(.horizontal, 16)
        }
    }
    private var shapePanel: some View {
        VStack(spacing: 0) {
            sectionTitle("Einstellungen").padding(.top, 21).padding(.bottom, 10)
            toggle("Halten und Ausrichten erfordern", value: $settings.holdForShapes).background(Theme.pill, in: Capsule()).padding(.horizontal, 16)
            sectionTitle("Erweiterte Optionen").padding(.top, 22).padding(.bottom, 10)
            VStack(spacing: 0) { toggle("An anderen Formen ausrichten", value: $settings.roundedShapes); rowDivider; toggle("Farbig ausfüllen", value: $settings.fillShapes) }.background(Theme.pill, in: RoundedRectangle(cornerRadius: 26)).padding(.horizontal, 16)
            pencilConnection.background(Theme.pill, in: Capsule()).padding(.horizontal, 16).padding(.top, 20)
        }
    }
    private var pencilPanel: some View {
        VStack(spacing: 20) {
            penDetail.padding(.horizontal, 16)
            pencilConnection.background(Theme.pill, in: Capsule()).padding(.horizontal, 16)
        }.padding(.top, 17)
    }
    private var lassoPanel: some View {
        VStack(spacing: 0) {
            sectionTitle("Lasso-Art").padding(.top, 10).padding(.bottom, 10)
            HStack(spacing: 8) {
                option("Rechteckig", asset: "newToolbar/lasso/lasso_mode_rectangular", selectedAsset: "newToolbar/lasso/lasso_mode_rectangular_selected", size: 22, height: 90, selected: settings.rectangularLasso) { settings.rectangularLasso = true }
                option("Freihand", asset: "newToolbar/lasso/lasso_mode_freehand", selectedAsset: "newToolbar/lasso/lasso_mode_freehand_selected", size: 22, height: 90, selected: !settings.rectangularLasso) { settings.rectangularLasso = false }
            }.padding(.horizontal, 20)
            sectionTitle("In Auswahl inbegriffen").padding(.top, 17.5).padding(.bottom, 10)
            VStack(spacing: 0) {
                toggle("Handschrift", value: $settings.selectHandwriting); rowDivider
                toggle("Bilder", value: $settings.selectImages); rowDivider
                toggle("Formen", value: $settings.selectShapes); rowDivider
                toggle("Pfeile", value: $settings.selectArrows); rowDivider
                toggle("Textfelder", value: $settings.selectText); rowDivider
                toggle("Gleichungen", value: $settings.selectEquations); rowDivider
                toggle("Tape", value: $settings.selectTape); rowDivider
                toggle("Notizzettel", value: $settings.selectNotes)
            }.background(Theme.pill, in: RoundedRectangle(cornerRadius: 26)).padding(.horizontal, 16).padding(.bottom, 11)
        }
    }
    private var laserPanel: some View {
        HStack(spacing: 8) {
            option("Punkt", asset: "newToolbar/laser_pointer_dot", size: 33, original: true, height: 88, selected: !settings.laserTrail) { settings.laserTrail = false }
            option("Linie", asset: "newToolbar/laser_pointer_trail", size: 33, original: true, height: 88, selected: settings.laserTrail) { settings.laserTrail = true }
        }.padding(.horizontal, 16).padding(.top, 8)
    }
    private var title: String {
        switch tool { case .pen: return settings.penStyle.rawValue; case .eraser: return "Radierertyp"; case .shapes: return "Draw Shape"; case .lasso: return "Lasso-Werkzeug"; default: return tool.label }
    }
    private func option(_ title: String, asset: String, selectedAsset: String? = nil, catalog: Bundle? = OriginalAssets.toolbar, size: CGFloat = 24, original: Bool = false, height: CGFloat, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                ZStack {
                    if selected && asset.contains("lasso_mode"), let selectedAsset {
                        OriginalIcon(name: selectedAsset, catalog: catalog, size: size).foregroundStyle(Color(referenceHex: "#00666A"))
                        OriginalIcon(name: asset, catalog: catalog, size: size).foregroundStyle(.white)
                    } else {
                        OriginalIcon(name: selected ? (selectedAsset ?? asset) : asset, catalog: catalog, size: size, original: original || (selected && selectedAsset != nil)).foregroundStyle(Color(referenceHex: "#CFD8E4"))
                    }
                }.frame(height: 36).offset(y: asset.contains("lasso_mode") ? 4.5 : (asset.contains("eraser") ? 5 : 0))
                Text(title).font(.system(size: 10.5)).lineLimit(1).minimumScaleFactor(0.8)
            }.frame(maxWidth: .infinity).frame(height: height).background(selected ? Theme.pill : .clear, in: RoundedRectangle(cornerRadius: 23))
        }.accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var stabilization: some View {
        let value = Binding(get: { tool == .marker ? settings.highlighterStabilization : settings.stabilization }, set: { if tool == .marker { settings.highlighterStabilization = $0 } else { settings.stabilization = $0 } })
        return VStack(spacing: 2) {
            HStack { Text("STRICH-STABILISIERUNG"); Spacer(); Text("\(Int(value.wrappedValue * 100))%") }.font(.system(size: 10.5)).frame(height: 13)
            ReferenceSlider(value: value, knobSize: CGSize(width: 36, height: 24), trackThickness: 2, minimumColor: UIColor(hex: "display-p3:#5394DB"), maximumColor: UIColor(hex: "display-p3:#444748")).frame(height: 30)
        }.padding(.horizontal, 16).frame(height: 62).background(Theme.pill, in: Capsule())
    }
    private var pencilConnection: some View {
        Button { settings.pencilConnected.toggle(); settings.finger = !settings.pencilConnected } label: { settingsRow(settings.pencilConnected ? "Apple Pencil trennen" : "Apple Pencil verbinden") }
    }
    private var penDetail: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Stift-Einstellungen").font(.system(size: 17, weight: .semibold))
            if tool == .pen && settings.penStyle == .ballpoint { Text("Der Kugelschreiber schreibt mit gleichbleibender Strichstärke.").font(.system(size: 13)).foregroundStyle(Theme.secondary) }
            Text("Druckempfindlichkeit"); Slider(value: $settings.pressure).disabled(tool == .pen && settings.penStyle == .ballpoint)
            Text("Schärfe der Spitze"); Slider(value: $settings.sharpness).disabled(tool == .pencil || settings.penStyle == .ballpoint)
            if tool != .pencil && settings.penStyle == .fountain { Text("Rundung der Spitze"); Slider(value: $settings.tipRoundness) }
            if tool != .pencil && settings.penStyle != .ballpoint {
                Toggle("Stärke nach Geschwindigkeit einstellen", isOn: $settings.reactToSpeed)
                Toggle("Auf Stiftdrehung reagieren", isOn: $settings.barrelRoll)
            }
            Toggle("Zeichnen und halten", isOn: $settings.drawAndHold)
            Toggle("Finger und passive Stifte", isOn: $settings.finger)
            Picker("Drucksensor", selection: $settings.pressureMode) { ForEach(StylusPressureMode.allCases, id: \.self) { mode in Text(mode.rawValue).tag(mode) } }
            Toggle("Einfache Apple-Stifte (Notfall)", isOn: $settings.appleInk)
            Text("Nur einschalten, falls der Stift nicht schreibt. Dann fehlen Stiftarten, Druck und Glättung.").font(.system(size: 11)).foregroundStyle(Theme.secondary)
        }.padding(20).frame(width: 320).background(Theme.popover).presentationBackground(Theme.popover)
    }
    private func sectionTitle(_ title: String) -> some View { Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.secondary).frame(maxWidth: .infinity, alignment: .leading).frame(height: 18).padding(.horizontal, 31) }
    private func settingsRow(_ title: String, chevron: Bool = false) -> some View { HStack { Text(title); Spacer(); if chevron { Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Theme.secondary) } }.font(.system(size: 15)).padding(.horizontal, 16).frame(height: 52) }
    private var rowDivider: some View { Color.clear.frame(height: 0).overlay { Rectangle().fill(Color(referenceHex: "#414343")).frame(height: 0.5).padding(.horizontal, 16) } }
    private func toggle(_ title: String, value: Binding<Bool>) -> some View { Toggle(title, isOn: value).font(.system(size: 15)).tint(Color(referenceHex: "#51B27C")).padding(.horizontal, 16).frame(height: 52) }
}
