import SwiftUI

@MainActor final class InkPaletteStore: ObservableObject {
    @Published private(set) var saved: [String]
    @Published private(set) var recent: [String]
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        saved = defaults.stringArray(forKey: "nullmini.inkPalette.saved") ?? []
        recent = defaults.stringArray(forKey: "nullmini.inkPalette.recent") ?? []
    }
    func remember(_ color: String) {
        recent.removeAll { $0 == color }; recent.insert(color, at: 0)
        recent = Array(recent.prefix(24)); defaults.set(recent, forKey: "nullmini.inkPalette.recent")
    }
    func save(_ color: String) {
        if !saved.contains(color) { saved.append(color); defaults.set(saved, forKey: "nullmini.inkPalette.saved") }
        remember(color)
    }
    func remove(_ color: String) { saved.removeAll { $0 == color }; defaults.set(saved, forKey: "nullmini.inkPalette.saved") }
}

@MainActor struct InkColorPalette: View {
    @Binding var settings: ToolSettings
    @StateObject private var palette = InkPaletteStore()
    @State private var custom = Color.black
    @State private var tab = 0
    @State private var editing = false
    @State private var customSheet = false
    // Sampled from the tagged Display P3 capture IMG_0873; personal colors are loaded separately.
    private let presets = [
        "#E04F47", "#E78B42", "#F0CC4A", "#6FC35E", "#67B6D0", "#69A8F8", "#B18BE4", "#DE72AC",
        "#8E2E27", "#904424", "#8A5E1D", "#316F29", "#2B657E", "#3A5AAA", "#69469D", "#8A3B6D",
        "#FFFFFF", "#E4E2DC", "#A7A6A1", "#5D5C59", "#1D1B1B", "#FBFBFB", "#E3E5E8", "#CCCBCD"
    ].map { "display-p3:" + $0 }
    private var presetsForTool: [String] {
        if settings.tool == .geometry { return ["#FFD9DC", "#FFE3CC", "#FFF1B6", "#DFF8D8", "#D3FCF5", "#E7F2FF", "#F3EAFF", "#FFE7F5"] + Array(presets.prefix(21)) }
        return presets
    }
    private var colors: [String] { tab == 0 ? presetsForTool + palette.saved.filter { !presetsForTool.contains($0) } : (tab == 1 ? palette.saved : palette.recent) }
    private var title: String {
        if settings.tool == .marker { return "Textmarker-Farbe" }
        if [.shapes, .geometry, .elements].contains(settings.tool) { return "Farbe" }
        return settings.penStyle == .fountain ? "Füller-Farbe" : "Stift-Farbe"
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { custom = Color(hex: settings.color); customSheet = true } label: {
                    OriginalIcon(name: "newToolbar/tool_settings", size: 24).frame(width: 44, height: 44).background(Theme.pill, in: Circle()).overlay { Circle().strokeBorder(.white.opacity(0.1), lineWidth: 0.75) }
                }.accessibilityLabel("Eigene Farbe auswählen")
                Spacer(minLength: 0); Text(title).font(.system(size: 17, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8); Spacer(minLength: 0)
                Button { editing.toggle(); if editing { tab = 1 } } label: { Text(editing ? "Fertig" : "Bearbeiten").font(.system(size: 17)).padding(.horizontal, 15).frame(height: 44).background(Theme.pill, in: Capsule()).overlay { Capsule().strokeBorder(.white.opacity(0.13), lineWidth: 0.75) } }
            }.padding(10)
            Picker("Farbpalette", selection: $tab) { Text("Voreinstellungen").tag(0); Text("Angepasst").tag(1); Text("Vorherige").tag(2) }.pickerStyle(.segmented).frame(height: 32).padding(.horizontal, 25).padding(.top, 12)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(24), spacing: 24), count: 8), spacing: 24) {
                    ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                        Button {
                            if editing && tab == 1 { palette.remove(color) }
                            else { settings.color = color; palette.remember(color) }
                        } label: {
                            Circle().fill(Color(hex: color)).frame(width: 24, height: 24)
                                .overlay { if settings.color == color { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(UIColor(hex: color).isLight ? .black : .white) } }
                                .overlay(alignment: .topTrailing) { if editing && tab == 1 { Image(systemName: "minus.circle.fill").font(.system(size: 13)).foregroundStyle(.white, .red).offset(x: 5, y: -5) } }
                        }.accessibilityLabel(color).accessibilityAddTraits(settings.color == color ? .isSelected : [])
                    }
                    if tab != 2 {
                        Button { custom = Color(hex: settings.color); customSheet = true } label: { Circle().strokeBorder(Theme.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])).frame(width: 24, height: 24).overlay { Image(systemName: "plus").font(.system(size: 12)).foregroundStyle(Theme.secondary) } }.accessibilityLabel("Farbe hinzufügen")
                    }
                }.padding(.horizontal, 25).padding(.vertical, 3)
            }.frame(height: max(168, min(312, CGFloat((colors.count + (tab == 2 ? 0 : 1) + 7) / 8) * 48 - 24 + 6))).padding(.top, 27).padding(.bottom, 27)
            if settings.tool == .geometry {
                VStack(spacing: 12) {
                    Toggle("Farbig ausfüllen", isOn: $settings.fillShapes).frame(height: 32).tint(Color(hex: "#00B58B"))
                    HStack { Text("Deckkraft"); Spacer(); Text("\(Int(settings.fillOpacity * 100))%").font(.system(size: 11)) }.frame(height: 14)
                    ReferenceSlider(value: $settings.fillOpacity).frame(height: 32)
                }.font(.system(size: 14)).padding(.horizontal, 36).padding(.top, 17).padding(.bottom, 24)
            }
        }.frame(width: 410).foregroundStyle(.white).background(Theme.popover).presentationBackground(Theme.popover).presentationCompactAdaptation(.popover).buttonStyle(.plain)
            .sheet(isPresented: $customSheet) {
                NavigationStack {
                    Form { ColorPicker("Farbe", selection: $custom, supportsOpacity: false) }.goodnotesSheet().navigationTitle("Eigene Farbe")
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { customSheet = false } }; ToolbarItem(placement: .confirmationAction) { Button("Hinzufügen") { let color = UIColor(custom).displayP3Hex; palette.save(color); settings.color = color; customSheet = false } } }
                }.presentationDetents([.medium])
            }
    }
}

extension UIColor {
    var isLight: Bool {
        var white: CGFloat = 0, alpha: CGFloat = 0
        if getWhite(&white, alpha: &alpha) { return white > 0.7 }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &alpha)
        return r * 0.2126 + g * 0.7152 + b * 0.0722 > 0.7
    }
    var displayP3Hex: String {
        let target = CGColorSpace(name: CGColorSpace.displayP3)!
        guard let source = cgColor.converted(to: target, intent: .defaultIntent, options: nil), let values = source.components, values.count >= 3 else { return rgbHex }
        func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "display-p3:#%02X%02X%02X", byte(values[0]), byte(values[1]), byte(values[2]))
    }
}
