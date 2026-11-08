import SwiftUI

/// Timings measured frame by frame from the original toolbar.mp4 (25 fps).
enum EditorMotion {
    /// Selected-tool highlight cross-fades from the old to the new tool in about 3–4 frames.
    static let selection = Animation.easeInOut(duration: 0.15)
    /// The floating sub-toolbar fades in, cross-fades its contents and resizes its width in about 4 frames, without sliding.
    static let subbar = Animation.easeInOut(duration: 0.16)
}

/// Top-bar buttons show a translucent rounded highlight while pressed, then fade it out.
struct ToolbarPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 11).fill(Color.white.opacity(configuration.isPressed ? 0.28 : 0))
                    .frame(width: 36, height: 36)
            }
            .contentShape(Rectangle())
            .animation(.easeOut(duration: configuration.isPressed ? 0.05 : 0.12), value: configuration.isPressed)
    }
}

/// Writing-tool artwork as the original composes it: an unselected outline, or when selected the
/// `_selected_body` artwork with the `_selected_color_*` nib layer tinted in the current ink color.
struct WritingToolIcon: View {
    let base: String
    let selected: Bool
    let color: String
    let colorLayer: String
    var size: CGFloat = 24
    var body: some View {
        ZStack {
            if selected && !colorLayer.isEmpty && OriginalAssets.image(base + "_selected_body", in: OriginalAssets.toolbar) != nil {
                OriginalIcon(name: base + "_selected_body", size: size, original: true)
                OriginalIcon(name: base + colorLayer, size: size).foregroundStyle(Color(hex: color))
            } else if selected, OriginalAssets.image(base + "_selected", in: OriginalAssets.toolbar) != nil {
                OriginalIcon(name: base + "_selected", size: size, original: true)
            } else {
                OriginalIcon(name: base, size: size)
            }
        }.frame(width: 32, height: 32)
    }
}
