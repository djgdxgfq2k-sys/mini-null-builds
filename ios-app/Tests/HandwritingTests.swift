import XCTest
import PencilKit
@testable import NullMini

@MainActor final class HandwritingTests:XCTestCase {
    func testMissingGlyphFailsBeforeWritingAnything() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let library = HandwritingLibrary(directory:directory)
        let drawing = PKDrawing(strokes:[StrokeFactory.stroke(points:[CGPoint(x:10,y:20),CGPoint(x:18,y:40)],color:.black,width:2)])
        try library.train("a",drawing:drawing)
        XCTAssertThrowsError(try library.synthesize("ab",page:CGSize(width:595,height:842)))
        let strokes = try library.synthesize("a a",page:CGSize(width:595,height:842))
        XCTAssertEqual(strokes.count,2)
        XCTAssertGreaterThanOrEqual(strokes[0].renderBounds.minX,47)
    }
    func testCorruptProfileIsNotOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let url = directory.appendingPathComponent("handwriting-profile.json"), original = Data("broken-profile".utf8)
        try original.write(to:url)
        let library = HandwritingLibrary(directory:directory)
        XCTAssertThrowsError(try library.save())
        XCTAssertEqual(try Data(contentsOf:url),original)
    }
}
