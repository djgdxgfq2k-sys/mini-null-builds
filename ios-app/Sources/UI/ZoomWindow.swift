import SwiftUI
import PencilKit

/// Zoom-Ansicht: a magnified strip at the bottom of the screen that writes into a small box on the page.
/// Writing large in the strip lays down small, neat strokes on the page. The arrows move the box along
/// the line; the return key jumps to the start of the next line.
@MainActor final class ZoomState: ObservableObject {
    @Published var visible = false
    /// Top-left of the source box in page coordinates.
    @Published var origin = CGPoint(x: 40, y: 80)
    @Published var magnification: CGFloat = 3
    @Published var revision = 0
    let margin: CGFloat = 40
}

struct ZoomPanel: View {
    @ObservedObject var state: ZoomState
    let commands: CanvasCommands
    let settings: ToolSettings
    let page: NotebookPage
    let directory: URL
    @State private var pageImage: UIImage?
    @State private var inkImage: UIImage?
    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height - 44
            let source = CGRect(origin: state.origin, size: CGSize(width: geo.size.width / state.magnification, height: height / state.magnification))
            VStack(spacing: 0) {
                HStack(spacing: 18) {
                    Image(systemName: "plus.magnifyingglass").foregroundStyle(Theme.accent)
                    Menu { ForEach([2.0, 3.0, 4.0, 5.0], id: \.self) { m in Button("\(Int(m))×") { state.magnification = m } } } label: { Text("\(Int(state.magnification))×").font(.system(size: 15, weight: .semibold)) }
                    Spacer()
                    Button { move(&state.origin, dx: -source.width * 0.8, source: source) } label: { Image(systemName: "arrow.left") }.accessibilityLabel("Nach links")
                    Button { move(&state.origin, dx: source.width * 0.8, source: source) } label: { Image(systemName: "arrow.right") }.accessibilityLabel("Nach rechts")
                    Button { state.origin = CGPoint(x: state.margin, y: min(page.size.height - source.height, state.origin.y + source.height)) } label: { Image(systemName: "return") }.accessibilityLabel("Nächste Zeile")
                    Button { state.origin.y = max(0, state.origin.y - source.height) } label: { Image(systemName: "arrow.up") }.accessibilityLabel("Nach oben")
                    Button { withAnimation(.easeInOut(duration: 0.2)) { state.visible = false } } label: { Image(systemName: "xmark") }.accessibilityLabel("Zoom-Ansicht schließen")
                }.font(.system(size: 17)).foregroundStyle(.white).padding(.horizontal, 18).frame(height: 44).background(Theme.toolbar).buttonStyle(.solidPlain)
                ZStack(alignment: .topLeading) {
                    Color.white
                    if let pageImage {
                        Image(uiImage: pageImage).resizable().frame(width: page.size.width * state.magnification, height: page.size.height * state.magnification)
                            .offset(x: -source.minX * state.magnification, y: -source.minY * state.magnification)
                    }
                    if let inkImage { Image(uiImage: inkImage).resizable().frame(width: geo.size.width, height: height) }
                    ZoomInput(source: source, scale: state.magnification, settings: settings) { strokes in
                        commands.append(strokes)
                        // Writing near the right edge slides the box on, like the original.
                        if let last = strokes.last?.path.last?.location, last.x > source.maxX - source.width * 0.2 { move(&state.origin, dx: source.width * 0.6, source: source) }
                        DispatchQueue.main.async { state.revision += 1 }
                    }
                }.frame(width: geo.size.width, height: height).clipped()
            }
            .task(id: page) { pageImage = await Task.detached { try? NotebookThumbnail.render(page: page, directory: directory, width: min(4000, page.size.width * 3)) }.value }
            .task(id: "\(state.revision)-\(source.debugDescription)") {
                let drawing = commands.snapshot()
                let scale = state.magnification * UIScreen.main.scale
                inkImage = drawing.paperImage(from: source, scale: scale)
            }
        }.background(Color.white).overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 0.5) }
    }
    private func move(_ origin: inout CGPoint, dx: CGFloat, source: CGRect) {
        var x = origin.x + dx, y = origin.y
        if x + source.width > page.size.width { x = state.margin; y = min(page.size.height - source.height, y + source.height) }
        origin = CGPoint(x: max(0, min(page.size.width - source.width, x)), y: max(0, y))
    }
}

/// Collects Pencil (and finger, when finger drawing is on) input and turns it into ink in page coordinates.
struct ZoomInput: UIViewRepresentable {
    let source: CGRect
    let scale: CGFloat
    let settings: ToolSettings
    let commit: ([PKStroke]) -> Void
    func makeUIView(context: Context) -> ZoomInputView { let v = ZoomInputView(); v.backgroundColor = .clear; v.isMultipleTouchEnabled = false; return v }
    func updateUIView(_ view: ZoomInputView, context: Context) { view.source = source; view.scale = scale; view.settings = settings; view.commit = commit }
}

final class ZoomInputView: UIView {
    var source = CGRect.zero, scale: CGFloat = 3, settings = ToolSettings(), commit: ([PKStroke]) -> Void = { _ in }
    private var samples: [InkSample] = []
    private let preview = CAShapeLayer()
    override init(frame: CGRect) {
        super.init(frame: frame)
        preview.fillColor = nil; preview.lineCap = .round; preview.lineJoin = .round; layer.addSublayer(preview)
    }
    required init?(coder: NSCoder) { nil }
    private func accepts(_ touch: UITouch) -> Bool { touch.type == .pencil || settings.finger || !settings.pencilConnected }
    private func sample(_ touch: UITouch) -> InkSample {
        let p = touch.preciseLocation(in: self)
        return InkSample(point: CGPoint(x: source.minX + p.x / scale, y: source.minY + p.y / scale), time: touch.timestamp,
                         force: touch.type == .pencil && touch.maximumPossibleForce > 0 ? min(1, touch.force / max(0.001, touch.maximumPossibleForce)) : 0.5,
                         altitude: touch.altitudeAngle, azimuth: touch.azimuthAngle(in: self))
    }
    private func redraw() {
        let path = UIBezierPath()
        for (i, s) in samples.enumerated() {
            let p = CGPoint(x: (s.point.x - source.minX) * scale, y: (s.point.y - source.minY) * scale)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        preview.path = path.cgPath
        preview.strokeColor = UIColor(hex: settings.color).withAlphaComponent(settings.tool == .marker ? 0.35 : 1).cgColor
        preview.lineWidth = max(1, (settings.tool == .marker ? max(12, settings.width * 6) : settings.width) * scale)
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first, accepts(t), [.pen, .pencil, .marker, .shapes].contains(settings.tool) else { return }
        samples = [sample(t)]; redraw()
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first, !samples.isEmpty else { return }
        samples += (event?.coalescedTouches(for: t) ?? [t]).map(sample); redraw()
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !samples.isEmpty else { return }
        let strokes = InkBuilder.strokes(samples, settings: settings, creationDate: Date(), seed: UInt32.random(in: 0 ... .max))
        samples = []
        if !strokes.isEmpty { commit(strokes) }
        // Keep the wet line until the page snapshot underneath has caught up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in if self?.samples.isEmpty == true { self?.preview.path = nil } }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { samples = []; preview.path = nil }
}
