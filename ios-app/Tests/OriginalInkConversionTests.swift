import XCTest
import PencilKit
@testable import NullMini

/// Goodnotes strokes become editable PencilKit strokes, placed where they were moved to.
final class OriginalInkConversionTests: XCTestCase {
    private func varint(_ value: UInt64) -> Data {
        var v = value, out = Data()
        repeat { var byte = UInt8(v & 0x7F); v >>= 7; if v != 0 { byte |= 0x80 }; out.append(byte) } while v != 0
        return out
    }
    private func field(_ n: Int, _ body: Data) -> Data { varint(UInt64(n << 3 | 2)) + varint(UInt64(body.count)) + body }
    private func field(_ n: Int, int value: UInt64) -> Data { varint(UInt64(n << 3)) + varint(value) }
    private func field(_ n: Int, float value: Float) -> Data { var bits = value.bitPattern.littleEndian; return varint(UInt64(n << 3 | 5)) + Data(bytes: &bits, count: 4) }
    private func u16(_ v: Int) -> Data { var x = UInt16(v).littleEndian; return Data(bytes: &x, count: 2) }
    private func u32(_ v: Int) -> Data { var x = UInt32(v).littleEndian; return Data(bytes: &x, count: 4) }
    private func f32(_ v: Float) -> Data { var x = v.bitPattern.littleEndian; return Data(bytes: &x, count: 4) }
    private func container(_ format: String, _ body: Data) -> Data {
        let head = Data("tpl".utf8) + Data([0])
        let rest = Data(format.utf8) + Data([0]) + u16(2) + body
        return head + u32(8 + rest.count) + rest
    }
    /// Stored uncompressed ("bv4-" block), which the decoder accepts like LZ4 blocks.
    private func stroke(type: Int?, raw: Data, color: (Float, Float, Float, Float), offset: CGPoint? = nil, marker: Bool = false) -> Data {
        let block = Data("bv4-".utf8) + u32(raw.count) + raw + Data("bv4$".utf8)
        var message = field(1, Data("S".utf8)) + field(2, block)
        if let type { message += field(3, int: UInt64(type)) }
        message += field(4, field(1, float: color.0) + field(2, float: color.1) + field(3, float: color.2) + field(4, float: color.3))
        if marker { message += field(5, int: 1) }
        if let offset { message += field(6, field(1, float: Float(offset.x)) + field(2, float: Float(offset.y))) }
        let record = field(7, message)
        return varint(UInt64(record.count)) + record
    }
    private func constantRaw(width: Float, start: CGPoint, control: CGPoint, end: CGPoint) -> Data {
        var body = f32(width)
        body += u32(2) + u16(0) + u16(1)
        body += u32(1) + f32(Float(start.x)) + f32(Float(start.y))
        body += u32(1) + f32(Float(control.x)) + f32(Float(control.y)) + f32(Float(end.x)) + f32(Float(end.y))
        body += u16(0) + u32(0)
        return container("vuA(v)A(S(uu))A(S(uuuu))vA(f)", body)
    }

    func testConstantPenBecomesMovedMonolineStroke() throws {
        let raw = constantRaw(width: 2, start: CGPoint(x: 100, y: 100), control: CGPoint(x: 150, y: 100), end: CGPoint(x: 200, y: 100))
        let data = stroke(type: nil, raw: raw, color: (0.1, 0.1, 0.1, 1), offset: CGPoint(x: -50, y: 20))
        let converted = try OriginalInk.read(data, convert: true)
        XCTAssertEqual(converted.unsupported, 0)
        XCTAssertTrue(converted.strokes.isEmpty, "converted strokes must not also draw on the original layer")
        let pk = try XCTUnwrap(converted.editable.first)
        XCTAssertEqual(converted.editable.count, 1)
        XCTAssertEqual(pk.ink.inkType, .monoline)
        let points = Array(pk.path)
        XCTAssertEqual(points.first?.location.x ?? 0, 50, accuracy: 0.01)
        XCTAssertEqual(points.first?.location.y ?? 0, 120, accuracy: 0.01)
        XCTAssertEqual(points.last?.location.x ?? 0, 150, accuracy: 0.01)
        XCTAssertEqual(points.first?.size.width ?? 0, 2, accuracy: 0.01)
        XCTAssertGreaterThan(points.count, 10, "curves are sampled densely enough to erase precisely")

        let overlay = try OriginalInk.read(data)
        XCTAssertTrue(overlay.editable.isEmpty)
        let box = try XCTUnwrap(overlay.strokes.first).path.boundingBoxOfPath
        XCTAssertEqual(box.minX, 50, accuracy: 0.01, "the original layer applies the move too")
        XCTAssertEqual(box.minY, 120, accuracy: 0.01)
    }

    func testOverlayOnlySkipsEditableStrokesButStillReportsCorruption() throws {
        let raw = constantRaw(width: 2, start: .zero, control: CGPoint(x: 20, y: 10), end: CGPoint(x: 40, y: 20))
        let data = stroke(type: 0, raw: raw, color: (0, 0, 0, 1))
        let converted = try OriginalInk.read(data, convert: true)
        let overlay = try OriginalInk.read(data, convert: true, overlayOnly: true)
        XCTAssertFalse(converted.editable.isEmpty)
        XCTAssertTrue(overlay.editable.isEmpty)
        XCTAssertEqual(overlay.unsupported, converted.unsupported)
        XCTAssertEqual(overlay.strokes.count, converted.strokes.count)
        let broken = stroke(type: 0, raw: Data([1, 2, 3]), color: (0, 0, 0, 1))
        XCTAssertEqual(try OriginalInk.read(broken, convert: true, overlayOnly: true).unsupported, 1)
    }

    func testVariablePenKeepsRadiiAndHighlighterBecomesMarker() throws {
        // Start dot (x, y, r, extra), then one quadratic piece: control (x, y, r), end (x, y, r), three extras.
        var body = Data()
        body += u32(2) + u16(4) + u16(5)
        body += u32(4) + [10, 10, 0.5, 0.52].map { f32($0) }.reduce(Data(), +)
        body += u32(9) + [20, 10, 1.0, 30, 10, 1.5, 0.5, 0.5, 0.3].map { f32($0) }.reduce(Data(), +)
        for _ in 0 ..< 8 { body += u32(0) }
        let raw = container("vA(v)A(u)A(u)A(v)A(v)A(u)A(u)A(u)A(u)A(v)", body)
        let pen = try OriginalInk.read(stroke(type: 1, raw: raw, color: (0, 0, 1, 1)), convert: true)
        let points = Array(try XCTUnwrap(pen.editable.first).path)
        XCTAssertEqual(pen.editable.first?.ink.inkType, .pen)
        XCTAssertEqual(points.first?.size.width ?? 0, 1, accuracy: 0.01)
        XCTAssertEqual(points.last?.size.width ?? 0, 3, accuracy: 0.01)
        XCTAssertEqual(points.last?.location.x ?? 0, 30, accuracy: 0.01)

        let marker = try OriginalInk.read(stroke(type: 1, raw: raw, color: (1, 0.4, 0.4, 0.5), marker: true), convert: true)
        XCTAssertEqual(marker.editable.first?.ink.inkType, .marker)
    }

    func testTouchingHighlighterPiecesJoinIntoOneStroke() {
        let a = [OriginalInk.InkPoint(point: CGPoint(x: 0, y: 0), radius: 4), OriginalInk.InkPoint(point: CGPoint(x: 10, y: 0), radius: 4)]
        let b = [OriginalInk.InkPoint(point: CGPoint(x: 11, y: 1), radius: 4), OriginalInk.InkPoint(point: CGPoint(x: 20, y: 0), radius: 4)]
        let far = [OriginalInk.InkPoint(point: CGPoint(x: 200, y: 0), radius: 4)]
        XCTAssertEqual(OriginalInk.joined([a, b, far]).count, 2)
    }

    func testFolderStylesMapGoodnotesColoursAndSymbols() {
        let json = ##"{"items":[{"path":"Schule","color":"black","symbol":"none"},{"path":"Schule/Bio","color":"green","symbol":"graduation"},{"path":"Kunst","color":"#6F44A3","symbol":"none"},{"path":"../x","color":"red"}],"compatibilityVersion":1}"##
        let styles = LibraryImport.folderStyles(Data(json.utf8))
        XCTAssertEqual(styles["Schule"]?.color, ReferenceLayout.folderPalette[8])
        XCTAssertEqual(styles["Schule/Bio"]?.color, ReferenceLayout.folderPalette[12])
        XCTAssertEqual(styles["Schule/Bio"]?.symbol, "folder-symbols/folder_icon_graduation")
        XCTAssertNil(styles["Schule"]?.symbol)
        XCTAssertEqual(styles["Kunst"]?.color, "#6F44A3")
        XCTAssertNil(styles["../x"])
        XCTAssertEqual(styles.count, 3)
    }

    private func point(_ x: Float, _ y: Float) -> Data { field(1, float: x) + field(2, float: y) }
    private func record(_ body: Data) -> Data { varint(UInt64(body.count)) + body }

    func testPicturesTextsAndStickiesAreReadAndDeletedOnesSkipped() throws {
        let live = "11111111-1111-4111-8111-111111111111", gone = "22222222-2222-4222-8222-222222222222"
        let attachment = "33333333-3333-4333-8333-333333333333"
        func picture(_ id: String) -> Data {
            field(1, field(1, Data(id.utf8)) + field(3, field(1, point(400, 500)) + field(2, point(200, 100)) + field(3, float: 1.5708)) + field(4, Data(attachment.utf8)))
        }
        let runs = field(1, field(1, Data("Hallo Welt".utf8)) + field(2, field(40, float: 14)))
        let block = Data("bv4-".utf8) + withUnsafeBytes(of: UInt32(runs.count).littleEndian) { Data($0) } + runs + Data("bv4$".utf8)
        let sticky = field(21, field(1, Data("44444444-4444-4444-8444-444444444444".utf8)) + field(2, int: 35)
            + field(20, field(1, point(10, 20)) + field(3, float: 1)) + field(21, field(2, point(150, 40)))
            + field(30, field(1, field(1, field(1, float: 1) + field(2, float: 0.9) + field(3, float: 0.4))))
            + field(32, field(1, field(2, block))))
        let tombstone = field(1, Data(gone.utf8)) + field(3, int: 1)
        let data = record(picture(live)) + record(tombstone) + record(picture(gone)) + record(sticky)
        let ink = try OriginalInk.read(data, convert: true)
        XCTAssertEqual(ink.images.count, 1, "the deleted picture is skipped")
        let image = try XCTUnwrap(ink.images.first)
        XCTAssertEqual(image.attachment, attachment)
        XCTAssertEqual(image.center.x, 400, accuracy: 0.01); XCTAssertEqual(image.size.width, 200, accuracy: 0.01)
        XCTAssertEqual(image.rotation, 1.5708, accuracy: 0.001)
        let box = try XCTUnwrap(ink.texts.first)
        XCTAssertEqual(box.text, "Hallo Welt"); XCTAssertEqual(box.x, 10, accuracy: 0.01); XCTAssertEqual(box.width, 150, accuracy: 0.01)
        XCTAssertEqual(box.fontSize ?? 0, 14, accuracy: 0.01)
        XCTAssertEqual(box.color, "#FFE566")
    }
}
