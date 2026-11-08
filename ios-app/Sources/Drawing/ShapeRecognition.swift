import UIKit

struct RecognizedShape {
    var points: [CGPoint]
    var closed: Bool
    var anchor: CGPoint {
        guard closed else { return points.first ?? .zero }
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGPoint(x: ((xs.min() ?? 0) + (xs.max() ?? 0)) / 2, y: ((ys.min() ?? 0) + (ys.max() ?? 0)) / 2)
    }
    func adjusted(from handle: CGPoint, to point: CGPoint) -> RecognizedShape {
        let origin = anchor, before = hypot(handle.x - origin.x, handle.y - origin.y)
        guard before > 2 else { return self }
        let scale = min(10, max(0.1, hypot(point.x - origin.x, point.y - origin.y) / before))
        let angle = atan2(point.y - origin.y, point.x - origin.x) - atan2(handle.y - origin.y, handle.x - origin.x)
        return RecognizedShape(points: points.map { p in let x = (p.x - origin.x) * scale, y = (p.y - origin.y) * scale; return CGPoint(x: origin.x + x * cos(angle) - y * sin(angle), y: origin.y + x * sin(angle) + y * cos(angle)) }, closed: closed)
    }
    func snapped(to anchors: [CGPoint], tolerance: CGFloat = 8) -> RecognizedShape {
        guard !points.isEmpty else { return self }
        func target(_ p: CGPoint) -> CGPoint? { anchors.filter { hypot($0.x - p.x, $0.y - p.y) <= tolerance }.min { hypot($0.x - p.x, $0.y - p.y) < hypot($1.x - p.x, $1.y - p.y) } }
        if closed {
            for point in points { if let other = target(point) { return RecognizedShape(points: points.map { CGPoint(x: $0.x + other.x - point.x, y: $0.y + other.y - point.y) }, closed: true) } }
            return self
        }
        let first = points[0], last = points[points.count - 1], start = target(first) ?? first, end = target(last) ?? last
        return RecognizedShape(points: points.enumerated().map { i, point in let t = CGFloat(i) / CGFloat(max(1, points.count - 1)); return CGPoint(x: point.x + (start.x - first.x) * (1 - t) + (end.x - last.x) * t, y: point.y + (start.y - first.y) * (1 - t) + (end.y - last.y) * t) }, closed: false)
    }
}

enum ShapeRecognition {
    static func recognize(_ input: [CGPoint]) -> RecognizedShape? {
        let valid = input.filter { $0.x.isFinite && $0.y.isFinite }
        let step = max(1, Int(ceil(Double(valid.count) / 512)))
        var points = stride(from: 0, to: valid.count, by: step).map { valid[$0] }
        if let last = valid.last, points.last != last { points.append(last) }
        guard points.count >= 2, let first = points.first, let last = points.last else { return nil }
        let xs = points.map(\.x), ys = points.map(\.y)
        let bounds = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        let diagonal = hypot(bounds.width, bounds.height)
        guard diagonal > 8 else { return nil }
        let length = zip(points, points.dropFirst()).reduce(CGFloat(0)) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        let chord = hypot(last.x - first.x, last.y - first.y)
        if chord > 5 && chord / max(1, length) > 0.9 {
            return RecognizedShape(points: [first, last], closed: false)
        }
        let closed = chord < max(12, diagonal * 0.18)
        if !closed {
            guard chord > diagonal * 0.5 else { return nil }
            let mid = points[points.count / 2]
            let control = CGPoint(x: mid.x * 2 - (first.x + last.x) / 2, y: mid.y * 2 - (first.y + last.y) / 2)
            let projected = points.map { (($0.x - first.x) * (last.x - first.x) + ($0.y - first.y) * (last.y - first.y)) / (chord * chord) }
            let backwards = zip(projected, projected.dropFirst()).filter { $0.1 < $0.0 - 0.02 }.count
            guard backwards < max(2, points.count / 10), length < chord * 2 else { return nil }
            let curve = (0...48).map { i in let t = CGFloat(i) / 48, u = 1 - t; return CGPoint(x: u*u*first.x + 2*u*t*control.x + t*t*last.x, y: u*u*first.y + 2*u*t*control.y + t*t*last.y) }
            let squaredError = points.reduce(CGFloat(0)) { sum, p in sum + (curve.map { ($0.x - p.x) * ($0.x - p.x) + ($0.y - p.y) * ($0.y - p.y) }.min() ?? 0) }
            guard sqrt(squaredError / CGFloat(points.count)) < diagonal * 0.06 else { return nil }
            return RecognizedShape(points: curve, closed: false)
        }
        if bounds.width > 5 && bounds.height > 5 {
            let radialError = points.reduce(CGFloat(0)) { sum, p in
                let x = (p.x - bounds.midX) / (bounds.width / 2), y = (p.y - bounds.midY) / (bounds.height / 2)
                return sum + abs(hypot(x, y) - 1)
            } / CGFloat(points.count)
            if radialError < 0.13 { return RecognizedShape(points: GeometricShape.ellipse.points(from: bounds.origin, to: CGPoint(x: bounds.maxX, y: bounds.maxY), samples: []), closed: true) }
        }
        var loop = points; if loop.last != first { loop.append(first) }
        var vertices = simplify(loop, tolerance: max(3, diagonal * 0.045))
        if vertices.first == vertices.last { vertices.removeLast() }
        guard (3...6).contains(vertices.count) else { return nil }
        vertices.append(vertices[0])
        return RecognizedShape(points: vertices, closed: true)
    }
    private static func simplify(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2, let a = points.first, let b = points.last else { return points }
        let dx = b.x - a.x, dy = b.y - a.y, squared = dx * dx + dy * dy
        var maximum: CGFloat = 0, index = 0
        for i in 1..<(points.count - 1) {
            let p = points[i], t = squared > 0 ? min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / squared)) : 0
            let distance = hypot(p.x - a.x - t * dx, p.y - a.y - t * dy)
            if distance > maximum { maximum = distance; index = i }
        }
        guard maximum > tolerance else { return [a, b] }
        return Array(simplify(Array(points[...index]), tolerance: tolerance).dropLast()) + simplify(Array(points[index...]), tolerance: tolerance)
    }
}
