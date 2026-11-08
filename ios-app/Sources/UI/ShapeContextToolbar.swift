import SwiftUI

struct ShapeContextToolbar: View {
    @Binding var settings: ToolSettings
    @State private var strokeOptions = false
    @State private var colorOptions = false
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(GeometricShape.allCases.enumerated()), id: \.element) { index, shape in
                Button { settings.geometricShape = shape } label: {
                    OriginalIcon(name: shape.asset, size: 24).frame(width: 36, height: 36).background(settings.geometricShape == shape ? Color(referenceHex: "#484A4D") : .clear, in: RoundedRectangle(cornerRadius: 11)).frame(width: 44, height: 45)
                }.accessibilityLabel(shape.label).accessibilityAddTraits(settings.geometricShape == shape ? .isSelected : [])
                if index == 2 || index == 7 { Rectangle().fill(Theme.border).frame(width: 0.5, height: 28).padding(.horizontal, 3.75) }
            }
            Button { strokeOptions = true } label: {
                VStack(spacing: 5) { Capsule().frame(width: 17, height: 1); Capsule().frame(width: 17, height: 2); Capsule().frame(width: 11, height: 3) }.frame(width: 44, height: 45)
            }.accessibilityLabel("Stricheinstellungen").popover(isPresented: $strokeOptions) { StrokeOptionsPopover(settings: $settings) }
            Button { colorOptions = true } label: { Circle().fill(Color(hex: settings.color)).frame(width: 20, height: 20).overlay { Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(UIColor(hex: settings.color).isLight ? .gray : .white) }.frame(width: 44, height: 45) }.accessibilityLabel("Farbe und Füllung")
                .popover(isPresented: $colorOptions) { InkColorPalette(settings: $settings) }
        }.padding(.horizontal, 1.5).foregroundStyle(.white)
    }
}

struct StrokeOptionsPopover: View {
    @Binding var settings: ToolSettings
    var presetIndex: Int? = nil
    private var supportsPattern: Bool { [.pen, .pencil, .marker, .geometry, .shapes].contains(settings.tool) }
    var body: some View {
        VStack(spacing: 0) {
            HStack { OriginalIcon(name: "newToolbar/tool_settings", size: 24).frame(width: 44, height: 44).background(Theme.pill, in: Circle()).overlay { Circle().strokeBorder(.white.opacity(0.1), lineWidth: 0.75) }; Spacer(); Text("Stricheinstellungen").font(.system(size: 17, weight: .semibold)); Spacer() }.padding(10)
            HStack(spacing: 4) {
                ForEach(StrokePattern.allCases, id: \.self) { pattern in
                    Button { settings.strokePattern = pattern } label: {
                        VStack(spacing: 27) {
                            Path { path in path.move(to: CGPoint(x: 0, y: 2)); path.addLine(to: CGPoint(x: 17, y: 2)) }.stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.7, dash: pattern == .solid ? [] : (pattern == .dashed ? [3, 2.5] : [1, 2.5]))).frame(width: 17, height: 4)
                            Text(pattern.rawValue).font(.system(size: 11)).lineLimit(1).frame(width: 70)
                        }.frame(maxWidth: .infinity).frame(height: 94).background((supportsPattern ? settings.strokePattern == pattern : pattern == .solid) ? Theme.pill : .clear, in: RoundedRectangle(cornerRadius: 22))
                    }.disabled(pattern != .solid && !supportsPattern).opacity(pattern == .solid || supportsPattern ? 1 : 0.4).accessibilityAddTraits(settings.strokePattern == pattern ? .isSelected : [])
                }
            }.padding(.horizontal, 12).padding(.top, 13)
            Text("STÄRKE DES STIFTES").font(.system(size: 12)).foregroundStyle(Theme.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 27).padding(.top, 32)
            HStack(spacing: 18) {
                Text(String(format: "%.2f mm", locale: Locale(identifier: "de_DE"), Double(settings.width / 2.83464567))).font(.system(size: 11)).frame(width: 64, alignment: .leading)
                ReferenceSlider(value: Binding(get: { Double(settings.width / 2.83464567) }, set: { value in settings.width = CGFloat(value) * 2.83464567; if let presetIndex, settings.widthPresets.indices.contains(presetIndex) { settings.widthPresets[presetIndex] = settings.width } }), range: 0.05...3, tapered: true)
            }.padding(.horizontal, 27).frame(height: 44).padding(.top, 8).padding(.bottom, 20)
        }.frame(width: 320).foregroundStyle(.white).background(Theme.popover).presentationBackground(Theme.popover).presentationCompactAdaptation(.popover).buttonStyle(.plain)
    }
}

struct ReferenceSlider: UIViewRepresentable {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var tapered = false
    var knobSize: CGSize? = nil
    var trackThickness: CGFloat = 1
    var minimumColor = UIColor(hex: "#208BC8")
    var maximumColor = UIColor(hex: "#393B3E")
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> ReferenceUISlider {
        let slider = ReferenceUISlider(); slider.tapered = tapered; slider.trackThickness = trackThickness
        slider.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        let size = knobSize ?? (tapered ? CGSize(width: 28, height: 28) : CGSize(width: 24, height: 14))
        let image = UIGraphicsImageRenderer(size: size).image { _ in UIColor.white.setFill(); UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2).fill() }
        slider.setThumbImage(image, for: .normal); slider.setThumbImage(image, for: .highlighted)
        updateUIView(slider, context: context); return slider
    }
    func updateUIView(_ slider: ReferenceUISlider, context: Context) {
        context.coordinator.parent = self
        slider.minimumValue = Float(range.lowerBound); slider.maximumValue = Float(range.upperBound)
        slider.setValue(Float(value), animated: false)
        slider.minimumTrackTintColor = tapered ? .clear : minimumColor
        slider.maximumTrackTintColor = tapered ? .clear : maximumColor
    }
    final class Coordinator: NSObject {
        var parent: ReferenceSlider
        init(_ parent: ReferenceSlider) { self.parent = parent }
        @objc func changed(_ slider: UISlider) { parent.value = Double(slider.value) }
    }
}

final class ReferenceUISlider: UISlider {
    var tapered = false
    var trackThickness: CGFloat = 1
    override func trackRect(forBounds bounds: CGRect) -> CGRect { CGRect(x: 0, y: bounds.midY - trackThickness / 2, width: bounds.width, height: trackThickness) }
    override func draw(_ rect: CGRect) {
        if tapered {
            let y = bounds.midY, w = bounds.width
            let path = UIBezierPath(); path.move(to: CGPoint(x: 0, y: y - 0.5)); path.addLine(to: CGPoint(x: w - 5, y: y - 5)); path.addQuadCurve(to: CGPoint(x: w - 5, y: y + 5), controlPoint: CGPoint(x: w + 5, y: y)); path.addLine(to: CGPoint(x: 0, y: y + 0.5)); path.close(); UIColor.white.setFill(); path.fill()
        }
        super.draw(rect)
    }
}
