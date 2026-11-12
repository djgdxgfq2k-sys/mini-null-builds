import SwiftUI
import UIKit

@main @MainActor struct NullMiniApp: App {
    @StateObject private var store = LibraryStore()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store).preferredColorScheme(.dark).tint(Theme.accent)
                .onOpenURL { url in
                    Task {
                        do { let item = try await NotebookArchive.importAsync(url, into:store,parent:nil); store.open(item.id) }
                        catch { store.error = error.localizedDescription }
                    }
                }
                .onAppear {
                    if ProcessInfo.processInfo.arguments.contains("--notebook"), let item = store.items.first(where: { !$0.folder }) { store.open(item.id) }
                    ScreenshotRun.startIfRequested()
                    HangMonitor.shared.start()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { do { try store.save() } catch { store.error = error.localizedDescription } }
                }
        }
        // A second window shows one notebook on its own, e.g. next to another one in Split View.
        WindowGroup("Notizbuch", id: "notebook", for: NotebookWindowTarget.self) { $target in
            if let target, store.item(target.bookID) != nil {
                NotebookWindow(target: target).environmentObject(store).preferredColorScheme(.dark).tint(Theme.accent)
            }
        }
    }
}

struct NotebookWindowTarget: Codable, Hashable { let bookID: String; let pageID: String }

@MainActor struct NotebookWindow: View {
    let target: NotebookWindowTarget
    @EnvironmentObject private var store: LibraryStore
    var body: some View {
        EditorView(bookID: target.bookID, separateWindow: true, initialPageID: target.pageID)
            .alert("Hinweis", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("OK") { store.error = nil } } message: { Text(store.error ?? "") }
    }
}

@MainActor struct RootView: View {
    @EnvironmentObject private var store: LibraryStore
    var body: some View {
        ZStack {
            // The library stays alive under an open notebook, so closing it returns to the same folder and scroll position.
            LibraryView()
                .scaleEffect(store.active == nil ? 1 : 0.97)
                .allowsHitTesting(store.active == nil).accessibilityHidden(store.active != nil)
            if let item = store.item(store.active) {
                // Opening zooms the notebook out of the card that was tapped, closing zooms it back.
                EditorView(bookID:item.id).id(item.id)
                    .transition(.scale(scale: 0.12, anchor: store.openAnchor).combined(with: .opacity))
                    .zIndex(1)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.9), value: store.active)
        .onChange(of: store.active, initial: true) { _, id in HangMonitor.shared.context = id == nil ? "library" : "editor \(store.item(id)?.pages.count ?? 0) pages" }
        .alert("Hinweis",isPresented:Binding(get:{ store.error != nil },set:{ if !$0 {store.error = nil} })) { Button("OK") { store.error = nil } } message: { Text(store.error ?? "") }
    }
}

@MainActor final class ScreenshotRun: NSObject {
    private static var runner: ScreenshotRun?
    private var link: CADisplayLink?
    private var frames = 0
    private let destination: String
    init(destination:String) { self.destination = destination }
    static func startIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard runner == nil, let index = args.firstIndex(of:"--screenshot"), index+1 < args.count else { return }
        let r = ScreenshotRun(destination:args[index+1]); runner = r
        r.link = CADisplayLink(target:r,selector:#selector(tick)); r.link?.add(to:.main,forMode:.common)
    }
    @objc private func tick() {
        frames += 1; guard frames >= 120 else { return }
        link?.invalidate()
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow) else { exit(2) }
        let renderer = UIGraphicsImageRenderer(bounds:window.bounds)
        let picture = renderer.image { _ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true) }
        do {
            let url = URL(fileURLWithPath:destination)
            try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
            guard let png = picture.pngData() else { exit(3) }
            try png.write(to:url,options:.atomic); exit(0)
        } catch { fputs("Screenshot failed: \(error)\n",stderr); exit(4) }
    }
}
