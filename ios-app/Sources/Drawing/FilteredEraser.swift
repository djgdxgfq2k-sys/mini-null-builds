import PencilKit
import UIKit

struct EraserFilters: Equatable, Codable {
    var pen = true
    var pencil = true
    var marker = true
    var tape = true
    var allEnabled: Bool { pen && pencil && marker && tape }
    func includes(_ ink: PKInk) -> Bool {
        switch ink.inkType { case .pencil: return pencil; case .marker: return marker; default: return pen }
    }
}

enum FilteredEraser {
    /// Only the local editable PencilKit layer is changed. Imported original ink and PDF backgrounds remain intact.
    static func erase(_ drawing: PKDrawing, points: [CGPoint], diameter: CGFloat, style: EraserStyle, filters: EraserFilters) -> PKDrawing? {
        guard let first = points.first, diameter > 0 else { return nil }
        let sweep: CGPath
        if points.count == 1 { sweep = CGPath(ellipseIn: CGRect(x: first.x - diameter / 2, y: first.y - diameter / 2, width: diameter, height: diameter), transform: nil) }
        else {
            let line = CGMutablePath(); line.move(to: first); for point in points.dropFirst() { line.addLine(to: point) }
            sweep = line.copy(strokingWithWidth: diameter, lineCap: .round, lineJoin: .round, miterLimit: 1)
        }
        var changed = false
        let strokes = drawing.strokes.compactMap { stroke -> PKStroke? in
            guard filters.includes(stroke.ink), stroke.renderBounds.intersects(sweep.boundingBoxOfPath) else { return stroke }
            let samples = Array(stroke.path.interpolatedPoints(by: .distance(1)))
            guard let first = samples.first else { return stroke }
            let width = max(0.5, samples.map { max($0.size.width, $0.size.height) }.max() ?? 1)
            let footprint: CGPath
            if samples.count == 1 { footprint = CGPath(ellipseIn: CGRect(x: first.location.x - width / 2, y: first.location.y - width / 2, width: width, height: width), transform: nil) }
            else {
                let center = CGMutablePath(); center.move(to: first.location); for point in samples.dropFirst() { center.addLine(to: point.location) }
                footprint = center.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 1)
            }
            let visible = stroke.mask.map { footprint.intersection($0.cgPath, using: .winding) } ?? footprint
            var transform = stroke.transform
            guard let world = visible.copy(using: &transform), !world.intersection(sweep, using: .winding).isEmpty else { return stroke }
            changed = true
            if style == .stroke { return nil }
            var inverse = stroke.transform.inverted()
            guard let localSweep = sweep.copy(using: &inverse) else { return stroke }
            let mask = stroke.mask?.cgPath ?? CGPath(rect: stroke.renderBounds.applying(inverse).insetBy(dx: -2, dy: -2), transform: nil)
            let remaining = mask.subtracting(localSweep, using: .winding)
            guard !remaining.isEmpty else { return nil }
            return PKStroke(ink: stroke.ink, path: stroke.path, transform: stroke.transform, mask: UIBezierPath(cgPath: remaining), randomSeed: stroke.randomSeed)
        }
        return changed ? PKDrawing(strokes: strokes) : nil
    }
}
