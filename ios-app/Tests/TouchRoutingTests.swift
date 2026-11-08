import XCTest
import SwiftUI
import UIKit
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

    func testPageTouchLandsOnInkLayerForPencilAndFinger() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = ToolSettingsStore.load()
        defer { ToolSettingsStore.save(saved) }
        let store = LibraryStore(root: root)
        let book = try XCTUnwrap(store.items.first(where: { !$0.folder }))
        store.open(book.id)
        for finger in [false, true] {
            var settings = ToolSettings(); settings.tool = .pen; settings.finger = finger; settings.width = 4
            ToolSettingsStore.save(settings)
            let host = UIHostingController(rootView: AnyView(EditorView(bookID: book.id).environmentObject(store).preferredColorScheme(.dark)))
            host.overrideUserInterfaceStyle = .dark
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1180, height: 820))
            window.rootViewController = host; window.makeKeyAndVisible()
            host.view.frame = window.bounds; host.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 800_000_000)
            host.view.layoutIfNeeded()

            let inks = allViews(window).compactMap { $0 as? InkInputView }.filter { $0.window != nil && !$0.isHidden }
            let ink = try XCTUnwrap(inks.first, "finger=\(finger): no visible InkInputView in the editor")
            XCTAssertTrue(ink.isUserInteractionEnabled, "finger=\(finger): ink layer has interaction disabled")
            let visible = ink.convert(ink.bounds, to: window).intersection(window.bounds.insetBy(dx: 0, dy: 120))
            XCTAssertFalse(visible.isNull || visible.isEmpty, "finger=\(finger): ink layer is not on screen: \(ink.convert(ink.bounds, to: window))")
            let point = CGPoint(x: visible.midX, y: visible.midY)
            let hit = window.hitTest(point, with: nil)
            XCTAssertTrue(hit === ink, "finger=\(finger): touch at \(point) lands on \(chain(hit)) instead of InkInputView (\(chain(ink)))")

            // Recognizers on the ink view or its ancestors that could take a one-finger or Pencil drag.
            var claims: [String] = []
            var view: UIView? = ink
            while let current = view {
                for g in current.gestureRecognizers ?? [] where g.isEnabled && g.cancelsTouchesInView
                    && (g is UIPanGestureRecognizer || g is UILongPressGestureRecognizer || g is UISwipeGestureRecognizer)
                    && !String(describing: type(of: g)).hasPrefix("_") && !String(describing: type(of: g)).contains("Knob") {
                    let types = g.allowedTouchTypes.map { $0.intValue }
                    let pencil = types.contains(UITouch.TouchType.pencil.rawValue)
                    let direct = types.contains(UITouch.TouchType.direct.rawValue)
                    let minimum = (g as? UIPanGestureRecognizer)?.minimumNumberOfTouches ?? 1
                    let claimsPencil = pencil && minimum == 1 && !(g is UITapGestureRecognizer)
                    let claimsFinger = finger && direct && minimum == 1 && !(g is UITapGestureRecognizer)
                    if (claimsPencil || claimsFinger) && current !== ink {
                        claims.append("\(type(of: g)) on \(type(of: current)) types=\(types) min=\(minimum)")
                    }
                }
                view = current.superview
            }
            XCTAssertTrue(claims.isEmpty, "finger=\(finger): drags can be taken away from the ink layer by: \(claims.joined(separator: "; "))")

            // Draw through the same entry points touches use, then look at the real screen pixels.
            let start = ink.convert(point, from: window)
            let source: UITouch.TouchType = finger ? .direct : .pencil
            ink.beginStroke(InkSample(point: CGPoint(x: start.x - 60, y: start.y), time: 0), source: source)
            ink.addSamples((1...30).map { InkSample(point: CGPoint(x: start.x - 60 + CGFloat($0) * 4, y: start.y), time: Double($0) / 120) })
            let wet = darkest(host.view, around: point)
            ink.endStroke()
            try await Task.sleep(nanoseconds: 600_000_000)
            let dry = darkest(host.view, around: point)
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let screen = UIGraphicsImageRenderer(size: host.view.bounds.size, format: format).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
            let shot = XCTAttachment(image: screen); shot.name = "touch-routing-finger-\(finger)-at-\(Int(point.x))x\(Int(point.y))"; shot.lifetime = .keepAlways; add(shot)
            let layers = allViews(ink.superview ?? ink).map { "\(type(of: $0)) hidden=\($0.isHidden) alpha=\($0.alpha) frame=\($0.frame.integral)" }.joined(separator: " | ")
            let canvasStrokes = allViews(window).compactMap { $0 as? PageInkCanvas }.map { $0.drawing.strokes.count }
            print("TOUCHDIAG finger=\(finger) wet=\(wet) dry=\(dry) canvasStrokes=\(canvasStrokes) style=\(ink.traitCollection.userInterfaceStyle.rawValue) layers: \(layers)")
            XCTAssertLessThan(wet, 300, "finger=\(finger): stroke is invisible while drawing (darkest pixel sum \(wet), white = 765)")
            XCTAssertLessThan(dry, 300, "finger=\(finger): stroke is invisible after lifting (darkest pixel sum \(dry), white = 765)")
            window.isHidden = true
        }
    }
}
