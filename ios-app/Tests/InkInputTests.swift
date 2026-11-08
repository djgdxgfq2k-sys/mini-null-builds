import XCTest
import PencilKit
import UIKit
@testable import NullMini

@MainActor final class InkInputTests: XCTestCase {
    override func setUp() async throws { try await super.setUp(); InkInputView.acceptsInput = true }
    override func tearDown() async throws { InkInputView.acceptsInput = false; try await super.tearDown() }
    private func line(y: CGFloat = 50, force: CGFloat = 0.5) -> [InkSample] {
        (0...40).map { i in InkSample(point: CGPoint(x: CGFloat(10 + i * 5), y: y), time: Double(i) / 120, force: force, altitude: 0.8, azimuth: 0.4) }
    }
    private func build(_ samples: [InkSample], _ settings: ToolSettings) -> [PKStroke] { InkBuilder.strokes(samples, settings: settings, creationDate: Date(timeIntervalSince1970: 0), seed: 42) }
    func testPenTypesPressureTiltAndBrushTipAffectNativeInk() throws {
        let samples = (0...20).map { i in InkSample(point: CGPoint(x: 10 + i * 5, y: 50), time: Double(i) / 120, force: CGFloat(i) / 20, altitude: 0.8, azimuth: 0.4) }
        var settings = ToolSettings(); settings.width = 10; settings.stabilization = 0; settings.pressure = 1
        let ball = try XCTUnwrap(build(samples, settings).first)
        XCTAssertEqual(ball.ink.inkType, .pen)
        XCTAssertTrue(ball.path.allSatisfy { $0.size.width == 10 })
        settings.penStyle = .fountain
        let fountain = try XCTUnwrap(build(samples, settings).first)
        XCTAssertEqual(fountain.ink.inkType, .fountainPen)
        XCTAssertGreaterThan(try XCTUnwrap(fountain.path.last).size.width, try XCTUnwrap(fountain.path.first).size.width * 5)
        XCTAssertEqual(fountain.path[10].altitude, 0.8, accuracy: 0.001); XCTAssertEqual(fountain.path[10].azimuth, 0.4, accuracy: 0.001)
        settings.penStyle = .brush; settings.pressure = 0; settings.sharpness = 1
        let brush = try XCTUnwrap(build(samples, settings).first)
        XCTAssertEqual(brush.ink.inkType, .pen); XCTAssertLessThan(brush.path[0].size.width, brush.path[10].size.width / 2)
        settings.tool = .pencil
        XCTAssertEqual(build(samples, settings).first?.ink.inkType, .pencil)
        settings.tool = .marker
        XCTAssertEqual(build(samples, settings).first?.ink.inkType, .marker)
    }
    func testStabilizationReducesJitterAndPreservesEndpoints() throws {
        var samples: [InkSample] = []
        for i in 0...40 { let x = CGFloat(10 + i * 3), y: CGFloat = i % 2 == 0 ? 53 : 47; samples.append(InkSample(point: CGPoint(x: x, y: y), time: Double(i) / 120)) }
        var settings = ToolSettings(); settings.stabilization = 0
        let raw = try XCTUnwrap(build(samples, settings).first)
        settings.stabilization = 1
        let smooth = try XCTUnwrap(build(samples, settings).first)
        func error(_ stroke: PKStroke) -> CGFloat { stroke.path.dropFirst().dropLast().reduce(0) { $0 + pow($1.location.y - 50, 2) } }
        XCTAssertLessThan(error(smooth), error(raw) / 2)
        XCTAssertEqual(smooth.path.first?.location, samples.first?.point); XCTAssertEqual(smooth.path.last?.location, samples.last?.point)
    }
    func testMinimumSensitivityStillRespondsAndNibControlsAffectInk() throws {
        var settings = ToolSettings(); settings.penStyle = .fountain; settings.pressure = 0; settings.sharpness = 0; settings.width = 10; settings.stabilization = 0
        let light = try XCTUnwrap(build(line(force: 0.1), settings).first)
        let firm = try XCTUnwrap(build(line(force: 0.9), settings).first)
        XCTAssertGreaterThan(firm.path[10].size.width, light.path[10].size.width)
        settings.tipRoundness = 0
        let flat = try XCTUnwrap(build(line(), settings).first)
        settings.tipRoundness = 1
        let round = try XCTUnwrap(build(line(), settings).first)
        XCTAssertLessThan(flat.path[10].size.height, round.path[10].size.height)
        var rolled = line(); for i in rolled.indices { rolled[i].roll = 0.7 }
        let fixed = try XCTUnwrap(build(rolled, settings).first); settings.barrelRoll = true
        let rotating = try XCTUnwrap(build(rolled, settings).first)
        XCTAssertEqual(rotating.path[10].azimuth - fixed.path[10].azimuth, 0.7, accuracy: 0.001)
        settings.reactToSpeed = true
        var slow = line(), fast = line()
        for i in slow.indices { slow[i].time = Double(i) / 10; fast[i].time = Double(i) / 1000 }
        XCTAssertGreaterThan(try XCTUnwrap(build(slow, settings).first).path[10].size.width, try XCTUnwrap(build(fast, settings).first).path[10].size.width)
    }
    func testStraightMarkerAndPatternedPenRenderAndSurviveSerialization() throws {
        var samples: [InkSample] = []
        for i in 0...40 { let x = CGFloat(10 + i * 5), y: CGFloat = i % 2 == 0 ? 54 : 46; samples.append(InkSample(point: CGPoint(x: x, y: y), time: Double(i) / 120)) }
        var settings = ToolSettings(); settings.tool = .marker; settings.straightHighlighter = true
        let marker = try XCTUnwrap(build(samples, settings).first)
        XCTAssertTrue(marker.path.allSatisfy { abs($0.location.y - 54) < 0.01 })
        settings.tool = .pen; settings.width = 2; settings.stabilization = 0; settings.strokePattern = .dashed
        let dashed = try PKDrawing(data: PKDrawing(strokes: build(line(), settings)).dataRepresentation())
        XCTAssertGreaterThan(dashed.strokes.count, 5)
        let pixels = try raster(dashed)
        XCTAssertGreaterThan(pixels[(50 * 240 + 14) * 4 + 3], 0)
        XCTAssertEqual(pixels[(50 * 240 + 20) * 4 + 3], 0, "The saved dashed pen has no visible gap")
        settings.strokePattern = .dotted
        let dotted = try PKDrawing(data: PKDrawing(strokes: build(line(), settings)).dataRepresentation())
        let dots = try raster(dotted)
        XCTAssertGreaterThan(dots[(50 * 240 + 10) * 4 + 3], 0)
        XCTAssertEqual(dots[(50 * 240 + 13) * 4 + 3], 0, "The saved dotted pen has no visible gap")
        let attachment = XCTAttachment(image: dashed.image(from: CGRect(x: 0, y: 0, width: 240, height: 100), scale: 2)); attachment.name = "synthetic-dashed-pen"; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testPredictionsStayOutOfSavedInkAndUndoRestoresPreviousDrawing() async throws {
        let original = StrokeFactory.stroke(points: [.zero, CGPoint(x: 20, y: 20)], color: .red, width: 2)
        let (root, page, commands, coordinator, view) = try workspace(initial: [original])
        defer { try? FileManager.default.removeItem(at: root) }
        let before = coordinator.drawing.dataRepresentation(), manager = try XCTUnwrap(view.canvas.undoManager)
        var settings = ToolSettings(); settings.strokePattern = .dashed; coordinator.configure(settings)
        manager.beginUndoGrouping()
        view.inkInput.beginStroke(InkSample(point: CGPoint(x: 20, y: 50), time: 0))
        view.inkInput.addSamples([InkSample(point: CGPoint(x: 100, y: 50), time: 1)], predicted: [InkSample(point: CGPoint(x: 900, y: 50), time: 2)])
        XCTAssertEqual(coordinator.drawing.dataRepresentation(), before)
        var deferred = false; commands.afterInput { deferred = true }; XCTAssertFalse(deferred)
        view.inkInput.endStroke(); await drained(); manager.endUndoGrouping()
        XCTAssertTrue(deferred); XCTAssertGreaterThan(coordinator.drawing.strokes.count, 2)
        XCTAssertLessThanOrEqual(coordinator.drawing.strokes.dropFirst().flatMap { $0.path.map(\.location.x) }.max() ?? 0, 100.01)
        let after = coordinator.drawing.dataRepresentation()
        let reloaded = try DrawingDisk.load(root, page.id)
        XCTAssertEqual(reloaded.strokes.count, coordinator.drawing.strokes.count)
        for (saved, live) in zip(reloaded.strokes, coordinator.drawing.strokes) {
            XCTAssertEqual(saved.ink.inkType, live.ink.inkType); XCTAssertEqual(saved.randomSeed, live.randomSeed)
            XCTAssertEqual(saved.path.count, live.path.count)
            for (a, b) in zip(saved.path, live.path) {
                XCTAssertEqual(a.location.x, b.location.x, accuracy: 0.005); XCTAssertEqual(a.location.y, b.location.y, accuracy: 0.005)
                XCTAssertEqual(a.size.width, b.size.width, accuracy: 0.005); XCTAssertEqual(a.force, b.force, accuracy: 0.005)
            }
        }
        XCTAssertTrue(try raster(reloaded) == raster(coordinator.drawing), "Native serialization changed the visible stroke")
        commands.undo(); XCTAssertEqual(coordinator.drawing.dataRepresentation(), before)
        commands.redo(); XCTAssertEqual(coordinator.drawing.dataRepresentation(), after)
    }
    func testCancelledInputAndReadOnlyDoNotCreateInk() async throws {
        let (root, _, _, coordinator, view) = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        view.inkInput.beginStroke(InkSample(point: .zero, time: 0)); view.inkInput.addSamples(line()); view.inkInput.cancelStroke(); await drained()
        XCTAssertTrue(coordinator.drawing.strokes.isEmpty); XCTAssertFalse(coordinator.usingTool)
        var settings = ToolSettings(); settings.readOnly = true; coordinator.configure(settings)
        view.inkInput.beginStroke(InkSample(point: .zero, time: 0)); view.inkInput.addSamples(line()); view.inkInput.endStroke()
        XCTAssertTrue(coordinator.drawing.strokes.isEmpty); XCTAssertFalse(view.inkInput.active)
    }
    func testPressurelessAndThirdPartyInputHaveUsableFallbacks() {
        XCTAssertEqual(StylusInputPolicy.force(type: .pencil, value: 1, maximum: 1, mode: .automatic), 0.5)
        XCTAssertEqual(StylusInputPolicy.force(type: .pencil, value: 0, maximum: 0, mode: .automatic), 0.5)
        XCTAssertEqual(StylusInputPolicy.force(type: .pencil, value: 3, maximum: 4, mode: .automatic), 0.75)
        XCTAssertEqual(StylusInputPolicy.force(type: .pencil, value: 0.3, maximum: 1, mode: .available), 0.3)
        XCTAssertEqual(StylusInputPolicy.force(type: .direct, value: 1, maximum: 4, mode: .automatic), 0.5)
        XCTAssertEqual(StylusInputPolicy.force(type: .indirectPointer, value: 1, maximum: 4, mode: .available), 0.25)
        XCTAssertEqual(StylusInputPolicy.force(type: .pencil, value: .nan, maximum: 4, mode: .automatic), 0.5)
        XCTAssertEqual(StylusInputPolicy.drawingTouches(finger: false, pencilConnected: true), [.pencil])
        XCTAssertEqual(StylusInputPolicy.drawingTouches(finger: true, pencilConnected: true), [.pencil, .direct, .indirectPointer])
        XCTAssertEqual(StylusInputPolicy.drawingTouches(finger: false, pencilConnected: false), [.direct, .indirectPointer])
    }
    func testPencilSuspendsPalmScrollingAndBackgroundSavesRealInput() async throws {
        let (root, page, _, coordinator, view) = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(view.scroll.panGestureRecognizer.isEnabled)
        view.inkInput.beginStroke(InkSample(point: .zero, time: 0), source: .pencil)
        XCTAssertFalse(view.scroll.panGestureRecognizer.isEnabled)
        view.inkInput.addSamples([InkSample(point: CGPoint(x: 60, y: 70), time: 1)])
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil); await drained()
        XCTAssertTrue(view.scroll.panGestureRecognizer.isEnabled); XCTAssertFalse(view.inkInput.active)
        XCTAssertEqual(coordinator.drawing.strokes.count, 1); XCTAssertEqual(try DrawingDisk.load(root, page.id).strokes.count, 1)
        view.inkInput.beginStroke(InkSample(point: .zero, time: 2), source: .direct)
        XCTAssertTrue(view.scroll.panGestureRecognizer.isEnabled); view.inkInput.cancelStroke()
        await drained()
        view.inkInput.beginStroke(InkSample(point: .zero, time: 3), source: .pencil)
        view.inkInput.addSamples([InkSample(point: CGPoint(x: 80, y: 90), time: 4)])
        view.inkInput.interruptStroke(source: .pencil); await drained()
        XCTAssertEqual(coordinator.drawing.strokes.count, 2, "Interrupted Pencil input must keep real samples")
    }
    func testEstimatedForceIsUpdatedBeforeCommitAndNextStrokeKeepsCommandsDeferred() async throws {
        let (root, _, commands, coordinator, view) = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = ToolSettings(); settings.penStyle = .fountain; settings.pressure = 1; settings.sharpness = 0; settings.width = 10; coordinator.configure(settings)
        view.inkInput.beginStroke(InkSample(point: .zero, time: 0, force: 0.1, estimateID: 1, awaitingUpdate: true))
        view.inkInput.addSamples([InkSample(point: CGPoint(x: 30, y: 30), time: 1, force: 0.1, estimateID: 2, awaitingUpdate: true)])
        view.inkInput.endStroke(); XCTAssertTrue(coordinator.drawing.strokes.isEmpty)
        view.inkInput.updateEstimate(InkSample(point: .zero, time: 0, force: 0.9, estimateID: 1))
        view.inkInput.updateEstimate(InkSample(point: CGPoint(x: 30, y: 30), time: 1, force: 0.9, estimateID: 2))
        XCTAssertEqual(try XCTUnwrap(coordinator.drawing.strokes.first?.path.first?.force), 0.9, accuracy: 0.001)
        XCTAssertGreaterThan(coordinator.drawing.strokes.first?.path.first?.size.width ?? 0, 10)
        view.inkInput.beginStroke(InkSample(point: CGPoint(x: 40, y: 40), time: 2))
        var deferred = false; commands.afterInput { deferred = true }; await drained()
        XCTAssertFalse(deferred); XCTAssertTrue(coordinator.usingTool)
        view.inkInput.addSamples([InkSample(point: CGPoint(x: 80, y: 80), time: 3)]); view.inkInput.endStroke(); await drained()
        XCTAssertTrue(deferred); XCTAssertEqual(coordinator.drawing.strokes.count, 2)
    }
    func testToolPreferencesPersistAndPartialOlderValuesKeepNewDefaults() throws {
        let name = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var settings = ToolSettings(); settings.penStyle = .brush; settings.strokePattern = .dotted; settings.color = "display-p3:#84DA69"; settings.widthPresets = [2, 4, 8]; settings.pressure = 0.8; settings.readOnly = true
        ToolSettingsStore.save(settings, defaults: defaults); settings.readOnly = false
        XCTAssertEqual(ToolSettingsStore.load(defaults: defaults), settings)
        let old = try JSONSerialization.data(withJSONObject: ["tool": "obsolete", "width": -2, "pressure": 5, "color": "#123456"])
        defaults.set(old, forKey: "nullmini.toolSettings.v1")
        let restored = ToolSettingsStore.load(defaults: defaults)
        XCTAssertEqual(restored.tool, .pen); XCTAssertEqual(restored.width, 0.1); XCTAssertEqual(restored.pressure, 1); XCTAssertEqual(restored.color, "#123456")
        XCTAssertEqual(restored.highlighterStabilization, 1); XCTAssertEqual(defaults.data(forKey: "nullmini.toolSettings.v1"), old)
        let styles = PenQuickStyleStore(defaults: defaults)
        settings.sharpness = 0.7; settings.tipRoundness = 0.2; settings.barrelRoll = true; styles.add(settings)
        let style = try XCTUnwrap(PenQuickStyleStore(defaults: defaults).styles.first)
        var applied = ToolSettings(); style.apply(to: &applied)
        XCTAssertEqual(applied.pressure, settings.pressure); XCTAssertEqual(applied.sharpness, settings.sharpness)
        XCTAssertEqual(applied.tipRoundness, settings.tipRoundness); XCTAssertEqual(applied.strokePattern, .dotted); XCTAssertTrue(applied.barrelRoll)
        let legacy = PenQuickStyle(color: "#123456", width: 2, style: .ballpoint)
        let encoded = try JSONEncoder().encode(legacy), decoded = try JSONDecoder().decode(PenQuickStyle.self, from: encoded)
        decoded.apply(to: &applied); XCTAssertEqual(applied.color, "#123456"); XCTAssertEqual(applied.pressure, settings.pressure)
    }
    func testTipShapeDoesNotDependOnInputSamplingRate() throws {
        var settings = ToolSettings(); settings.penStyle = .brush; settings.width = 10; settings.sharpness = 1; settings.stabilization = 0
        let dense = line()
        var sparse: [InkSample] = []
        for i in 0...20 { sparse.append(InkSample(point: CGPoint(x: CGFloat(10 + i * 10), y: 50), time: Double(i) / 60)) }
        let a = try XCTUnwrap(build(dense, settings).first), b = try XCTUnwrap(build(sparse, settings).first)
        XCTAssertEqual(a.path[2].location, b.path[1].location)
        XCTAssertEqual(a.path[2].size.width, b.path[1].size.width, accuracy: 0.001)
    }
    func testBlackInkStaysDarkOnPaperInDarkAppearance() throws {
        var settings = ToolSettings(); settings.width = 12; settings.color = "#000001"
        let drawing = PKDrawing(strokes: build(line(), settings))
        let rect = drawing.bounds.insetBy(dx: -4, dy: -4)
        var image = UIImage()
        UITraitCollection(userInterfaceStyle: .dark).performAsCurrent { image = drawing.paperImage(from: rect, scale: 1) }
        let center = CGPoint(x: drawing.bounds.midX - rect.minX, y: drawing.bounds.midY - rect.minY)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(UIColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        context.translateBy(x: -center.x, y: -(rect.height - center.y))
        context.draw(try XCTUnwrap(image.cgImage), in: CGRect(origin: .zero, size: rect.size))
        XCTAssertLessThan(Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2]), 200, "Black ink must not be inverted to white on the light page")
        let canvas = PageViewport(page: NotebookPage(), directory: FileManager.default.temporaryDirectory)
        XCTAssertEqual(canvas.document.overrideUserInterfaceStyle, .light)
    }
    func testModernInkTypesSurviveNativeSerialization() throws {
        for style in [PenStyle.ballpoint, .fountain] {
            var settings = ToolSettings(); settings.penStyle = style
            let drawing = PKDrawing(strokes: build(line(), settings))
            let restored = try PKDrawing(data: drawing.dataRepresentation())
            XCTAssertEqual(restored.strokes.first?.ink.inkType, drawing.strokes.first?.ink.inkType)
        }
    }
    private func workspace(initial: [PKStroke] = []) throws -> (URL, NotebookPage, CanvasCommands, CanvasSurface.Coordinator, PageViewport) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let page = NotebookPage(), commands = CanvasCommands()
        if !initial.isEmpty { try DrawingDisk.save(PKDrawing(strokes: initial), directory: root, page: page.id) }
        let coordinator = CanvasSurface.Coordinator(page: page, directory: root, commands: commands)
        let view = PageViewport(page: page, directory: root); view.frame = CGRect(x: 0, y: 0, width: 600, height: 900); view.layoutIfNeeded()
        coordinator.attach(view); coordinator.configure(ToolSettings())
        return (root, page, commands, coordinator, view)
    }
    private func drained() async { let done = expectation(description: "Input queue drained"); DispatchQueue.main.async { done.fulfill() }; await fulfillment(of: [done], timeout: 2) }
    private func raster(_ drawing: PKDrawing) throws -> [UInt8] {
        let image = try XCTUnwrap(drawing.image(from: CGRect(x: 0, y: 0, width: 240, height: 100), scale: 1).cgImage)
        var pixels = [UInt8](repeating: 0, count: 240 * 100 * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 240, height: 100, bitsPerComponent: 8, bytesPerRow: 960, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: 240, height: 100))
        }
        return pixels
    }
}
