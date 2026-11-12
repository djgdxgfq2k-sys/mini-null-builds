import UIKit
import PencilKit
import PDFKit
import ImageIO

struct OriginalStroke {
    let path: CGPath
    let color: UIColor
    let width: CGFloat
    let filled: Bool
    func moved(_ t: CGAffineTransform) -> OriginalStroke {
        guard !t.isIdentity else { return self }
        var t = t
        return OriginalStroke(path: path.copy(using: &t) ?? path, color: color, width: width, filled: filled)
    }
}
struct OriginalInk {
    var strokes: [OriginalStroke] = []
    /// Pen, fountain-pen and highlighter strokes rebuilt as PencilKit strokes, so they can be erased,
    /// lassoed and undone like anything written in NullMini. Filled only when `read(_:convert:)` converts.
    var editable: [PKStroke] = []
    /// Photos and pasted pictures: an attachment drawn at `center` with `size`, turned by `rotation` radians.
    var images: [OriginalImage] = []
    /// Text boxes and sticky notes, converted to NullMini text boxes when the page is imported.
    var texts: [TextBox] = []
    var unsupported = 0
    struct OriginalImage { let attachment: String; let center: CGPoint; let size: CGSize; let rotation: CGFloat; var image: UIImage? = nil }

    private static func point(_ field: WireField?) -> CGPoint? {
        guard let m = try? field?.message(), let x = m[1]?.float, let y = m[2]?.float, x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: x, y: y)
    }
    private static func color(_ field: WireField?) -> UIColor? {
        guard let m = try? field?.message() else { return nil }
        return UIColor(red: m[1]?.float ?? 0, green: m[2]?.float ?? 0, blue: m[3]?.float ?? 0, alpha: m[4]?.float ?? 1)
    }
    private static func hex(_ color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(max(0, min(1, r)) * 255), Int(max(0, min(1, g)) * 255), Int(max(0, min(1, b)) * 255))
    }
    /// A picture element: field 3 holds centre, natural size and rotation; field 4 names the attachment.
    static func image(_ m: WireMessage) -> OriginalImage? {
        guard let attachment = m[4]?.string, UUID(uuidString: attachment) != nil, m[14]?.integer != 1,
              let geometry = try? m[3]?.message(), let center = point(geometry[1]), let size = point(geometry[2]),
              size.x > 0, size.y > 0, size.x < 100_000, size.y < 100_000 else { return nil }
        let rotation = geometry[3]?.float ?? 0
        return OriginalImage(attachment: attachment, center: center, size: CGSize(width: size.x, height: size.y), rotation: rotation.isFinite ? rotation : 0)
    }
    /// A text box (kind 31) or sticky note (kind 35): origin and scale in field 20, box size in 21,
    /// and the LZ4-compressed attributed text in 32 as runs of (string, attributes).
    static func text(_ m: WireMessage) -> TextBox? {
        guard let place = try? m[20]?.message(), let origin = point(place[1]),
              let body = try? m[32]?.message(), let content = try? body[1]?.message(), let compressed = content[2]?.data,
              let raw = try? AppleLZ4.decode(compressed), let runs = try? WireMessage(raw) else { return nil }
        var string = "", fontSize: CGFloat?
        for run in runs.fields where run.number == 1 {
            guard let r = try? run.message() else { continue }
            string += r[1]?.string ?? ""
            if fontSize == nil, let attributes = try? r[2]?.message(), let size = attributes[40]?.float, size > 0 { fontSize = size }
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let sticky = m[2]?.integer == 35
        guard !trimmed.isEmpty || sticky else { return nil }
        let scale = max(0.05, min(20, place[3]?.float ?? 1))
        var width: CGFloat = 200, height: CGFloat = 40
        if let frame = try? m[21]?.message(), let sized = try? (frame[2] ?? frame[3])?.message() {
            if let w = sized[1]?.float, w.isFinite, w > 0 { width = w }
            if let h = sized[2]?.float, h.isFinite, h > 0 { height = h }
        }
        if let measured = point(body[2]), measured.y.isFinite { height = max(height, measured.y + 20) }
        var box = TextBox(text: string.hasSuffix("\n") ? String(string.dropLast()) : string, x: origin.x, y: origin.y, width: width * scale, height: height * scale)
        box.fontSize = (fontSize ?? 17) * scale
        if sticky, let background = (try? m[30]?.message()).flatMap({ try? $0[1]?.message() }).flatMap({ color($0[1]) }) { box.color = hex(background) }
        else if sticky { box.color = "#FFE36E" }
        return box
    }
    /// A connector line or arrow drawn freely: field 20 holds start, bends and end; field 32 width and colour.
    static func connector(_ m: WireMessage) -> (points: [CGPoint], width: CGFloat, color: UIColor)? {
        guard let path = try? m[20]?.message() else { return nil }
        var points: [CGPoint] = []
        for f in path.fields {
            if f.number == 2, let p = point(f) { points.append(p) }
            else if f.number == 1 || f.number == 3, let inner = try? f.message(), let p = point(inner[1]) { if f.number == 1 { points.insert(p, at: 0) } else { points.append(p) } }
        }
        guard points.count >= 2 else { return nil }
        let style = try? m[32]?.message()
        let width = max(0.3, min(50, style?[1]?.float ?? 1.5))
        let ink = (try? style?[3]?.message()).flatMap { color($0[1]) } ?? UIColor(red: 0.118, green: 0.106, blue: 0.106, alpha: 1)
        return (points, width, ink)
    }

    static func read(_ data: Data, convert: Bool = false, overlayOnly: Bool = false) throws -> OriginalInk {
        var result = OriginalInk()
        let date = Date(timeIntervalSince1970: 0)
        let records = try WireMessage.records(data)
        // A bare record whose field 3 is 1 is a tombstone: the element with that id was deleted in Goodnotes.
        var deleted = Set<String>()
        for record in records where record[3]?.integer == 1 && record[3]?.kind == 0 {
            if let id = record[1]?.string, UUID(uuidString: id) != nil { deleted.insert(id) }
        }
        for record in records {
            if let field = record[1], field.kind == 2, field.string.flatMap({ UUID(uuidString: $0) }) == nil,
               let m = try? field.message(), let picture = image(m) {
                if let id = m[1]?.string, deleted.contains(id) { continue }
                result.images.append(picture); continue
            }
            if let field = record[21], let m = try? field.message() {
                if let id = m[1]?.string, deleted.contains(id) { continue }
                if !overlayOnly, let box = text(m) { result.texts.append(box) }
                continue
            }
            if let field = record[22], let m = try? field.message() {
                if let id = m[1]?.string, deleted.contains(id) { continue }
                if let line = connector(m) {
                    if convert {
                        let lines = [line.points.map { InkPoint(point: $0, radius: line.width / 2) }]
                        if !overlayOnly { result.editable += lines.compactMap { editableStroke(densified($0), offset: .identity, color: line.color, marker: false, variable: false, date: date) } }
                    } else {
                        let path = CGMutablePath(); path.addLines(between: line.points)
                        result.strokes.append(OriginalStroke(path: path, color: line.color, width: line.width, filled: false))
                    }
                }
                continue
            }
            guard let field = record[7] else { continue }
            // Some elements under field 7 are not stroke messages; count them instead of failing the page.
            guard let m = try? field.message() else { result.unsupported += 1; continue }
            if let id = m[1]?.string, deleted.contains(id) { continue }
            if m[14]?.integer == 1 && m[14]?.kind == 0 { continue }
            guard let compressed = m[2]?.data else { continue }
            do {
                let raw = try AppleLZ4.decode(compressed)
                let type = m[3]?.integer ?? 0
                let colorMessage = try m[4]?.message()
                let c = UIColor(red: colorMessage?[1]?.float ?? 0, green: colorMessage?[2]?.float ?? 0,
                                blue: colorMessage?[3]?.float ?? 0, alpha: colorMessage?[4]?.float ?? 1)
                // Field 6 is where a stroke was moved to after it was drawn (lasso moves).
                var offset = CGAffineTransform.identity
                if let move = try? m[6]?.message() {
                    let dx = move[1]?.float ?? 0, dy = move[2]?.float ?? 0
                    if dx.isFinite, dy.isFinite { offset = CGAffineTransform(translationX: dx, y: dy) }
                }
                let marker = m[5]?.integer == 1
                if convert, [0, 1, 4, 5].contains(type) {
                    let lines = try centerlines(raw, type: Int(type))
                    if !overlayOnly { result.editable += lines.compactMap { editableStroke($0, offset: offset, color: c, marker: marker, variable: type == 1 || type == 4, pencil: type == 5, date: date) } }
                    continue
                }
                if type == 0 { if let stroke = try constant(raw, color: c) { result.strokes.append(stroke.moved(offset)) } }
                else if type == 1 { result.strokes.append(contentsOf: try flattened(raw, color: c).map { $0.moved(offset) }) }
                else if type == 5 {
                    for line in try centerlines(raw, type: 5) where line.count > 1 {
                        let path = CGMutablePath(); path.addLines(between: line.map(\.point))
                        result.strokes.append(OriginalStroke(path: path, color: c.withAlphaComponent(c.cgColor.alpha * 0.8), width: (line.first?.radius ?? 0.5) * 2, filled: false).moved(offset))
                    }
                }
                else { result.unsupported += 1 }
            } catch { result.unsupported += 1 }
        }
        return result
    }

    struct InkPoint: Equatable { var point: CGPoint; var radius: CGFloat }

    /// Centre lines with their half widths. Constant pens (type 0) store move/quad commands and one width;
    /// variable pens store per-point radii: type 1 as start dots followed by quadratic segments
    /// (control and end, each x, y, radius), type 4 as dots and straight pieces (x0, y0, x1, y1, r0, r1).
    static func centerlines(_ data: Data, type: Int) throws -> [[InkPoint]] {
        var r = ByteReader(data)
        guard try r.take(4) == Data([116, 112, 108, 0]), Int(try r.uint(4)) == data.count else { throw NotebookError.invalid("Unbekannter Strichcontainer.") }
        var format = Data()
        while true { let b = try r.take(1); if b.first == 0 { break }; format.append(b) }
        let name = String(data: format, encoding: .ascii) ?? ""
        _ = try r.uint(2)
        var lines: [[InkPoint]] = []
        func sampleQuad(_ a: InkPoint, _ control: InkPoint, _ b: InkPoint, into line: inout [InkPoint]) {
            let length = hypot(control.point.x - a.point.x, control.point.y - a.point.y) + hypot(b.point.x - control.point.x, b.point.y - control.point.y)
            let steps = max(1, min(64, Int((length / 1.5).rounded(.up))))
            for i in 1 ... steps {
                let t = CGFloat(i) / CGFloat(steps), u = 1 - t
                let x = u * u * a.point.x + 2 * u * t * control.point.x + t * t * b.point.x
                let y = u * u * a.point.y + 2 * u * t * control.point.y + t * t * b.point.y
                let radius = u * u * a.radius + 2 * u * t * control.radius + t * t * b.radius
                line.append(InkPoint(point: CGPoint(x: x, y: y), radius: radius))
            }
        }
        if type == 0 || type == 5 {
            func count(_ stride: Int) throws -> Int { let n = Int(try r.uint(4)); guard n <= r.remaining / stride else { throw NotebookError.invalid("Stricharray abgeschnitten.") }; return n }
            let radius: CGFloat
            if type == 5 {
                // Pencil: width, commands, then per-sample tilt/pressure records that only shade the
                // texture, followed by the same move/quad centre line as a constant pen.
                guard name == "vuA(v)A(S(uuuuu))A(S(uuuuuuuuuuu))A(S(uu))A(v)A(S(uu))A(S(uuuu))A(u)" else { throw NotebookError.invalid("Unbekannte Bleistiftversion.") }
                radius = max(0.05, min(50, try r.float() / 2))
                for stride in [2, 20, 44, 8] { _ = try r.take(try count(stride) * stride) }
            } else {
                guard name == "vuA(v)A(S(uu))A(S(uuuu))vA(f)" else { throw NotebookError.invalid("Unbekannte Strichversion.") }
                radius = max(0.05, min(5000, try r.float() / 2))
            }
            var commands: [UInt64] = []
            for _ in 0 ..< (try count(2)) { commands.append(try r.uint(2)) }
            var moves: [CGPoint] = []
            for _ in 0 ..< (try count(8)) { moves.append(CGPoint(x: try r.float(), y: try r.float())) }
            var quads: [(CGPoint, CGPoint)] = []
            for _ in 0 ..< (try count(16)) { quads.append((CGPoint(x: try r.float(), y: try r.float()), CGPoint(x: try r.float(), y: try r.float()))) }
            var a = 0, b = 0, line: [InkPoint] = []
            for command in commands {
                if command == 0 {
                    guard a < moves.count else { throw NotebookError.invalid("Startpunkt fehlt.") }
                    if !line.isEmpty { lines.append(line) }
                    line = [InkPoint(point: moves[a], radius: radius)]; a += 1
                } else if command == 1 {
                    guard b < quads.count, let last = line.last else { throw NotebookError.invalid("Kurvenpunkt fehlt.") }
                    sampleQuad(last, InkPoint(point: quads[b].0, radius: radius), InkPoint(point: quads[b].1, radius: radius), into: &line); b += 1
                } else { throw NotebookError.invalid("Unbekannter Strichbefehl.") }
            }
            if !line.isEmpty { lines.append(line) }
            return lines
        }
        guard name.hasSuffix("A(v)A(u)A(u)A(v)A(v)A(u)A(u)A(u)A(u)A(v)") else { throw NotebookError.invalid("Unbekannte variable Strichversion.") }
        if name.hasPrefix("vu") { _ = try r.float() }
        var arrays: [[CGFloat]] = []
        for size in [2, 4, 4, 2, 2, 4, 4, 4, 4, 2] {
            let n = Int(try r.uint(4)); guard n <= r.remaining / size else { throw NotebookError.invalid("Stricharray abgeschnitten.") }
            var values: [CGFloat] = []; values.reserveCapacity(n)
            for _ in 0 ..< n { values.append(size == 2 ? CGFloat(try r.uint(2)) : try r.float()) }
            arrays.append(values)
        }
        var i1 = 0, i2 = 0, line: [InkPoint] = []
        func take(_ array: Int, _ index: inout Int, _ n: Int) throws -> [CGFloat] {
            guard index + n <= arrays[array].count else { throw NotebookError.invalid("Vektorbefehl abgeschnitten.") }
            defer { index += n }; return Array(arrays[array][index ..< index + n])
        }
        func dot(_ p: [CGFloat]) { if !line.isEmpty { lines.append(line) }; line = [InkPoint(point: CGPoint(x: p[0], y: p[1]), radius: max(0.05, p[2]))] }
        for command in arrays[0] {
            switch Int(command) {
            case 0, 2: dot(try take(1, &i1, 3))
            case 4: dot(try take(1, &i1, 4))
            case 1, 5:
                let p = try take(2, &i2, Int(command) == 1 ? 6 : 9)
                let control = InkPoint(point: CGPoint(x: p[0], y: p[1]), radius: max(0.05, p[2])), end = InkPoint(point: CGPoint(x: p[3], y: p[4]), radius: max(0.05, p[5]))
                if let last = line.last { sampleQuad(last, control, end, into: &line) } else { line = [control, end] }
            case 3:
                // Type 4 draws in short overlapping pieces; a piece touching the line's end continues it.
                let p = try take(2, &i2, 6)
                let start = InkPoint(point: CGPoint(x: p[0], y: p[1]), radius: max(0.05, p[4])), end = InkPoint(point: CGPoint(x: p[2], y: p[3]), radius: max(0.05, p[5]))
                if let last = line.last, hypot(last.point.x - start.point.x, last.point.y - start.point.y) <= max(1, last.radius * 1.5) {
                    line.append(start); line.append(end)
                } else { if !line.isEmpty { lines.append(line) }; line = [start, end] }
            default: throw NotebookError.invalid("Unbekannter variabler Strichbefehl.")
            }
        }
        if !line.isEmpty { lines.append(line) }
        return type == 4 ? joined(lines) : lines
    }
    /// Type 4 lines alternate between a dot and the piece leaving it; lines that touch are merged so a
    /// translucent highlighter does not darken where its pieces overlap.
    static func joined(_ lines: [[InkPoint]]) -> [[InkPoint]] {
        var result: [[InkPoint]] = []
        for line in lines {
            if let last = result.last?.last, let first = line.first, hypot(last.point.x - first.point.x, last.point.y - first.point.y) <= max(1, max(last.radius, first.radius) * 1.5) {
                result[result.count - 1] += line
            } else { result.append(line) }
        }
        return result
    }

    /// Straight connector segments get intermediate points so the erasers can cut them anywhere.
    static func densified(_ line: [InkPoint]) -> [InkPoint] {
        guard var last = line.first else { return line }
        var out = [last]
        for p in line.dropFirst() {
            let steps = max(1, min(400, Int(hypot(p.point.x - last.point.x, p.point.y - last.point.y) / 2)))
            for i in 1 ... steps { let t = CGFloat(i) / CGFloat(steps); out.append(InkPoint(point: CGPoint(x: last.point.x + (p.point.x - last.point.x) * t, y: last.point.y + (p.point.y - last.point.y) * t), radius: p.radius)) }
            last = p
        }
        return out
    }
    static func editableStroke(_ line: [InkPoint], offset: CGAffineTransform, color: UIColor, marker: Bool, variable: Bool, pencil: Bool = false, date: Date) -> PKStroke? {
        var points = line.filter { $0.point.x.isFinite && $0.point.y.isFinite && $0.radius.isFinite }
        guard let first = points.first else { return nil }
        if points.count == 1 { points.append(InkPoint(point: CGPoint(x: first.point.x + 0.01, y: first.point.y), radius: first.radius)) }
        let ink = PKInk(marker ? .marker : (pencil ? .pencil : (variable ? .pen : .monoline)), color: color)
        let controls = points.enumerated().map { index, p in
            let width = max(0.1, min(400, p.radius * 2))
            return PKStrokePoint(location: p.point.applying(offset), timeOffset: TimeInterval(index) / 240, size: CGSize(width: width, height: width), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: controls, creationDate: date))
    }
    // Observed flattened arrays from 0x101f87f24 / 0x101f88874.
    // Arc parameter interpretation is provisional until validated against iPad rendering.
    static func flattened(_ data:Data,color:UIColor) throws -> [OriginalStroke] {
        var r = ByteReader(data)
        guard try r.take(4) == Data([116,112,108,0]), Int(try r.uint(4)) == data.count else { throw NotebookError.invalid("Unbekannter Strichcontainer.") }
        var format = Data()
        while true { let b = try r.take(1); if b.first == 0 { break }; format.append(b) }
        guard String(data:format,encoding:.ascii) == "vA(v)A(u)A(u)A(v)A(v)A(u)A(u)A(u)A(u)A(v)", try r.uint(2) == 2 else { throw NotebookError.invalid("Unbekannte variable Strichversion.") }
        var arrays:[[CGFloat]] = []
        for size in [2,4,4,2,2,4,4,4,4,2] {
            let n = Int(try r.uint(4)); guard n <= r.remaining/size else { throw NotebookError.invalid("Stricharray abgeschnitten.") }
            var values:[CGFloat] = []
            for _ in 0..<n { if size == 2 { values.append(CGFloat(try r.uint(2))) } else { values.append(try r.float()) } }
            arrays.append(values)
        }
        guard r.remaining == 0 else { throw NotebookError.invalid("Unbekannte variable Strichfelder.") }
        var positions = Array(repeating:0,count:10)
        func take(_ array:Int,_ n:Int) throws -> [CGFloat] {
            let start = positions[array]
            guard n >= 0, start+n <= arrays[array].count else { throw NotebookError.invalid("Vektorbefehl abgeschnitten.") }
            positions[array] += n; return Array(arrays[array][start..<start+n])
        }
        let filled = CGMutablePath()
        var width:CGFloat = 1
        for command in arrays[0] {
            switch Int(command) {
            case 0,4:
                let p = try take(1,Int(command) == 0 ? 3 : 4); width = max(0.1,p[2]*2)
            case 1,5:
                _ = try take(2,Int(command) == 1 ? 6 : 9)
                let n = Int(try take(3,1)[0]); let shape = CGMutablePath()
                for _ in 0..<n {
                    let kind = Int(try take(4,1)[0])
                    switch kind {
                    case 0: let p = try take(5,2); shape.move(to:CGPoint(x:p[0],y:p[1]))
                    case 1: let p = try take(6,4); shape.addQuadCurve(to:CGPoint(x:p[2],y:p[3]),control:CGPoint(x:p[0],y:p[1]))
                    case 2: let p = try take(7,6); shape.addCurve(to:CGPoint(x:p[4],y:p[5]),control1:CGPoint(x:p[0],y:p[1]),control2:CGPoint(x:p[2],y:p[3]))
                    case 3:
                        let p = try take(8,5); let clockwise = try take(9,1)[0] == 1
                        guard p[2] >= 0 else { throw NotebookError.invalid("Ungültiger Kreisbogen.") }
                        shape.addArc(center:CGPoint(x:p[0],y:p[1]),radius:p[2],startAngle:p[3],endAngle:p[4],clockwise:clockwise)
                    case 6:
                        let p = try take(8,7); let clockwise = try take(9,1)[0] == 1
                        guard p[2] >= 0, p[3] >= 0 else { throw NotebookError.invalid("Ungültiger Ellipsenbogen.") }
                        let t = CGAffineTransform(a:cos(p[6])*p[2],b:sin(p[6])*p[2],c:-sin(p[6])*p[3],d:cos(p[6])*p[3],tx:p[0],ty:p[1])
                        shape.addArc(center:.zero,radius:1,startAngle:p[4],endAngle:p[5],clockwise:clockwise,transform:t)
                    default: throw NotebookError.invalid("Unbekannter Konturbefehl.")
                    }
                }
                shape.closeSubpath(); filled.addPath(shape)
            default: throw NotebookError.invalid("Unbekannter variabler Strichbefehl.")
            }
        }
        for i in 1..<10 where positions[i] != arrays[i].count { throw NotebookError.invalid("Nicht interpretierte Strichdaten.") }
        var result:[OriginalStroke] = []
        if !filled.isEmpty { result.append(OriginalStroke(path:filled,color:color,width:width,filled:true)) }
        return result
    }
    // Independently implemented from the observed tpl format and decoder rules.
    static func constant(_ data: Data, color: UIColor) throws -> OriginalStroke? {
        var r = ByteReader(data)
        guard try r.take(4) == Data([116,112,108,0]), Int(try r.uint(4)) == data.count else { throw NotebookError.invalid("Unbekannter Strichcontainer.") }
        var format = Data()
        while true { let b = try r.take(1); if b.first == 0 { break }; format.append(b) }
        guard String(data: format, encoding: .ascii) == "vuA(v)A(S(uu))A(S(uuuu))vA(f)", try r.uint(2) == 2 else { throw NotebookError.invalid("Unbekannte Strichversion.") }
        let width = try r.float()
        func count(_ r: inout ByteReader, stride: Int) throws -> Int {
            let n = Int(try r.uint(4)); guard n <= r.remaining / stride else { throw NotebookError.invalid("Stricharray abgeschnitten.") }; return n
        }
        let n = try count(&r, stride: 2); var commands: [UInt64] = []
        for _ in 0 ..< n { commands.append(try r.uint(2)) }
        let moves = try count(&r, stride: 8); var points: [CGPoint] = []
        for _ in 0 ..< moves { points.append(CGPoint(x: try r.float(), y: try r.float())) }
        let curves = try count(&r, stride: 16); var quads: [(CGPoint,CGPoint)] = []
        for _ in 0 ..< curves { quads.append((CGPoint(x: try r.float(), y: try r.float()), CGPoint(x: try r.float(), y: try r.float()))) }
        _ = try r.uint(2)
        let samples = try count(&r, stride: 8); _ = try r.take(samples * 8)
        guard r.remaining == 0 else { throw NotebookError.invalid("Unbekannte Strichfelder.") }
        if commands.isEmpty { return nil }
        let p = CGMutablePath(); var a = 0; var b = 0
        for cmd in commands {
            switch cmd {
            case 0:
                guard a < points.count else { throw NotebookError.invalid("Startpunkt fehlt.") }
                p.move(to: points[a]); a += 1
            case 1:
                guard b < quads.count else { throw NotebookError.invalid("Kurvenpunkt fehlt.") }
                p.addQuadCurve(to: quads[b].1, control: quads[b].0); b += 1
            default: throw NotebookError.invalid("Unbekannter Strichbefehl.")
            }
        }
        guard width >= 0, width <= 10000 else { throw NotebookError.invalid("Ungültige Strichbreite.") }
        return OriginalStroke(path: p, color: color, width: width, filled: false)
    }
}

final class OriginalInkView: UIView {
    var ink = OriginalInk() { didSet { let ink = ink; detail.locked { tileInk = ink }; setNeedsDisplay() } }
    private var tileInk = OriginalInk()
    private lazy var detail = SharpDetailView { [weak self] c, _ in
        guard let self else { return }
        Self.render(c, ink: self.tileInk)
    }
    override init(frame: CGRect) { super.init(frame: frame); detail.frame = bounds; addSubview(detail) }
    required init?(coder: NSCoder) { nil }
    override func setNeedsDisplay() { super.setNeedsDisplay(); detail.setNeedsDisplay() }
    override func draw(_ rect: CGRect) {
        guard let c = UIGraphicsGetCurrentContext() else { return }
        Self.render(c, ink: ink)
    }
    private static func render(_ c: CGContext, ink: OriginalInk) { ink.draw(in: c) }
}

extension OriginalInk {
    /// Pictures first (they sit under ink in Goodnotes), then the strokes that stayed on the original layer.
    func draw(in c: CGContext) {
        for picture in images {
            guard let image = picture.image else { continue }
            c.saveGState()
            c.translateBy(x: picture.center.x, y: picture.center.y); c.rotate(by: picture.rotation)
            UIGraphicsPushContext(c)
            image.draw(in: CGRect(x: -picture.size.width / 2, y: -picture.size.height / 2, width: picture.size.width, height: picture.size.height))
            UIGraphicsPopContext()
            c.restoreGState()
        }
        for s in strokes {
            c.saveGState(); c.setStrokeColor(s.color.cgColor); c.setFillColor(s.color.cgColor)
            c.setLineWidth(s.width); c.setLineCap(.round); c.setLineJoin(.round); c.addPath(s.path)
            if s.filled { c.fillPath() } else { c.strokePath() }; c.restoreGState()
        }
    }
    /// Decodes picture attachments copied next to the notebook, downsampled so a page never holds full camera images.
    mutating func loadImages(from directory: URL) {
        for index in images.indices {
            let url = directory.appendingPathComponent("attachment-" + images[index].attachment)
            guard let data = try? Data(contentsOf: url) else { continue }
            if data.starts(with: Data("%PDF".utf8)), let page = PDFDocument(data: data)?.page(at: 0) {
                images[index].image = page.thumbnail(of: CGSize(width: 2000, height: 2000), for: .cropBox)
            } else if let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2400, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) {
                images[index].image = UIImage(cgImage: cg)
            }
        }
    }
}
