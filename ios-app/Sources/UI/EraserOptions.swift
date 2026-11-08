import SwiftUI

struct EraserContextToolbar: View {
    @Binding var settings: ToolSettings
    let selectType: () -> Void
    let clearPage: () -> Void
    @State private var advanced = false
    private var typeName: String { settings.eraserStyle == .stroke ? "Strich" : (settings.eraserStyle == .precision ? "Präzision" : "Standard") }
    private var typeAsset: String { "newToolbar/eraser/eraser_" + (settings.eraserStyle == .stroke ? "stroke" : (settings.eraserStyle == .precision ? "precision" : "standard")) }
    var body: some View {
        HStack(spacing: 0) {
            Button(action: selectType) {
                HStack(spacing: 5) { OriginalIcon(name: typeAsset, size: 24); Text(typeName).font(.system(size: 15)); Image(systemName: "chevron.down").font(.system(size: 11)).foregroundStyle(Theme.secondary) }
                    .frame(width: 118, height: 36).background(Color(hex: "#3B3D40"), in: RoundedRectangle(cornerRadius: 13.5))
            }.accessibilityLabel("Radierertyp")
            Button { advanced = true } label: { OriginalIcon(name: "newToolbar/toggles-some", size: 24).frame(width: 48, height: 45) }.accessibilityLabel("Erweiterte Einstellungen")
                .popover(isPresented: $advanced) { EraserAdvancedOptions(settings: $settings) { advanced = false; clearPage() } }
            ForEach(0..<3) { index in
                let name = ["small", "medium", "large"][index]
                Button { settings.eraserSize = index } label: {
                    OriginalIcon(name: "newToolbar/eraser_size/eraser_" + name + (settings.eraserSize == index ? "_selected" : ""), size: [24.0, 36.0, 72.0][index], original: true)
                        .offset(x: index == 2 ? 2 : 0).frame(width: [44.0, 60.0, 84.0][index], height: 45)
                }.accessibilityLabel(["Kleiner Radierer", "Mittlerer Radierer", "Großer Radierer"][index]).accessibilityAddTraits(settings.eraserSize == index ? .isSelected : [])
            }
        }.padding(.horizontal, 4).frame(width: 362, height: 45).foregroundStyle(.white).buttonStyle(.plain).clipped()
    }
}

struct EraserAdvancedOptions: View {
    @Binding var settings: ToolSettings
    let clearPage: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            Text("Erweiterte Einstellungen").font(.system(size: 17, weight: .semibold)).frame(height: 64)
            Text("RADIERERFILTER").font(.system(size: 11)).foregroundStyle(Theme.secondary).frame(maxWidth: .infinity, alignment: .leading).frame(height: 13).padding(.horizontal, 32).padding(.top, 8).padding(.bottom, 9.5)
            VStack(spacing: 0) {
                filter("Stift", asset: "fountain_pen", value: $settings.eraserFilters.pen); divider(52)
                filter("Bleistift", asset: "pencil", value: $settings.eraserFilters.pencil); divider(52)
                filter("Textmarker", asset: "highlighter", value: $settings.eraserFilters.marker); divider(52)
                filter("Tape", asset: "tape", value: $settings.eraserFilters.tape); divider(0, trailing: 0)
                Button { settings.eraserFilters = EraserFilters() } label: { row("Alle auswählen").foregroundStyle(settings.eraserFilters.allEnabled ? Color(hex: "#9C9E9E") : .white) }.disabled(settings.eraserFilters.allEnabled)
            }.background(Theme.pill, in: RoundedRectangle(cornerRadius: 32)).padding(.horizontal, 16)
            Text("Der Radierer ignoriert Eingaben aller hier\ndeaktivierten Werkzeuge.").font(.system(size: 11)).foregroundStyle(Theme.secondary).frame(maxWidth: .infinity, alignment: .leading).frame(height: 28, alignment: .top).padding(.horizontal, 32).padding(.top, 8.5)
            VStack(spacing: 0) {
                Button(action: clearPage) { row("Seite leeren").foregroundStyle(Color(referenceHex: "#E7492E")) }; divider(16)
                Toggle("Automatisch abwählen", isOn: $settings.eraserAutoDeselect).padding(.horizontal, 16).frame(height: 52); divider(16)
                Button { settings.pencilConnected.toggle(); settings.finger = !settings.pencilConnected } label: { row(settings.pencilConnected ? "Apple Pencil trennen" : "Apple Pencil verbinden") }
            }.background(Theme.pill, in: RoundedRectangle(cornerRadius: 32)).padding(.horizontal, 16).padding(.top, 14)
            Spacer(minLength: 0)
        }.font(.system(size: 15)).foregroundStyle(.white).tint(Color(referenceHex: "#51B27C")).buttonStyle(.plain).frame(width: 393, height: 588).background(.black).presentationBackground(.black).presentationCompactAdaptation(.popover)
    }
    private func filter(_ title: String, asset: String, value: Binding<Bool>) -> some View {
        HStack(spacing: 12) { OriginalIcon(name: "newToolbar/writing_tools/tools/" + asset, size: 24); Toggle(title, isOn: value) }.padding(.horizontal, 16).frame(height: 52)
    }
    private func row(_ title: String) -> some View { Text(title).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).frame(height: 52).contentShape(Rectangle()) }
    private func divider(_ leading: CGFloat, trailing: CGFloat = 16) -> some View { Rectangle().fill(Color(referenceHex: "#414343")).frame(height: 0.5).padding(.leading, leading).padding(.trailing, trailing) }
}
