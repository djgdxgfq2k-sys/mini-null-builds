import SwiftUI
import UIKit

struct PencilToolHistory {
    private(set) var previous = EditorTool.eraser
    private(set) var lastNonEraser = EditorTool.pen

    mutating func record(from old: EditorTool, to new: EditorTool) {
        guard old != new else { return }
        previous = old
        if old != .eraser { lastNonEraser = old }
    }
    func tool(for action: UIPencilPreferredAction, current: EditorTool) -> EditorTool? {
        switch action {
        case .switchEraser: return current == .eraser ? lastNonEraser : .eraser
        case .switchPrevious: return previous == current ? nil : previous
        default: return nil
        }
    }
}

/// One interaction for the editor, including when a native eraser or lasso is active.
/// The transparent view never takes canvas touches away from the input surface.
@MainActor struct PencilGestureView: UIViewRepresentable {
    var enabled: Bool
    var perform: (UIPencilPreferredAction, CGPoint?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(perform: perform) }
    func makeUIView(context: Context) -> PassthroughView {
        let view = PassthroughView()
        let interaction = UIPencilInteraction()
        interaction.delegate = context.coordinator
        view.addInteraction(interaction)
        return view
    }
    func updateUIView(_ view: PassthroughView, context: Context) {
        context.coordinator.perform = perform
        for interaction in view.interactions { (interaction as? UIPencilInteraction)?.isEnabled = enabled }
    }
    final class PassthroughView: UIView {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
    }
    final class Coordinator: NSObject, UIPencilInteractionDelegate {
        var perform: (UIPencilPreferredAction, CGPoint?) -> Void
        init(perform: @escaping (UIPencilPreferredAction, CGPoint?) -> Void) { self.perform = perform }
        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            perform(UIPencilInteraction.preferredTapAction, nil)
        }
        @available(iOS 17.5, *)
        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
            perform(UIPencilInteraction.preferredTapAction, tap.hoverPose?.location)
        }
        @available(iOS 17.5, *)
        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
            guard squeeze.phase == .ended else { return }
            perform(UIPencilInteraction.preferredSqueezeAction, squeeze.hoverPose?.location)
        }
    }
}

enum PencilPalette: String, Identifiable {
    case tools, colors, attributes
    var id: String { rawValue }
    static func preferred(for action: UIPencilPreferredAction) -> PencilPalette? {
        if #available(iOS 17.5, *), action == .showContextualPalette { return .tools }
        switch action {
        case .showColorPalette: return .colors
        case .showInkAttributes: return .attributes
        default: return nil
        }
    }
    static func anchor(_ point: CGPoint?, in size: CGSize) -> UnitPoint {
        guard let point, point.x.isFinite, point.y.isFinite else { return .center }
        return UnitPoint(x: min(1, max(0, point.x / max(1, size.width))), y: min(1, max(0, point.y / max(1, size.height))))
    }
}

@MainActor struct PencilToolPalette: View {
    @Binding var settings: ToolSettings
    @ObservedObject var commands: CanvasCommands
    var showColors: () -> Void
    var showAttributes: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 2) {
                tool(.pen, asset: "toolbar/tool_ballpen")
                tool(.pencil, asset: "toolbar/tool_hb_pencil")
                tool(.marker, asset: "toolbar/tool_highlighter")
                tool(.eraser, asset: "toolbar/tool_object_eraser")
                tool(.lasso, asset: "newToolbar/lasso/lasso", catalog: OriginalAssets.toolbar)
                tool(.shapes, asset: "toolbar/tool_shapes")
            }
            HStack(spacing: 2) {
                Button { commands.undo() } label: { OriginalIcon(name: "toolbar/tool_undo").frame(width: 40, height: 40) }.disabled(!commands.canUndo).accessibilityLabel("Widerrufen")
                Button { commands.redo() } label: { OriginalIcon(name: "toolbar/tool_redo").frame(width: 40, height: 40) }.disabled(!commands.canRedo).accessibilityLabel("Wiederholen")
                ForEach(settings.widthPresets.indices, id: \.self) { index in
                    let width = settings.widthPresets[index]
                    Button { settings.width = width } label: {
                        Capsule().fill(.white).frame(width: 17, height: min(18, width)).frame(width: 40, height: 40)
                            .background(settings.width == width ? Theme.selectedRow : .clear, in: RoundedRectangle(cornerRadius: 11))
                    }.accessibilityLabel("Stärke \(width)")
                }
                Button(action: showAttributes) { OriginalIcon(name: "newToolbar/tool_settings").frame(width: 40, height: 40) }.accessibilityLabel("Werkzeug-Optionen")
            }
            HStack(spacing: 2) {
                ForEach(Theme.inks, id: \.self) { color in
                    Button { settings.color = color } label: {
                        Circle().fill(Color(hex: color)).frame(width: 22, height: 22).frame(width: 40, height: 40)
                            .background(settings.color == color ? Theme.selectedRow : .clear, in: RoundedRectangle(cornerRadius: 11))
                    }.accessibilityLabel("Farbe \(color)")
                }
                Button(action: showColors) { Image(systemName: "plus").frame(width: 40, height: 40) }.accessibilityLabel("Weitere Farben")
            }
        }.padding(10).foregroundStyle(.white).background(Theme.popover).buttonStyle(.solidPlain)
            .presentationBackground(Theme.popover).presentationCompactAdaptation(.popover)
    }
    private func tool(_ tool: EditorTool, asset: String, catalog: Bundle? = OriginalAssets.icons) -> some View {
        Button { settings.tool = tool } label: {
            OriginalIcon(name: asset, catalog: catalog, size: catalog == OriginalAssets.icons ? 36 : 24)
                .frame(width: 40, height: 40).background(settings.tool == tool ? Theme.selectedRow : .clear, in: RoundedRectangle(cornerRadius: 11))
        }.accessibilityLabel(tool.label).accessibilityAddTraits(settings.tool == tool ? .isSelected : [])
    }
}
