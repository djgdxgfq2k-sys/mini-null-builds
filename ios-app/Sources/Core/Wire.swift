import Foundation

enum NotebookError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

struct ByteReader {
    let bytes: [UInt8]
    var position = 0
    init(_ data: Data) { bytes = Array(data) }
    var remaining: Int { bytes.count - position }
    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw NotebookError.invalid("Abgeschnittene Datei.") }
        defer { position += count }
        return Data(bytes[position ..< position + count])
    }
    mutating func uint(_ count: Int) throws -> UInt64 {
        let b = try take(count)
        return b.enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) }
    }
    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            let b = try uint(1)
            guard shift != 63 || b <= 1 else { throw NotebookError.invalid("Ungültige Ganzzahl.") }
            result |= (b & 127) << shift
            if b < 128 { return result }
        }
        throw NotebookError.invalid("Ungültige Ganzzahl.")
    }
    mutating func float() throws -> CGFloat {
        let value = CGFloat(Float(bitPattern: UInt32(try uint(4))))
        guard value.isFinite else { throw NotebookError.invalid("Ungültige Koordinate.") }
        return value
    }
}

struct WireField {
    let number: Int
    let kind: Int
    let data: Data
    let integer: UInt64
    var string: String? { String(data: data, encoding: .utf8) }
    func message() throws -> WireMessage { try WireMessage(data) }
    var float: CGFloat? {
        guard kind == 5, data.count == 4 else { return nil }
        var r = ByteReader(data); return try? r.float()
    }
}

struct WireMessage {
    let fields: [WireField]
    init(_ data: Data) throws {
        var r = ByteReader(data); var out: [WireField] = []
        while r.remaining > 0 {
            let key = try r.varint(), kind = Int(key & 7)
            guard key >> 3 > 0, key >> 3 <= 536_870_911 else { throw NotebookError.invalid("Ungültiges Protobuf-Feld.") }
            var value: UInt64 = 0; let body: Data
            switch kind {
            case 0: value = try r.varint(); body = Data()
            case 1: body = try r.take(8)
            case 5: body = try r.take(4)
            case 2:
                let count = try r.varint()
                guard count <= UInt64(r.remaining) else { throw NotebookError.invalid("Ungültige Protobuf-Länge.") }
                body = try r.take(Int(count))
            default: throw NotebookError.invalid("Nicht unterstützter Protobuf-Wire-Typ.")
            }
            out.append(WireField(number: Int(key >> 3), kind: kind, data: body, integer: value))
            guard out.count <= 1_000_000 else { throw NotebookError.invalid("Zu viele Datenfelder.") }
        }
        fields = out
    }
    subscript(_ n: Int) -> WireField? { fields.last { $0.number == n } }
    static func records(_ data: Data) throws -> [WireMessage] {
        var r = ByteReader(data); var result: [WireMessage] = []
        while r.remaining > 0 {
            let size = try r.varint()
            guard size <= UInt64(r.remaining) else { throw NotebookError.invalid("Ungültiger Datensatz.") }
            result.append(try WireMessage(r.take(Int(size))))
            guard result.count < 1_000_000 else { throw NotebookError.invalid("Zu viele Datensätze.") }
        }
        return result
    }
}

enum AppleLZ4 {
    static let limit = 64 * 1024 * 1024
    static func decode(_ data: Data) throws -> Data {
        var r = ByteReader(data); var output = Data()
        while r.remaining >= 4 {
            let magic = try r.take(4)
            if magic == Data("bv4$".utf8) {
                guard r.remaining == 0 else { throw NotebookError.invalid("Zusätzliche Kompressionsdaten.") }
                return output
            }
            let size = Int(try r.uint(4))
            guard size <= limit - output.count else { throw NotebookError.invalid("Strichdaten zu groß.") }
            if magic == Data("bv4-".utf8) { output.append(try r.take(size)); continue }
            guard magic == Data("bv41".utf8) else { throw NotebookError.invalid("Unbekannte Strichkompression.") }
            let compressed = Int(try r.uint(4)); let block = try r.take(compressed)
            var b = ByteReader(block); var out: [UInt8] = []
            while b.remaining > 0 {
                let token = Int(try b.uint(1))
                func extended(_ initial: Int, _ b: inout ByteReader) throws -> Int {
                    var n = initial
                    if initial == 15 {
                        var c = 255
                        while c == 255 { c = Int(try b.uint(1)); n += c; guard n <= limit else { throw NotebookError.invalid("LZ4-Länge zu groß.") } }
                    }
                    return n
                }
                let n = try extended(token >> 4, &b)
                guard n <= size - out.count else { throw NotebookError.invalid("LZ4-Länge ungültig.") }
                out.append(contentsOf: try b.take(n))
                if b.remaining == 0 { break }
                let offset = Int(try b.uint(2)); let count = try extended(token & 15, &b) + 4
                guard offset > 0, offset <= out.count, count <= size - out.count else { throw NotebookError.invalid("LZ4-Verweis ungültig.") }
                for _ in 0 ..< count { out.append(out[out.count - offset]) }
            }
            guard out.count == size else { throw NotebookError.invalid("LZ4-Ergebnis abgeschnitten.") }
            output.append(contentsOf: out)
        }
        throw NotebookError.invalid("LZ4-Abschluss fehlt.")
    }
}
