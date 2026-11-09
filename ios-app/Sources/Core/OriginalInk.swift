import UIKit

struct OriginalStroke {
    let path: CGPath
    let color: UIColor
    let width: CGFloat
    let filled: Bool
}
struct OriginalInk {
    var strokes: [OriginalStroke] = []
    var unsupported = 0
    static func read(_ data: Data) throws -> OriginalInk {
        var result = OriginalInk()
        for record in try WireMessage.records(data) {
            guard let field = record[7] else { continue }
            let m = try field.message()
            guard let compressed = m[2]?.data else { continue }
            do {
                let raw = try AppleLZ4.decode(compressed)
                let type = m[3]?.integer ?? 0
                let colorMessage = try m[4]?.message()
                let c = UIColor(red: colorMessage?[1]?.float ?? 0, green: colorMessage?[2]?.float ?? 0,
                                blue: colorMessage?[3]?.float ?? 0, alpha: colorMessage?[4]?.float ?? 1)
                if type == 0 { if let stroke = try constant(raw, color: c) { result.strokes.append(stroke) } }
                else if type == 1 { result.strokes.append(contentsOf:try flattened(raw,color:c)) }
                else { result.unsupported += 1 }
            } catch { result.unsupported += 1 }
        }
        return result
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
    private static func render(_ c: CGContext, ink: OriginalInk) {
        guard !ink.strokes.isEmpty else { return }
        for s in ink.strokes {
            c.saveGState(); c.setStrokeColor(s.color.cgColor); c.setFillColor(s.color.cgColor)
            c.setLineWidth(s.width); c.setLineCap(.round); c.setLineJoin(.round); c.addPath(s.path)
            if s.filled { c.fillPath() } else { c.strokePath() }; c.restoreGState()
        }
    }
}
