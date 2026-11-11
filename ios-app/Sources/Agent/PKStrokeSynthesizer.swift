import PencilKit
import UIKit

/// Look of synthesized ink. Taken from the user's recent strokes so AI ink matches their pen.
struct SynthInkStyle {
    var color: UIColor = UIColor(red: 0.12, green: 0.11, blue: 0.11, alpha: 1)
    var width: CGFloat = 2
    /// Cap height in page points; x-height is 0.55 of it.
    var capHeight: CGFloat = 20

    /// Matches the last written line: its median stroke height, point width and color.
    static func matching(_ drawing: PKDrawing) -> SynthInkStyle {
        var style = SynthInkStyle()
        let strokes = drawing.strokes.filter { $0.ink.inkType != .marker }
        guard let bottom = strokes.map(\.renderBounds.maxY).max() else { return style }
        let line = strokes.filter { $0.renderBounds.maxY > bottom - 40 }
        func median(_ v: [CGFloat]) -> CGFloat? { let s = v.sorted(); return s.isEmpty ? nil : s[s.count / 2] }
        if let h = median(line.map(\.renderBounds.height).filter { $0 > 4 }) { style.capHeight = min(36, max(14, h)) }
        if let w = median(line.compactMap { $0.path.first?.size.width }.filter { $0 > 0.2 }) { style.width = min(6, max(0.8, w)) }
        if let color = line.last?.ink.color { style.color = color }
        return style
    }
}

/// Turns streamed AI text into native PencilKit strokes, written like handwriting from a cursor point.
///
/// Feed text chunks as they arrive with `write(_:)`; it returns strokes for every completed word, so the
/// answer appears word by word. Call `finish()` at the end for the last word.
/// - Glyphs: the user's trained handwriting (HandwritingStudio) when every letter of a word is trained,
///   otherwise a built-in single-stroke font.
/// - Human touch: per-glyph size/baseline variation, a slight forward slant, low-frequency wobble along
///   each stroke, and small pressure (force), azimuth and altitude changes per point.
/// - Layout: lines start at the cursor's x, wrap at the right margin, stop at the bottom margin
///   (`overflowed` is then true and the rest is not written).
@MainActor final class PKStrokeSynthesizer {
    let style: SynthInkStyle
    private(set) var overflowed = false
    private(set) var pen: CGPoint                     // x and baseline y of the next glyph
    private let lineLeft: CGFloat, right: CGFloat, bottom: CGFloat
    private let lineHeight: CGFloat
    private let trained: [String: [Data]]
    private var buffer = ""
    private var random: SeededRandom
    private var clock: TimeInterval = 0
    private let start = Date()

    /// - Parameters:
    ///   - anchor: top-left of the first line (the gateway's `cursor_x/cursor_y`).
    ///   - profile: trained handwriting; pass nil to always use the built-in font.
    init(anchor: CGPoint, pageSize: CGSize, style: SynthInkStyle, margin: CGFloat = 40,
         profile: HandwritingProfile? = nil, seed: UInt64 = UInt64.random(in: 1 ... .max)) {
        self.style = style
        lineHeight = style.capHeight * 1.75
        lineLeft = min(max(margin * 0.5, anchor.x), pageSize.width * 0.6)
        right = pageSize.width - margin
        bottom = pageSize.height - margin
        pen = CGPoint(x: lineLeft, y: anchor.y + style.capHeight)
        trained = profile?.glyphs ?? [:]
        random = SeededRandom(seed: seed)
        if pen.y > bottom { overflowed = true }
    }

    /// Writes a chunk of streamed text; returns the strokes of all words completed by it.
    func write(_ chunk: String) -> [PKStroke] {
        var out: [PKStroke] = []
        for c in chunk {
            if c == "\n" { out += flushWord(); newline() }
            else if c.isWhitespace { out += flushWord(); pen.x += style.capHeight * 0.38 }
            else { buffer.append(c) }
        }
        return out
    }

    /// Writes whatever is still buffered (the last word).
    func finish() -> [PKStroke] { flushWord() }

    /// Convenience: all strokes for a complete text.
    func strokes(for text: String) -> [PKStroke] { write(text) + finish() }

    /// Where to start writing on a page: under the last line of ink, aligned with its left edge.
    static func anchor(below drawing: PKDrawing, pageSize: CGSize, style: SynthInkStyle, margin: CGFloat = 40) -> CGPoint {
        let strokes = drawing.strokes
        guard !strokes.isEmpty else { return CGPoint(x: margin * 1.5, y: margin * 1.5) }
        let maxY = drawing.bounds.maxY
        let line = strokes.map(\.renderBounds).filter { $0.maxY > maxY - style.capHeight * 1.5 }
        let x = line.map(\.minX).min() ?? margin
        return CGPoint(x: min(max(margin * 0.5, x), pageSize.width * 0.6), y: maxY + style.capHeight * 0.6)
    }

    // MARK: Layout

    private func newline() {
        pen.x = lineLeft; pen.y += lineHeight
        if pen.y > bottom { overflowed = true }
    }

    private func flushWord() -> [PKStroke] {
        defer { buffer = "" }
        let word = Self.cleanMarkdown(buffer)
        guard !word.isEmpty, !overflowed else { return [] }
        let glyphs = layoutGlyphs(word)
        let width = glyphs.reduce(0) { $0 + $1.advance }
        if pen.x > lineLeft, pen.x + width > right { newline() }
        guard !overflowed else { return [] }
        var out: [PKStroke] = []
        for g in glyphs {
            if pen.x + g.advance > right, pen.x > lineLeft { newline() }   // a word longer than a line
            guard !overflowed else { break }
            out += render(g)
            pen.x += g.advance
        }
        return out
    }

    private struct PlacedGlyph {
        enum Source { case font(StrokeFont.Glyph), trained(PKDrawing, Character) }
        let source: Source
        let scale: CGFloat           // 1 normal, ~0.6 for superscripts
        let raise: CGFloat           // baseline shift up in cap heights
        let advance: CGFloat
    }

    private func layoutGlyphs(_ word: String) -> [PlacedGlyph] {
        let chars = Array(word)
        let useTrained = !trained.isEmpty && chars.allSatisfy { trained[String($0)]?.isEmpty == false }
        var result: [PlacedGlyph] = []
        var superscript = false
        for c in chars {
            if c == "^" { superscript = true; continue }
            var scale: CGFloat = 1, raise: CGFloat = 0, char = c
            if let digit = StrokeFont.superscripts[c] { char = digit; scale = 0.6; raise = 0.45 }
            else if superscript {
                if c.isLetter || c.isNumber || "+-()".contains(c) { scale = 0.6; raise = 0.45 } else { superscript = false }
            }
            if useTrained, scale == 1, let variants = trained[String(char)], !variants.isEmpty,
               let drawing = try? PKDrawing(data: variants[Int(random.next() % UInt64(variants.count))]),
               drawing.bounds.height > 0 {
                let box = Self.trainedBox(char, capHeight: style.capHeight)
                let width = drawing.bounds.width * box.height / drawing.bounds.height
                result.append(PlacedGlyph(source: .trained(drawing, char), scale: 1, raise: 0, advance: width + style.capHeight * 0.12))
            } else if let glyph = StrokeFont.glyph(for: char) {
                result.append(PlacedGlyph(source: .font(glyph), scale: scale, raise: raise,
                                          advance: (glyph.advance + 0.1) * style.capHeight * scale))
            } else {
                result.append(PlacedGlyph(source: .font(StrokeFont.Glyph(advance: 0.4, strokes: [])), scale: 1, raise: 0,
                                          advance: style.capHeight * 0.5))
            }
        }
        return result
    }

    /// Height and top (relative to baseline, in points) of a trained glyph by letter class.
    private static func trainedBox(_ c: Character, capHeight s: CGFloat) -> (top: CGFloat, height: CGFloat) {
        if "acemnorsuvwxzäöü".contains(c) { return (-0.55 * s, 0.55 * s) }
        if "gpqy".contains(c) { return (-0.55 * s, 0.85 * s) }
        if c == "j" { return (-0.8 * s, 1.1 * s) }
        if "it".contains(c) { return (-0.8 * s, 0.8 * s) }
        return (-s, s)
    }

    // MARK: Rendering

    private func render(_ glyph: PlacedGlyph) -> [PKStroke] {
        switch glyph.source {
        case .trained(let drawing, let char): return renderTrained(drawing, char)
        case .font(let g): return renderFont(g, scale: glyph.scale, raise: glyph.raise)
        }
    }

    private func renderTrained(_ drawing: PKDrawing, _ char: Character) -> [PKStroke] {
        let box = Self.trainedBox(char, capHeight: style.capHeight)
        let b = drawing.bounds
        let scale = box.height / b.height * CGFloat(1 + (random.unit() - 0.5) * 0.06)
        let wobble = CGFloat((random.unit() - 0.5) * 0.04) * style.capHeight
        let t = CGAffineTransform(translationX: -b.minX, y: -b.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: pen.x, y: pen.y + box.top + wobble))
        let ink = PKInk(.pen, color: style.color)
        return drawing.transformed(using: t).strokes.map { PKStroke(ink: ink, path: $0.path, transform: $0.transform, mask: $0.mask) }
    }

    private func renderFont(_ glyph: StrokeFont.Glyph, scale: CGFloat, raise: CGFloat) -> [PKStroke] {
        let s = style.capHeight * scale * CGFloat(1 + (random.unit() - 0.5) * 0.07)
        let baseline = pen.y - raise * style.capHeight + CGFloat((random.unit() - 0.5) * 0.05) * style.capHeight
        let slant = 0.1 + CGFloat((random.unit() - 0.5) * 0.04)
        let ink = PKInk(.pen, color: style.color)
        var strokes: [PKStroke] = []
        for polyline in glyph.strokes where !polyline.isEmpty {
            let page = polyline.map { p in
                CGPoint(x: pen.x + p.x * s + (1 - p.y) * s * slant, y: baseline + (p.y - 1) * s)
            }
            strokes.append(PKStroke(ink: ink, path: path(through: page)))
        }
        return strokes
    }

    /// Resamples a polyline and turns it into stroke points with human-like variation.
    private func path(through points: [CGPoint]) -> PKStrokePath {
        let spacing = max(0.8, style.capHeight / 16)
        var dense: [CGPoint] = [points[0]]
        for (a, b) in zip(points, points.dropFirst()) {
            let d = hypot(b.x - a.x, b.y - a.y)
            let n = max(1, Int(d / spacing))
            for i in 1 ... n { let t = CGFloat(i) / CGFloat(n); dense.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)) }
        }
        if dense.count == 1 { dense.append(CGPoint(x: dense[0].x + 0.3, y: dense[0].y + 0.3)) }   // dots
        // Smooth noise: two sines with random phase per stroke, so wobble is continuous, not grainy.
        let phase = (0 ..< 6).map { _ in CGFloat(random.unit() * 2 * .pi) }
        let amp = style.capHeight * 0.012
        let speed = 160 + random.unit() * 80                 // points per second
        var result: [PKStrokePoint] = []
        var travelled: CGFloat = 0
        for (i, p) in dense.enumerated() {
            if i > 0 { travelled += hypot(p.x - dense[i - 1].x, p.y - dense[i - 1].y) }
            let u = travelled / max(style.capHeight, 1)
            let n1 = sin(u * 2.1 + phase[0]) * 0.6 + sin(u * 5.3 + phase[1]) * 0.4
            let n2 = sin(u * 1.7 + phase[2]) * 0.6 + sin(u * 4.1 + phase[3]) * 0.4
            let n3 = sin(u * 3.3 + phase[4])
            let ease = min(1, CGFloat(i) / 3, CGFloat(dense.count - 1 - i) / 3 + 0.35)   // lighter touch-down and lift
            let width = style.width * (1 + 0.06 * n3) * (0.85 + 0.15 * ease)
            result.append(PKStrokePoint(
                location: CGPoint(x: p.x + amp * n1, y: p.y + amp * n2),
                timeOffset: clock + Double(travelled) / speed,
                size: CGSize(width: width, height: width),
                opacity: 1,
                force: max(0.1, 0.7 + 0.15 * n3) * (0.8 + 0.2 * ease),
                azimuth: 0.85 + 0.08 * n1,
                altitude: 0.98 + 0.06 * n2))
        }
        clock += Double(travelled) / speed + 0.12               // pen lift between strokes
        return PKStrokePath(controlPoints: result, creationDate: start)
    }

    /// Removes markdown that would otherwise be drawn literally.
    static func cleanMarkdown(_ word: String) -> String {
        var w = word.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
        if w.allSatisfy({ $0 == "#" }) { w = "" }
        return w
    }
}

/// Built-in single-stroke font. Glyph coordinates are in cap heights with y pointing down:
/// 0 = cap/ascender top, 0.45 = x-height, 1 = baseline, 1.3 = descender.
enum StrokeFont {
    struct Glyph { let advance: CGFloat; let strokes: [[CGPoint]] }

    static func glyph(for c: Character) -> Glyph? {
        if let g = table[c] { return g }
        if let mapped = aliases[c] { return table[mapped] }
        // Accented letters fall back to their base letter (é → e).
        let base = String(c).decomposedStringWithCanonicalMapping.unicodeScalars.first.map(Character.init)
        if let base, base != c { return table[base] }
        return nil
    }

    static let superscripts: [Character: Character] = ["⁰": "0", "¹": "1", "²": "2", "³": "3", "⁴": "4", "⁵": "5", "⁶": "6", "⁷": "7", "⁸": "8", "⁹": "9", "⁺": "+", "⁻": "-"]
    static let aliases: [Character: Character] = ["’": "'", "‘": "'", "“": "\"", "”": "\"", "„": "\"", "–": "-", "—": "-", "−": "-", "·": "·", "∙": "·", "⋅": "·", "•": "·", "*": "*"]

    // Metrics
    private static let X: CGFloat = 0.45, B: CGFloat = 1, D: CGFloat = 1.3, M: CGFloat = 0.725, R: CGFloat = 0.275

    private static func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
    /// Elliptical arc; angles in degrees, 0 = right, 90 = down (screen coordinates).
    private static func arc(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ from: CGFloat, _ to: CGFloat) -> [CGPoint] {
        let steps = max(4, Int(abs(to - from) / 12))
        return (0 ... steps).map { i in
            let a = (from + (to - from) * CGFloat(i) / CGFloat(steps)) * .pi / 180
            return p(cx + rx * cos(a), cy + ry * sin(a))
        }
    }
    private static func dot(_ x: CGFloat, _ y: CGFloat) -> [CGPoint] { [p(x, y), p(x + 0.01, y + 0.02)] }
    private static func g(_ advance: CGFloat, _ strokes: [CGPoint]...) -> Glyph { Glyph(advance: advance, strokes: strokes) }
    private static func withDots(_ base: Glyph, y: CGFloat) -> Glyph {
        let xs = base.strokes.flatMap { $0 }.map(\.x); let mid = ((xs.min() ?? 0) + (xs.max() ?? base.advance)) / 2
        return Glyph(advance: base.advance, strokes: base.strokes + [dot(mid - 0.11, y), dot(mid + 0.11, y)])
    }

    static let table: [Character: Glyph] = {
        var t: [Character: Glyph] = [:]
        // Lowercase
        t["a"] = g(0.6, arc(0.26, M, 0.24, R, -15, -345), [p(0.5, X), p(0.5, B)])
        t["b"] = g(0.6, [p(0.04, 0), p(0.04, B)], arc(0.29, M, 0.25, R, 180, 540))
        t["c"] = g(0.55, arc(0.27, M, 0.25, R, -40, -320))
        t["d"] = g(0.6, arc(0.25, M, 0.24, R, 0, -360), [p(0.49, 0), p(0.49, B)])
        t["e"] = g(0.58, [p(0.03, M)] + arc(0.27, M, 0.24, R, 0, -320))
        t["f"] = g(0.42, arc(0.32, 0.13, 0.12, 0.12, -15, -180) + [p(0.2, B)], [p(0.04, X), p(0.38, X)])
        t["g"] = g(0.6, arc(0.25, M, 0.24, R, 0, -360), [p(0.49, X), p(0.49, 1.15)] + arc(0.27, 1.15, 0.22, 0.14, 0, 160))
        t["h"] = g(0.58, [p(0.04, 0), p(0.04, B)], arc(0.26, 0.66, 0.22, 0.2, 180, 360) + [p(0.48, B)])
        t["i"] = g(0.2, [p(0.07, X), p(0.07, B)], dot(0.07, 0.25))
        t["j"] = g(0.3, [p(0.22, X), p(0.22, 1.15)] + arc(0.1, 1.15, 0.12, 0.14, 0, 160), dot(0.22, 0.25))
        t["k"] = g(0.5, [p(0.04, 0), p(0.04, B)], [p(0.42, X), p(0.04, 0.8)], [p(0.17, 0.69), p(0.46, B)])
        t["l"] = g(0.2, [p(0.07, 0), p(0.07, B)])
        t["m"] = g(0.8, [p(0.04, X), p(0.04, B)], arc(0.2, 0.63, 0.16, 0.18, 180, 360) + [p(0.36, B)], arc(0.53, 0.63, 0.17, 0.18, 180, 360) + [p(0.7, B)])
        t["n"] = g(0.58, [p(0.04, X), p(0.04, B)], arc(0.26, 0.66, 0.22, 0.2, 180, 360) + [p(0.48, B)])
        t["o"] = g(0.58, arc(0.27, M, 0.25, R, -90, 270))
        t["p"] = g(0.6, [p(0.04, X), p(0.04, D)], arc(0.29, M, 0.25, R, 180, 540))
        t["q"] = g(0.6, arc(0.25, M, 0.24, R, 0, -360), [p(0.49, X), p(0.49, D)])
        t["r"] = g(0.4, [p(0.04, X), p(0.04, B)], arc(0.22, 0.66, 0.18, 0.2, 180, 300))
        t["s"] = g(0.48, arc(0.23, 0.59, 0.19, 0.14, -30, -270) + arc(0.23, 0.86, 0.2, 0.14, -90, 150))
        t["t"] = g(0.42, [p(0.18, 0.1), p(0.18, 0.88)] + arc(0.3, 0.88, 0.12, 0.12, 180, 20), [p(0.02, X), p(0.38, X)])
        t["u"] = g(0.56, [p(0.04, X), p(0.04, 0.78)] + arc(0.25, 0.78, 0.21, 0.22, 180, 0), [p(0.46, X), p(0.46, B)])
        t["v"] = g(0.52, [p(0, X), p(0.25, B), p(0.5, X)])
        t["w"] = g(0.76, [p(0, X), p(0.18, B), p(0.37, 0.6), p(0.56, B), p(0.74, X)])
        t["x"] = g(0.5, [p(0.02, X), p(0.46, B)], [p(0.46, X), p(0.02, B)])
        t["y"] = g(0.52, [p(0, X), p(0.26, 0.98)], [p(0.5, X), p(0.1, D)])
        t["z"] = g(0.52, [p(0.03, X), p(0.47, X), p(0.03, B), p(0.49, B)])
        t["ß"] = g(0.52, [p(0.04, B), p(0.04, 0.2)] + arc(0.2, 0.2, 0.16, 0.18, 180, 450) + arc(0.22, 0.68, 0.22, 0.3, -90, 150))
        // Uppercase
        t["A"] = g(0.68, [p(0, B), p(0.32, 0), p(0.64, B)], [p(0.12, 0.65), p(0.52, 0.65)])
        t["B"] = g(0.66, [p(0.04, 0), p(0.04, B)], [p(0.04, 0), p(0.34, 0)] + arc(0.34, 0.24, 0.22, 0.24, -90, 90) + [p(0.04, 0.48)],
                   [p(0.04, 0.48), p(0.38, 0.48)] + arc(0.38, 0.74, 0.24, 0.26, -90, 90) + [p(0.04, B)])
        t["C"] = g(0.72, arc(0.38, 0.5, 0.36, 0.5, -40, -320))
        t["D"] = g(0.72, [p(0.04, 0), p(0.04, B)], [p(0.04, 0), p(0.25, 0)] + arc(0.25, 0.5, 0.4, 0.5, -90, 90) + [p(0.04, B)])
        t["E"] = g(0.56, [p(0.5, 0), p(0.04, 0), p(0.04, B), p(0.5, B)], [p(0.04, 0.5), p(0.4, 0.5)])
        t["F"] = g(0.54, [p(0.5, 0), p(0.04, 0), p(0.04, B)], [p(0.04, 0.5), p(0.4, 0.5)])
        t["G"] = g(0.76, arc(0.38, 0.5, 0.36, 0.5, -40, -360) + [p(0.42, 0.5)])
        t["H"] = g(0.66, [p(0.04, 0), p(0.04, B)], [p(0.6, 0), p(0.6, B)], [p(0.04, 0.5), p(0.6, 0.5)])
        t["I"] = g(0.2, [p(0.06, 0), p(0.06, B)])
        t["J"] = g(0.5, [p(0.4, 0), p(0.4, 0.72)] + arc(0.22, 0.72, 0.18, 0.28, 0, 180))
        t["K"] = g(0.6, [p(0.04, 0), p(0.04, B)], [p(0.55, 0), p(0.04, 0.6)], [p(0.2, 0.45), p(0.58, B)])
        t["L"] = g(0.52, [p(0.04, 0), p(0.04, B), p(0.48, B)])
        t["M"] = g(0.8, [p(0.04, B), p(0.04, 0), p(0.38, 0.7), p(0.72, 0), p(0.72, B)])
        t["N"] = g(0.68, [p(0.04, B), p(0.04, 0), p(0.6, B), p(0.6, 0)])
        t["O"] = g(0.82, arc(0.4, 0.5, 0.38, 0.5, -90, 270))
        t["P"] = g(0.62, [p(0.04, B), p(0.04, 0), p(0.32, 0)] + arc(0.32, 0.25, 0.24, 0.25, -90, 90) + [p(0.04, 0.5)])
        t["Q"] = g(0.82, arc(0.4, 0.5, 0.38, 0.5, -90, 270), [p(0.46, 0.72), p(0.78, 1.02)])
        t["R"] = g(0.64, [p(0.04, B), p(0.04, 0), p(0.32, 0)] + arc(0.32, 0.25, 0.24, 0.25, -90, 90) + [p(0.04, 0.5)], [p(0.3, 0.5), p(0.58, B)])
        t["S"] = g(0.62, arc(0.3, 0.25, 0.26, 0.25, -30, -270) + arc(0.3, 0.75, 0.28, 0.25, -90, 150))
        t["T"] = g(0.62, [p(0, 0), p(0.6, 0)], [p(0.3, 0), p(0.3, B)])
        t["U"] = g(0.68, [p(0.04, 0), p(0.04, 0.66)] + arc(0.32, 0.66, 0.28, 0.34, 180, 0) + [p(0.6, 0)])
        t["V"] = g(0.66, [p(0, 0), p(0.32, B), p(0.64, 0)])
        t["W"] = g(0.9, [p(0, 0), p(0.22, B), p(0.44, 0.35), p(0.66, B), p(0.88, 0)])
        t["X"] = g(0.62, [p(0.02, 0), p(0.58, B)], [p(0.58, 0), p(0.02, B)])
        t["Y"] = g(0.62, [p(0, 0), p(0.3, 0.5), p(0.6, 0)], [p(0.3, 0.5), p(0.3, B)])
        t["Z"] = g(0.64, [p(0.03, 0), p(0.57, 0), p(0.03, B), p(0.6, B)])
        // Umlauts
        for (u, base, y) in [("ä", "a", 0.3), ("ö", "o", 0.3), ("ü", "u", 0.3), ("Ä", "A", -0.15), ("Ö", "O", -0.15), ("Ü", "U", -0.15)] as [(Character, Character, CGFloat)] {
            if let b = t[base] { t[u] = withDots(b, y: y) }
        }
        // Digits
        t["0"] = g(0.6, arc(0.28, 0.5, 0.26, 0.5, -90, 270))
        t["1"] = g(0.42, [p(0.08, 0.2), p(0.28, 0), p(0.28, B)])
        t["2"] = g(0.58, arc(0.27, 0.27, 0.24, 0.25, -170, 10) + [p(0.03, B), p(0.53, B)])
        t["3"] = g(0.56, arc(0.26, 0.26, 0.22, 0.24, -160, 90) + arc(0.26, 0.74, 0.25, 0.26, -90, 160))
        t["4"] = g(0.6, [p(0.42, B), p(0.42, 0), p(0.02, 0.7), p(0.56, 0.7)])
        t["5"] = g(0.58, [p(0.5, 0), p(0.1, 0), p(0.07, 0.46)] + arc(0.27, 0.68, 0.25, 0.31, -140, 150))
        t["6"] = g(0.6, arc(0.33, 0.6, 0.29, 0.56, -60, -180) + arc(0.3, 0.72, 0.25, 0.28, 180, 540))
        t["7"] = g(0.56, [p(0.02, 0), p(0.55, 0), p(0.2, B)])
        t["8"] = g(0.58, arc(0.28, 0.25, 0.21, 0.24, 90, 450), arc(0.28, 0.74, 0.25, 0.26, -90, 270))
        t["9"] = g(0.6, arc(0.28, 0.3, 0.25, 0.29, 0, 360) + [p(0.53, 0.3), p(0.45, B)])
        // Punctuation and math
        t["."] = g(0.2, dot(0.06, 0.97))
        t[","] = g(0.2, [p(0.08, 0.94), p(0.03, 1.12)])
        t[":"] = g(0.2, dot(0.06, 0.55), dot(0.06, 0.97))
        t[";"] = g(0.2, dot(0.08, 0.55), [p(0.08, 0.94), p(0.03, 1.12)])
        t["!"] = g(0.2, [p(0.07, 0), p(0.07, 0.72)], dot(0.07, 0.97))
        t["?"] = g(0.5, arc(0.25, 0.24, 0.22, 0.22, -170, 90) + [p(0.25, 0.7)], dot(0.25, 0.97))
        t["'"] = g(0.15, [p(0.06, 0), p(0.05, 0.22)])
        t["\""] = g(0.3, [p(0.06, 0), p(0.05, 0.22)], [p(0.2, 0), p(0.19, 0.22)])
        t["-"] = g(0.46, [p(0.05, 0.62), p(0.4, 0.62)])
        t["_"] = g(0.5, [p(0, 1.05), p(0.5, 1.05)])
        t["+"] = g(0.6, [p(0.05, 0.62), p(0.55, 0.62)], [p(0.3, 0.37), p(0.3, 0.87)])
        t["="] = g(0.6, [p(0.05, 0.52), p(0.55, 0.52)], [p(0.05, 0.72), p(0.55, 0.72)])
        t["×"] = g(0.56, [p(0.08, 0.42), p(0.48, 0.82)], [p(0.48, 0.42), p(0.08, 0.82)])
        t["÷"] = g(0.6, [p(0.05, 0.62), p(0.55, 0.62)], dot(0.3, 0.42), dot(0.3, 0.8))
        t["·"] = g(0.3, dot(0.12, 0.6))
        t["*"] = g(0.46, [p(0.22, 0.15), p(0.22, 0.55)], [p(0.04, 0.25), p(0.4, 0.45)], [p(0.4, 0.25), p(0.04, 0.45)])
        t["/"] = g(0.48, [p(0.44, -0.02), p(0.04, 1.05)])
        t["\\"] = g(0.48, [p(0.04, -0.02), p(0.44, 1.05)])
        t["|"] = g(0.2, [p(0.08, -0.05), p(0.08, 1.15)])
        t["("] = g(0.32, arc(0.42, 0.5, 0.3, 0.6, -120, -240))
        t[")"] = g(0.32, arc(0, 0.5, 0.3, 0.6, -60, 60))
        t["["] = g(0.3, [p(0.25, -0.05), p(0.07, -0.05), p(0.07, 1.08), p(0.25, 1.08)])
        t["]"] = g(0.3, [p(0.03, -0.05), p(0.21, -0.05), p(0.21, 1.08), p(0.03, 1.08)])
        t["{"] = g(0.34, [p(0.28, -0.05), p(0.16, 0.02), p(0.16, 0.42), p(0.04, 0.5), p(0.16, 0.58), p(0.16, 1.0), p(0.28, 1.08)])
        t["}"] = g(0.34, [p(0.04, -0.05), p(0.16, 0.02), p(0.16, 0.42), p(0.28, 0.5), p(0.16, 0.58), p(0.16, 1.0), p(0.04, 1.08)])
        t["<"] = g(0.56, [p(0.5, 0.4), p(0.05, 0.62), p(0.5, 0.84)])
        t[">"] = g(0.56, [p(0.05, 0.4), p(0.5, 0.62), p(0.05, 0.84)])
        t["≤"] = g(0.56, [p(0.5, 0.3), p(0.05, 0.52), p(0.5, 0.74)], [p(0.05, 0.9), p(0.5, 0.9)])
        t["≥"] = g(0.56, [p(0.05, 0.3), p(0.5, 0.52), p(0.05, 0.74)], [p(0.05, 0.9), p(0.5, 0.9)])
        t["≠"] = g(0.6, [p(0.05, 0.52), p(0.55, 0.52)], [p(0.05, 0.72), p(0.55, 0.72)], [p(0.42, 0.35), p(0.18, 0.9)])
        let wave: (CGFloat) -> [CGPoint] = { y in (0 ... 12).map { i in let x = CGFloat(i) / 12; return p(0.05 + x * 0.5, y - sin(x * 2 * .pi) * 0.06) } }
        t["~"] = g(0.6, wave(0.62))
        t["≈"] = g(0.6, wave(0.52), wave(0.74))
        t["→"] = g(0.76, [p(0.05, 0.62), p(0.7, 0.62)], [p(0.52, 0.48), p(0.7, 0.62), p(0.52, 0.76)])
        t["←"] = g(0.76, [p(0.7, 0.62), p(0.05, 0.62)], [p(0.23, 0.48), p(0.05, 0.62), p(0.23, 0.76)])
        t["⇒"] = g(0.76, [p(0.05, 0.54), p(0.6, 0.54)], [p(0.05, 0.7), p(0.6, 0.7)], [p(0.48, 0.42), p(0.72, 0.62), p(0.48, 0.82)])
        t["∞"] = g(0.8, arc(0.2, 0.62, 0.16, 0.14, 0, 360) + arc(0.52, 0.62, 0.16, 0.14, 180, -180))
        t["√"] = g(0.95, [p(0, 0.6), p(0.12, 0.55), p(0.28, B), p(0.5, -0.02), p(0.92, -0.02)])
        t["π"] = g(0.64, [p(0.02, 0.48), p(0.6, 0.45)], [p(0.18, 0.47), p(0.15, B)], [p(0.45, 0.46), p(0.48, 0.95), p(0.56, B)])
        t["∫"] = g(0.42, arc(0.3, 0.08, 0.08, 0.08, -20, -180) + [p(0.22, 0.92)] + arc(0.14, 0.92, 0.08, 0.08, 0, 160))
        t["Σ"] = g(0.62, [p(0.56, 0), p(0.04, 0), p(0.34, 0.5), p(0.04, B), p(0.58, B)])
        t["∑"] = t["Σ"]
        t["Δ"] = g(0.68, [p(0.32, 0), p(0, B), p(0.64, B), p(0.32, 0)])
        t["α"] = g(0.62, arc(0.25, M, 0.22, R, -10, -350) + [p(0.58, X)])
        t["β"] = t["ß"]
        t["λ"] = g(0.56, [p(0.06, 0), p(0.5, B)], [p(0.26, 0.45), p(0.02, B)])
        t["μ"] = g(0.58, [p(0.04, X), p(0.04, D)], [p(0.04, 0.78)] + arc(0.25, 0.78, 0.21, 0.22, 180, 0), [p(0.46, X), p(0.46, B)])
        t["θ"] = g(0.58, arc(0.27, 0.5, 0.24, 0.5, -90, 270), [p(0.04, 0.5), p(0.5, 0.5)])
        t["°"] = g(0.3, arc(0.12, 0.12, 0.09, 0.1, -90, 270))
        t["%"] = g(0.7, arc(0.14, 0.18, 0.11, 0.16, -90, 270), [p(0.6, 0), p(0.08, B)], arc(0.54, 0.82, 0.11, 0.16, -90, 270))
        t["#"] = g(0.62, [p(0.22, 0.25), p(0.16, 0.95)], [p(0.44, 0.25), p(0.38, 0.95)], [p(0.04, 0.45), p(0.56, 0.45)], [p(0.02, 0.75), p(0.54, 0.75)])
        t["&"] = g(0.66, [p(0.62, B), p(0.12, 0.38)] + arc(0.24, 0.22, 0.14, 0.18, 150, -150) + [p(0.07, 0.72)] + arc(0.25, 0.75, 0.2, 0.25, 180, 60) + [p(0.6, 0.55)])
        t["€"] = g(0.66, arc(0.4, 0.5, 0.34, 0.5, -45, -315), [p(0, 0.42), p(0.44, 0.42)], [p(0, 0.6), p(0.44, 0.6)])
        t["$"] = g(0.6, arc(0.3, 0.32, 0.24, 0.2, -30, -270) + arc(0.3, 0.72, 0.26, 0.2, -90, 150), [p(0.3, -0.05), p(0.3, 1.05)])
        t["@"] = g(0.9, arc(0.42, 0.66, 0.14, 0.18, 0, -360), [p(0.56, 0.48), p(0.56, 0.8)] + arc(0.42, 0.6, 0.4, 0.45, 25, -320))
        return t
    }()
}
