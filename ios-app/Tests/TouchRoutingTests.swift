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

    func testPageTouchLandsOnInkLayerForPencilAndFinger() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = ToolSettingsStore.load()
        defer { ToolSettingsStore.save(saved) }
        let store = LibraryStore(root: root)
        let book = try XCTUnwrap(store.items.first(where: { !$0.folder }))
        store.open(book.id)
        for finger in [false, true] {
            var settings = ToolSettings(); settings.tool = .pen; settings.finger = finger
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
                for g in current.gestureRecognizers ?? [] where g.isEnabled && g.cancelsTouchesInView {
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
            window.isHidden = true
        }
    }
}
