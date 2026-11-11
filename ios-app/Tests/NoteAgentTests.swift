import XCTest
import PencilKit
import UIKit
@testable import NullMini

@MainActor final class NoteAgentTests: XCTestCase {
    // MARK: Gateway protocol

    func testParsesEveryGatewayMessage() {
        XCTAssertEqual(AgentEvent.parse(#"{"type":"status","request_id":"r","message":"starting local 7B"}"#)?.event, .status("starting local 7B"))
        let route = AgentEvent.parse(#"{"type":"route","request_id":"r","route":"REASONING_POOL","backend":"127.0.0.1:8082","reason":"keyword rule","triage_ms":0}"#)
        XCTAssertEqual(route?.requestID, "r")
        XCTAssertEqual(route?.event, .route(route: "REASONING_POOL", backend: "127.0.0.1:8082", reason: "keyword rule", triageMs: 0))
        XCTAssertEqual(AgentEvent.parse(#"{"type":"token","request_id":"r","text":"√2 "}"#)?.event, .token("√2 "))
        XCTAssertEqual(AgentEvent.parse(#"{"type":"done","request_id":"r","backend":"ollama","anchor":{"x":10.5,"y":20},"elapsed_ms":812}"#)?.event,
                       .done(backend: "ollama", anchor: CGPoint(x: 10.5, y: 20), elapsedMs: 812))
        let error = AgentEvent.parse(#"{"type":"error","request_id":null,"message":"invalid JSON"}"#)
        XCTAssertNil(error?.requestID)
        XCTAssertEqual(error?.event, .failed("invalid JSON"))
        XCTAssertNil(AgentEvent.parse("not json"))
        XCTAssertNil(AgentEvent.parse(#"{"type":"something-new"}"#))
    }

    func testRequestUsesGatewayFieldNames() throws {
        let request = AgentRequest(requestID: "abc", transcript: "prove it", canvasImageBase64: nil, cursor: CGPoint(x: 12, y: 340), pageText: "notes")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(json["request_id"] as? String, "abc")
        XCTAssertEqual(json["transcript"] as? String, "prove it")
        XCTAssertEqual(json["cursor_x"] as? Double, 12)
        XCTAssertEqual(json["cursor_y"] as? Double, 340)
        XCTAssertEqual(json["page_text"] as? String, "notes")
        XCTAssertNil(json["canvas_image_b64"], "no image key unless an image is attached")
    }

    func testSettingsBuildWebSocketURL() {
        XCTAssertEqual(AgentSettings(host: "100.95.154.45", port: 8000, token: "").url?.absoluteString, "ws://100.95.154.45:8000/ws/note-agent")
        XCTAssertNil(AgentSettings(host: "  ", port: 8000, token: "").url)
    }

    // MARK: Stroke font

    func testFontCoversLettersDigitsAndCommonSymbols() {
        let required = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789äöüÄÖÜß.,:;!?'\"-+=×÷/()[]<>%√π∫≤≥≠≈→²³éàç–’"
        let missing = required.filter { StrokeFont.glyph(for: $0) == nil && StrokeFont.superscripts[$0] == nil }
        XCTAssertEqual(String(missing), "", "characters without a glyph")
        for (char, glyph) in StrokeFont.table {
            XCTAssertGreaterThan(glyph.advance, 0, "\(char)")
            for stroke in glyph.strokes { for p in stroke { XCTAssert(p.x.isFinite && p.y.isFinite && p.y > -0.3 && p.y < 1.4, "\(char) point \(p)") } }
        }
    }

    // MARK: Synthesizer

    private let page = CGSize(width: 595, height: 842)

    func testWritesWordsAsStreamedAndStaysInsideTheMargins() {
        let writer = PKStrokeSynthesizer(anchor: CGPoint(x: 60, y: 100), pageSize: page, style: SynthInkStyle(), seed: 7)
        XCTAssertTrue(writer.write("Hal").isEmpty, "a word is written only once it is complete")
        let first = writer.write("lo ")
        XCTAssertFalse(first.isEmpty)
        let rest = writer.strokes(for: "Welt, dies ist ein längerer Satz, der sicher über mehr als eine Zeile umbrechen muss, weil er so lang ist.")
        let all = first + rest
        let bounds = PKDrawing(strokes: all).bounds
        XCTAssertGreaterThanOrEqual(bounds.minX, 55)
        // Slant, stroke width and wobble may reach a few points past the layout box.
        XCTAssertLessThanOrEqual(bounds.maxX, page.width - 40 + 6)
        XCTAssertGreaterThan(bounds.height, SynthInkStyle().capHeight * 2.5, "long text wraps onto several lines")
        XCTAssertGreaterThanOrEqual(bounds.minY, 100 - 4, "starts at the cursor")
        XCTAssertFalse(writer.overflowed)
    }

    func testStrokePointsCarryHumanVariation() throws {
        let writer = PKStrokeSynthesizer(anchor: CGPoint(x: 40, y: 40), pageSize: page, style: SynthInkStyle(), seed: 3)
        let stroke = try XCTUnwrap(writer.strokes(for: "o").first)
        let points = Array(stroke.path)
        XCTAssertGreaterThan(points.count, 10)
        let forces = Set(points.map { ($0.force * 100).rounded() }), azimuths = Set(points.map { ($0.azimuth * 100).rounded() })
        XCTAssertGreaterThan(forces.count, 2, "pressure varies")
        XCTAssertGreaterThan(azimuths.count, 2, "azimuth varies")
        XCTAssertTrue(zip(points, points.dropFirst()).allSatisfy { $0.timeOffset <= $1.timeOffset }, "time runs forward")
        XCTAssertEqual(stroke.ink.inkType, .pen)
    }

    func testSameSeedIsDeterministic() {
        let a = PKStrokeSynthesizer(anchor: .init(x: 40, y: 40), pageSize: page, style: SynthInkStyle(), seed: 11).strokes(for: "x = 2")
        let b = PKStrokeSynthesizer(anchor: .init(x: 40, y: 40), pageSize: page, style: SynthInkStyle(), seed: 11).strokes(for: "x = 2")
        func locations(_ strokes: [PKStroke]) -> [CGPoint] { strokes.flatMap { $0.path.map(\.location) } }
        XCTAssertEqual(locations(a), locations(b))
        XCTAssertFalse(locations(a).isEmpty)
    }

    func testStopsAtTheBottomOfThePage() {
        let writer = PKStrokeSynthesizer(anchor: CGPoint(x: 40, y: page.height - 70), pageSize: page, style: SynthInkStyle(), seed: 1)
        _ = writer.strokes(for: Array(repeating: "Zeile mit Text\n", count: 6).joined())
        XCTAssertTrue(writer.overflowed)
    }

    func testSuperscriptIsSmallerAndRaised() throws {
        let style = SynthInkStyle()
        let base = PKDrawing(strokes: PKStrokeSynthesizer(anchor: .init(x: 40, y: 40), pageSize: page, style: style, seed: 2).strokes(for: "2")).bounds
        let sup = PKDrawing(strokes: PKStrokeSynthesizer(anchor: .init(x: 40, y: 40), pageSize: page, style: style, seed: 2).strokes(for: "²")).bounds
        XCTAssertLessThan(sup.height, base.height * 0.8)
        XCTAssertLessThan(sup.maxY, base.maxY - style.capHeight * 0.2)
    }

    func testMarkdownIsNotDrawn() {
        XCTAssertEqual(PKStrokeSynthesizer.cleanMarkdown("**wichtig**"), "wichtig")
        XCTAssertEqual(PKStrokeSynthesizer.cleanMarkdown("`code`"), "code")
        XCTAssertEqual(PKStrokeSynthesizer.cleanMarkdown("##"), "")
    }

    func testTrainedHandwritingIsUsedWhenEveryLetterIsTrained() throws {
        var profile = HandwritingProfile()
        let glyph = PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: [
            PKStrokePoint(location: .zero, timeOffset: 0, size: CGSize(width: 2, height: 2), opacity: 1, force: 1, azimuth: 0, altitude: 1),
            PKStrokePoint(location: CGPoint(x: 10, y: 30), timeOffset: 0.1, size: CGSize(width: 2, height: 2), opacity: 1, force: 1, azimuth: 0, altitude: 1),
        ], creationDate: Date()))])
        profile.glyphs["l"] = [glyph.dataRepresentation()]
        let trained = PKStrokeSynthesizer(anchor: .init(x: 40, y: 40), pageSize: page, style: SynthInkStyle(), profile: profile, seed: 5).strokes(for: "ll")
        XCTAssertEqual(trained.count, 2)
        XCTAssertEqual(trained.first?.path.count, 2, "the trained glyph's own points are used")
        let fallback = PKStrokeSynthesizer(anchor: .init(x: 40, y: 40), pageSize: page, style: SynthInkStyle(), profile: profile, seed: 5).strokes(for: "lo")
        XCTAssertGreaterThan(fallback.first?.path.count ?? 0, 2, "an untrained letter switches the whole word to the built-in font")
    }

    func testAnchorGoesBelowTheLastLine() {
        let writer = PKStrokeSynthesizer(anchor: CGPoint(x: 80, y: 200), pageSize: page, style: SynthInkStyle(), seed: 9)
        let drawing = PKDrawing(strokes: writer.strokes(for: "Notiz"))
        let anchor = PKStrokeSynthesizer.anchor(below: drawing, pageSize: page, style: SynthInkStyle())
        XCTAssertGreaterThan(anchor.y, drawing.bounds.maxY)
        XCTAssertEqual(anchor.x, drawing.bounds.minX, accuracy: 1)
        XCTAssertEqual(PKStrokeSynthesizer.anchor(below: PKDrawing(), pageSize: page, style: SynthInkStyle()), CGPoint(x: 60, y: 60))
    }

    // MARK: Voice activity detection

    private func tone(seconds: Double, amplitude: Float) -> [Float] {
        (0 ..< Int(seconds * 16_000)).map { amplitude * sin(Float($0) * 2 * .pi * 220 / 16_000) }
    }

    func testVoiceActivityDetectorEndsAfterAPauseAndTrimsSilence() async {
        var options = M3WhisperTranscriber.Options(); options.endSilence = 0.6
        let sink = SampleSink(options: options, onLevel: nil)
        let audio = tone(seconds: 0.6, amplitude: 0.0005) + tone(seconds: 1.0, amplitude: 0.2) + tone(seconds: 1.0, amplitude: 0.0005)
        for chunk in stride(from: 0, to: audio.count, by: 1024).map({ Array(audio[$0 ..< min($0 + 1024, audio.count)]) }) { sink.append(chunk) }
        let samples = await sink.result()
        let seconds = Double(samples.count) / 16_000
        XCTAssertEqual(seconds, 1.0 + 0.3 + 0.25, accuracy: 0.15, "speech plus 300 ms lead-in and 250 ms tail")
    }

    func testVoiceActivityDetectorReturnsNothingWithoutSpeech() async {
        var options = M3WhisperTranscriber.Options(); options.noSpeechTimeout = 1
        let sink = SampleSink(options: options, onLevel: nil)
        sink.append(tone(seconds: 1.2, amplitude: 0.0005))
        let samples = await sink.result()
        XCTAssertTrue(samples.isEmpty)
    }
}
