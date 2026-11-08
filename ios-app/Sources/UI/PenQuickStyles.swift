import SwiftUI

struct PenQuickStyle: Identifiable, Codable {
    var id = UUID().uuidString
    let color: String
    let width: Double
    let style: PenStyle
    var pressure: Double?
    var sharpness: Double?
    var roundness: Double?
    var stabilization: Double?
    var pattern: StrokePattern?
    var reactToSpeed: Bool?
    var barrelRoll: Bool?
    func apply(to settings: inout ToolSettings) {
        settings.tool = .pen; settings.penStyle = style; settings.color = color; settings.width = width
        if let pressure { settings.pressure = pressure }; if let sharpness { settings.sharpness = sharpness }
        if let roundness { settings.tipRoundness = roundness }; if let stabilization { settings.stabilization = stabilization }
        if let pattern { settings.strokePattern = pattern }; if let reactToSpeed { settings.reactToSpeed = reactToSpeed }; if let barrelRoll { settings.barrelRoll = barrelRoll }
    }
}

@MainActor final class PenQuickStyleStore: ObservableObject {
    @Published private(set) var styles: [PenQuickStyle]
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        styles = defaults.data(forKey: "nullmini.penQuickStyles").flatMap { try? JSONDecoder().decode([PenQuickStyle].self, from: $0) } ?? []
    }
    func add(_ settings: ToolSettings) { styles.append(PenQuickStyle(color: settings.color, width: settings.width, style: settings.penStyle, pressure: settings.pressure, sharpness: settings.sharpness, roundness: settings.tipRoundness, stabilization: settings.stabilization, pattern: settings.strokePattern, reactToSpeed: settings.reactToSpeed, barrelRoll: settings.barrelRoll)); save() }
    func remove(at offsets: IndexSet) { styles.remove(atOffsets: offsets); save() }
    private func save() { if let data = try? JSONEncoder().encode(styles) { defaults.set(data, forKey: "nullmini.penQuickStyles") } }
}

struct StrokeSample: View {
    var color = Color.white
    var lineWidth: CGFloat = 3.5
    var pattern = StrokePattern.solid
    var body: some View {
        Canvas { context, size in
            let inset = lineWidth / 2 + 0.5
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: inset + x * max(0, size.width - inset * 2), y: inset + y * max(0, size.height - inset * 2)) }
            // Curve measured from the original ballpoint preview in IMG_0867.
            var path = Path(); path.move(to: p(0, 0.4948))
            path.addCurve(to: p(0.1796, 0.9525), control1: p(0.076, 0.906), control2: p(0.1374, 0.9525))
            path.addCurve(to: p(0.6912, 0.0416), control1: p(0.3313, 0.9525), control2: p(0.4139, 0.0416))
            path.addCurve(to: p(1, 0.5466), control1: p(0.8723, 0.0416), control2: p(0.9995, 0.6007))
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, dash: pattern == .solid ? [] : (pattern == .dashed ? [lineWidth * 4, lineWidth * 2] : [0.01, lineWidth * 3])))
        }
    }
}

@MainActor struct QuickStyleManager: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: PenQuickStyleStore
    @Binding var settings: ToolSettings
    var body: some View {
        NavigationStack {
            List {
                ForEach(store.styles) { style in
                    Button {
                        style.apply(to: &settings); dismiss()
                    } label: { HStack(spacing: 20) { StrokeSample(color: Color(hex: style.color), lineWidth: 2, pattern: style.pattern ?? .solid).frame(width: 50, height: 20); Text(style.style.rawValue); Spacer(); Text(String(format: "%.2f mm", style.width / 2.83464567)).foregroundStyle(Theme.secondary) } }
                }.onDelete(perform: store.remove)
                Button("Aktuellen Stil hinzufügen") { store.add(settings) }
            }.goodnotesSheet().navigationTitle("Schnellzugriffsstile").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarLeading) { EditButton() }; ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
        }.presentationDetents([.medium, .large])
    }
}
