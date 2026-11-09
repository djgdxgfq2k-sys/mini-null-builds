import PencilKit
import UIKit

/// Goodnotes-style tape: a straight, opaque strip laid over the page to hide what is under it.
/// Tapping a strip with the tape tool peels it back to a faint outline; tapping again covers it.
/// Strips are ordinary PencilKit strokes, so they can be erased, lassoed and undone like any ink.
enum TapeInk {
    static let width: CGFloat = 22
    static let coveredAlpha: CGFloat = 0.97
    static let peeledAlpha: CGFloat = 0.18
    /// A short contact is a tap: it travels to the canvas as an invisible probe stroke instead of ink.
    static let probeAlpha: CGFloat = 0

    static func strokes(_ input: [InkSample], settings: ToolSettings, creationDate: Date) -> [PKStroke] {
        guard let first = input.first?.point, let last = input.last?.point else { return [] }
        let travelled = zip(input, input.dropFirst()).reduce(CGFloat(0)) { $0 + hypot($1.1.point.x - $1.0.point.x, $1.1.point.y - $1.0.point.y) }
        if travelled < 6 {
            return [stroke(from: first, to: CGPoint(x: first.x + 0.01, y: first.y), color: UIColor(hex: settings.tapeColor).withAlphaComponent(probeAlpha), width: 0.5, date: creationDate)]
        }
        return [stroke(from: first, to: last, color: UIColor(hex: settings.tapeColor).withAlphaComponent(coveredAlpha), width: width, date: creationDate)]
    }
    static func stroke(from a: CGPoint, to b: CGPoint, color: UIColor, width: CGFloat, date: Date) -> PKStroke {
        let length = hypot(b.x - a.x, b.y - a.y), steps = max(1, Int(length / 4))
        let points = (0 ... steps).map { i -> PKStrokePoint in
            let t = CGFloat(i) / CGFloat(steps)
            return PKStrokePoint(location: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), timeOffset: Double(i) / 240, size: CGSize(width: width, height: width), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.monoline, color: color), path: PKStrokePath(controlPoints: points, creationDate: date))
    }
    private static func alpha(_ stroke: PKStroke) -> CGFloat { stroke.ink.color.cgColor.alpha }
    static func isProbe(_ stroke: PKStroke) -> Bool { stroke.ink.inkType == .monoline && alpha(stroke) < 0.001 && (stroke.path.first?.size.width ?? 1) < 1 }
    static func isTape(_ stroke: PKStroke) -> Bool {
        guard stroke.ink.inkType == .monoline, (stroke.path.first?.size.width ?? 0) >= width - 0.5 else { return false }
        let a = alpha(stroke)
        return abs(a - coveredAlpha) < 0.01 || abs(a - peeledAlpha) < 0.01
    }
    /// Flips the topmost strip under `point`; nil when the tap missed every strip.
    static func toggled(_ drawing: PKDrawing, at point: CGPoint) -> PKDrawing? {
        var strokes = drawing.strokes
        for index in strokes.indices.reversed() where isTape(strokes[index]) {
            let s = strokes[index]
            guard let a = s.path.first?.location.applying(s.transform), let b = s.path.last?.location.applying(s.transform) else { continue }
            let dx = b.x - a.x, dy = b.y - a.y, lengthSquared = max(0.0001, dx * dx + dy * dy)
            let t = min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
            let distance = hypot(point.x - (a.x + dx * t), point.y - (a.y + dy * t))
            guard distance <= width / 2 + 4 else { continue }
            let covered = abs(alpha(s) - coveredAlpha) < 0.01
            let color = s.ink.color.withAlphaComponent(covered ? peeledAlpha : coveredAlpha)
            strokes[index] = PKStroke(ink: PKInk(.monoline, color: color), path: s.path, transform: s.transform, mask: s.mask)
            return PKDrawing(strokes: strokes)
        }
        return nil
    }
}

/// "Bestimmte Objekte löschen": clears one kind of content from the current page.
enum ClearKind: String, CaseIterable, Identifiable {
    case pens = "Stifte und Bleistifte", highlighters = "Textmarker", tape = "Klebeband", text = "Text und Notizzettel"
    var id: String { rawValue }
    func removes(_ stroke: PKStroke) -> Bool {
        switch self {
        case .tape: return TapeInk.isTape(stroke)
        case .highlighters: return stroke.ink.inkType == .marker
        case .pens: return stroke.ink.inkType != .marker && !TapeInk.isTape(stroke)
        case .text: return false
        }
    }
}
