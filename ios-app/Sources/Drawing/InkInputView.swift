import UIKit
import PencilKit

/// Captures actual and predicted input separately. Only actual samples enter the saved drawing.
final class InkInputView: UIView {
    private let preview = PKCanvasView()
    private var settings = ToolSettings()
    private var strokeSettings = ToolSettings()
    private var samples: [InkSample] = []
    private var activeTouch: UITouch?
    private var date = Date()
    private var seed: UInt32 = 0
    private var generation = 0
    private var pendingPreview: Int?
    private var awaitingEnd = false
    private var completion: DispatchWorkItem?
    private var holdTask: DispatchWorkItem?
    private var holdPoint: CGPoint?
    private var recognizedBase: RecognizedShape?
    private var recognized: RecognizedShape?
    private var holdHandle = CGPoint.zero
    private struct ScrollingState {
        weak var scroll: UIScrollView?
        let pan: Bool
        let pinch: Bool
    }
    private var suspendedScrolling: [ScrollingState] = []
    private var backgroundObserver: NSObjectProtocol?
    private(set) var active = false
    var onInteraction: ((Bool) -> Void)?
    var onCommit: (([PKStroke]) -> Void)?
    var snapShape: ((RecognizedShape) -> RecognizedShape)?
    weak var managedUndo: UndoManager?
    override var canBecomeFirstResponder: Bool { true }
    override var undoManager: UndoManager? { managedUndo ?? super.undoManager }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false; backgroundColor = .clear; isMultipleTouchEnabled = true
        preview.isOpaque = false; preview.backgroundColor = .clear; preview.isUserInteractionEnabled = false; preview.isScrollEnabled = false
        preview.maximumSupportedContentVersion = .latest
        preview.overrideUserInterfaceStyle = .light; overrideUserInterfaceStyle = .light
        addSubview(preview)
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.finishPendingStroke() } }
    }
    deinit { if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) } }
    required init?(coder: NSCoder) { nil }
    override func layoutSubviews() { super.layoutSubviews(); preview.frame = bounds }
    func configure(_ value: ToolSettings, writable: Bool) {
        settings = value
        let enabled = writable && [.pen, .pencil, .marker, .shapes].contains(value.tool)
        isUserInteractionEnabled = enabled; isHidden = !enabled
    }
    func beginStroke(_ sample: InkSample, source: UITouch.TouchType = .pencil) {
        guard isUserInteractionEnabled, !isHidden else { return }
        if active { finishStroke() }
        completion?.cancel(); awaitingEnd = false; samples = [sample]; strokeSettings = settings
        recognized = nil; recognizedBase = nil; holdPoint = nil
        pendingPreview = nil
        date = Date(); seed = UInt32.random(in: 0...UInt32.max); generation += 1; active = true
        if source == .pencil { suspendScrolling() }
        becomeFirstResponder(); onInteraction?(true); updatePreview(predicted: []); scheduleRecognition()
    }
    func addSamples(_ values: [InkSample], predicted: [InkSample] = []) {
        guard active, !awaitingEnd else { return }
        for value in values {
            if let id = value.estimateID, let i = samples.lastIndex(where: { $0.estimateID == id }) { samples[i] = value }
            else if value.time > (samples.last?.time ?? -.infinity) { samples.append(value) }
        }
        if let base = recognizedBase, let point = samples.last?.point { recognized = snap(base.adjusted(from: holdHandle, to: point)) }
        else if strokeSettings.tool == .shapes && !strokeSettings.holdForShapes { recognized = ShapeRecognition.recognize(samples.map(\.point)).map(snap) }
        else { scheduleRecognition() }
        updatePreview(predicted: strokeSettings.reduceLatency ? predicted : [])
    }
    func endStroke() {
        guard active else { return }
        holdTask?.cancel(); holdTask = nil
        activeTouch = nil; awaitingEnd = true
        if samples.contains(where: \.awaitingUpdate) {
            let expected = generation
            let task = DispatchWorkItem { [weak self] in if self?.generation == expected { self?.finishStroke() } }; completion = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: task)
            updatePreview(predicted: [])
        } else { finishStroke() }
    }
    func updateEstimate(_ sample: InkSample) {
        guard active, let id = sample.estimateID, let i = samples.firstIndex(where: { $0.estimateID == id }) else { return }
        samples[i] = sample; updatePreview(predicted: [])
        if awaitingEnd && !samples.contains(where: \.awaitingUpdate) { finishStroke() }
    }
    func cancelStroke() {
        guard active else { return }
        completion?.cancel(); completion = nil; holdTask?.cancel(); holdTask = nil; active = false; activeTouch = nil; awaitingEnd = false; samples.removeAll(keepingCapacity: true)
        preview.drawing = PKDrawing(); restoreScrolling(); onInteraction?(false)
    }
    func finishPendingStroke() { if active { finishStroke() } }
    func interruptStroke(source: UITouch.TouchType) { if source == .direct { cancelStroke() } else { finishPendingStroke() } }
    func committedCanvasDidRender() {
        guard !active, pendingPreview == generation else { return }
        pendingPreview = nil; preview.drawing = PKDrawing()
    }
    private func finishStroke() {
        guard active else { return }
        completion?.cancel(); completion = nil; holdTask?.cancel(); holdTask = nil
        let strokes = InkBuilder.strokes(samples, settings: strokeSettings, creationDate: date, seed: seed, recognizedShape: recognized)
        active = false; activeTouch = nil; awaitingEnd = false; samples.removeAll(keepingCapacity: true)
        pendingPreview = generation
        onCommit?(strokes); restoreScrolling(); onInteraction?(false)
        // Retain wet ink until the authoritative canvas reports its committed content ready for display.
        let expected = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in if self?.generation == expected { self?.committedCanvasDidRender() } }
    }
    private func updatePreview(predicted: [InkSample]) {
        preview.drawing = PKDrawing(strokes: InkBuilder.strokes(samples + predicted.filter { $0.time > (samples.last?.time ?? -.infinity) }, settings: strokeSettings, creationDate: date, seed: seed, recognizedShape: recognized))
    }
    private func snap(_ shape: RecognizedShape) -> RecognizedShape { strokeSettings.roundedShapes ? (snapShape?(shape) ?? shape) : shape }
    func recognizeHeldShape() {
        guard active, !awaitingEnd, recognizedBase == nil, let shape = ShapeRecognition.recognize(samples.map(\.point)) else { return }
        recognized = snap(shape); recognizedBase = recognized; holdHandle = samples.last?.point ?? .zero
        updatePreview(predicted: [])
    }
    private func scheduleRecognition() {
        guard active, recognizedBase == nil, strokeSettings.drawAndHold || strokeSettings.tool == .shapes, let point = samples.last?.point else { return }
        guard strokeSettings.tool != .shapes || strokeSettings.holdForShapes else { return }
        if let previous = holdPoint, hypot(previous.x - point.x, previous.y - point.y) < 3 { return }
        holdPoint = point; holdTask?.cancel()
        let expected = generation
        let task = DispatchWorkItem { [weak self] in if self?.generation == expected { self?.recognizeHeldShape() } }
        holdTask = task; DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: task)
    }
    private func accepts(_ touch: UITouch) -> Bool {
        StylusInputPolicy.drawingTouches(finger: settings.finger, pencilConnected: settings.pencilConnected).contains(touch.type)
    }
    private func sample(_ touch: UITouch) -> InkSample {
        let p = touch.preciseLocation(in: self)
        let force = StylusInputPolicy.force(type: touch.type, value: touch.force, maximum: touch.maximumPossibleForce, mode: active ? strokeSettings.pressureMode : settings.pressureMode)
        var roll: CGFloat = 0
        if #available(iOS 17.5, macCatalyst 17.5, *), touch.type == .pencil { roll = touch.rollAngle }
        let altitude = touch.type == .pencil && touch.altitudeAngle > 0 ? touch.altitudeAngle : .pi / 2
        return InkSample(point: p, time: touch.timestamp, force: force, altitude: altitude, azimuth: touch.type == .pencil ? touch.azimuthAngle(in: self) : 0, roll: roll, estimateID: touch.estimationUpdateIndex?.intValue, awaitingUpdate: !touch.estimatedPropertiesExpectingUpdates.isEmpty)
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let pencil = touches.first(where: { $0.type == .pencil && accepts($0) }), activeTouch?.type != .pencil {
            if active && activeTouch != nil { cancelStroke() }
            beginStroke(sample(pencil), source: .pencil); activeTouch = pencil; return
        }
        guard activeTouch == nil, let touch = touches.first(where: accepts) else { return }
        beginStroke(sample(touch), source: touch.type); activeTouch = touch
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        addSamples((event?.coalescedTouches(for: touch) ?? [touch]).map(sample), predicted: (event?.predictedTouches(for: touch) ?? []).map(sample))
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        addSamples((event?.coalescedTouches(for: touch) ?? [touch]).map(sample)); endStroke()
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }; interruptStroke(source: touch.type)
    }
    override func touchesEstimatedPropertiesUpdated(_ touches: Set<UITouch>) { for touch in touches { updateEstimate(sample(touch)) } }
    private func suspendScrolling() {
        restoreScrolling()
        var ancestor = superview
        while let view = ancestor {
            if let scroll = view as? UIScrollView {
                suspendedScrolling.append(ScrollingState(scroll: scroll, pan: scroll.panGestureRecognizer.isEnabled, pinch: scroll.pinchGestureRecognizer?.isEnabled ?? false))
                scroll.panGestureRecognizer.isEnabled = false; scroll.pinchGestureRecognizer?.isEnabled = false
            }
            ancestor = view.superview
        }
    }
    private func restoreScrolling() {
        for state in suspendedScrolling { state.scroll?.panGestureRecognizer.isEnabled = state.pan; state.scroll?.pinchGestureRecognizer?.isEnabled = state.pinch }
        suspendedScrolling.removeAll()
    }
}
