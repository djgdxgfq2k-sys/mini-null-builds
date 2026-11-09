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

/// Goodnotes' three erasers on the editable PencilKit layer. Imported original ink and PDF backgrounds stay intact.
/// - Precision: removes exactly what lies under the eraser circle (masks the stroke).
/// - Standard: cuts the touched piece out of the stroke across its full width and drops leftover crumbs,
///   so no thin slivers or traces stay behind ("Effizientes Löschen ohne Spuren zu hinterlassen").
/// - Stroke: removes every stroke the eraser touches.
enum FilteredEraser {
    /// PencilKit erases natively (and fastest) for unfiltered precision and stroke erasing only.
    static func needsOverlay(_ settings: ToolSettings) -> Bool { settings.eraserStyle == .standard || !settings.eraserFilters.allEnabled }

    static func erase(_ drawing: PKDrawing, points: [CGPoint], diameter: CGFloat, style: EraserStyle, filters: EraserFilters) -> PKDrawing? {
        guard let first = points.first, diameter > 0 else { return nil }
        let radius = diameter / 2
        let path = points.count == 1 ? [first, first] : points
        let reach = path.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }.insetBy(dx: -radius, dy: -radius)
        var changed = false
        var result: [PKStroke] = []
        result.reserveCapacity(drawing.strokes.count)
        for stroke in drawing.strokes {
            guard filters.includes(stroke.ink), stroke.renderBounds.intersects(reach) else { result.append(stroke); continue }
            switch style {
            case .stroke:
                if touches(stroke, path: path, radius: radius) { changed = true } else { result.append(stroke) }
            case .standard:
                guard let pieces = cut(stroke, path: path, radius: radius) else { result.append(stroke); continue }
                changed = true; result.append(contentsOf: pieces)
            case .precision:
                guard let masked = mask(stroke, path: path, radius: radius) else { result.append(stroke); continue }
                changed = true; if let masked = masked { result.append(masked) }
            }
        }
        return changed ? PKDrawing(strokes: result) : nil
    }

    // MARK: Geometry

    private static func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
        guard length > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
    private static func distance(_ p: CGPoint, toPath path: [CGPoint]) -> CGFloat {
        var best = CGFloat.greatestFiniteMagnitude
        for i in 1 ..< path.count { best = min(best, distance(p, toSegment: path[i - 1], path[i])) }
        return best
    }
    /// Dense samples in stroke space plus whether each lies under the eraser (in page space).
    private static func samples(_ stroke: PKStroke, path: [CGPoint], radius: CGFloat) -> (points: [PKStrokePoint], hit: [Bool]) {
        let points = Array(stroke.path.interpolatedPoints(by: .distance(1.5)))
        let hit = points.map { point -> Bool in
            let world = point.location.applying(stroke.transform)
            let half = max(point.size.width, point.size.height) / 2
            return distance(world, toPath: path) <= radius + half * 0.8
        }
        return (points, hit)
    }
    private static func touches(_ stroke: PKStroke, path: [CGPoint], radius: CGFloat) -> Bool {
        samples(stroke, path: path, radius: radius).hit.contains(true)
    }

    /// Remaining pieces of a stroke after cutting out the touched samples, or nil when untouched.
    static func cut(_ stroke: PKStroke, path: [CGPoint], radius: CGFloat) -> [PKStroke]? {
        let (points, hit) = samples(stroke, path: path, radius: radius)
        guard hit.contains(true) else { return nil }
        var pieces: [PKStroke] = []
        var run: [PKStrokePoint] = []
        func flush() {
            defer { run.removeAll(keepingCapacity: true) }
            guard run.count >= 2 else { return }
            var length: CGFloat = 0
            for i in 1 ..< run.count { length += hypot(run[i].location.x - run[i - 1].location.x, run[i].location.y - run[i - 1].location.y) }
            let width = run.map { $0.size.width }.max() ?? 1
            // Crumbs shorter than the line is thick would read as specks: drop them, leave no traces.
            guard length >= max(2, width * 0.9) else { return }
            let start = run[0].timeOffset
            let shifted = run.map { PKStrokePoint(location: $0.location, timeOffset: $0.timeOffset - start, size: $0.size, opacity: $0.opacity, force: $0.force, azimuth: $0.azimuth, altitude: $0.altitude) }
            let piece = PKStrokePath(controlPoints: shifted, creationDate: stroke.path.creationDate.addingTimeInterval(start))
            pieces.append(PKStroke(ink: stroke.ink, path: piece, transform: stroke.transform, mask: stroke.mask, randomSeed: stroke.randomSeed))
        }
        for (point, erased) in zip(points, hit) { if erased { flush() } else { run.append(point) } }
        flush()
        return pieces
    }

    /// Precision erasing: subtract the swept circle from the stroke's mask. Outer nil = untouched, inner nil = fully erased.
    private static func mask(_ stroke: PKStroke, path: [CGPoint], radius: CGFloat) -> PKStroke?? {
        guard touches(stroke, path: path, radius: radius) else { return nil }
        let line = CGMutablePath(); line.move(to: path[0]); for point in path.dropFirst() { line.addLine(to: point) }
        let sweep = line.copy(strokingWithWidth: radius * 2, lineCap: .round, lineJoin: .round, miterLimit: 1)
        var inverse = stroke.transform.inverted()
        guard let localSweep = sweep.copy(using: &inverse) else { return nil }
        let base = stroke.mask?.cgPath ?? CGPath(rect: stroke.renderBounds.applying(inverse).insetBy(dx: -2, dy: -2), transform: nil)
        let remaining = base.subtracting(localSweep, using: .winding)
        guard !remaining.isEmpty else { return .some(nil) }
        return .some(PKStroke(ink: stroke.ink, path: stroke.path, transform: stroke.transform, mask: UIBezierPath(cgPath: remaining), randomSeed: stroke.randomSeed))
    }
}
