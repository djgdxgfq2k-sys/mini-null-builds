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
