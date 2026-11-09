import SwiftUI
import PencilKit

/// The ruler accessory: drag it with one finger, turn it with two. Strokes written along either edge
/// snap to a straight line on that edge, like a real ruler.
@MainActor final class RulerState: ObservableObject {
    static let shared = RulerState()
    @Published var visible = false
    /// Centre in window coordinates and rotation in radians.
    @Published var center = CGPoint(x: 600, y: 420)
    @Published var angle: CGFloat = 0
    static let length: CGFloat = 900, height: CGFloat = 76

    /// The two long edges as (point, unit direction) in window coordinates.
    var edges: [(CGPoint, CGVector)] {
        let d = CGVector(dx: cos(angle), dy: sin(angle)), n = CGVector(dx: -sin(angle), dy: cos(angle))
        return [-1.0, 1.0].map { side in (CGPoint(x: center.x + n.dx * Self.height / 2 * side, y: center.y + n.dy * Self.height / 2 * side), d) }
    }

    /// Straightens `stroke` onto an edge when every point lies close to it; nil when it was drawn elsewhere.
    func snapped(_ stroke: PKStroke, toWindow: (CGPoint) -> CGPoint, fromWindow: (CGPoint) -> CGPoint) -> PKStroke? {
        guard visible else { return nil }
        let points = Array(stroke.path)
        guard points.count > 1 else { return nil }
        let window = points.map { toWindow($0.location.applying(stroke.transform)) }
        for (origin, d) in edges {
            func along(_ p: CGPoint) -> CGFloat { (p.x - origin.x) * d.dx + (p.y - origin.y) * d.dy }
            func across(_ p: CGPoint) -> CGFloat { abs(-(p.x - origin.x) * d.dy + (p.y - origin.y) * d.dx) }
            guard window.allSatisfy({ across($0) < 26 && abs(along($0)) < Self.length / 2 + 20 }) else { continue }
            let a = along(window.first!), b = along(window.last!)
            let invert = stroke.transform.inverted()
            let snappedPoints = points.enumerated().map { i, p -> PKStrokePoint in
                let t = CGFloat(i) / CGFloat(points.count - 1), s = a + (b - a) * t
                let w = CGPoint(x: origin.x + d.dx * s, y: origin.y + d.dy * s)
                return PKStrokePoint(location: fromWindow(w).applying(invert), timeOffset: p.timeOffset, size: p.size, opacity: p.opacity, force: p.force, azimuth: p.azimuth, altitude: p.altitude)
            }
            return PKStroke(ink: stroke.ink, path: PKStrokePath(controlPoints: snappedPoints, creationDate: stroke.path.creationDate), transform: stroke.transform, mask: stroke.mask)
        }
        return nil
    }
}

struct RulerOverlay: View {
    @ObservedObject var state: RulerState
    @State private var dragStart: CGPoint?
    @State private var angleStart: CGFloat?
    var body: some View {
        GeometryReader { geo in
            let origin = geo.frame(in: .global).origin
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.92).opacity(0.86))
                    .overlay { RoundedRectangle(cornerRadius: 6).stroke(.black.opacity(0.25), lineWidth: 0.5) }
                Canvas { context, size in
                    for i in 0 ... Int(size.width / 10) {
                        let x = CGFloat(i) * 10, long = i % 10 == 0, mid = i % 5 == 0
                        var tick = Path(); tick.move(to: CGPoint(x: x, y: 0)); tick.addLine(to: CGPoint(x: x, y: long ? 18 : (mid ? 12 : 7)))
                        context.stroke(tick, with: .color(.black.opacity(0.6)), lineWidth: 0.6)
                        if long { context.draw(Text("\(i / 10)").font(.system(size: 9)).foregroundColor(.black.opacity(0.6)), at: CGPoint(x: x + 5, y: 26)) }
                    }
                }
                Text("\(Int((state.angle * 180 / .pi).truncatingRemainder(dividingBy: 360).rounded()))°").font(.system(size: 12, weight: .semibold)).foregroundStyle(.black.opacity(0.7))
            }
            .frame(width: RulerState.length, height: RulerState.height)
            .rotationEffect(.radians(state.angle))
            .position(x: state.center.x - origin.x, y: state.center.y - origin.y)
            .gesture(SimultaneousGesture(
                DragGesture(coordinateSpace: .global).onChanged { v in
                    let start = dragStart ?? state.center; dragStart = start
                    state.center = CGPoint(x: start.x + v.translation.width, y: start.y + v.translation.height)
                }.onEnded { _ in dragStart = nil },
                RotationGesture().onChanged { r in
                    let start = angleStart ?? state.angle; angleStart = start
                    var next = start + CGFloat(r.radians)
                    // Settles on whole multiples of 45° when close, like the original ruler.
                    let step = CGFloat.pi / 4, nearest = (next / step).rounded() * step
                    if abs(next - nearest) < 0.035 { next = nearest }
                    state.angle = next
                }.onEnded { _ in angleStart = nil }
            ))
        }.transition(.opacity)
    }
}
