import SwiftUI
import PencilKit
import PDFKit
import Combine

enum EditorTool: String, CaseIterable, Codable {
    case pen, pencil, eraser, marker, shapes, geometry, lasso, elements, text, laser, hand
    var symbol: String {
        switch self {
        case .pen: return "pencil.tip"
        case .pencil: return "pencil"
        case .eraser: return "eraser"
        case .marker: return "highlighter"
        case .shapes: return "square.on.circle"
        case .geometry: return "square.triangle.circle"
        case .lasso: return "lasso"
        case .elements: return "star.square"
        case .text: return "textformat"
        case .laser: return "laser.burst"
        case .hand: return "hand.point.up"
        }
    }
    var label: String {
        switch self {
        case .pen: return "Stift"
        case .pencil: return "Bleistift"
        case .eraser: return "Radierer"
        case .marker: return "Textmarker"
        case .shapes: return "Formen"
        case .geometry: return "Formen"
        case .lasso: return "Lasso"
        case .elements: return "Elemente"
        case .text: return "Textfeld"
        case .laser: return "Laserpointer"
        case .hand: return "Hand"
        }
    }
}
struct ToolSettings: Equatable, Codable {
    var tool = EditorTool.pen
    var color = "#000001"
    var width: CGFloat = 1
    var widthPresets: [CGFloat] = [1, 2, 4]
    var strokePattern = StrokePattern.solid
    var geometricShape = GeometricShape.ellipse
    var fillOpacity = 1.0
    var finger = false
    var readOnly = false
    var pencilConnected = true
    var pressureMode = StylusPressureMode.automatic
    var toolbarTools: Set<EditorTool> = [.lasso, .pen, .eraser, .geometry, .laser]
    /// Toolbar buttons the user switched off: "text", "elements", "image", "sticky", "audio", "accessories".
    var hiddenToolbarItems: Set<String> = []
    var stabilization = 0.22
    var highlighterStabilization = 1.0
    var reduceLatency = true
    var holdForShapes = true
    var drawAndHold = true
    var rectangularLasso = false
    var selectShapes = true
    var selectArrows = true
    var selectEquations = false
    var selectTape = false
    var selectNotes = false
    var laserTrail = true
    var penStyle = PenStyle.ballpoint
    var eraserStyle = EraserStyle.stroke
    var eraserSize = 0
    var eraserFilters = EraserFilters()
    var eraserAutoDeselect = false
    /// Emergency fallback: write with Apple's plain PencilKit pens instead of the Goodnotes stroke engine.
    var appleInk = false
    var eraserDiameter: CGFloat { [8, 16, 64][min(2, max(0, eraserSize))] }
    var pressure = 0.5
    var sharpness = 0.5
    var tipRoundness = 0.5
    var reactToSpeed = false
    var barrelRoll = false
    var highlighterOnly = false
    var straightHighlighter = false
    /// The highlighter slot is shared with tape: with `tape` set it lays opaque strips instead of ink.
    var tape = false
    var tapeColor = "#E9B949"
    var fillShapes = false
    var roundedShapes = false
    var selectHandwriting = true
    var selectImages = true
    var selectText = true
}
enum PenStyle: String, Codable, CaseIterable { case fountain = "Füllfederhalter", ballpoint = "Kugelschreiber", brush = "Pinselstift" }
enum EraserStyle: String, CaseIterable, Codable { case precision = "Präzisionsradierer", standard = "Standardradierer", stroke = "Strichradierer" }

@MainActor final class CanvasCommands: ObservableObject {
    weak var target: CanvasSurface.Coordinator? { didSet { if oldValue !== target { refreshUndo() } } }
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    var toggleKnight: (() -> Void)?
    var requestStudio: (() -> Void)?
    var reportError: (String) -> Void = { _ in }
    var didFinishErasing: (() -> Void)?
    func undo() { target?.perform { [weak self] in self?.target?.canvas?.undoManager?.undo(); self?.refreshUndo() } }
    func redo() { target?.perform { [weak self] in self?.target?.canvas?.undoManager?.redo(); self?.refreshUndo() } }
    func snapshot() -> PKDrawing { target?.drawing ?? PKDrawing() }
    func append(_ strokes: [PKStroke]) { target?.append(strokes) }
    func flush() { target?.viewport?.inkInput.finishPendingStroke(); target?.persist() }
    func addStickyNote() { target?.viewport?.addStickyNote() }
    func clear(_ kind: ClearKind) { target?.clear(kind) }
    func refreshUndo() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let undo = self.target?.canvas?.undoManager?.canUndo ?? false, redo = self.target?.canvas?.undoManager?.canRedo ?? false
            if self.canUndo != undo { self.canUndo = undo }; if self.canRedo != redo { self.canRedo = redo }
        }
    }
    func afterInput(onFailure: (() -> Void)? = nil, _ action: @escaping () -> Void) {
        if let target { target.perform { if target.persist() { action() } else { onFailure?() } } }
        else { action() }
    }
}

@MainActor struct CanvasSurface: UIViewRepresentable {
    let page: NotebookPage
    let directory: URL
    let settings: ToolSettings
    let commands: CanvasCommands

    func makeCoordinator() -> Coordinator { Coordinator(page: page, directory: directory, commands: commands) }
    func makeUIView(context: Context) -> PageViewport {
        let view = PageViewport(page: page, directory: directory)
        context.coordinator.attach(view)
        context.coordinator.configure(settings)
        return view
    }
    func updateUIView(_ view: PageViewport, context: Context) {
        // Page orientation/layout and input configuration never reload the authoritative drawing.
        view.updatePage(page)
        context.coordinator.configure(settings)
    }
    static func dismantleUIView(_ view: PageViewport, coordinator: Coordinator) {
        view.inkInput.finishPendingStroke(); coordinator.persist(); view.canvas.delegate = nil
    }

    @MainActor final class Coordinator: NSObject, PKCanvasViewDelegate, UIScrollViewDelegate {
        private(set) var drawing = PKDrawing()
        private(set) var usingTool = false
        private var queued: [() -> Void] = []
        private var inputGeneration = 0
        private var filteredEraseBefore: PKDrawing?
        private var filteredEraseChanged = false
        private var cancelledInput = false
        private var currentSettings: ToolSettings?
        private var writable = true
        private let page: NotebookPage
        private let directory: URL
        private weak var commands: CanvasCommands?
        weak var canvas: PKCanvasView?
        weak var viewport: PageViewport?
        var onActivate: (() -> Void)?
        init(page: NotebookPage, directory: URL, commands: CanvasCommands) {
            self.page = page; self.directory = directory; self.commands = commands
            super.init()
            do { drawing = try DrawingDisk.load(directory, page.id) }
            catch { writable = false; DispatchQueue.main.async { commands.reportError("Gespeicherte Zeichnung konnte nicht geladen werden. Sie wird nicht überschrieben: \(error.localizedDescription)") } }
        }
        func attach(_ view: PageViewport) {
            viewport = view; canvas = view.canvas
            // Only initialization assigns persisted state; the delegate is installed afterwards.
            view.canvas.drawing = drawing
            view.inkDetail.update(drawing)
            view.canvas.delegate = self
            view.canvas.isUserInteractionEnabled = writable
            commands?.target = self
            view.onError = { [weak self] in self?.commands?.reportError($0) }
            view.onRenderScale = { [weak self] in self?.applyTool() }
            if let error = view.textReadError { commands?.reportError(error) }
            view.onShape = { [weak self] points, closed in
                guard let self, let settings = self.currentSettings else { return }
                self.append(GeometricInk.strokes(points: points, settings: settings, closed: closed))
            }
            view.onInteraction = { [weak self] active in
                guard let self else { return }
                if active {
                    self.inputGeneration += 1; self.usingTool = true; self.cancelledInput = false; self.commands?.target = self; self.onActivate?()
                    if let settings = self.currentSettings, settings.tool == .eraser, FilteredEraser.needsOverlay(settings) { self.filteredEraseBefore = self.drawing; self.filteredEraseChanged = false }
                } else { self.finishFilteredErase(); self.finishToolUse() }
            }
            view.inkInput.onInteraction = view.onInteraction
            view.lasso.onInteraction = view.onInteraction
            view.lasso.drawing = { [weak self] in self?.drawing ?? PKDrawing() }
            view.lasso.commit = { [weak self] next in
                guard let self, self.writable, let canvas = self.canvas else { return }
                self.replaceByUserCommand(next, canvas: canvas)
            }
            view.inkInput.onCommit = { [weak self] strokes in
                guard let self, self.writable, let canvas = self.canvas, !strokes.isEmpty else { return }
                if strokes.count == 1, let probe = strokes.first, TapeInk.isProbe(probe) {
                    if let location = probe.path.first?.location, let next = TapeInk.toggled(self.drawing, at: location) { self.replaceByUserCommand(next, canvas: canvas) }
                    return
                }
                // Strokes laid along the ruler's edge come out straight.
                let strokes: [PKStroke] = MainActor.assumeIsolated {
                    guard RulerState.shared.visible, let page = self.viewport?.document else { return strokes }
                    return strokes.map { RulerState.shared.snapped($0, toWindow: { page.convert($0, to: nil) }, fromWindow: { page.convert($0, from: nil) }) ?? $0 }
                }
                self.replaceByUserCommand(PKDrawing(strokes: self.drawing.strokes + strokes), canvas: canvas)
            }
            view.inkInput.snapShape = { [weak self] shape in
                guard let self else { return shape }
                let anchors = self.drawing.strokes.flatMap { stroke -> [CGPoint] in
                    [stroke.path.first, stroke.path.last].compactMap { $0?.location.applying(stroke.transform) }
                }
                return shape.snapped(to: anchors)
            }
            view.onErase = { [weak self] points in
                guard let self, let settings = self.currentSettings, settings.tool == .eraser, !settings.readOnly else { return }
                guard let canvas = self.canvas, self.writable,
                      let next = FilteredEraser.erase(self.drawing, points: points, diameter: settings.eraserDiameter, style: settings.eraserStyle, filters: settings.eraserFilters) else { return }
                if self.filteredEraseBefore != nil {
                    // This input surface owns the gesture; native wet ink is disabled while it erases.
                    self.filteredEraseChanged = true; self.drawing = next; canvas.drawing = next
                } else { self.replaceByUserCommand(next, canvas: canvas) }
            }
            view.onEraseCancelled = { [weak self] in
                guard let self else { return }
                if let before = self.filteredEraseBefore, let canvas = self.canvas {
                    self.drawing = before; canvas.drawing = before; self.persist()
                }
                self.filteredEraseBefore = nil; self.filteredEraseChanged = false; self.cancelledInput = true
            }
            // Imported Goodnotes strokes load off the main thread so scrolling never waits on unzipping.
            if page.sourceNotes != nil {
                let source = page, folder = directory
                DispatchQueue.global(qos: .userInitiated).async { [weak view, weak self] in
                    let result = Result { try NotebookArchive.originalInk(page: source, directory: folder) }
                    DispatchQueue.main.async {
                        switch result {
                        case .success(let ink): view?.original.ink = ink
                        case .failure(let error): self?.commands?.reportError("Originalebene nicht lesbar: \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
        func configure(_ settings: ToolSettings) {
            guard settings != currentSettings, let canvas else { return }
            // Do not swap a live Pencil tool during a stroke.
            if usingTool { queued.append { [weak self] in self?.configure(settings) }; return }
            currentSettings = settings
            applyTool()
            canvas.drawingPolicy = settings.finger || !settings.pencilConnected ? .anyInput : .pencilOnly
            let drawingTouches = StylusInputPolicy.drawingTouches(finger: settings.finger, pencilConnected: settings.pencilConnected)
            canvas.drawingGestureRecognizer.allowedTouchTypes = drawingTouches.map { NSNumber(value: $0.rawValue) }
            viewport?.setTool(settings, writable: writable && !settings.readOnly)
            viewport?.scroll.panGestureRecognizer.minimumNumberOfTouches = settings.readOnly || (settings.pencilConnected && !settings.finger) ? 1 : 2
        }
        /// PencilKit sizes ink relative to the canvas's own zoom. The canvas zooms only to render sharply,
        /// so widths are multiplied by that zoom to keep strokes as thick on the page as the user chose.
        func applyTool() {
            guard let canvas, let settings = currentSettings else { return }
            if usingTool { queued.append { [weak self] in self?.applyTool() }; return }
            // PencilKit's live ink must be exactly as wide as the finished stroke at every zoom.
            let scale = PencilKitZoom.widthFactor(renderScale: viewport?.renderScale ?? 1)
            switch settings.tool {
            case .eraser:
                // Precision erases exactly the circle at its set size, whatever the pressure.
                canvas.tool = settings.eraserStyle == .precision ? PKEraserTool(.fixedWidthBitmap, width: settings.eraserDiameter * scale) : PKEraserTool(.vector)
            case .lasso: canvas.tool = PKLassoTool()
            case .marker: canvas.tool = PKInkingTool(.marker, color: UIColor(hex: settings.color).withAlphaComponent(0.35), width: max(12, settings.width * 6) * scale)
            case .pencil: canvas.tool = PKInkingTool(.pencil, color: UIColor(hex: settings.color), width: settings.width * scale)
            default:
                let ink: PKInkingTool.InkType = settings.penStyle == .fountain ? .fountainPen : .pen
                canvas.tool = PKInkingTool(ink, color: UIColor(hex: settings.color), width: settings.width * scale)
            }
        }
        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) { inputGeneration += 1; usingTool = true; restyleIfReady(); pendingRestyle = nil; toolStart = canvasView.drawing; viewport?.showLiveInk(true); commands?.target = self; onActivate?() }
        private var toolStart: PKDrawing?
        /// Replaces the strokes PencilKit just wrote with the Goodnotes-style pens built from the same
        /// samples (fountain pen width by speed, pencil grain, tape strips, held shapes, ruler edges).
        /// The stroke PencilKit is finishing: its start drawing and when the Pencil lifted. PencilKit adds
        /// the stroke to the drawing around the end-of-tool callback, in either order, so both paths try.
        private var pendingRestyle: (start: PKDrawing, lifted: Date)?
        private func restyleIfReady() {
            guard let pending = pendingRestyle, let canvas, canvas.drawing.strokes.count > pending.start.strokes.count else { return }
            pendingRestyle = nil
            restyleNewStrokes(since: pending.start, lifted: pending.lifted)
        }
        func restyleNewStrokes(since start: PKDrawing, lifted: Date = Date()) {
            InkDiagnostics.log("restyle start canvas=\(canvas?.drawing.strokes.count ?? -1) start=\(start.strokes.count) writable=\(writable) tool=\(currentSettings?.tool.rawValue ?? "-") appleInk=\(currentSettings?.appleInk ?? false)")
            guard let canvas, writable, let settings = currentSettings, !settings.appleInk || settings.tape,
                  [.pen, .pencil, .marker, .shapes].contains(settings.tool) else { return }
            let now = canvas.drawing
            guard now.strokes.count > start.strokes.count else { return }
            let added = Array(now.strokes.dropFirst(start.strokes.count))
            if let first = added.first {
                let base = settings.tool == .marker ? max(12, settings.width * 6) : settings.width
                PencilKitZoom.learn(from: first, toolWidth: base * PencilKitZoom.widthFactor(renderScale: viewport?.renderScale ?? 1), renderScale: viewport?.renderScale ?? 1)
                if PencilKitZoom.needsReapply { PencilKitZoom.needsReapply = false; applyTool() }
            }
            var rebuilt: [PKStroke] = []
            for stroke in added {
                let points = Array(stroke.path)
                guard !points.isEmpty else { continue }
                // Passive and USB-C styluses can leave force, tilt or angle undefined; any value that is not a
                // number would make the engine drop every sample, so it falls back to a neutral one.
                func finite(_ v: CGFloat, _ fallback: CGFloat) -> CGFloat { v.isFinite ? v : fallback }
                let forces = points.map { finite($0.force, 0) }
                let maxForce = forces.max() ?? 0
                let flat = forces.allSatisfy { abs($0 - forces[0]) < 0.0001 }
                var samples = points.enumerated().map { i, p in
                    InkSample(point: p.location.applying(stroke.transform), time: finite(p.timeOffset, TimeInterval(i) / 120),
                              force: flat ? 0.5 : min(1, max(0, maxForce > 1 ? forces[i] / 4.1667 : forces[i])),
                              altitude: finite(p.altitude, .pi / 2) > 0 ? finite(p.altitude, .pi / 2) : .pi / 2, azimuth: finite(p.azimuth, 0))
                }
                samples = samples.filter { $0.point.x.isFinite && $0.point.y.isFinite }
                guard !samples.isEmpty else { continue }
                if samples.count == 1 { samples.append(samples[0]) }
                // Draw-and-hold: the Pencil rested at the end of the stroke. PencilKit records no points while
                // the Pencil stands still, so the rest is the gap between the last point and the lift.
                var shape: RecognizedShape?
                if (settings.drawAndHold || (settings.tool == .shapes && settings.holdForShapes)) || (settings.tool == .shapes && !settings.holdForShapes),
                   let end = samples.last {
                    let rest = samples.reversed().prefix { hypot($0.point.x - end.point.x, $0.point.y - end.point.y) < 3 }
                    let still = lifted.timeIntervalSince(stroke.path.creationDate.addingTimeInterval(end.time))
                    let held = still >= 0.45 || (rest.first?.time ?? 0) - (rest.last?.time ?? 0) >= 0.5
                    if held || (settings.tool == .shapes && !settings.holdForShapes) {
                        shape = ShapeRecognition.recognize(samples.map(\.point)).map { settings.roundedShapes ? (viewport?.inkInput.snapShape?($0) ?? $0) : $0 }
                    }
                }
                var made = InkBuilder.strokes(samples, settings: settings, creationDate: stroke.path.creationDate, seed: stroke.randomSeed, recognizedShape: shape)
                // Keep exactly the thickness that was on screen while writing: scale the rebuilt widths so
                // their median matches the stroke PencilKit drew.
                func median(_ values: [CGFloat]) -> CGFloat { let v = values.sorted(); return v.isEmpty ? 0 : v[v.count / 2] }
                let drawn = median(points.map { finite($0.size.width, 0) })
                let built = median(made.flatMap { $0.path.map(\.size.width) })
                if !(settings.tool == .marker && settings.tape), drawn > 0, built > 0, abs(drawn / built - 1) > 0.02 {
                    let ratio = drawn / built
                    made = made.map { s in
                        let controls = s.path.map { p in PKStrokePoint(location: p.location, timeOffset: p.timeOffset, size: CGSize(width: p.size.width * ratio, height: p.size.height * ratio), opacity: p.opacity, force: p.force, azimuth: p.azimuth, altitude: p.altitude) }
                        return PKStroke(ink: s.ink, path: PKStrokePath(controlPoints: controls, creationDate: s.path.creationDate), transform: s.transform, mask: s.mask, randomSeed: s.randomSeed)
                    }
                }
                // Plain writing stays exactly as PencilKit drew it; only patterns, held shapes and tape rebuild.
                if settings.strokePattern == .solid && shape == nil && !(settings.tool == .marker && settings.tape) && settings.tool != .shapes { made = [stroke] }
                rebuilt += made
            }
            let unchanged = rebuilt.count == added.count && zip(rebuilt, added).allSatisfy { $0.path.creationDate == $1.path.creationDate && $0.path.count == $1.path.count && $0.ink.inkType == $1.ink.inkType && $0.path.first?.size == $1.path.first?.size }
            let ruler = MainActor.assumeIsolated { RulerState.shared.visible }
            if unchanged && !ruler { InkDiagnostics.log("kept as drawn"); return }
            InkDiagnostics.log("restyle added=\(added.count) nativeW=\(added.first.map { InkDiagnostics.widths($0) } ?? "-") nativeBox=\(added.first.map { InkDiagnostics.box($0.renderBounds) } ?? "-") pts=\(added.first?.path.count ?? 0) t=\(added.first.map { InkDiagnostics.times($0) } ?? "-") rebuilt=\(rebuilt.count) rebuiltW=\(rebuilt.first.map { InkDiagnostics.widths($0) } ?? "-") rebuiltBox=\(rebuilt.first.map { InkDiagnostics.box($0.renderBounds) } ?? "-") ink=\(rebuilt.first.map { "\($0.ink.inkType.rawValue) a=\($0.ink.color.cgColor.alpha)" } ?? "-") width=\(settings.width) tool=\(settings.tool.rawValue) style=\(settings.penStyle.rawValue) scale=\(viewport?.renderScale ?? 0) alpha=\(canvas.alpha) overlay=\(viewport?.inkDetail.isHidden == false)")
            // Nothing to show instead: keep what PencilKit wrote rather than lose the stroke.
            guard !rebuilt.isEmpty else { return }
            // Take PencilKit's own undo step back so one undo removes the whole stroke.
            if canvas.undoManager?.canUndo == true {
                canvas.undoManager?.undo()
                // Something else was on top of the undo stack: put it back.
                if canvas.drawing.strokes.count < start.strokes.count, canvas.undoManager?.canRedo == true { canvas.undoManager?.redo() }
            }
            if canvas.drawing.strokes.count != start.strokes.count { canvas.drawing = start }
            drawing = start
            viewport?.inkInput.onCommit?(rebuilt)
            InkDiagnostics.log("after commit strokes=\(drawing.strokes.count) canvas=\(canvas.drawing.strokes.count) start=\(start.strokes.count) undo=\(canvas.undoManager?.canUndo ?? false)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak canvas] in
                InkDiagnostics.log("1s later strokes=\(self?.drawing.strokes.count ?? -1) canvas=\(canvas?.drawing.strokes.count ?? -1) alpha=\(canvas?.alpha ?? -1) hidden=\(canvas?.isHidden ?? true) overlay=\(self?.viewport?.inkDetail.isHidden == false)")
            }
            // If the rebuilt strokes did not land, put PencilKit's stroke back instead of losing it.
            if drawing.strokes.count <= start.strokes.count, !(rebuilt.count == 1 && TapeInk.isProbe(rebuilt[0])) {
                drawing = now; canvas.drawing = now; viewport?.inkDetail.update(now); persist()
            }
        }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            // Sole authoritative drawing lives here. Never publish it through SwiftUI state.
            drawing = canvasView.drawing
            viewport?.inkDetail.update(drawing)
            if !usingTool, pendingRestyle != nil { DispatchQueue.main.async { [weak self] in self?.restyleIfReady() } }
            // While a tool is in use PencilKit reports every small change; writing the whole page to disk
            // each time made erasing stutter. Save once the tool lifts, or shortly after a burst of changes.
            if filteredEraseBefore == nil { if usingTool { schedulePersist() } else { persist() } }
            commands?.refreshUndo()
        }
        private var pendingPersist: DispatchWorkItem?
        private func schedulePersist() {
            pendingPersist?.cancel()
            let task = DispatchWorkItem { [weak self] in self?.persist() }
            pendingPersist = task; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: task)
        }
        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            InkDiagnostics.log("end tool=\(currentSettings?.tool.rawValue ?? "-") strokes=\(canvasView.drawing.strokes.count) start=\(toolStart?.strokes.count ?? -1)")
            if let start = toolStart { toolStart = nil; pendingRestyle = (start, Date()) }
            drawing = canvasView.drawing; persist()
            finishToolUse()
        }
        func canvasViewDidFinishRendering(_ canvasView: PKCanvasView) { viewport?.inkInput.committedCanvasDidRender() }
        private func finishToolUse() {
            let erasing = currentSettings?.tool == .eraser && !cancelledInput
            let generation = inputGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.inputGeneration == generation else { return }
                self.usingTool = false
                self.restyleIfReady()
                self.viewport?.showLiveInk(false)
                let pending = self.queued; self.queued.removeAll()
                for action in pending { action() }
                if erasing { self.commands?.didFinishErasing?() }
                self.commands?.refreshUndo()
            }
        }
        @discardableResult func persist() -> Bool {
            pendingPersist?.cancel(); pendingPersist = nil
            guard writable else { return true }
            do { try DrawingDisk.save(drawing, directory: directory, page: page.id); return true }
            catch { commands?.reportError("Striche sind noch im Speicher, konnten aber nicht gesichert werden: \(error.localizedDescription)"); return false }
        }
        func perform(_ action: @escaping () -> Void) { if usingTool { queued.append(action) } else { action() } }
        func clear(_ kind: ClearKind) {
            perform { [weak self] in
                guard let self, self.writable, let canvas = self.canvas else { return }
                if kind == .text { self.viewport?.removeAllText(); return }
                let next = PKDrawing(strokes: self.drawing.strokes.filter { !kind.removes($0) })
                if next.strokes.count != self.drawing.strokes.count { self.replaceByUserCommand(next, canvas: canvas) }
            }
        }
        func append(_ strokes: [PKStroke]) {
            perform { [weak self] in
                guard let self, let canvas = self.canvas, self.writable else { return }
                self.replaceByUserCommand(PKDrawing(strokes: self.drawing.strokes + strokes), canvas: canvas)
            }
        }
        private func replaceByUserCommand(_ next: PKDrawing, canvas: PKCanvasView) {
            let before = drawing
            registerUndo(before, canvas: canvas)
            drawing = next; canvas.drawing = next; viewport?.inkDetail.update(next); persist(); commands?.refreshUndo()
        }
        private func registerUndo(_ before: PKDrawing, canvas: PKCanvasView) {
            canvas.undoManager?.registerUndo(withTarget: self) { target in
                guard let c = target.canvas else { return }; target.viewport?.lasso.clearSelection(animated: false); target.replaceByUserCommand(before, canvas: c)
            }
        }
        private func finishFilteredErase() {
            if filteredEraseChanged, let before = filteredEraseBefore, let canvas { registerUndo(before, canvas: canvas); persist() }
            filteredEraseBefore = nil; filteredEraseChanged = false
        }
    }
}

/// Tiled layer that redraws only the visible part of a page at the zoom it is shown at,
/// so paper, PDFs and imported ink stay pixel-sharp instead of being scaled up.
final class SharpTiledLayer: CATiledLayer {
    override class func fadeDuration() -> CFTimeInterval { 0 }
}

/// Sharp overlay for a page layer. The owner keeps drawing a normal, always-ready base image
/// underneath, so a tile that is still rendering never shows as an empty area, only as briefly softer.
final class SharpDetailView: UIView {
    override class var layerClass: AnyClass { SharpTiledLayer.self }
    private let paint: (CGContext, CGRect) -> Void
    init(paint: @escaping (CGContext, CGRect) -> Void) {
        self.paint = paint
        super.init(frame: .zero)
        backgroundColor = .clear; isOpaque = false; isUserInteractionEnabled = false
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if let tiled = layer as? CATiledLayer {
            // Detail from 1x up to 16x the page size: iPad screens are 2x and the notebook zooms up to ~8x.
            tiled.levelsOfDetail = 5; tiled.levelsOfDetailBias = 4
            tiled.tileSize = CGSize(width: 512, height: 512)
        }
    }
    required init?(coder: NSCoder) { nil }
    /// Tiles render on background threads. Owners change what `paint` reads only inside `locked`,
    /// and every draw runs inside it too, so PDF pages are never drawn from two threads at once.
    private let lock = NSLock()
    func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    override func draw(_ rect: CGRect) {
        guard let c = UIGraphicsGetCurrentContext() else { return }
        let size = bounds
        locked { paint(c, size) }
    }
}

final class PaperView: UIView {
    var page: NotebookPage { didSet { let page = page; detail.locked { tilePage = page }; detail.setNeedsDisplay() } }
    private var tilePage: NotebookPage
    let pdf: PDFDocument?
    private lazy var detail = SharpDetailView { [weak self] c, bounds in
        guard let self else { return }
        self.render(c, bounds: bounds, page: self.tilePage)
    }
    init(page: NotebookPage, directory: URL) {
        self.page = page; tilePage = page
        pdf = page.pdf.flatMap { Self.document(directory.appendingPathComponent($0)) }
        super.init(frame: CGRect(origin: .zero, size: page.nativeSize)); backgroundColor = .white
        contentMode = .redraw
        detail.frame = bounds; addSubview(detail)
    }
    override func setNeedsDisplay() { super.setNeedsDisplay(); detail.setNeedsDisplay() }
    required init?(coder: NSCoder) { nil }
    /// Imported notebooks share one background PDF across many pages; open each file only once.
    private static let documents = NSCache<NSURL, PDFDocument>()
    private static let pdfLock = NSLock()
    private static func document(_ url: URL) -> PDFDocument? {
        if let cached = documents.object(forKey: url as NSURL) { return cached }
        guard let document = PDFDocument(url: url) else { return nil }
        documents.setObject(document, forKey: url as NSURL); return document
    }
    override func draw(_ rect: CGRect) {
        guard let c = UIGraphicsGetCurrentContext() else { return }
        let page = page, bounds = bounds
        detail.locked { render(c, bounds: bounds, page: page) }
    }
    private func render(_ c: CGContext, bounds: CGRect, page: NotebookPage) {
        c.setFillColor(UIColor(hex: page.paperColor ?? "#FFFFFF").cgColor); c.fill(bounds)
        if let p = pdf?.page(at: page.pdfPage) {
            c.saveGState(); c.translateBy(x: 0, y: bounds.height); c.scaleBy(x: 1, y: -1)
            let box = p.bounds(for: .cropBox)
            guard box.width > 0, box.height > 0 else { c.restoreGState(); return }
            c.scaleBy(x: bounds.width / box.width, y: bounds.height / box.height)
            // Pages share PDF documents and tiles render on several threads; PDFKit draws one at a time.
            c.translateBy(x: -box.minX, y: -box.minY)
            Self.pdfLock.lock(); p.draw(with: .cropBox, to: c); Self.pdfLock.unlock()
            c.restoreGState()
        } else { Self.paint(c, bounds: bounds, paper: page.paper) }
    }
    nonisolated static func paint(_ c: CGContext, bounds: CGRect, paper: String) {
        guard paper != "blank" else { return }
        // Pattern geometry from the supplied GNDynamicTemplates bundle.
        c.setStrokeColor(UIColor(hex: "#D0D2D3").cgColor); c.setLineWidth(0.5)
        if paper == "dotted" {
            c.setFillColor(UIColor(hex: "#D0D2D3").cgColor)
            for y in stride(from: CGFloat(15), to: bounds.height, by: 16) { for x in stride(from: CGFloat(10), to: bounds.width, by: 16) { c.fillEllipse(in: CGRect(x: x, y: y, width: 1, height: 1)) } }
            return
        }
        let gap: CGFloat = paper == "wide" ? 25 : 16
        let top: CGFloat = paper == "grid" ? 8 : 50
        let bottom = paper == "grid" ? bounds.height : min(bounds.height, top + bounds.height * 0.8)
        for y in stride(from: top, to: bottom, by: gap) { c.move(to: CGPoint(x:0,y:y)); c.addLine(to: CGPoint(x:bounds.width,y:y)) }
        if paper == "grid" { for x in stride(from: CGFloat(8), to: bounds.width, by: 16) { c.move(to: CGPoint(x:x,y:0)); c.addLine(to: CGPoint(x:x,y:bounds.height)) } }
        c.strokePath()
    }
}

struct TextBox: Codable { var text: String; var x: Double; var y: Double; var width: Double; var height: Double
    /// Sticky notes are text boxes with a paper colour and a fixed square size.
    var color: String? = nil
    /// Imported Goodnotes text keeps its size; boxes made here use the default.
    var fontSize: Double? = nil
    static let stickyInset = UIEdgeInsets(top: 14, left: 10, bottom: 14, right: 10)
    static let stickyFont: CGFloat = 17
}
final class PageTextView: UITextView { var noteColor: String?; var fontSize: Double? }

extension PKDrawing {
    /// Paper is always light. PencilKit adapts ink to the current appearance, which would turn black ink white in the dark app UI.
    func paperImage(from rect: CGRect, scale: CGFloat) -> UIImage {
        var image = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent { image = self.image(from: rect, scale: scale) }
        return image
    }
}

final class PageInkCanvas: PKCanvasView {
    private let pageUndo = UndoManager()
    override var undoManager: UndoManager? { pageUndo }
}

final class PageViewport: UIView, UITextViewDelegate, UIScrollViewDelegate {
    let scroll = UIScrollView()
    let content: UIView
    let document: UIView
    let canvas = PageInkCanvas()
    let inkInput = InkInputView(frame: .zero)
    let original = OriginalInkView()
    let interaction = UIView()
    let lasso = LassoSelectionView(frame: .zero)
    private let laser = CAShapeLayer()
    private var tool = EditorTool.pen
    private var shape = GeometricShape.ellipse
    private var panInput: UIPanGestureRecognizer?
    private var eraseInput: UILongPressGestureRecognizer?
    private lazy var inkTouches = InkTouchRecognizer(ink: inkInput)
    private var tapInput: UITapGestureRecognizer?
    private var points: [CGPoint] = []
    var laserTrail = true
    private var start = CGPoint.zero
    private var boxes: [PageTextView] = []
    private var textWritable = true
    private(set) var textReadError:String?
    var onError:((String)->Void)?
    private let textURL: URL
    private var lastBounds = CGSize.zero
    private var pageMetadata: NotebookPage?
    var onShape: (([CGPoint], Bool) -> Void)?
    var onInteraction: ((Bool) -> Void)?
    var onErase: (([CGPoint]) -> Void)?
    var onEraseCancelled: (() -> Void)?
    private var eraserDiameter: CGFloat = 8
    init(page: NotebookPage, directory: URL) {
        content = UIView(frame: CGRect(origin: .zero, size: page.size))
        document = UIView(frame: CGRect(origin: .zero, size: page.nativeSize))
        textURL = directory.appendingPathComponent(page.id + ".texts.json")
        super.init(frame: .zero); backgroundColor = UIColor(hex: "#1B1C1C")
        // Page surfaces stay light so PencilKit renders ink in its true colors inside the dark app chrome.
        document.overrideUserInterfaceStyle = .light
        addSubview(scroll); scroll.addSubview(content); content.addSubview(document); document.addSubview(PaperView(page: page, directory: directory))
        original.frame = document.bounds; original.backgroundColor = .clear; original.isUserInteractionEnabled = false; document.addSubview(original)
        canvas.backgroundColor = .clear; canvas.isOpaque = false
        canvas.maximumSupportedContentVersion = .latest
        canvas.overrideUserInterfaceStyle = .light
        canvas.isScrollEnabled = false; canvas.minimumZoomScale = 1; canvas.maximumZoomScale = 1
        document.addSubview(canvas)
        inkDetail.frame = document.bounds; inkDetail.isHidden = true; document.addSubview(inkDetail)
        inkInput.frame = document.bounds; inkInput.managedUndo = canvas.undoManager; document.addSubview(inkInput)
        interaction.frame = document.bounds; interaction.backgroundColor = .clear; interaction.isHidden = true; document.addSubview(interaction)
        lasso.frame = document.bounds; lasso.isHidden = true; document.addSubview(lasso)
        scroll.minimumZoomScale = 0.1; scroll.maximumZoomScale = PageViewport.maximumZoom; scroll.contentSize = content.bounds.size
        canvas.addGestureRecognizer(inkTouches)
        let eraseTouch = UILongPressGestureRecognizer(target: self, action: #selector(erase(_:)))
        // Starts on first contact, unlike a pan, so erasing reacts without a movement threshold.
        eraseTouch.minimumPressDuration = 0; eraseTouch.allowableMovement = .greatestFiniteMagnitude
        eraseInput = eraseTouch; interaction.addGestureRecognizer(eraseTouch)
        scroll.delegate = self
        scroll.panGestureRecognizer.minimumNumberOfTouches = 2
        scroll.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        content.layer.shadowColor = UIColor.black.cgColor; content.layer.shadowOpacity = 0.13; content.layer.shadowRadius = 12; content.layer.shadowOffset = CGSize(width: 0,height: 4)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tap(_:))); tapInput = tap; interaction.addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:))); panInput = pan; interaction.addGestureRecognizer(pan)
        laser.strokeColor = UIColor.systemRed.cgColor; laser.lineWidth = 3; laser.fillColor = nil; laser.lineCap = .round; interaction.layer.addSublayer(laser)
        if FileManager.default.fileExists(atPath:textURL.path) {
            do { let saved = try JSONDecoder().decode([TextBox].self,from:Data(contentsOf:textURL)); for box in saved { addText(box) } }
            catch { textWritable = false; textReadError = "Textfelder konnten nicht geladen werden und werden nicht überschrieben: \(error.localizedDescription)" }
        }
        updatePage(page)
    }
    required init?(coder: NSCoder) { nil }
    func updatePage(_ page: NotebookPage) {
        guard page != pageMetadata else { return }; pageMetadata = page
        content.bounds.size = page.size
        document.transform = .identity; document.bounds = CGRect(origin: .zero, size: page.nativeSize)
        document.center = CGPoint(x: content.bounds.midX, y: content.bounds.midY)
        document.transform = CGAffineTransform(rotationAngle: CGFloat(page.quarterTurns) * .pi / 2)
        original.frame = document.bounds; inkInput.frame = document.bounds; interaction.frame = document.bounds; lasso.frame = document.bounds
        inkDetail.frame = document.bounds
        layoutCanvas()
        if let paper = document.subviews.first as? PaperView { paper.page = page; paper.frame = document.bounds; paper.setNeedsDisplay() }
        scroll.contentSize = CGSize(width: page.size.width * scroll.zoomScale, height: page.size.height * scroll.zoomScale)
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { scrollView === scroll ? content : nil }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerPage() }
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) { updateRenderScale() }
    /// Deepest zoom, relative to the page's own size; pages also render sharp up to here.
    static let maximumZoom: CGFloat = 10
    /// Zoom of the notebook scroll view that holds this page (1 when the page zooms by itself).
    var outerZoom: CGFloat = 1 { didSet { updateRenderScale() } }
    /// Scale PencilKit renders the ink at, matching the on-screen zoom so strokes stay pixel-sharp.
    private(set) var renderScale: CGFloat = 1
    func updateRenderScale() {
        // Quarter steps keep PencilKit from re-rendering on every tiny zoom change.
        // While a stroke is live PencilKit redraws the whole canvas in one layer; past this size the
        // existing ink could vanish until the Pencil lifted, so the sharp canvas stays within 8192 pixels (sharp up to about 4.8x on A4).
        let longest = max(1, max(document.bounds.width, document.bounds.height) * (window?.screen.scale ?? 2))
        let budget = max(1, (8192 / longest * 4).rounded(.down) / 4)
        let target = min(PageViewport.maximumZoom, budget, max(1, (outerZoom * scroll.zoomScale * 4).rounded(.up) / 4))
        wantedScale = min(PageViewport.maximumZoom, max(1, (outerZoom * scroll.zoomScale * 4).rounded(.up) / 4))
        guard target != renderScale else { updateInkDetail(); return }
        renderScale = target; layoutCanvas(); updateInkDetail(); onRenderScale?()
    }
    /// Beyond PencilKit's pixel budget the committed ink is shown by tiles rendered at the full zoom;
    /// the canvas underneath stays (nearly invisible) to take the Pencil and shows live ink while writing.
    let inkDetail = InkDetailView()
    private var wantedScale: CGFloat = 1
    private var writing = false
    private func updateInkDetail() {
        let sharpOverlay = wantedScale > renderScale + 0.01 && !writing
        inkDetail.isHidden = !sharpOverlay
        canvas.alpha = sharpOverlay ? 0.02 : 1
    }
    func showLiveInk(_ live: Bool) {
        guard live != writing else { return }
        writing = live
        if live { updateInkDetail(); return }
        // Let the sharp tiles catch up before the canvas fades back under them.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in if self?.writing == false { self?.updateInkDetail() } }
    }
    var onRenderScale: (() -> Void)?
    /// The canvas is laid out `renderScale` times larger, zoomed by the same factor and shrunk back
    /// by a transform: it covers exactly the page, but PencilKit draws at the zoomed resolution.
    private func layoutCanvas() {
        canvas.layoutSharp(covering: document.bounds.size, scale: renderScale)
        inkInput.renderScale = renderScale
    }
    override func layoutSubviews() {
        super.layoutSubviews(); scroll.frame = bounds
        if bounds.size != lastBounds && bounds.width > 0 {
            let initial = lastBounds == .zero
            lastBounds = bounds.size
            if initial { scroll.zoomScale = max(0.1,min(4,min((bounds.width - 88) / content.bounds.width, (bounds.height - 88) / content.bounds.height))) }
            centerPage(); updateRenderScale()
        }
    }
    func centerPage() {
        let size = scroll.contentSize
        scroll.contentInset = UIEdgeInsets(top: max(64,(bounds.height-size.height)/2), left: max(24,(bounds.width-size.width)/2), bottom: 32, right: max(24,(bounds.width-size.width)/2))
    }
    func setTool(_ settings: ToolSettings, writable: Bool) {
        let tool = settings.tool; self.tool = tool; shape = settings.geometricShape
        laserTrail = settings.laserTrail
        // PencilKit has no Goodnotes-style standard eraser, so it and filtered erasing run on the overlay.
        let overlay = [.geometry,.elements,.text,.laser].contains(tool) || (tool == .eraser && FilteredEraser.needsOverlay(settings))
        eraserDiameter = settings.eraserDiameter
        canvas.isUserInteractionEnabled = writable && !overlay && tool != .lasso && tool != .hand
        inkInput.configure(settings, writable: writable)
        // The stroke engine writes; PencilKit's own recognizer only writes in the Apple-pen fallback or erases.
        // PencilKit's own recognizer is the one input route proven on every iPad and stylus; custom touch
        // routing never reached the engine on the device. The engine restyles each stroke once it lifts.
        let engine = inkInput.enabled && InkInputView.liveTouches
        inkTouches.isEnabled = engine
        inkInput.isHidden = !engine
        canvas.drawingGestureRecognizer.isEnabled = !engine
        interaction.isHidden = !overlay || !writable
        let touches = StylusInputPolicy.drawingTouches(finger: settings.finger, pencilConnected: settings.pencilConnected)
        panInput?.allowedTouchTypes = touches.map { NSNumber(value: $0.rawValue) }
        eraseInput?.allowedTouchTypes = touches.map { NSNumber(value: $0.rawValue) }
        eraseInput?.isEnabled = tool == .eraser
        let lassoActive = tool == .lasso && writable
        if !lassoActive && !lasso.isHidden { lasso.clearSelection(animated: false) }
        lasso.isHidden = !lassoActive; lasso.rectangular = settings.rectangularLasso; lasso.setAllowedTouches(touches)
        tapInput?.allowedTouchTypes = (tool == .eraser ? touches : [.direct, .pencil, .indirectPointer]).map { NSNumber(value: $0.rawValue) }
        laser.strokeColor = (tool == .laser ? UIColor.systemRed : UIColor(hex: settings.color)).cgColor
        laser.lineWidth = tool == .laser ? 3 : settings.width
        laser.fillColor = tool == .geometry && shape.isClosed && settings.fillShapes ? UIColor(hex: settings.color).withAlphaComponent(CGFloat(settings.fillOpacity)).cgColor : nil
        laser.shadowColor = UIColor.systemRed.cgColor; laser.shadowOpacity = tool == .laser ? 0.8 : 0; laser.shadowRadius = tool == .laser ? 4 : 0
        for box in boxes { box.isUserInteractionEnabled = tool == .text && writable }
        if tool != .text || !writable { endEditing(true) }
    }
    @objc private func tap(_ recognizer: UITapGestureRecognizer) {
        let p = recognizer.location(in: document)
        if tool == .eraser { return } // The erase recognizer already handled the contact.
        if tool == .laser {
            laser.removeAllAnimations(); laser.fillColor = UIColor.systemRed.cgColor
            laser.path = UIBezierPath(ovalIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)).cgPath
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0; fade.duration = 0.6; laser.opacity = 0; laser.add(fade, forKey: "fade")
            return
        }
        if tool == .text && textWritable { addText(TextBox(text: "", x: p.x, y: p.y, width: min(240,document.bounds.width-p.x), height: 90)); boxes.last?.becomeFirstResponder() }
        if tool == .elements {
            let points = (0...10).map { i -> CGPoint in let a = CGFloat(i) * .pi / 5 - .pi / 2; let r: CGFloat = i % 2 == 0 ? 35 : 15; return CGPoint(x:p.x+cos(a)*r,y:p.y+sin(a)*r) }; onShape?(points, true)
        }
    }
    @objc private func erase(_ recognizer: UILongPressGestureRecognizer) {
        guard tool == .eraser else { return }
        let location = recognizer.location(in: document)
        let p = CGPoint(x: min(max(0, location.x), document.bounds.width), y: min(max(0, location.y), document.bounds.height))
        switch recognizer.state {
        case .began:
            points = [p]; onInteraction?(true); laser.removeAllAnimations(); laser.opacity = 1
        case .changed, .ended:
            // Skip sub-point jitter; each call erases along the segment since the last point.
            if let last = points.last, hypot(last.x - p.x, last.y - p.y) < 0.75, recognizer.state == .changed { return }
            points.append(p)
        default: break
        }
        laser.strokeColor = UIColor(white: 0.45, alpha: 0.9).cgColor; laser.lineWidth = 1 / max(0.1, outerZoom * scroll.zoomScale)
        laser.fillColor = UIColor(white: 1, alpha: 0.35).cgColor
        laser.path = UIBezierPath(ovalIn: CGRect(x: p.x - eraserDiameter / 2, y: p.y - eraserDiameter / 2, width: eraserDiameter, height: eraserDiameter)).cgPath
        if [.began, .changed, .ended].contains(recognizer.state) { onErase?(Array(points.suffix(2))) }
        if recognizer.state == .ended { onInteraction?(false); laser.path = nil; points.removeAll() }
        if recognizer.state == .cancelled || recognizer.state == .failed { onEraseCancelled?(); onInteraction?(false); laser.path = nil; points.removeAll() }
    }
    @objc private func pan(_ recognizer: UIPanGestureRecognizer) {
        guard [.geometry, .laser].contains(tool) else { return }
        let location = recognizer.location(in: document)
        let p = CGPoint(x: min(max(0, location.x), document.bounds.width), y: min(max(0, location.y), document.bounds.height))
        if recognizer.state == .began { start = p; points = [p]; onInteraction?(true); laser.removeAllAnimations(); laser.opacity = 1 }
        else { points.append(p) }
        let path = UIBezierPath(); path.move(to:start)
        if tool == .geometry {
            let outline = shape.points(from: start, to: p, samples: points)
            path.append(GeometricInk.path(outline)); if shape.isClosed { path.close() }
            if [.elbow, .curve].contains(shape) { path.append(GeometricInk.path(GeometricInk.arrowhead(outline, width: laser.lineWidth))) }
        }
        else if tool == .laser {
            laser.fillColor = laserTrail ? nil : UIColor.systemRed.cgColor
            if laserTrail { path.append(GeometricInk.path(points)) }
            else { path.removeAllPoints(); path.append(UIBezierPath(ovalIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6))) }
        }
        else { path.addLine(to:p) }
        laser.path = path.cgPath
        if recognizer.state == .ended {
            if tool == .geometry { onShape?(shape.points(from: start, to: p, samples: points), shape.isClosed) }
            onInteraction?(false)
            let animation = CABasicAnimation(keyPath: "opacity"); animation.fromValue = 1; animation.toValue = 0; animation.duration = 0.6; laser.opacity = 0; laser.add(animation,forKey:"fade")
        }
        if recognizer.state == .cancelled || recognizer.state == .failed { laser.path = nil; onInteraction?(false) }
    }
    private func addText(_ box: TextBox) {
        let view = PageTextView(frame:CGRect(x:box.x,y:box.y,width:max(40,box.width),height:box.height))
        view.text = box.text; view.font = .systemFont(ofSize:20); view.textColor = UIColor(hex: "#1E1B1B"); view.backgroundColor = .clear; view.delegate = self
        view.isScrollEnabled = false; view.isUserInteractionEnabled = tool == .text
        view.fontSize = box.fontSize
        if let size = box.fontSize { view.font = .systemFont(ofSize: CGFloat(size)) }
        if let color = box.color {
            view.noteColor = color; view.backgroundColor = UIColor(hex: color); view.font = .systemFont(ofSize: box.fontSize.map { CGFloat($0) } ?? TextBox.stickyFont)
            view.textContainerInset = TextBox.stickyInset; view.layer.cornerRadius = 3
            view.layer.borderColor = UIColor.black.withAlphaComponent(0.08).cgColor; view.layer.borderWidth = 0.5
        }
        boxes.append(view); document.addSubview(view)
    }
    func textViewDidChange(_ textView: UITextView) {
        guard textWritable else { return }
        if (textView as? PageTextView)?.noteColor == nil { textView.sizeToFit() }
        saveTexts()
    }
    private func saveTexts() {
        let saved = boxes.map { TextBox(text:$0.text,x:$0.frame.minX,y:$0.frame.minY,width:$0.frame.width,height:$0.frame.height,color:$0.noteColor,fontSize:$0.fontSize) }
        do { try JSONEncoder().encode(saved).write(to:textURL,options:.atomic) }
        catch { onError?("Text konnte nicht gespeichert werden: \(error.localizedDescription)") }
    }
    /// Places a square sticky note in the middle of what is on screen and starts typing on it.
    func addStickyNote(color: String = "#FFE36E") {
        guard textWritable else { return }
        var center = CGPoint(x: document.bounds.midX, y: document.bounds.midY)
        if let window { center = document.convert(CGPoint(x: window.bounds.midX, y: window.bounds.midY), from: window) }
        let side = min(200, document.bounds.width * 0.45)
        let x = min(max(0, center.x - side / 2), max(0, document.bounds.width - side))
        let y = min(max(0, center.y - side / 2), max(0, document.bounds.height - side))
        addText(TextBox(text: "", x: x, y: y, width: side, height: side, color: color))
        saveTexts()
        guard let view = boxes.last else { return }
        view.isUserInteractionEnabled = true
        view.alpha = 0; view.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        UIView.animate(withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.78, initialSpringVelocity: 0) { view.alpha = 1; view.transform = .identity }
        view.becomeFirstResponder()
    }
    func removeAllText() {
        guard textWritable, !boxes.isEmpty else { return }
        let removed = boxes; boxes.removeAll(); saveTexts()
        UIView.animate(withDuration: 0.2, animations: { removed.forEach { $0.alpha = 0 } }) { _ in removed.forEach { $0.removeFromSuperview() } }
    }
}

enum StrokeFactory {
    static func stroke(points: [CGPoint], color: UIColor, width: CGFloat) -> PKStroke {
        let controls = points.enumerated().map { i,p in PKStrokePoint(location:p,timeOffset:Double(i)/120,size:CGSize(width:width,height:width),opacity:1,force:1,azimuth:0,altitude:.pi/2) }
        return PKStroke(ink: PKInk(.pen,color:color), path:PKStrokePath(controlPoints:controls,creationDate:Date()))
    }
}

/// Whether PencilKit divides a tool's width by the canvas zoom. The sharp canvas is zoomed to its render
/// scale, so the tool width is multiplied back when it does; the answer is measured from real strokes.
enum PencilKitZoom {
    // v2: the first version learned from strokes PencilKit had clamped to its minimum width and got it wrong.
    private static let key = "nullmini.pencilKitDividesByZoom.v2"
    static var needsReapply = false
    static var dividesByZoom: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { if newValue != dividesByZoom { UserDefaults.standard.set(newValue, forKey: key); needsReapply = true } }
    }
    static func widthFactor(renderScale: CGFloat) -> CGFloat { dividesByZoom ? renderScale : 1 }
    /// Compares the width PencilKit stored with the width it was given, at a zoom where the two answers differ.
    static func learn(from stroke: PKStroke, toolWidth: CGFloat, renderScale: CGFloat) {
        // Only widths PencilKit keeps as given tell anything; clamped ones look like "does not divide".
        let valid = stroke.ink.inkType.validWidthRange
        guard renderScale >= 1.5, toolWidth >= valid.lowerBound * 2, toolWidth <= valid.upperBound / 2 else { return }
        let widths = stroke.path.map(\.size.width).sorted()
        guard widths.count >= 5 else { return }
        let ratio = widths[widths.count / 2] / toolWidth
        // Dividing stores about 1/scale of the tool width; not dividing stores about the tool width.
        dividesByZoom = ratio < (1 + 1 / renderScale) / 2
    }
}

/// Committed ink drawn in tiles at the exact on-screen zoom, for zooms beyond what the PencilKit canvas renders.
final class InkDetailView: UIView {
    override class var layerClass: AnyClass { SharpTiledLayer.self }
    private let lock = NSLock()
    private var drawing = PKDrawing()
    private var dirty = false
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear; isOpaque = false; isUserInteractionEnabled = false; overrideUserInterfaceStyle = .light
        if let tiled = layer as? CATiledLayer { tiled.levelsOfDetail = 5; tiled.levelsOfDetailBias = 4; tiled.tileSize = CGSize(width: 512, height: 512) }
    }
    required init?(coder: NSCoder) { nil }
    func update(_ next: PKDrawing) {
        lock.lock(); drawing = next; lock.unlock()
        if isHidden { dirty = true } else { setNeedsDisplay() }
    }
    override var isHidden: Bool { didSet { if !isHidden && dirty { dirty = false; setNeedsDisplay() } } }
    override func draw(_ rect: CGRect) {
        guard let c = UIGraphicsGetCurrentContext() else { return }
        lock.lock(); let ink = drawing; lock.unlock()
        guard !ink.strokes.isEmpty, ink.bounds.intersects(rect) else { return }
        let scale = max(1, min(40, hypot(c.ctm.a, c.ctm.b)))
        ink.paperImage(from: rect, scale: scale).draw(in: rect)
    }
}

/// Temporary on-device log (Documents/ink-diagnostics.log) to find where strokes get lost.
enum InkDiagnostics {
    private static let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ink-diagnostics.log")
    static func log(_ line: String) {
        let text = ISO8601DateFormatter().string(from: Date()) + " " + line + String(UnicodeScalar(10))
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            if (try? handle.seekToEnd()) ?? 0 > 2_000_000 { return }
            try? handle.write(contentsOf: data)
        } else { try? data.write(to: url) }
    }
    static func widths(_ s: PKStroke) -> String {
        let w = s.path.map(\.size.width)
        return String(format: "%.2f-%.2f", w.min() ?? 0, w.max() ?? 0)
    }
    static func times(_ s: PKStroke) -> String { String(format: "%.3f-%.3f", s.path.first?.timeOffset ?? -1, s.path.last?.timeOffset ?? -1) }
    static func box(_ r: CGRect) -> String { String(format: "%.0f,%.0f %.0fx%.0f", r.minX, r.minY, r.width, r.height) }
}
