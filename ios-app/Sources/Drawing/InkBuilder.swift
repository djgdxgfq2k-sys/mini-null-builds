import PencilKit
import UIKit

struct InkSample {
    var point: CGPoint
    var time: TimeInterval
    var force: CGFloat = 0.5
    var altitude: CGFloat = .pi / 2
    var azimuth: CGFloat = 0
    var roll: CGFloat = 0
    var estimateID: Int?
    var awaitingUpdate = false
}

/// Local writing behavior. This is not the proprietary Goodnotes stroke engine.
enum InkBuilder {
    private struct Point {
        var sample: InkSample
        var width: CGFloat
        var opacity: CGFloat = 1
        func interpolated(to other: Point, fraction t: CGFloat) -> Point {
            let mix: (CGFloat, CGFloat) -> CGFloat = { $0 + ($1 - $0) * t }
            func angle(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + atan2(sin(b - a), cos(b - a)) * t }
            return Point(sample: InkSample(point: CGPoint(x: mix(sample.point.x, other.sample.point.x), y: mix(sample.point.y, other.sample.point.y)), time: sample.time + (other.sample.time - sample.time) * Double(t), force: mix(sample.force, other.sample.force), altitude: mix(sample.altitude, other.sample.altitude), azimuth: angle(sample.azimuth, other.sample.azimuth), roll: angle(sample.roll, other.sample.roll)), width: mix(width, other.width), opacity: mix(opacity, other.opacity))
        }
    }
    static func strokes(_ input: [InkSample], settings: ToolSettings, creationDate: Date, seed: UInt32, recognizedShape: RecognizedShape? = nil) -> [PKStroke] {
        if settings.tool == .marker && settings.tape { return TapeInk.strokes(input, settings: settings, creationDate: creationDate) }
        if let shape = recognizedShape {
            if settings.tool == .shapes { return GeometricInk.strokes(points: shape.points, settings: settings, closed: shape.closed) }
            let force = input.reduce(CGFloat(0)) { $0 + $1.force } / CGFloat(max(1, input.count))
            let points = shape.points.enumerated().map { i, point in InkSample(point: point, time: (input.first?.time ?? 0) + Double(i) / 120, force: force, altitude: input.first?.altitude ?? .pi / 2, azimuth: input.first?.azimuth ?? 0, roll: input.first?.roll ?? 0) }
            var clean = settings; clean.stabilization = 0; clean.highlighterStabilization = 0; clean.straightHighlighter = false
            return strokes(points, settings: clean, creationDate: creationDate, seed: seed)
        }
        guard [.pen, .pencil, .marker, .shapes].contains(settings.tool) else { return [] }
        var samples = input.filter { $0.point.x.isFinite && $0.point.y.isFinite && $0.time.isFinite && $0.force.isFinite && $0.altitude.isFinite && $0.azimuth.isFinite && $0.roll.isFinite }
        guard !samples.isEmpty else { return [] }
        if samples.count == 2 && [.pen, .shapes].contains(settings.tool) && settings.penStyle != .ballpoint {
            let a = samples[0], b = samples[1]
            let mid = InkSample(point: CGPoint(x: (a.point.x + b.point.x) / 2, y: (a.point.y + b.point.y) / 2), time: (a.time + b.time) / 2, force: (a.force + b.force) / 2, altitude: (a.altitude + b.altitude) / 2, azimuth: (a.azimuth + b.azimuth) / 2, roll: (a.roll + b.roll) / 2)
            samples.insert(mid, at: 1)
        }
        let strength = CGFloat(settings.tool == .marker ? settings.highlighterStabilization : settings.stabilization)
        var smooth = stabilized(samples, strength: min(1, max(0, strength)))
        if settings.tool == .marker && settings.straightHighlighter, let start = smooth.first?.point, let end = smooth.last?.point {
            let dx = end.x - start.x, dy = end.y - start.y, length = dx * dx + dy * dy
            if length > 0.01 {
                for i in smooth.indices {
                    let t = min(1, max(0, ((smooth[i].point.x - start.x) * dx + (smooth[i].point.y - start.y) * dy) / length))
                    smooth[i].point = CGPoint(x: start.x + dx * t, y: start.y + dy * t)
                }
            }
        }
        // A Pencil without a pressure sensor (USB-C Apple Pencil, passive styluses, fingers) reports one
        // constant force. Fountain and brush pens then swell and thin with writing speed instead, like a
        // real nib: slow strokes lay down more ink, quick flicks come out thin.
        if [.pen, .shapes].contains(settings.tool), settings.penStyle != .ballpoint, Self.hasFlatPressure(smooth) {
            Self.applySpeedPressure(&smooth)
        }
        let base = max(0.1, min(100, settings.width))
        var distances = [CGFloat](repeating: 0, count: smooth.count)
        for i in smooth.indices.dropFirst() { distances[i] = distances[i - 1] + hypot(smooth[i].point.x - smooth[i - 1].point.x, smooth[i].point.y - smooth[i - 1].point.y) }
        let total = distances.last ?? 0
        let points = smooth.enumerated().map { index, sample -> Point in
            var width = settings.tool == .marker ? max(12, base * 6) : base
            if settings.tool == .pencil {
                // Graphite: pressure darkens the line and widens it a little; tilting the Pencil
                // shades with the side of the lead, a much wider and lighter stroke.
                let force = min(1, max(0, sample.force))
                let tilt = min(1, max(0, 1 - sample.altitude / (.pi / 2) * 1.35))
                width *= (0.8 + 0.4 * force) * (1 + tilt * 3)
                let opacity = (0.35 + 0.65 * pow(force, 0.8)) * (1 - tilt * 0.45)
                return Point(sample: sample, width: width, opacity: max(0.12, min(1, opacity)))
            }
            if [.pen, .shapes].contains(settings.tool) && settings.penStyle != .ballpoint {
                let minimum: CGFloat = settings.penStyle == .brush && settings.tool != .pencil ? 0.3 : 0.15
                let sensitivity = minimum + (1 - minimum) * CGFloat(settings.pressure)
                width *= max(0.08, 1 + sensitivity * (min(1, max(0, sample.force)) * 2 - 1))
                if settings.reactToSpeed, index > 0 {
                    let before = smooth[index - 1], elapsed = max(0.001, sample.time - before.time)
                    let speed = hypot(sample.point.x - before.point.x, sample.point.y - before.point.y) / CGFloat(elapsed)
                    width *= min(1.3, max(0.3, 1.3 - speed / 1600))
                }
                if [.pen, .shapes].contains(settings.tool) && total > 0.1 && settings.sharpness > 0 {
                    let endDistance = min(distances[index], total - distances[index])
                    let radius = min(total / 2, max(1, base * 2) * CGFloat(settings.sharpness))
                    let minimum = 1 - CGFloat(settings.sharpness) * 0.88
                    width *= minimum + (1 - minimum) * min(1, endDistance / max(0.01, radius))
                }
            }
            return Point(sample: sample, width: width)
        }
        let type: PKInk.InkType
        switch settings.tool {
        case .marker: type = .marker
        case .pencil: type = .pencil
        default: type = settings.penStyle == .fountain ? .fountainPen : .pen
        }
        let color = UIColor(hex: settings.color)
        let ink = PKInk(type, color: settings.tool == .marker ? color.withAlphaComponent(0.35) : color)
        let segments = patterned(points, pattern: settings.strokePattern, width: settings.tool == .marker ? max(12, base * 6) : base)
        let startTime = samples[0].time
        return segments.enumerated().map { index, segment in
            var controls = segment.map { point -> PKStrokePoint in
                let angle = point.sample.azimuth + (settings.barrelRoll ? point.sample.roll : 0)
                let aspect: CGFloat = [.pen, .shapes].contains(settings.tool) && settings.penStyle == .fountain ? 0.2 + CGFloat(settings.tipRoundness) * 0.8 : 1
                return PKStrokePoint(location: point.sample.point, timeOffset: max(0, point.sample.time - startTime), size: CGSize(width: point.width, height: point.width * aspect), opacity: point.opacity, force: max(0, point.sample.force), azimuth: angle, altitude: point.sample.altitude)
            }
            if controls.count == 1, let point = segment.first {
                controls.append(PKStrokePoint(location: CGPoint(x: point.sample.point.x + 0.01, y: point.sample.point.y), timeOffset: max(0, point.sample.time - startTime) + 0.001, size: controls[0].size, opacity: 1, force: max(0, point.sample.force), azimuth: controls[0].azimuth, altitude: point.sample.altitude))
            }
            return PKStroke(ink: ink, path: PKStrokePath(controlPoints: controls, creationDate: creationDate), randomSeed: seed &+ UInt32(index))
        }
    }
    /// `StylusInputPolicy.force` reports exactly 0.5 for input without a pressure sensor; real pressure always varies.
    static func hasFlatPressure(_ samples: [InkSample]) -> Bool {
        samples.count > 2 && samples.allSatisfy { abs($0.force - 0.5) < 0.001 }
    }
    /// Replaces a constant force with one derived from smoothed writing speed (0.2 fast … 0.85 slow).
    static func applySpeedPressure(_ samples: inout [InkSample]) {
        var speed: CGFloat = 0
        for i in samples.indices {
            if i > 0 {
                let dt = max(1.0 / 240, samples[i].time - samples[i - 1].time)
                let current = hypot(samples[i].point.x - samples[i - 1].point.x, samples[i].point.y - samples[i - 1].point.y) / CGFloat(dt)
                // Smooth over a few samples so the line breathes instead of flickering.
                speed = i == 1 ? current : speed + (current - speed) * 0.25
            }
            let fast = min(1, max(0, (speed - 60) / 900))
            samples[i].force = 0.85 - 0.65 * pow(fast, 0.7)
        }
        if samples.count > 1 { samples[0].force = samples[1].force }
    }
    private static func stabilized(_ samples: [InkSample], strength: CGFloat) -> [InkSample] {
        guard strength > 0, samples.count > 2 else { return samples }
        var result = [samples[0]], previous = samples[0].point
        for i in 1..<samples.count {
            let dt = max(1.0 / 1000, samples[i].time - samples[i - 1].time)
            let distance = hypot(samples[i].point.x - samples[i - 1].point.x, samples[i].point.y - samples[i - 1].point.y)
            let speed = Double(distance) / dt
            let alpha = CGFloat(1 / (1 + Double(strength) * 0.04 / (dt * (1 + speed / 1200))))
            previous = CGPoint(x: previous.x + alpha * (samples[i].point.x - previous.x), y: previous.y + alpha * (samples[i].point.y - previous.y))
            var next = samples[i]; next.point = previous; result.append(next)
        }
        result[result.count - 1].point = samples[samples.count - 1].point
        return result
    }
    private static func patterned(_ points: [Point], pattern: StrokePattern, width: CGFloat) -> [[Point]] {
        guard let first = points.first else { return [] }
        guard pattern != .solid, points.count > 1 else { return [points] }
        let on: CGFloat = pattern == .dotted ? 0 : max(2, width * 4)
        let off = pattern == .dotted ? max(3, width * 3) : max(2, width * 2)
        var output: [[Point]] = [], segment = [first], drawing = true, remaining = on
        if pattern == .dotted { output.append([first]); drawing = false; remaining = off }
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i], length = hypot(b.sample.point.x - a.sample.point.x, b.sample.point.y - a.sample.point.y)
            guard length > 0.0001 else { continue }
            var walked: CGFloat = 0
            while walked < length - 0.0001 {
                let step = min(length - walked, remaining); walked += step; remaining -= step
                let current = a.interpolated(to: b, fraction: walked / length)
                if drawing { segment.append(current) }
                if remaining < 0.0001 {
                    if pattern == .dotted { output.append([current]); remaining = off }
                    else if drawing { output.append(segment); segment = []; drawing = false; remaining = off }
                    else { segment = [current]; drawing = true; remaining = on }
                }
            }
        }
        if drawing && !segment.isEmpty { output.append(segment) }
        return output
    }
}
