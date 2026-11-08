import UIKit
import PencilKit

enum GeometricShape: String, CaseIterable, Codable {
    case freehand, elbow, curve, rectangle, ellipse, triangle, diamond, roundedRectangle
    var label: String {
        switch self { case .freehand: return "Freihand"; case .elbow: return "Winkellinie"; case .curve: return "Kurve"; case .rectangle: return "Rechteck"; case .ellipse: return "Ellipse"; case .triangle: return "Dreieck"; case .diamond: return "Raute"; case .roundedRectangle: return "Abgerundetes Rechteck" }
    }
    var asset: String {
        switch self {
        case .freehand: return "newToolbar/shapes/drawing_mode"
        case .elbow: return "ShapeTool/line_type/elbow_none_triangle"
        case .curve: return "ShapeTool/line_type/curved_none_triangle"
        case .rectangle: return "ShapeTool/shape_type/rectangle"
        case .ellipse: return "ShapeTool/shape_type/ellipse"
        case .triangle: return "ShapeTool/shape_type/triangle"
        case .diamond: return "ShapeTool/shape_type/diamond"
        case .roundedRectangle: return "ShapeTool/shape_type/roundedRect"
        }
    }
    var isClosed: Bool { ![.freehand, .elbow, .curve].contains(self) }

    func points(from start: CGPoint, to end: CGPoint, samples: [CGPoint]) -> [CGPoint] {
        let r = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        switch self {
        case .freehand: return samples
        case .elbow: return [start, CGPoint(x: end.x, y: start.y), end]
        case .curve:
            return (0...48).map { i in
                let t = CGFloat(i) / 48, u = 1 - t
                return CGPoint(x: u*u*u*start.x + 3*u*u*t*end.x + 3*u*t*t*start.x + t*t*t*end.x, y: u*u*u*start.y + 3*u*u*t*start.y + 3*u*t*t*end.y + t*t*t*end.y)
            }
        case .rectangle: return [r.origin, CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY), r.origin]
        case .ellipse:
            return (0...96).map { i in let a = CGFloat(i) * .pi / 48; return CGPoint(x: r.midX + cos(a) * r.width / 2, y: r.midY + sin(a) * r.height / 2) }
        case .triangle: return [CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.midX, y: r.minY)]
        case .diamond: return [CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.midX, y: r.minY)]
        case .roundedRectangle:
            let radius = min(r.width, r.height) * 0.2
            var result: [CGPoint] = []
            for (index, center) in [CGPoint(x: r.maxX - radius, y: r.minY + radius), CGPoint(x: r.maxX - radius, y: r.maxY - radius), CGPoint(x: r.minX + radius, y: r.maxY - radius), CGPoint(x: r.minX + radius, y: r.minY + radius)].enumerated() {
                for i in 0...16 { let a = CGFloat(index - 1) * .pi / 2 + CGFloat(i) * .pi / 32; result.append(CGPoint(x: center.x + cos(a)*radius, y: center.y + sin(a)*radius)) }
            }
            if let first = result.first { result.append(first) }; return result
        }
    }
}

enum StrokePattern: String, CaseIterable, Codable { case solid = "Durchgehend", dashed = "Gestrichelt", dotted = "Gepunktet" }

enum GeometricInk {
    static func path(_ points: [CGPoint]) -> UIBezierPath {
        let path = UIBezierPath(); guard let first = points.first else { return path }
        path.move(to: first); for point in points.dropFirst() { path.addLine(to: point) }; return path
    }
    static func strokes(points: [CGPoint], settings: ToolSettings, closed: Bool) -> [PKStroke] {
        guard points.count > 1 else { return [] }
        let color = UIColor(hex: settings.color), width = max(0.1, settings.width)
        var strokes: [PKStroke] = []
        if closed && settings.fillShapes && settings.fillOpacity > 0 {
            let mask = path(points); mask.close()
            let box = mask.bounds
            if box.width > 0 && box.height > 0 {
                let fill = StrokeFactory.stroke(points: [CGPoint(x: box.minX, y: box.midY), CGPoint(x: box.maxX, y: box.midY)], color: color.withAlphaComponent(CGFloat(settings.fillOpacity)), width: box.height + 4)
                strokes.append(PKStroke(ink: fill.ink, path: fill.path, mask: mask))
            }
        }
        // Dense polyline controls retain corners in PencilKit's spline representation.
        let dense = points.enumerated().flatMap { index, point -> [CGPoint] in
            guard index > 0 else { return [point] }
            let before = points[index - 1], length = hypot(point.x - before.x, point.y - before.y)
            let count = max(1, min(512, Int(ceil(length / 2))))
            return (1...count).map { i in let t = CGFloat(i) / CGFloat(count); return CGPoint(x: before.x + (point.x - before.x)*t, y: before.y + (point.y - before.y)*t) }
        }
        if settings.strokePattern == .solid {
            strokes.append(StrokeFactory.stroke(points: dense, color: color, width: width))
            appendArrow(points, settings: settings, to: &strokes)
            return strokes
        }
        let dash: CGFloat = settings.strokePattern == .dotted ? max(width, 1) : max(width * 5, 8)
        let gap = max(width * 3, 5)
        var distance: CGFloat = 0, segment: [CGPoint] = []
        for (index, point) in dense.enumerated() {
            if index > 0 { distance += hypot(point.x - dense[index-1].x, point.y - dense[index-1].y) }
            if distance.truncatingRemainder(dividingBy: dash + gap) < dash { segment.append(point) }
            else if !segment.isEmpty { appendSegment(segment, color: color, width: width, to: &strokes); segment.removeAll(keepingCapacity: true) }
        }
        appendSegment(segment, color: color, width: width, to: &strokes)
        appendArrow(points, settings: settings, to: &strokes)
        return strokes
    }
    static func arrowhead(_ points: [CGPoint], width: CGFloat) -> [CGPoint] {
        guard let end = points.last, points.count > 1 else { return [] }
        let before = points[points.count - 2], angle = atan2(end.y - before.y, end.x - before.x), size = max(10, width * 6)
        return [CGPoint(x: end.x - cos(angle - .pi / 6) * size, y: end.y - sin(angle - .pi / 6) * size), end, CGPoint(x: end.x - cos(angle + .pi / 6) * size, y: end.y - sin(angle + .pi / 6) * size)]
    }
    private static func appendArrow(_ points: [CGPoint], settings: ToolSettings, to strokes: inout [PKStroke]) {
        if settings.tool == .geometry && [.elbow, .curve].contains(settings.geometricShape) { strokes.append(StrokeFactory.stroke(points: arrowhead(points, width: settings.width), color: UIColor(hex: settings.color), width: settings.width)) }
    }
    private static func appendSegment(_ points: [CGPoint], color: UIColor, width: CGFloat, to strokes: inout [PKStroke]) {
        guard let first = points.first else { return }
        strokes.append(StrokeFactory.stroke(points: points.count > 1 ? points : [first, CGPoint(x: first.x + 0.01, y: first.y)], color: color, width: width))
    }
}
