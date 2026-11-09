import SwiftUI

struct WritingToolMenu: View {
    let pencil: () -> Void
    let customize: () -> Void
    var tape: () -> Void = {}
    var body: some View {
        VStack(spacing: 16) {
            Text("Schreibwerkzeug").font(.system(size: 17, weight: .semibold)).frame(height: 32)
            VStack(spacing: 0) {
                Button(action: pencil) { row("Bleistift", asset: "newToolbar/writing_tools/tools/pencil") }
                Divider().overlay(Theme.border.opacity(0.4)).padding(.leading, 46)
                Button(action: tape) { row("Tape", asset: "newToolbar/writing_tools/tools/tape") }
            }.background(Theme.pill, in: RoundedRectangle(cornerRadius: 24))
            Button(action: customize) { Text("Werkzeugleiste anpassen").font(.system(size: 15)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).frame(height: 44) }.background(Theme.pill, in: Capsule())
        }.padding(16).frame(width: 320).foregroundStyle(.white).background(Theme.popover).presentationBackground(Theme.popover).presentationCompactAdaptation(.popover).buttonStyle(.solidPlain)
    }
    private func row(_ label: String, asset: String) -> some View { HStack(spacing: 12) { OriginalIcon(name: asset, size: 24); Text(label).font(.system(size: 15)); Spacer() }.padding(.horizontal, 14).frame(height: 44) }
}

struct ToolbarCustomizationView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var settings: ToolSettings
    private let tools: [EditorTool] = [.lasso, .pen, .eraser, .geometry, .laser]
    private let extras = [("text", "Text"), ("elements", "Elemente"), ("image", "Bilder"), ("sticky", "Notizzettel"), ("audio", "Aufnahmen"), ("accessories", "Zubehör")]
    var body: some View {
        NavigationStack {
            Form {
                Section("Werkzeuge") {
                    ForEach(tools, id: \.self) { tool in
                        Toggle(tool == .pen ? "Schreibwerkzeuge" : tool.label, isOn: Binding(get: { settings.toolbarTools.contains(tool) }, set: { if $0 { settings.toolbarTools.insert(tool) } else { settings.toolbarTools.remove(tool) } }))
                    }
                    ForEach(extras, id: \.0) { key, label in
                        Toggle(label, isOn: Binding(get: { !settings.hiddenToolbarItems.contains(key) }, set: { if $0 { settings.hiddenToolbarItems.remove(key) } else { settings.hiddenToolbarItems.insert(key) } }))
                    }
                }
                Section { Button("Standard wiederherstellen") { settings.toolbarTools = Set(tools); settings.hiddenToolbarItems = [] } }
                    footer: { Text("Tipp: Halte die Werkzeugleiste gedrückt, um sie jederzeit anzupassen.") }
            }.goodnotesSheet().navigationTitle("Werkzeugleiste").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
        }.presentationDetents([.medium])
    }
}
