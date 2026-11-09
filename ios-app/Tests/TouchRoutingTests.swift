import XCTest
import SwiftUI
import UIKit
import PencilKit
@testable import NullMini

/// Hosts the real editor in a window and asks UIKit where a touch on the page lands.
/// Unit tests cannot create UITouch objects, so this checks the two things that decide
/// whether writing reaches the ink layer: hit-testing and gesture recognizers that can
/// claim a one-touch drag before the ink view sees it.
@MainActor final class TouchRoutingTests: XCTestCase {
    private func allViews(_ root: UIView) -> [UIView] { [root] + root.subviews.flatMap(allViews) }
    private func chain(_ view: UIView?) -> String {
        var parts: [String] = []; var v = view
        while let current = v, parts.count < 14 { parts.append(String(describing: type(of: current))); v = current.superview }
        return parts.joined(separator: " < ")
    }

    /// Darkest pixel (r+g+b) in a small box of the rendered window, so 765 means pure white.
    private func darkest(_ window: UIView, around point: CGPoint) -> Int {
        let box = CGRect(x: point.x - 40, y: point.y - 12, width: 80, height: 24)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: box.size, format: format).image { context in
            context.cgContext.translateBy(x: -box.minX, y: -box.minY)
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard let cg = image.cgImage else { return 765 }
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var best = 765
        for i in stride(from: 0, to: pixels.count, by: 4) { best = min(best, Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])) }
        return best
    }

    /// Number of partly grey pixels (neither ink nor paper) in a 2x-scale column through `column`.
    private func edgePixels(_ view: UIView, column point: CGPoint) -> Int {
        let box = CGRect(x: point.x, y: point.y - 30, width: 1, height: 60)
        let format = UIGraphicsImageRendererFormat(); format.scale = 2
        let image = UIGraphicsImageRenderer(size: box.size, format: format).image { context in
            context.cgContext.translateBy(x: -box.minX, y: -box.minY)
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        guard let cg = image.cgImage else { return 99 }
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var grey = 0
        for y in 0..<height { let i = y * width * 4; let sum = Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2]); if sum > 120 && sum < 560 { grey += 1 } }
        return grey
    }

    func testPageTouchLandsOnInkLayerForPencilAndFinger() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = ToolSettingsStore.load()
        defer { ToolSettingsStore.save(saved) }
        let store = LibraryStore(root: root)
        let book = try XCTUnwrap(store.items.first(where: { !$0.folder }))
        store.open(book.id)
        for (round, finger) in [false, true].enumerated() {
            var settings = ToolSettings(); settings.tool = .pen; settings.finger = finger; settings.width = 4
            ToolSettingsStore.save(settings)
            let host = UIHostingController(rootView: AnyView(EditorView(bookID: book.id).environmentObject(store).preferredColorScheme(.dark)))
            host.overrideUserInterfaceStyle = .dark
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1180, height: 820))
            window.rootViewController = host; window.makeKeyAndVisible()
            host.view.frame = window.bounds; host.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 800_000_000)
            host.view.layoutIfNeeded()

            let canvases = allViews(window).compactMap { $0 as? PageInkCanvas }.filter { $0.window != nil && !$0.isHidden }
            let canvas = try XCTUnwrap(canvases.first, "finger=\(finger): no visible page canvas in the editor")
            XCTAssertTrue(canvas.isUserInteractionEnabled, "finger=\(finger): page canvas does not accept input")
            // PencilKit's own recognizer takes the Pencil (the only route proven on the device); the engine
            // restyles finished strokes, so its live recognizer must stay off to avoid a second stroke.
            XCTAssertTrue(canvas.drawingGestureRecognizer.isEnabled, "finger=\(finger): PencilKit does not take the Pencil")
            let recognizer = canvas.gestureRecognizers?.compactMap { $0 as? InkTouchRecognizer }.first
            XCTAssertFalse(recognizer?.isEnabled ?? false, "finger=\(finger): two input routes would each draw a stroke")
            let types = StylusInputPolicy.drawingTouches(finger: finger, pencilConnected: false)
            XCTAssertTrue(types.contains(.pencil), "finger=\(finger): Pencil is not allowed to draw")
            if finger { XCTAssertTrue(types.contains(.direct), "finger mode: fingers and passive styluses are not allowed to draw") }
            // Zoom in like a pinch would: the ink must re-render at that zoom, not be scaled up.
            let notebook = try XCTUnwrap(allViews(window).compactMap { $0 as? NotebookViewport }.first)
            notebook.scroll.setZoomScale(2.5, animated: false)
            notebook.scrollViewDidEndZooming(notebook.scroll, with: nil, atScale: 2.5)
            host.view.layoutIfNeeded()
            let document = try XCTUnwrap(canvas.superview)
            // Sharp up to the live-ink pixel budget (8192 px on the long side).
            let longest = max(document.bounds.width, document.bounds.height) * (window.screen.scale)
            let expected = min(2.5, max(1, (8192 / longest * 4).rounded(.down) / 4))
            XCTAssertEqual(canvas.zoomScale, expected, accuracy: 0.01, "finger=\(finger): ink is not rendered at the on-screen zoom")
            XCTAssertEqual(canvas.frame.width, document.bounds.width, accuracy: 0.5, "finger=\(finger): sharp canvas no longer covers the page")
            XCTAssertEqual(canvas.frame.height, document.bounds.height, accuracy: 0.5)
            let pageOnScreen = document.convert(document.bounds, to: window)
            let pageTop = CGPoint(x: pageOnScreen.midX, y: max(pageOnScreen.minY, 0) + 300)
            notebook.scroll.contentOffset.x += pageOnScreen.midX - window.bounds.midX
            notebook.scroll.contentOffset.y += pageTop.y - window.bounds.midY
            host.view.layoutIfNeeded()
            let visible = canvas.convert(canvas.bounds, to: window).intersection(window.bounds.insetBy(dx: 0, dy: 120))
            XCTAssertFalse(visible.isNull || visible.isEmpty, "finger=\(finger): page canvas is not on screen")
            let point = CGPoint(x: visible.midX, y: visible.midY + CGFloat(round) * 60)
            let hit = window.hitTest(point, with: nil)
            XCTAssertTrue(hit?.isDescendant(of: canvas) == true, "finger=\(finger): touch at \(point) lands on \(chain(hit)) instead of the page canvas (\(chain(canvas)))")

            // Black ink on the page must render dark, not inverted to white by the dark app UI.
            let local = document.convert(point, from: window)
            var drawing = canvas.drawing
            drawing.strokes.append(StrokeFactory.stroke(points: (0...30).map { CGPoint(x: local.x - 15 + CGFloat($0), y: local.y) }, color: .black, width: 4))
            canvas.drawing = drawing
            try await Task.sleep(nanoseconds: 800_000_000)
            let dry = darkest(host.view, around: point)
            // A 4 pt line at 2.5x zoom is 20 screen pixels tall; rendered sharply its edges are ~1 px of grey each,
            // while 2x ink scaled up 2.5x smears each edge over several pixels.
            let grey = edgePixels(host.view, column: point)
            XCTAssertLessThanOrEqual(grey, 6, "finger=\(finger): zoomed ink looks blurry (\(grey) grey edge pixels)")
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let screen = UIGraphicsImageRenderer(size: host.view.bounds.size, format: format).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
            let shot = XCTAttachment(image: screen); shot.name = "touch-routing-finger-\(finger)"; shot.lifetime = .keepAlways; add(shot)
            XCTAssertLessThan(dry, 300, "finger=\(finger): black ink is invisible on the page (darkest pixel sum \(dry), white = 765)")
            window.isHidden = true; window.rootViewController = nil
        }
    }
}
