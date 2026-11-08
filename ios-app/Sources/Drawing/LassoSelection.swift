import PencilKit
import UIKit

/// Stroke selection rules for the custom lasso. A stroke is selected when most of its length lies inside the loop.
enum LassoSelection {
    static func polygonPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first); path.addLines(between: points); path.closeSubpath()
        return path
    }
    static func rectangle(from a: CGPoint, to b: CGPoint) -> [CGPoint] {
        [a, CGPoint(x: b.x, y: a.y), b, CGPoint(x: a.x, y: b.y)]
    }
    static func indices(in drawing: PKDrawing, polygon: [CGPoint]) -> IndexSet {
        guard polygon.count > 2 else { return [] }
        let path = polygonPath(polygon), area = path.boundingBoxOfPath
        var result = IndexSet()
        for (index, stroke) in drawing.strokes.enumerated() where stroke.renderBounds.intersects(area) {
            let points = samplePoints(stroke)
            guard !points.isEmpty else { continue }
            let inside = points.filter { path.contains($0, using: .winding) }.count
            if inside * 2 >= points.count { result.insert(index) }
        }
        return result
    }
    static func samplePoints(_ stroke: PKStroke) -> [CGPoint] {
        var points = stroke.path.interpolatedPoints(by: .distance(4)).map { $0.location.applying(stroke.transform) }
        if points.isEmpty, let first = stroke.path.first { points = [first.location.applying(stroke.transform)] }
        return points
    }
    static func bounds(_ drawing: PKDrawing, _ indices: IndexSet) -> CGRect {
        indices.reduce(CGRect.null) { rect, i in drawing.strokes.indices.contains(i) ? rect.union(drawing.strokes[i].renderBounds) : rect }
    }
    static func translated(_ drawing: PKDrawing, _ indices: IndexSet, by offset: CGPoint) -> PKDrawing {
        var next = drawing
        for i in indices where next.strokes.indices.contains(i) {
            next.strokes[i].transform = next.strokes[i].transform.concatenating(CGAffineTransform(translationX: offset.x, y: offset.y))
        }
        return next
    }
    static func recolored(_ drawing: PKDrawing, _ indices: IndexSet, color: UIColor) -> PKDrawing {
        var next = drawing
        for i in indices where next.strokes.indices.contains(i) {
            let ink = next.strokes[i].ink
            next.strokes[i].ink = PKInk(ink.inkType, color: ink.inkType == .marker ? color.withAlphaComponent(0.35) : color)
        }
        return next
    }
    static func removing(_ drawing: PKDrawing, _ indices: IndexSet) -> PKDrawing {
        PKDrawing(strokes: drawing.strokes.enumerated().filter { !indices.contains($0.offset) }.map(\.element))
    }
    static func selected(_ drawing: PKDrawing, _ indices: IndexSet) -> PKDrawing {
        PKDrawing(strokes: drawing.strokes.enumerated().filter { indices.contains($0.offset) }.map(\.element))
    }
    /// Appends a copy offset like the original's duplicate and returns the drawing plus the indices of the copies.
    static func duplicated(_ drawing: PKDrawing, _ indices: IndexSet, offset: CGPoint = CGPoint(x: 20, y: 20)) -> (PKDrawing, IndexSet) {
        let copies = translated(selected(drawing, indices), IndexSet(integersIn: 0..<indices.count), by: offset).strokes
        let start = drawing.strokes.count
        return (PKDrawing(strokes: drawing.strokes + copies), IndexSet(integersIn: start..<(start + copies.count)))
    }
}

/// Custom lasso surface matching the original: blue dashed loop, floating white action menu,
/// a translucent preview while dragging, and the menu fading back in after the drop.
final class LassoSelectionView: UIView, UIGestureRecognizerDelegate {
    static let tint = UIColor(red: 0.29, green: 0.56, blue: 0.85, alpha: 1)
    var drawing: (() -> PKDrawing)?
    var commit: ((PKDrawing) -> Void)?
    var onInteraction: ((Bool) -> Void)?
    var rectangular = false
    private(set) var selection = IndexSet()
    private let loop = CAShapeLayer()
    private let menu = UIStackView()
    private let menuBackground = UIView()
    private let ghost = UIImageView()
    private var points: [CGPoint] = []
    private var start = CGPoint.zero
    private var dragging = false
    private var dragOrigin = CGPoint.zero
    private var selectionPath: CGPath?
    private let pan = UIPanGestureRecognizer()
    private let tap = UITapGestureRecognizer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        loop.strokeColor = Self.tint.cgColor; loop.fillColor = nil; loop.lineWidth = 1.5; loop.lineDashPattern = [5, 4]
        loop.lineCap = .round; loop.lineJoin = .round
        layer.addSublayer(loop)
        ghost.alpha = 0.5; ghost.isHidden = true; addSubview(ghost)
        buildMenu()
        pan.addTarget(self, action: #selector(panned(_:))); pan.maximumNumberOfTouches = 1; pan.delegate = self; addGestureRecognizer(pan)
        tap.addTarget(self, action: #selector(tapped(_:))); addGestureRecognizer(tap)
    }
    required init?(coder: NSCoder) { nil }

    func setAllowedTouches(_ types: [UITouch.TouchType]) {
        let values = types.map { NSNumber(value: $0.rawValue) }
        pan.allowedTouchTypes = values; tap.allowedTouchTypes = values
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, isUserInteractionEnabled else { return nil }
        if !menuBackground.isHidden, menuBackground.alpha > 0.01, let hit = menuBackground.hitTest(convert(point, to: menuBackground), with: event) { return hit }
        return super.hitTest(point, with: event)
    }

    // MARK: Menu

    private func buildMenu() {
        menuBackground.backgroundColor = .white; menuBackground.layer.cornerRadius = 16
        menuBackground.layer.shadowColor = UIColor.black.cgColor; menuBackground.layer.shadowOpacity = 0.16
        menuBackground.layer.shadowRadius = 10; menuBackground.layer.shadowOffset = CGSize(width: 0, height: 3)
        menuBackground.isHidden = true; menuBackground.alpha = 0
        menu.axis = .horizontal; menu.spacing = 2; menu.alignment = .center
        menu.translatesAutoresizingMaskIntoConstraints = false
        menuBackground.addSubview(menu)
        NSLayoutConstraint.activate([
            menu.leadingAnchor.constraint(equalTo: menuBackground.leadingAnchor, constant: 6),
            menu.trailingAnchor.constraint(equalTo: menuBackground.trailingAnchor, constant: -6),
            menu.topAnchor.constraint(equalTo: menuBackground.topAnchor),
            menu.bottomAnchor.constraint(equalTo: menuBackground.bottomAnchor)
        ])
        let color = button("paintpalette", "Farbe") {}
        let names = ["Rot", "Blau", "Grün", "Weiß", "Schwarz", "Gelb"]
        color.menu = UIMenu(title: "Farbe", children: Theme.inks.enumerated().map { index, hex in
            UIAction(title: names.indices.contains(index) ? names[index] : hex, image: UIImage(systemName: "circle.fill")?.withTintColor(UIColor(hex: hex), renderingMode: .alwaysOriginal)) { [weak self] _ in self?.recolor(hex) }
        })
        color.showsMenuAsPrimaryAction = true
        menu.addArrangedSubview(color)
        menu.addArrangedSubview(button("scissors", "Ausschneiden") { [weak self] in self?.cut() })
        menu.addArrangedSubview(button("doc.on.doc", "Kopieren") { [weak self] in self?.copySelection() })
        menu.addArrangedSubview(button("plus.square.on.square", "Duplizieren") { [weak self] in self?.duplicate() })
        menu.addArrangedSubview(button("trash", "Löschen", tint: UIColor(red: 0.89, green: 0.27, blue: 0.27, alpha: 1)) { [weak self] in self?.delete() })
        let more = button("ellipsis.circle", "Mehr") {}
        more.menu = UIMenu(children: [UIAction(title: "Als Bild kopieren", image: UIImage(systemName: "photo")) { [weak self] _ in self?.copyAsImage() }])
        more.showsMenuAsPrimaryAction = true
        menu.addArrangedSubview(more)
        addSubview(menuBackground)
    }
    private func button(_ symbol: String, _ label: String, tint: UIColor = UIColor(white: 0.24, alpha: 1), action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .system, primaryAction: UIAction { _ in action() })
        b.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .regular)), for: .normal)
        b.tintColor = tint; b.accessibilityLabel = label
        b.widthAnchor.constraint(equalToConstant: 36).isActive = true; b.heightAnchor.constraint(equalToConstant: 32).isActive = true
        return b
    }
    private var screenScale: CGFloat {
        guard window != nil else { return 1 }
        let unit = convert(CGRect(x: 0, y: 0, width: 1, height: 1), to: nil)
        return max(0.05, unit.width)
    }
    private func placeMenu() {
        guard let drawing = drawing?() else { return }
        let rect = LassoSelection.bounds(drawing, selection).union(selectionPath?.boundingBoxOfPath ?? .null)
        guard !rect.isNull else { return }
        let scale = screenScale
        menuBackground.transform = .identity
        let size = menuBackground.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        menuBackground.bounds = CGRect(origin: .zero, size: CGSize(width: max(size.width, 60), height: 32))
        // The menu keeps its on-screen size at any zoom level.
        let gap = 14 / scale, half = 16 / scale
        let above = rect.minY - gap - half
        let y = above > half ? above : rect.maxY + gap + half
        menuBackground.center = CGPoint(x: min(max(rect.midX, 0), bounds.width), y: y)
        menuBackground.transform = CGAffineTransform(scaleX: 1 / scale, y: 1 / scale)
    }
    private func showMenu() {
        placeMenu()
        menuBackground.isHidden = false
        let base = menuBackground.transform
        menuBackground.alpha = 0; menuBackground.transform = base.scaledBy(x: 0.92, y: 0.92)
        UIView.animate(withDuration: 0.12, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            self.menuBackground.alpha = 1; self.menuBackground.transform = base
        }
    }
    private func hideMenu(animated: Bool = true) {
        guard !menuBackground.isHidden else { return }
        UIView.animate(withDuration: animated ? 0.12 : 0, delay: 0, options: [.curveEaseIn, .allowUserInteraction], animations: { self.menuBackground.alpha = 0 },
            completion: { _ in if self.menuBackground.alpha < 0.01 { self.menuBackground.isHidden = true } })
    }

    // MARK: Selection state

    func clearSelection(animated: Bool = true) {
        selection = []; selectionPath = nil; dragging = false; ghost.isHidden = true
        hideMenu(animated: animated)
        fadeLoop(animated: animated)
    }
    private func fadeLoop(animated: Bool) {
        guard loop.path != nil else { return }
        if animated {
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0; fade.duration = 0.2
            loop.add(fade, forKey: "fade")
        }
        CATransaction.begin(); CATransaction.setDisableActions(true); loop.opacity = 0; loop.path = nil; loop.opacity = 1; CATransaction.commit()
    }
    private func select(_ indices: IndexSet, outline: CGPath) {
        selection = indices; selectionPath = outline
        CATransaction.begin(); CATransaction.setDisableActions(true); loop.removeAllAnimations(); loop.opacity = 1; loop.path = outline; CATransaction.commit()
        showMenu()
    }
    private func selectionContains(_ point: CGPoint) -> Bool {
        guard !selection.isEmpty else { return false }
        if let selectionPath, selectionPath.contains(point, using: .winding) { return true }
        guard let drawing = drawing?() else { return false }
        return LassoSelection.bounds(drawing, selection).insetBy(dx: -12, dy: -12).contains(point)
    }

    // MARK: Gestures

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        let p = recognizer.location(in: self)
        if selectionContains(p) { menuBackground.isHidden ? showMenu() : hideMenu() }
        else { clearSelection() }
    }
    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        let p = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            onInteraction?(true)
            if selectionContains(p) { beginDrag(at: p) }
            else {
                if !selection.isEmpty { clearSelection(animated: false) }
                start = p; points = [p]; loop.removeAllAnimations(); loop.opacity = 1; updateLoop(to: p)
            }
        case .changed:
            if dragging { moveDrag(to: p) } else { points.append(p); updateLoop(to: p) }
        case .ended:
            if dragging { endDrag(at: p) } else { points.append(p); finishLoop(at: p) }
            onInteraction?(false)
        default:
            if dragging { cancelDrag() } else { fadeLoop(animated: true) }
            onInteraction?(false)
        }
    }
    private func outline(to p: CGPoint) -> [CGPoint] { rectangular ? LassoSelection.rectangle(from: start, to: p) : points }
    private func updateLoop(to p: CGPoint) {
        let shape = outline(to: p)
        let path = CGMutablePath(); if let first = shape.first { path.move(to: first); path.addLines(between: shape); if rectangular { path.closeSubpath() } }
        CATransaction.begin(); CATransaction.setDisableActions(true); loop.path = path; CATransaction.commit()
    }
    private func finishLoop(at p: CGPoint) {
        let shape = outline(to: p)
        guard let drawing = drawing?() else { fadeLoop(animated: true); return }
        let found = LassoSelection.indices(in: drawing, polygon: shape)
        if found.isEmpty { fadeLoop(animated: true); return }
        select(found, outline: LassoSelection.polygonPath(shape))
    }
    private func beginDrag(at p: CGPoint) {
        guard let drawing = drawing?() else { return }
        dragging = true; dragOrigin = p; hideMenu()
        let rect = LassoSelection.bounds(drawing, selection).insetBy(dx: -2, dy: -2)
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return }
        ghost.image = LassoSelection.selected(drawing, selection).paperImage(from: rect, scale: max(1, min(3, screenScale * (window?.screen.scale ?? 2))))
        ghost.frame = rect; ghost.isHidden = false
    }
    private func moveDrag(to p: CGPoint) {
        let dx = p.x - dragOrigin.x, dy = p.y - dragOrigin.y
        ghost.transform = CGAffineTransform(translationX: dx, y: dy)
        CATransaction.begin(); CATransaction.setDisableActions(true); loop.setAffineTransform(CGAffineTransform(translationX: dx, y: dy)); CATransaction.commit()
    }
    private func endDrag(at p: CGPoint) {
        let offset = CGPoint(x: p.x - dragOrigin.x, y: p.y - dragOrigin.y)
        dragging = false; ghost.isHidden = true; ghost.transform = .identity
        CATransaction.begin(); CATransaction.setDisableActions(true); loop.setAffineTransform(.identity); CATransaction.commit()
        if hypot(offset.x, offset.y) > 0.5, let drawing = drawing?() {
            commit?(LassoSelection.translated(drawing, selection, by: offset))
            if let path = selectionPath { var move = CGAffineTransform(translationX: offset.x, y: offset.y); selectionPath = path.copy(using: &move) }
            CATransaction.begin(); CATransaction.setDisableActions(true); loop.path = selectionPath; CATransaction.commit()
        }
        showMenu()
    }
    private func cancelDrag() {
        dragging = false; ghost.isHidden = true; ghost.transform = .identity
        CATransaction.begin(); CATransaction.setDisableActions(true); loop.setAffineTransform(.identity); CATransaction.commit()
        showMenu()
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === pan || gestureRecognizer === tap {
            let p = gestureRecognizer.location(in: menuBackground)
            if !menuBackground.isHidden && menuBackground.bounds.contains(p) { return false }
        }
        return true
    }

    // MARK: Actions

    private func copySelection() {
        guard let drawing = drawing?(), !selection.isEmpty else { return }
        let picked = LassoSelection.selected(drawing, selection)
        UIPasteboard.general.setData(picked.dataRepresentation(), forPasteboardType: "com.apple.drawing")
        hideMenu()
    }
    private func copyAsImage() {
        guard let drawing = drawing?(), !selection.isEmpty else { return }
        let rect = LassoSelection.bounds(drawing, selection)
        guard !rect.isNull else { return }
        UIPasteboard.general.image = LassoSelection.selected(drawing, selection).paperImage(from: rect, scale: 2)
        hideMenu()
    }
    private func recolor(_ hex: String) {
        guard let drawing = drawing?(), !selection.isEmpty else { return }
        commit?(LassoSelection.recolored(drawing, selection, color: UIColor(hex: hex)))
    }
    private func cut() { copySelection(); delete() }
    private func delete() {
        guard let drawing = drawing?(), !selection.isEmpty else { return }
        commit?(LassoSelection.removing(drawing, selection)); clearSelection()
    }
    private func duplicate() {
        guard let drawing = drawing?(), !selection.isEmpty else { return }
        let (next, copies) = LassoSelection.duplicated(drawing, selection)
        commit?(next)
        var move = CGAffineTransform(translationX: 20, y: 20)
        let outline = selectionPath?.copy(using: &move) ?? CGPath(rect: LassoSelection.bounds(next, copies), transform: nil)
        hideMenu(animated: false); select(copies, outline: outline)
    }
}
